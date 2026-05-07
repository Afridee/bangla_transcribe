#!/usr/bin/env bash
# whisper_ggml (1.7.0): Android used `noexcept` on jsonToChar while calling
# json::dump(), which throws on invalid UTF-8 in transcript text → SIGABRT.
# This script patches the pub-cache copy after `dart pub get` / `flutter pub get`.
set -euo pipefail

PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
VER="whisper_ggml-1.7.0"
BASE="$PUB_CACHE/hosted/pub.dev/$VER"

patch_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "skip (missing): $f" >&2
    return 0
  fi
  if grep -q 'error_handler_t::replace' "$f"; then
    echo "already patched: $f"
    return 0
  fi
  echo "patching: $f"
  python3 - "$f" << 'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
# Android: drop noexcept and use replace handler
text = text.replace(
    """char *jsonToChar(json jsonData) noexcept
{
    std::string result = jsonData.dump();
    char *ch = new char[result.size() + 1];
    strcpy(ch, result.c_str());
    return ch;
}""",
    """char *jsonToChar(json jsonData)
{
    std::string result = jsonData.dump(
        -1, ' ', false, json::error_handler_t::replace);
    char *ch = new char[result.size() + 1];
    strcpy(ch, result.c_str());
    return ch;
}""",
)
# iOS / macOS: same dump() fix (no noexcept in upstream)
text = text.replace(
    """char *jsonToChar(json jsonData)
{
    std::string result = jsonData.dump();
    char *ch = new char[result.size() + 1];
    strcpy(ch, result.c_str());
    return ch;
}""",
    """char *jsonToChar(json jsonData)
{
    std::string result = jsonData.dump(
        -1, ' ', false, json::error_handler_t::replace);
    char *ch = new char[result.size() + 1];
    strcpy(ch, result.c_str());
    return ch;
}""",
)
path.write_text(text, encoding="utf-8")
PY
}

patch_file "$BASE/android/src/whisper/main.cpp"
patch_file "$BASE/ios/Classes/whisper_flutter_plus.cpp"
patch_file "$BASE/macos/Classes/whisper_ggml.cpp"
echo "Done. Rebuild the app (clean if needed) so native code recompiles."
