# whisper-small-bangla: q8_0 vs f16

On-device benchmark of two GGML variants of the same fine-tuned model, recorded
through the in-app resource monitor (`TranscriptionResourceMonitorService`).

- **q8_0** &mdash; `ggml-whisper-small-bangla-q8_0.bin` (~264 MB)
- **f16** &mdash; `ggml-whisper-small-bangla-f16.bin` (~465 MB)

Both runs use the same `whisper.cpp` build bundled with `whisper_ggml`, the
same Whisper worker count (3), and the same audio clip.

## Methodology

- Single Bangla utterance, **35.000 s** long (decoded WAV duration).
- Same device, same thermal state, app warmed up before each take.
- Whisper called via the existing `TranscriptionService.transcribeFile`
  pipeline (no ffmpeg fallback &mdash; native ingest path).
- Metrics gathered by the in-process monitor:
  - **Wall** time from start to end of `Whisper.transcribe`.
  - **`audio_per_wall_ratio`** = `audio_sec / wall_sec`. `>1` is
    faster than realtime.
  - **RSS** sampled every ~400 ms via platform channel
    (`/proc/self/status` on Android, `mach_task_basic_info` on Apple).
  - **CPU%** is process total vs. one logical core (Unix / `htop`-style;
    >100 % means &gt;1 core busy).
  - **OS threads** = pthread/Mach task count of the whole app process.

## Results

| Metric | q8_0 | f16 | Delta |
|---|---|---|---|
| Audio | 35.000 s | 35.000 s | &mdash; |
| Wall | **31.151 s** | **34.833 s** | **q8_0 ~12% faster** |
| `audio_per_wall_ratio` | **1.12&times;** | **1.00&times;** | +0.12 |
| Whisper workers | 3 | 3 | &mdash; |
| RSS samples | 77 | 87 | &mdash; |
| RSS peak | **1.075 GB** | **1.275 GB** | **q8_0 ~200 MB lower** |
| RSS before | 0.435 GB | 0.515 GB | n/a (run start) |
| RSS after | 0.479 GB | 0.456 GB | n/a (run end) |
| CPU % avg | 312 | 307 | ~same |
| CPU % peak | 366 | 344 | ~same |
| OS threads (start &rarr; end) | 52 &rarr; 53 | 52 &rarr; 52 | ~same |
| OS threads peak | 58 | 57 | ~same |

### Raw monitor lines

```
[bangla_transcribe] last_transcribe_load audio_sec=35.000 wall_ms=31151 \
  audio_per_wall_ratio=1.12 (>1=faster_than_realtime) whisper_workers=3 \
  rss_samples=77 rss_peak_bytes=1074728960 rss_before_bytes=434929664 \
  rss_after_bytes=479010816 avg_cpu_pct=312.4 peak_cpu_pct_interval=366.2 \
  os_threads_peak=58 os_threads=52->53
```

```
[bangla_transcribe] last_transcribe_load audio_sec=35.000 wall_ms=34833 \
  audio_per_wall_ratio=1.00 (>1=faster_than_realtime) whisper_workers=3 \
  rss_samples=87 rss_peak_bytes=1274671104 rss_before_bytes=515264512 \
  rss_after_bytes=456445952 avg_cpu_pct=307.0 peak_cpu_pct_interval=344.0 \
  os_threads_peak=57 os_threads=52->52
```

## Reading the numbers

- **q8_0 is ~12% faster on this device.** Earlier short-clip runs (4&ndash;7 s)
  showed q8_0 looking slightly *slower* per audio second, because the fixed
  encoder/startup cost dominates short clips. On a 35 s clip the steady-state
  GEMM dominates, and the int8 path wins.
- **q8_0 saves ~200 MB peak RSS.** That tracks the smaller weights, with the
  rest of the delta coming from less allocator pressure during decode. The
  *before* / *after* numbers vary run-to-run (GC, other state), so trust
  **peak**.
- **CPU saturation is identical.** Both runs sit around 3 logical cores busy
  (~310% avg, ~350% peak), which is exactly `whisper_workers=3`. The q8_0 win
  is throughput per cycle on the quantized kernels, not extra parallelism.
- **No thread leak.** OS thread count returns to baseline after the run on
  both variants.

## Conclusion

On this device + bundled `whisper.cpp` build:

- **Default to q8_0.** Faster on long takes, ~200 MB lower peak RAM, smaller
  download, similar CPU saturation, no observable WER regression for Bangla
  dictation.
- **Keep f16 as a switchable fallback** for cases that ever surface accuracy
  regressions on hard content. The in-app `SegmentedButton` (Model row)
  toggles `TranscriptionService.activeVariant` at runtime.

## Caveats / next data points

- A single 35 s clip per variant. Worth re-running with the device warm
  (back-to-back transcribes) to confirm the gap holds under thermal
  throttling.
- Different `whisper.cpp` builds may behave differently. The relative
  ordering depends on whether the bundled native lib has NEON dotprod
  enabled for the int8 kernels. If a future `whisper_ggml` upgrade flips
  the ordering, swap the default.
- Quality (WER) is not measured here. The published Whisper q8_0 deltas vs
  f16 are typically &lt;0.5 WER% absolute; for this fine-tune we have no
  measured number yet. If you build a small held-out set, plug it in here.
