import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct DraftAttachment: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: String
    var filename: String
    var mimeType: String
    var byteSize: Int
    var width: Int?
    var height: Int?
    var durationMS: Int?
}

struct ChatAttachment: Codable, Identifiable {
    var id: UUID
    var kind: String
    var url: URL?
    var mimeType: String
    var byteSize: Int
    var width: Int?
    var height: Int?
    var durationMS: Int?
    enum CodingKeys: String, CodingKey {
        case id, kind, url, width, height
        case mimeType = "mime_type", byteSize = "byte_size", durationMS = "duration_ms"
    }
    var displaySize: CGSize {
        guard let width, let height, width > 0, height > 0 else { return CGSize(width: 160, height: 120) }
        let scale = min(240 / CGFloat(width), 280 / CGFloat(height))
        return CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    }
}

enum AttachmentFiles {
    static func url(for draft: DraftAttachment) throws -> URL {
        let suffix = draft.kind == "image" ? "jpg" : "m4a"
        guard ["image", "audio"].contains(draft.kind), draft.filename == draft.id.uuidString + "." + suffix else {
            throw PalFailure(message: "This attachment is unavailable. Please select it again.")
        }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PalAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(draft.filename)
    }
    private static func persist(_ data: Data, draft: DraftAttachment) throws -> DraftAttachment {
        let destination = try url(for: draft)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var file = destination; try file.setResourceValues(values)
        return draft
    }
    static func prepare(imageData: Data) throws -> DraftAttachment {
        guard imageData.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw PalFailure(message: "Choose a smaller, readable photo.")
        }
        for quality in [0.85, 0.65, 0.45] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination), data.length <= 2 * 1024 * 1024 else { continue }
            let id = UUID()
            return try persist(data as Data, draft: DraftAttachment(id: id, kind: "image", filename: id.uuidString + ".jpg", mimeType: "image/jpeg", byteSize: data.length, width: image.width, height: image.height, durationMS: nil))
        }
        throw PalFailure(message: "This photo is too large to send. Choose another photo.")
    }
    static func prepareAudio(fileURL: URL) async throws -> DraftAttachment {
        guard fileURL.isFileURL else { throw PalFailure(message: "This recording is unavailable.") }
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, duration <= 60, !tracks.isEmpty else {
            throw PalFailure(message: "Record a voice message of up to 60 seconds.")
        }
        let descriptions = try await tracks[0].load(.formatDescriptions)
        guard !descriptions.isEmpty, descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else {
            throw PalFailure(message: "Record an AAC voice message in Pal.")
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count >= 12, String(data: data[4..<8], encoding: .ascii) == "ftyp" else {
            throw PalFailure(message: "This recording is not a readable M4A file.")
        }
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw PalFailure(message: "This recording is too large to send.") }
        let id = UUID()
        return try persist(data, draft: DraftAttachment(id: id, kind: "audio", filename: id.uuidString + ".m4a", mimeType: "audio/mp4", byteSize: data.count, width: nil, height: nil, durationMS: Int((duration * 1000).rounded())))
    }
    static func remove(_ draft: DraftAttachment) throws {
        let file = try url(for: draft)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
