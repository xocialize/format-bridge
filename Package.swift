// swift-tools-version: 5.9
import PackageDescription

// format-bridge — the media I/O + encode + measure foundation extracted from
// forge-studio-optimizer per ADR-0024 (extraction pin: forge @ fa146b5d). One package,
// remote-consumable (no path deps), four library products:
//
//   FFmpegXC     — LGPL-safe static ffmpeg 7.1.1 (decoders/demuxers FULLY enabled: WebM/MKV,
//                  VP8/VP9, AV1/dav1d, MPEG-2/4, Opus/Vorbis, …; encode: VideoToolbox,
//                  libvpx-VP9, in-process SVT-AV1). Binaries are NOT committed —
//                  run scripts/build-ffmpeg.sh once (see README).
//   FormatBridge — tier-routed video conversion (native AVFoundation fast path vs FFmpeg
//                  hybrid), probe, subtitle/metadata/timestamp migration, VideoToolbox +
//                  SVT-AV1 encoders, QualityTargetSearch/Encoder (VMAF-targeted), ShotDetector.
//   ImageBridge  — stills: ImageIO decode/encode (AVIF/HEIC/PNG/JPEG/TIFF), PDF rasterizer,
//                  animated GIF→MP4, alpha split, oxipng lossless, SSIMULACRA2, StillQualityTarget.
//   MediaMeasure — the measurement seam that shells out (kept OUT of FormatBridge by design):
//                  QualityMeasure (VMAF via ffmpeg+libvmaf, frame-exact reference recipe) +
//                  FFmpegVMAFScorer (the QualityScoring adapter the signage search consumes).
let package = Package(
    name: "format-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FFmpegXC", targets: ["FFmpegXC"]),
        .library(name: "FormatBridge", targets: ["FormatBridge"]),
        .library(name: "ImageBridge", targets: ["ImageBridge"]),
        .library(name: "MediaMeasure", targets: ["MediaMeasure"]),
        .executable(name: "imagebridge", targets: ["imagebridge-cli"]),
    ],
    targets: [
        .target(
            name: "FFmpegXC",
            path: "Sources/FFmpegXC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/Sources/FFmpegXC/lib",
                ]),
                .linkedLibrary("avformat"),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
                .linkedLibrary("swresample"),
                .linkedLibrary("dav1d"),
                .linkedLibrary("vpx"),
                .linkedLibrary("opus"),
                .linkedLibrary("SvtAv1Enc"),   // SVT-AV1 encoder (BSD)
                .linkedLibrary("c++"),         // SVT-AV1 is C++ → needs the C++ runtime
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("lzma"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "FormatBridge",
            dependencies: ["FFmpegXC"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "COxipng",
            path: "Sources/COxipng",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/Sources/COxipng/lib",
                ]),
                .linkedLibrary("oxipng_shim"),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "ImageBridge",
            dependencies: ["FormatBridge", "COxipng"]
        ),
        .target(
            name: "MediaMeasure",
            dependencies: ["FormatBridge"]
        ),
        .executableTarget(
            name: "imagebridge-cli",
            dependencies: ["ImageBridge"]
        ),
        .testTarget(
            name: "FormatBridgeTests",
            dependencies: ["FormatBridge"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ImageBridgeTests",
            dependencies: ["ImageBridge"]
        ),
    ]
)
