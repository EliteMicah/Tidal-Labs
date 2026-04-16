//
//  ContentView.swift
//  WristCut
//
//  Created by Micah Woodring on 4/11/26.
//

import SwiftUI
import AVFoundation
import CloudKit
import Photos
internal import Combine
internal import Combine
internal import Combine

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var session: AVCaptureSession? {
            get { previewLayer.session }
            set {
                previewLayer.session = newValue
                previewLayer.videoGravity = .resizeAspectFill
            }
        }
    }
}

// MARK: - Lens Model

struct CameraLens: Identifiable, Equatable {
    let id: String
    let label: String
    let deviceType: AVCaptureDevice.DeviceType
}

// MARK: - Camera + CloudKit Manager

@MainActor
class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Waiting for watch command..."
    @Published var cameraAuthorized = false
    @Published var availableLenses: [CameraLens] = []
    @Published var selectedLens: CameraLens?
    @Published var showCustomZoom = false
    @Published var customZoom: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 6.0

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var pollingTask: Task<Void, Never>?
    private var lastProcessedDate = Date()
    private let container = CKContainer(identifier: "iCloud.Micah-Woodring.WristCut")
    private var currentVideoInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        Task { await requestPermissionsAndSetup() }
    }

    deinit {
        pollingTask?.cancel()
    }

    private func requestPermissionsAndSetup() async {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if videoStatus == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            statusMessage = "Camera permission required."
            return
        }
        await setupSession()
    }

    private func setupSession() async {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Detect available back lenses
        let candidates: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInUltraWideCamera, "0.5x"),
            (.builtInWideAngleCamera, "1x"),
            (.builtInTelephotoCamera, "2x")
        ]
        var lenses: [CameraLens] = []
        for (type, label) in candidates {
            if AVCaptureDevice.default(type, for: .video, position: .back) != nil {
                lenses.append(CameraLens(id: label, label: label, deviceType: type))
            }
        }
        availableLenses = lenses

        // Start with wide angle
        let initialLens = lenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? lenses.first
        if let lens = initialLens,
           let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device) {
            session.addInput(input)
            currentVideoInput = input
            selectedLens = lens
            maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        }

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()
        cameraAuthorized = true

        Task.detached(priority: .userInitiated) { [weak self] in
            self?.session.startRunning()
        }

        startPolling()
    }

    func switchToLens(_ lens: CameraLens) {
        guard !isRecording,
              lens != selectedLens,
              let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if let old = currentVideoInput {
            session.removeInput(old)
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            currentVideoInput = newInput
            selectedLens = lens
            showCustomZoom = false
            customZoom = 1.0
            maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        }
        session.commitConfiguration()
    }

    func applyCustomZoom(_ factor: CGFloat) {
        guard let device = currentVideoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
            device.unlockForConfiguration()
        } catch {}
    }

    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                await pollCloudKit()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func pollCloudKit() async {
        let predicate = NSPredicate(format: "issuedAt > %@", lastProcessedDate as CVarArg)
        let query = CKQuery(recordType: "RecordingCommand", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "issuedAt", ascending: true)]

        do {
            let (matchResults, _) = try await container.privateCloudDatabase.records(matching: query)
            let records = matchResults
                .compactMap { try? $1.get() }
                .sorted { ($0["issuedAt"] as? Date ?? .distantPast) < ($1["issuedAt"] as? Date ?? .distantPast) }

            guard let latest = records.last,
                  let command = latest["command"] as? String,
                  let issuedAt = latest["issuedAt"] as? Date else { return }

            lastProcessedDate = issuedAt
            handleCommand(command)
        } catch {
            // Silently ignore transient network errors during polling
        }
    }

    private func handleCommand(_ command: String) {
        switch command {
        case "start" where !isRecording:
            startRecording()
        case "stop" where isRecording:
            stopRecording()
        default:
            break
        }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        statusMessage = "Recording..."
    }

    func stopRecording() {
        movieOutput.stopRecording()
    }

    func startSession() async {
        let record = CKRecord(recordType: "SessionEvent")
        record["event"] = "session_started" as CKRecordValue
        record["issuedAt"] = Date() as CKRecordValue
        do {
            try await container.privateCloudDatabase.save(record)
            print("✅ session_started written to CloudKit")
        } catch {
            print("❌ CloudKit write failed: \(error)")
        }
    }

    func endSession() async {
        if isRecording {
            stopRecording()
        }
        let record = CKRecord(recordType: "SessionEvent")
        record["event"] = "session_ended" as CKRecordValue
        record["issuedAt"] = Date() as CKRecordValue
        try? await container.privateCloudDatabase.save(record)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.statusMessage = "Saving to Photos..."
        }

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run { self.statusMessage = "Photos permission denied." }
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
                }
                await MainActor.run { self.statusMessage = "Saved! Waiting for watch command..." }
            } catch {
                await MainActor.run { self.statusMessage = "Save failed: \(error.localizedDescription)" }
            }
            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }
}

// MARK: - Surfboard Shape

struct SurfboardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Nose (top, pointed)
        path.move(to: CGPoint(x: w * 0.5, y: 0))

        // Right rail: nose → wide point
        path.addCurve(
            to: CGPoint(x: w * 0.88, y: h * 0.38),
            control1: CGPoint(x: w * 0.65, y: h * 0.04),
            control2: CGPoint(x: w * 0.88, y: h * 0.18)
        )

        // Right rail: wide point → tail
        path.addCurve(
            to: CGPoint(x: w * 0.63, y: h),
            control1: CGPoint(x: w * 0.88, y: h * 0.66),
            control2: CGPoint(x: w * 0.76, y: h * 0.88)
        )

        // Squash tail
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.93))
        path.addLine(to: CGPoint(x: w * 0.37, y: h))

        // Left rail: tail → wide point
        path.addCurve(
            to: CGPoint(x: w * 0.12, y: h * 0.38),
            control1: CGPoint(x: w * 0.24, y: h * 0.88),
            control2: CGPoint(x: w * 0.12, y: h * 0.66)
        )

        // Left rail: wide point → nose
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: 0),
            control1: CGPoint(x: w * 0.12, y: h * 0.18),
            control2: CGPoint(x: w * 0.35, y: h * 0.04)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Home Screen

struct HomeView: View {
    let onStart: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SurfboardShape()
                .stroke(.white.opacity(0.12), lineWidth: 2)
                .frame(width: 260, height: 670)

            VStack(spacing: 40) {
                Text("WristCut")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Button(action: onStart) {
                    Text("Start Session")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 16)
                        .background(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Camera Recording Screen

struct RecordingView: View {
    @ObservedObject var camera: CameraManager
    let onEnd: () -> Void
    @State private var screenDimmed = false
    private let previousBrightness = UIScreen.main.brightness

    var body: some View {
        ZStack {
            if camera.cameraAuthorized {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                Spacer()

                // Lens picker
                if !camera.availableLenses.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(camera.availableLenses) { lens in
                            lensButton(lens)
                        }
                        customZoomButton
                    }
                    .padding(.bottom, 12)
                }

                // Custom zoom slider
                if camera.showCustomZoom {
                    HStack(spacing: 10) {
                        Text("1×")
                            .foregroundStyle(.white)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                        Slider(value: $camera.customZoom, in: 1...camera.maxZoom, step: 0.1)
                            .tint(.white)
                            .onChange(of: camera.customZoom) { _, value in
                                camera.applyCustomZoom(value)
                            }
                        Text(String(format: "%.1f×", camera.maxZoom))
                            .foregroundStyle(.white)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }

                // Status pill
                HStack(spacing: 8) {
                    if camera.isRecording {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .transition(.scale)
                    }
                    Text(camera.statusMessage)
                        .foregroundStyle(.white)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
                .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 24)

                HStack(spacing: 12) {
                    Button {
                        screenDimmed.toggle()
                        UIScreen.main.brightness = screenDimmed ? 0 : previousBrightness
                    } label: {
                        Image(systemName: screenDimmed ? "sun.max.fill" : "sun.min")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(screenDimmed ? .black : .white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(screenDimmed ? .white : .white.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    Button(action: {
                        UIScreen.main.brightness = previousBrightness
                        onEnd()
                    }) {
                        Text("End Session")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func lensButton(_ lens: CameraLens) -> some View {
        let isSelected = camera.selectedLens == lens && !camera.showCustomZoom
        Button {
            camera.switchToLens(lens)
        } label: {
            Text(lens.label)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? .white : .white.opacity(0.2))
                .clipShape(Capsule())
        }
        .disabled(camera.isRecording)
    }

    private var customZoomButton: some View {
        let isSelected = camera.showCustomZoom
        return Button {
            if !camera.isRecording {
                camera.showCustomZoom.toggle()
            }
        } label: {
            Text(isSelected ? String(format: "%.1f×", camera.customZoom) : "Custom")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? .white : .white.opacity(0.2))
                .clipShape(Capsule())
        }
        .disabled(camera.isRecording)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var sessionActive = false

    var body: some View {
        if sessionActive {
            RecordingView(camera: camera) {
                Task { await camera.endSession() }
                sessionActive = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        } else {
            HomeView {
                sessionActive = true
                UIApplication.shared.isIdleTimerDisabled = true
                Task { await camera.startSession() }
            }
        }
    }
}

#Preview {
    ContentView()
}
