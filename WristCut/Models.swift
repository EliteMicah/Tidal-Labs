import Foundation
import AVFoundation

// MARK: - Lens Model

struct CameraLens: Identifiable, Equatable {
    let id: String
    let label: String
    let deviceType: AVCaptureDevice.DeviceType
}

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
    case k2 = "2K"
    case k4 = "4K"
}

// MARK: - App Screen

enum AppScreen: Hashable {
    case settings
    case sessions
}
