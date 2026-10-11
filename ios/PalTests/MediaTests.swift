import XCTest
import AVFoundation
import UIKit
import UniformTypeIdentifiers
@testable import Pal

final class MediaTests: XCTestCase {
    func testPhotoPreparationPersistsBoundedJPEGAndRejectsTraversal() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let draft = try AttachmentFiles.prepare(imageData: XCTUnwrap(image.pngData()))
        defer { try? AttachmentFiles.remove(draft) }
        let file = try AttachmentFiles.url(for: draft)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(draft.kind, "image")
        XCTAssertEqual(draft.mimeType, "image/jpeg")
        XCTAssertEqual(draft.byteSize, data.count)
        XCTAssertLessThanOrEqual(data.count, 2 * 1024 * 1024)
        XCTAssertEqual(draft.width, 1600)
        XCTAssertEqual(draft.height, 800)
        XCTAssertEqual(data.prefix(2), Data([0xff, 0xd8]))
        var invalid = draft; invalid.filename = "../outside.jpg"
        XCTAssertThrowsError(try AttachmentFiles.url(for: invalid))
        XCTAssertThrowsError(try AttachmentFiles.prepare(imageData: Data([0, 1, 2])))
    }

    @MainActor func testRecorderUsesAACAndLeavesPaddingBelowServerLimit() {
        XCTAssertEqual(VoiceRecorder.maximumDuration, 59)
        XCTAssertEqual(VoiceRecorder.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(VoiceRecorder.settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(VoiceRecorder.settings[AVEncoderBitRateKey] as? Int, 64_000)
    }

    func testAudioPreparationCopiesActualAACAndRejectsOverlongRecording() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: original) }
        try writeAAC(to: original, seconds: 1)
        let draft = try await AttachmentFiles.prepareAudio(fileURL: original)
        defer { try? AttachmentFiles.remove(draft) }
        XCTAssertEqual(draft.mimeType, "audio/mp4")
        XCTAssertNotEqual(try AttachmentFiles.url(for: draft), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try AttachmentFiles.url(for: draft).path))
        XCTAssertGreaterThan(try XCTUnwrap(draft.durationMS), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(draft.durationMS), 60_000)
        try FileManager.default.removeItem(at: original)
        try writeAAC(to: original, seconds: 61)
        do {
            let overlong = try await AttachmentFiles.prepareAudio(fileURL: original)
            try? AttachmentFiles.remove(overlong)
            XCTFail("Audio beyond 60 seconds must be rejected.")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    private func writeAAC(to url: URL, seconds: Int) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<44_100 { channel[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.05) }
        for _ in 0..<seconds { try file.write(from: buffer) }
    }
}
