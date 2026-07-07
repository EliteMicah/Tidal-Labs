import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UIKit
#endif

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
    var isFavorite: Bool = false
    var cropRect: CGRect?          // normalized 0–1, origin top-left, nil = full frame
    var cropApplied: Bool = false
}

// Custom decode in an extension keeps the synthesized memberwise init + Encodable,
// while letting old sessions.json (missing the new keys) still decode.
extension WaveClip {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        date = try c.decode(Date.self, forKey: .date)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        cropRect = try c.decodeIfPresent(CGRect.self, forKey: .cropRect)
        cropApplied = try c.decodeIfPresent(Bool.self, forKey: .cropApplied) ?? false
    }
}

struct WaveSession: Identifiable, Codable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    var clips: [WaveClip]
    var name: String?
    var spotName: String?
    var isProcessing: Bool = false

    var displayName: String { name ?? WaveSession.timeOfDayName(for: startDate) }

    static func timeOfDayName(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<10: return "Dawn Patrol Session"
        case 10..<15: return "Lunch Session"
        case 15..<20: return "Afternoon Session"
        default: return "Overnight Session"
        }
    }
}

extension WaveSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        clips = try c.decode([WaveClip].self, forKey: .clips)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        spotName = try c.decodeIfPresent(String.self, forKey: .spotName)
        isProcessing = try c.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
    }
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
    case favorites
}

// MARK: - Pending Watch Session (received from watch, awaiting video import)

struct PendingWatchTimestamp: Codable {
    let id: String
    let start: Date
    let end: Date
}

struct GPSFix: Codable {
    let t: Double   // timeIntervalSince1970
    let lat: Double
    let lon: Double
}

struct PendingWatchSession: Codable {
    let id: String
    let startDate: Date
    let endDate: Date
    var timestamps: [PendingWatchTimestamp]
    var gpsTrack: [GPSFix] = []
}

extension PendingWatchSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        timestamps = try c.decode([PendingWatchTimestamp].self, forKey: .timestamps)
        gpsTrack = try c.decodeIfPresent([GPSFix].self, forKey: .gpsTrack) ?? []
    }
}

// MARK: - Pending Import Video (video held while waiting for watch sync)

struct PendingImportVideo {
    let asset: AVAsset
    let creationDate: Date
    let durationSeconds: TimeInterval
    var tempURL: URL? = nil  // set only when asset came from a loadTransferable copy
}

// MARK: - PHPickerViewController wrapper (reliable assetIdentifier + no full-file copy for PHAsset path)

#if canImport(UIKit)
struct VideoPicker: UIViewControllerRepresentable {
    let onProgress: (Double?) -> Void
    let onResult: (Result<(AVAsset, URL?, String?), Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProgress: onProgress, onResult: onResult) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onProgress: (Double?) -> Void
        let onResult: (Result<(AVAsset, URL?, String?), Error>) -> Void

        init(onProgress: @escaping (Double?) -> Void, onResult: @escaping (Result<(AVAsset, URL?, String?), Error>) -> Void) {
            self.onProgress = onProgress
            self.onResult = onResult
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            print("[VideoImport] PHPicker: assetIdentifier=\(result.assetIdentifier ?? "nil")")

            if let assetID = result.assetIdentifier {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                if let phAsset = assets.firstObject {
                    print("[VideoImport] PHPicker: PHAsset found, requesting AVAsset (no file copy)")
                    let opts = PHVideoRequestOptions()
                    opts.isNetworkAccessAllowed = true
                    opts.deliveryMode = .highQualityFormat
                    opts.progressHandler = { [weak self] progress, _, _, _ in
                        print("[VideoImport] PHPicker: iCloud progress \(progress)")
                        DispatchQueue.main.async { self?.onProgress(progress < 1.0 ? progress : nil) }
                    }
                    PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { [weak self] asset, _, info in
                        DispatchQueue.main.async { self?.onProgress(nil) }
                        if let avAsset = asset {
                            print("[VideoImport] PHPicker: AVAsset=\(type(of: avAsset)), no copy needed")
                            self?.onResult(.success((avAsset, nil, assetID)))
                        } else {
                            print("[VideoImport] PHPicker: requestAVAsset nil, trying item provider")
                            self?.loadFromItemProvider(result.itemProvider)
                        }
                    }
                    return
                }
                print("[VideoImport] PHPicker: PHAsset not found for id=\(assetID)")
            }

            print("[VideoImport] PHPicker: no assetIdentifier, using item provider (will copy file)")
            loadFromItemProvider(result.itemProvider)
        }

        private func loadFromItemProvider(_ provider: NSItemProvider) {
            let types: [UTType] = [.quickTimeMovie, .mpeg4Movie, .movie]
            guard let utType = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
                onResult(.failure(VideoPickerError.noVideo))
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: utType.identifier) { [weak self] url, error in
                if let error { self?.onResult(.failure(error)); return }
                guard let url else { self?.onResult(.failure(VideoPickerError.noVideo)); return }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    print("[VideoImport] PHPicker: item provider copy to \(dest.lastPathComponent)")
                    self?.onResult(.success((AVURLAsset(url: dest), dest, nil)))
                } catch {
                    self?.onResult(.failure(error))
                }
            }
        }

        enum VideoPickerError: Error { case noVideo }
    }
}
#endif

// MARK: - Video Import Transferable (fallback when Photos authorization unavailable)

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .quickTimeMovie) { v in
            SentTransferredFile(v.url)
        } importing: { received in
            try VideoTransferable.moveToTemp(received.file)
        }
        FileRepresentation(contentType: .mpeg4Movie) { v in
            SentTransferredFile(v.url)
        } importing: { received in
            try VideoTransferable.moveToTemp(received.file)
        }
        FileRepresentation(contentType: .movie) { v in
            SentTransferredFile(v.url)
        } importing: { received in
            try VideoTransferable.moveToTemp(received.file)
        }
    }

    private static func moveToTemp(_ source: URL) throws -> VideoTransferable {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        do {
            try FileManager.default.moveItem(at: source, to: dest)
        } catch {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return VideoTransferable(url: dest)
    }
}
