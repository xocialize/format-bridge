//
// FrameStreamTransform.swift
// FormatBridge
//
// The N:M streaming frame-transform path for ML video processing (MLXEngine Layer-2
// consolidation): tier-agnostic FFmpeg decode (native codecs ride VideoToolbox; non-native —
// WebM/MKV/VP9/AV1/MPEG-2… — decode in software) → BGRA conversion → an async transform that
// emits ZERO OR MORE output frames per input frame (1:1 upscale/restore, 1:N interpolation) →
// HEVC encode, always BT.709-tagged (forge #61). Frames stream one at a time so memory stays
// bounded; cancellation is checked per source frame.
//
// This replaces the per-consumer AVFoundation reader/writer copies that predated format-bridge
// (mlx-seedvr2-swift VideoIO, mlx-rife-swift InterpolatingVideoIO) — one decode path now serves
// native AND non-native sources. Video-only by design (both ML consumers drop audio today);
// audio passthrough belongs to the 1:1 ConversionOrchestrator path.
//

import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// N:M streaming frame transform: decode → transform (0+ outputs per input) → HEVC/BT.709.
public enum FrameStreamTransform {

    /// How output presentation timestamps are assigned.
    public enum Timing: Sendable {
        /// Keep each source frame's PTS (valid for 1:1 transforms).
        case preserveSource
        /// Re-time uniformly at `fps` (output index / fps) — for N:M transforms.
        case uniform(fps: Double)
    }

    public struct Output: Sendable {
        /// Source metadata (post-probe).
        public let sourceWidth: Int
        public let sourceHeight: Int
        public let sourceFrameRate: Double
        public let sourceDuration: Double
        /// Frames written.
        public let frameCount: Int
    }

    public enum TransformError: Error {
        case noVideoStream(String)
        case conversionFailed(String)
        case writeFailed(String)
        case noFramesDecoded
    }

    /// Stream-process `input` → `output`.
    ///
    /// - Parameters:
    ///   - transform: called once per decoded source frame (BGRA), returns the frames to append
    ///     (BGRA, any size — output dimensions lock from the first emitted frame). Return `[]`
    ///     to consume without emitting (e.g. priming a pairwise window).
    ///   - flush: called once after the last source frame — emit any tail frames (e.g. the
    ///     held `prev` of a pairwise transform).
    public static func run(
        input: URL,
        output: URL,
        timing: Timing = .preserveSource,
        transform: (CVPixelBuffer) async throws -> [CVPixelBuffer],
        flush: () async throws -> [CVPixelBuffer] = { [] }
    ) async throws -> Output {
        FormatBridgeFactory.initialize()

        // Probe: fps + stream index + dims (tier-agnostic — the FFmpeg decoder reads
        // native codecs via VideoToolbox and non-native ones in software).
        let info = try await FormatBridgeFactory.makeProbe().probe(url: input)
        guard let v = info.videoStreams.first else {
            throw TransformError.noVideoStream(input.lastPathComponent)
        }

        let decoder = FormatBridgeFactory.makeDecoder()
        try await decoder.open(url: input)
        try decoder.selectStreams(video: v.index, audio: -1)
        defer { decoder.close() }

        // BGRA conversion (decoder emits NV12/P010).
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard let transferSession = session else {
            throw TransformError.conversionFailed("VTPixelTransferSessionCreate")
        }
        var bgraPool: CVPixelBufferPool?

        func toBGRA(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
            if CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA { return src }
            let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
            if bgraPool == nil {
                CVPixelBufferPoolCreate(nil, nil, [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: w,
                    kCVPixelBufferHeightKey: h,
                    kCVPixelBufferIOSurfacePropertiesKey: [:],
                ] as CFDictionary, &bgraPool)
            }
            var dst: CVPixelBuffer?
            guard let pool = bgraPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
                  let dstPB = dst else {
                throw TransformError.conversionFailed("BGRA pool")
            }
            guard VTPixelTransferSessionTransferImage(transferSession, from: src, to: dstPB) == noErr else {
                throw TransformError.conversionFailed("VTPixelTransferSessionTransferImage")
            }
            return dstPB
        }

        // Lazy HEVC/BT.709 writer (dims from the first emitted frame).
        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var outIndex = 0
        let uniformDuration: CMTime? = {
            if case .uniform(let fps) = timing {
                let ts: CMTimeScale = 60_000
                return CMTime(value: CMTimeValue((Double(ts) / max(fps, 1)).rounded()), timescale: ts)
            }
            return nil
        }()

        func append(_ pb: CVPixelBuffer, sourcePTS: CMTime) async throws {
            if writer == nil {
                let ow = CVPixelBufferGetWidth(pb), oh = CVPixelBufferGetHeight(pb)
                let w = try AVAssetWriter(outputURL: output, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: ow,
                    AVVideoHeightKey: oh,
                    // BT.709, always tagged (forge #61).
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                    ],
                ])
                input.expectsMediaDataInRealTime = false
                let a = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: ow,
                        kCVPixelBufferHeightKey as String: oh,
                    ])
                w.add(input)
                guard w.startWriting() else {
                    throw TransformError.writeFailed(w.error?.localizedDescription ?? "startWriting")
                }
                w.startSession(atSourceTime: .zero)
                writer = w; writerInput = input; adaptor = a
            }
            guard let inp = writerInput, let adaptor else { return }
            // Video-only track: a bounded wait for readiness is safe (no cross-track interleave).
            while !inp.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                try Task.checkCancellation()
            }
            let t: CMTime
            if let d = uniformDuration {
                t = CMTimeMultiply(d, multiplier: Int32(outIndex))
            } else if sourcePTS.isValid && sourcePTS.isNumeric {
                t = sourcePTS
            } else {
                let fallback = CMTime(value: 1, timescale: CMTimeScale(max(v.frameRate, 1)))
                t = CMTimeMultiply(fallback, multiplier: Int32(outIndex))
            }
            guard adaptor.append(pb, withPresentationTime: t) else {
                throw TransformError.writeFailed(writer?.error?.localizedDescription ?? "append \(outIndex)")
            }
            outIndex += 1
        }

        // Decode → transform → append.
        while let frame = try await decoder.decodeNextVideoFrame() {
            try Task.checkCancellation()
            let bgra = try toBGRA(frame.pixelBuffer)
            for out in try await transform(bgra) {
                try await append(out, sourcePTS: frame.presentationTime)
            }
        }
        for out in try await flush() {
            try await append(out, sourcePTS: .invalid)
        }

        guard let writer, let writerInput else {
            throw TransformError.noFramesDecoded
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw TransformError.writeFailed(writer.error?.localizedDescription ?? "finishWriting")
        }

        return Output(sourceWidth: v.width, sourceHeight: v.height,
                      sourceFrameRate: v.frameRate,
                      sourceDuration: info.duration.seconds,
                      frameCount: outIndex)
    }
}
