# format-bridge

The **media I/O + encode + measure foundation** for Apple-Silicon media pipelines — extracted
from `xocialize/forge-studio-optimizer` per **ADR-0024** (extraction pin: forge `fa146b5d`).
This is Layer 2 of the MLXEngine cross-modal optimization service, and it exists to serve two
goals proven in Forge:

1. **Import what AVFoundation can't.** The vendored LGPL ffmpeg has decoders + demuxers FULLY
   enabled: WebM/MKV containers, VP8/VP9, AV1 (dav1d), MPEG-2/MPEG-4-era codecs, Opus/Vorbis,
   and everything else LGPL ffmpeg reads. A tier router probes each input and uses the native
   AVFoundation fast path when possible, the FFmpeg hybrid path when not.
2. **The signage-distribution goal:** large source videos → high-quality **same-scale** files
   suitable for internet distribution. `QualityTargetSearch` (ab-av1-style VMAF-targeted probe
   search) finds the smallest file clearing a perceptual floor — proven **63% smaller @
   VMAF ≥ 95** (79% @ ≥ 90) on signage corpora; SVT-AV1 opt-in lands ~44–53% below HEVC.

## Products

| Product | What it is |
|---|---|
| `FFmpegXC` | LGPL-safe static ffmpeg 7.1.1 (VideoToolbox/AudioToolbox, dav1d, libvpx, opus, **SVT-AV1 in-process**; muxers webm/matroska/mp4/ivf; `--disable-gpl --disable-nonfree`) |
| `FormatBridge` | Tier-routed video conversion: probe (`MediaInfo`, `isNativeApple`) → native fast path / FFmpeg hybrid; subtitle + metadata + timestamp migration; VideoToolbox (BT.709-tagged) + SVT-AV1 encoders; `QualityTargetSearch`/`QualityTargetEncoder`; `ShotDetector` |
| `ImageBridge` | Stills: ImageIO decode/encode (AVIF/HEIC/PNG/JPEG/TIFF), **PDF rasterizer**, animated **GIF→MP4**, alpha split, oxipng lossless, `SSIMULACRA2Scorer`, `StillQualityTarget` |
| `MediaMeasure` | The measurement seam that shells out (kept OUT of FormatBridge by design): `QualityMeasure` (frame-exact VMAF via ffmpeg+libvmaf) + `FFmpegVMAFScorer` (the `QualityScoring` adapter the search consumes) |
| `imagebridge` (CLI) | PDF→crisp raster + optimize; raster convert + optimize |

## One-time build of the vendored libraries

The static `.a` files are **not committed** (≈210 MB). After cloning:

```sh
./scripts/build-ffmpeg.sh    # ffmpeg 7.1.1 + dav1d + libvpx + opus + SVT-AV1 (~10 min)
./scripts/build-oxipng.sh    # oxipng Rust shim (needs rustup)
```

Outputs land in `Sources/FFmpegXC/lib/` and `Sources/COxipng/lib/`; SPM links them from there.

## Licensing

- Wrapper/Swift code: MIT.
- FFmpeg: **LGPL-2.1+ / LGPL-3** components only (`--disable-gpl --disable-nonfree`,
  `--enable-version3`). Static linking is used — apps that ship this must satisfy LGPL
  relink/object obligations (or switch the build to dylibs).
- SVT-AV1: BSD-3-Clause-Clear + Alliance for Open Media patent license. dav1d: BSD-2. libvpx:
  BSD-3. opus: BSD-3. oxipng: MIT.
- `MediaMeasure` shells out to an external `ffmpeg` binary with libvmaf (e.g. Homebrew) — it
  does not link libvmaf.

## Provenance

Seeded verbatim from forge-studio-optimizer `fa146b5d` (Packages/{FFmpegXC, FormatBridge,
Oxipng, ImageBridge} + ForgeOptimizer/Benchmark/{QualityMeasure, FFmpegVMAFScorer}); the only
changes are the merged single-package manifest (remote-consumable: no path deps), repo-root
build-script anchoring, and this README. Forge ADRs referenced: 0002, 0013–0015, 0017–0019,
0022, 0024.
