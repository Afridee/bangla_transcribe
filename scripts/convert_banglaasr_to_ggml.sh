#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# convert_banglaasr_to_ggml.sh
#
# Converts a Hugging Face Whisper-small (or compatible) checkpoint into
# quantized GGML .bin files for whisper.cpp / whisper_ggml on-device.
#
# Default source: bangla-speech-processing/BanglaASR. Override with HF_REPO,
# e.g. ashrafulparan/whisper-small-bangla.
#
# What it produces (artifact names depend on HF_REPO and QUANT):
#   BanglaASR + default QUANT=q5_0:
#     <workdir>/ggml-banglaasr-small-f16.bin, ggml-banglaasr-small-q5_0.bin
#   ashrafulparan/whisper-small-bangla + QUANT=q8_0:
#     <workdir>/ggml-whisper-small-bangla-f16.bin,
#               ggml-whisper-small-bangla-q8_0.bin
#   <workdir>/SHA256SUMS
#
# Optional: QUANT (default q5_0). Common values: q5_0, q8_0. Example 8-bit:
#   QUANT=q8_0 HF_REPO=ashrafulparan/whisper-small-bangla \
#     ./scripts/convert_banglaasr_to_ggml.sh ./build/wsb-q8
#
# Usage
#   chmod +x scripts/convert_banglaasr_to_ggml.sh
#   ./scripts/convert_banglaasr_to_ggml.sh              # BanglaASR, ./build/banglaasr
#   ./scripts/convert_banglaasr_to_ggml.sh /tmp/bn      # BanglaASR, custom workdir
#   HF_REPO=ashrafulparan/whisper-small-bangla \
#     ./scripts/convert_banglaasr_to_ggml.sh ./build/wsb
#
# Requirements (host machine — NOT the device)
#   * macOS or Linux with at least 6 GB free disk and 4 GB free RAM
#   * git, git-lfs, cmake, make, python3 (>=3.10), pip
#   * Network access to huggingface.co and github.com
#
# After it finishes: upload the quantized .bin (name includes QUANT, e.g. ...-q8_0.bin),
# note the sha256 from SHA256SUMS, and point TranscriptionService at both.
# ----------------------------------------------------------------------------
set -Eeuo pipefail

QUANT="${QUANT:-q5_0}"
HF_REPO="${HF_REPO:-bangla-speech-processing/BanglaASR}"
WORKDIR="${1:-$(pwd)/build/banglaasr}"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
cd "$WORKDIR"

REPO_SHORT="$(basename "$HF_REPO")"
if [[ "$HF_REPO" == "bangla-speech-processing/BanglaASR" ]]; then
  HF_MODEL_DIR="$WORKDIR/BanglaASR"
  ARTIFACT_STEM="banglaasr-small"
else
  HF_MODEL_DIR="$WORKDIR/$REPO_SHORT"
  ARTIFACT_STEM="$REPO_SHORT"
fi

WHISPER_CPP_DIR="$WORKDIR/whisper.cpp"
OPENAI_WHISPER_DIR="$WORKDIR/openai-whisper"
OUT_DIR="$WORKDIR/out"
VENV_DIR="$WORKDIR/.venv"

mkdir -p "$OUT_DIR"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mERR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 0. Sanity checks ------------------------------------------------------

command -v git    >/dev/null || fail "git not found"
command -v cmake  >/dev/null || fail "cmake not found (brew install cmake)"
command -v python3 >/dev/null || fail "python3 not found"
git lfs version  >/dev/null 2>&1 || fail "git-lfs not installed (brew install git-lfs && git lfs install)"

# ---- 1. Clone whisper.cpp (provides converter + quantize tool) -------------

if [ ! -d "$WHISPER_CPP_DIR/.git" ]; then
  log "Cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp "$WHISPER_CPP_DIR"
else
  log "whisper.cpp already cloned, skipping"
fi

# ---- 2. Clone openai/whisper (converter needs its mel_filters.npz) --------

if [ ! -d "$OPENAI_WHISPER_DIR/.git" ]; then
  log "Cloning openai/whisper (for assets the converter reads)"
  git clone --depth 1 https://github.com/openai/whisper "$OPENAI_WHISPER_DIR"
else
  log "openai/whisper already cloned, skipping"
fi

# ---- 3. git-lfs pull the Hugging Face weights ------------------------------

if [ ! -d "$HF_MODEL_DIR/.git" ]; then
  log "Cloning $HF_REPO (large git-lfs objects — first run can take a while)"
  GIT_LFS_SKIP_SMUDGE=0 git clone "https://huggingface.co/$HF_REPO" "$HF_MODEL_DIR"
else
  log "$REPO_SHORT already cloned, ensuring LFS files are present"
  (cd "$HF_MODEL_DIR" && git lfs pull)
fi

# Sanity: the converter needs pytorch_model.bin OR model.safetensors
if [ ! -f "$HF_MODEL_DIR/pytorch_model.bin" ] && [ ! -f "$HF_MODEL_DIR/model.safetensors" ]; then
  fail "Neither pytorch_model.bin nor model.safetensors found in $HF_MODEL_DIR — did git-lfs pull complete?"
fi

# ---- 4. Python venv with the converter's deps -----------------------------

if [ ! -d "$VENV_DIR" ]; then
  log "Creating Python venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

log "Installing converter Python dependencies (transformers, torch, numpy, tiktoken, more-itertools)"
pip install --upgrade pip wheel >/dev/null
pip install --quiet \
  "torch>=2.1" \
  "numpy<2" \
  "transformers>=4.40" \
  "tiktoken" \
  "more-itertools" \
  "sentencepiece"

# ---- 5. Run the HF -> GGML converter --------------------------------------

CONVERTER="$WHISPER_CPP_DIR/models/convert-h5-to-ggml.py"
[ -f "$CONVERTER" ] || fail "Converter script not found at $CONVERTER"

GGML_F16="$WORKDIR/ggml-${ARTIFACT_STEM}-f16.bin"

if [ -f "$GGML_F16" ]; then
  log "F16 GGML already exists at $GGML_F16, skipping converter"
else
  log "Running convert-h5-to-ggml.py ($HF_REPO)"
  # Args: <hf-model-dir> <openai-whisper-repo-checkout> <output-dir>
  python3 "$CONVERTER" "$HF_MODEL_DIR" "$OPENAI_WHISPER_DIR" "$OUT_DIR"

  RAW_F16="$OUT_DIR/ggml-model.bin"
  [ -f "$RAW_F16" ] || fail "Converter did not produce $RAW_F16"

  # Stable filename for distribution
  mv "$RAW_F16" "$GGML_F16"
fi
log "F16 GGML: $GGML_F16 ($(du -h "$GGML_F16" | awk '{print $1}'))"

# ---- 6. Build whisper.cpp's quantize tool ---------------------------------
#
# The exact target name has changed across whisper.cpp versions
# ("quantize" -> "whisper-quantize"). Rather than guess, just build the
# whole project (it's small) and then locate any *quantize* binary the
# build dropped into ./build.

log "Configuring whisper.cpp build"
cmake -S "$WHISPER_CPP_DIR" -B "$WHISPER_CPP_DIR/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DCMAKE_BUILD_TYPE=Release >/dev/null

log "Building whisper.cpp (full build, ~1-2 min)"
cmake --build "$WHISPER_CPP_DIR/build" --config Release -j

QUANTIZE_BIN="$(
  find "$WHISPER_CPP_DIR/build" -type f -perm -u+x \
       \( -name 'whisper-quantize' -o -name 'quantize' \) \
       -not -name '*.o' -not -name '*.a' \
       2>/dev/null | head -n1
)"
[ -n "$QUANTIZE_BIN" ] && [ -x "$QUANTIZE_BIN" ] \
  || fail "Could not locate compiled quantize binary under $WHISPER_CPP_DIR/build (try: ls $WHISPER_CPP_DIR/build/bin)"
log "Found quantize binary: $QUANTIZE_BIN"

# ---- 7. Quantize (e.g. q5_0 mobile default, q8_0 higher quality / larger) ---

GGML_QUANT="$WORKDIR/ggml-${ARTIFACT_STEM}-${QUANT}.bin"
if [ -f "$GGML_QUANT" ]; then
  log "Quantized GGML already exists at $GGML_QUANT, skipping quantize"
else
  log "Quantizing F16 → $QUANT"
  "$QUANTIZE_BIN" "$GGML_F16" "$GGML_QUANT" "$QUANT"
fi
log "$QUANT GGML: $GGML_QUANT ($(du -h "$GGML_QUANT" | awk '{print $1}'))"

# ---- 8. sha256 the artifacts ----------------------------------------------

cd "$WORKDIR"
{ shasum -a 256 "ggml-${ARTIFACT_STEM}-f16.bin" "ggml-${ARTIFACT_STEM}-${QUANT}.bin"; } > SHA256SUMS
log "Wrote $WORKDIR/SHA256SUMS:"
cat SHA256SUMS

_QUANT_SHA=$(shasum -a 256 "$GGML_QUANT" | awk '{print $1}')

# ---- 9. Done --------------------------------------------------------------

cat <<EOF

============================================================
DONE.

Ship this file to mobile users:
  $GGML_QUANT
  size:  $(du -h "$GGML_QUANT" | awk '{print $1}')
  sha256: $_QUANT_SHA

Next step:
  1. Upload $(basename "$GGML_QUANT") to a place the app can fetch:
       - HuggingFace dataset repo (free, public, supports 'resolve' URLs)
       - Cloudflare R2 / S3 / your own CDN
  2. Update TranscriptionService: url, filename, expectedSha256, approxSizeMB

HF_REPO=$HF_REPO  QUANT=$QUANT
============================================================
EOF
