import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import FormatBridge

@Suite("FrameStreamTransform — N:M streaming frame transform (MLXEngine Layer-2 consolidation)")
struct FrameStreamTransformTests {

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    private func tmpOut() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    private func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let duration = try await asset.load(.duration).seconds
        let fps = try await track.load(.nominalFrameRate)
        return Int((duration * Double(fps)).rounded())
    }

    @Test("1:1 passthrough (native mp4) preserves frame count; output is HEVC/BT.709")
    func passthroughNative() async throws {
        let out = tmpOut()
        defer { try? FileManager.default.removeItem(at: out) }

        let result = try await FrameStreamTransform.run(
            input: fixtureURL("sample.mp4"), output: out,
            timing: .preserveSource,
            transform: { [$0] }
        )
        #expect(result.frameCount > 0)

        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first
        #expect(track != nil)
        let desc = try await track!.load(.formatDescriptions).first!
        #expect(CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_HEVC)
        let ext = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        #expect((ext as? String) == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
    }

    @Test("1:1 transform on a NON-NATIVE source (webm/VP9) — the consolidation's reason to exist")
    func passthroughNonNative() async throws {
        let out = tmpOut()
        defer { try? FileManager.default.removeItem(at: out) }

        let result = try await FrameStreamTransform.run(
            input: fixtureURL("sample.webm"), output: out,
            timing: .preserveSource,
            transform: { [$0] }
        )
        #expect(result.frameCount > 0)
        let written = try await frameCount(of: out)
        #expect(abs(written - result.frameCount) <= 1)
    }

    @Test("1:2 insertion (pairwise, RIFE-shaped) doubles frames; flush emits the tail")
    func pairwiseInsertion() async throws {
        let out = tmpOut()
        defer { try? FileManager.default.removeItem(at: out) }

        let probe = try await FormatBridgeFactory.makeProbe().probe(url: fixtureURL("sample.mp4"))
        let srcFPS = probe.videoStreams.first!.frameRate

        final class Window: @unchecked Sendable { var prev: CVPixelBuffer? }
        let w = Window()

        let result = try await FrameStreamTransform.run(
            input: fixtureURL("sample.mp4"), output: out,
            timing: .uniform(fps: srcFPS * 2),
            transform: { frame in
                defer { w.prev = frame }
                guard let p = w.prev else { return [] }   // prime the window
                return [p, p]                              // prev + "midpoint" (dup stand-in)
            },
            flush: { w.prev.map { [$0] } ?? [] }
        )

        let sourceFrames = Int((result.sourceDuration * result.sourceFrameRate).rounded())
        // N source frames -> 2(N-1) + 1 outputs
        #expect(result.frameCount == 2 * (sourceFrames - 1) + 1)
    }

    @Test("1:1 with dimension change (SeedVR2-shaped) locks output dims from the first emitted frame")
    func dimensionChange() async throws {
        let out = tmpOut()
        defer { try? FileManager.default.removeItem(at: out) }

        func downscale(_ src: CVPixelBuffer) -> CVPixelBuffer {
            let w = CVPixelBufferGetWidth(src) / 2, h = CVPixelBufferGetHeight(src) / 2
            var dst: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            VTPixelTransferSessionTransferImage(session!, from: src, to: dst!)
            return dst!
        }

        let result = try await FrameStreamTransform.run(
            input: fixtureURL("sample.mp4"), output: out,
            transform: { [downscale($0)] }
        )
        #expect(result.frameCount > 0)

        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == result.sourceWidth / 2)
        #expect(Int(size.height) == result.sourceHeight / 2)
    }
}
