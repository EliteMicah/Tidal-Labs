import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Session Recording Model

struct SessionRecording: Identifiable {
    let id: UUID
    let url: URL
    let date: Date
}

// MARK: - Wave Session Models

struct WaveClip: Identifiable, Codable {
    let id: UUID
    let filename: String
    let date: Date
}

struct WaveSession: Identifiable, Codable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    var clips: [WaveClip]
}

// MARK: - Video Resolution

enum VideoResolution: String, CaseIterable {
    case p720 = "720p"
    case p1080 = "1080p"
    case k4 = "4K"
}

// MARK: - App Screen

enum AppScreen: Hashable {
    case settings
    case sessions
}

// MARK: - Pending Watch Session (received from watch, awaiting video import)

struct PendingWatchTimestamp: Codable {
    let id: String
    let start: Date
    let end: Date
}

struct PendingWatchSession: Codable {
    let id: String
    let startDate: Date
    let endDate: Date
    var timestamps: [PendingWatchTimestamp]
}

// MARK: - Pending Import Video (video held while waiting for watch sync)

struct PendingImportVideo {
    let url: URL
    let creationDate: Date
    let durationSeconds: TimeInterval
}

// MARK: - Video Import Transferable

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .quickTimeMovie) { v in
            SentTransferredFile(v.url)
        } importing: { received in
            try VideoTransferable.copyToTemp(received.file)
        }
        FileRepresentation(contentType: .mpeg4Movie) { v in
            SentTransferredFile(v.url)
        } importing: { received in
            try VideoTransferable.copyToTemp(received.file)
        }
        FileRepresentation(contentType: .movie) { v in
            SentTransferredFile(v.url)
        } importing: { received in
            try VideoTransferable.copyToTemp(received.file)
        }
    }

    private static func copyToTemp(_ source: URL) throws -> VideoTransferable {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return VideoTransferable(url: dest)
    }
}
