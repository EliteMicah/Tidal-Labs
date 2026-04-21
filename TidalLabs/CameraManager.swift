import Foundation
import AVFoundation
import CloudKit
import WatchConnectivity
internal import Combine

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
    @Published var recordings: [SessionRecording] = []
    @Published var waveSessions: [WaveSession] = []
    @Published var watchRequestedSessionStart = false

    private var recordingStartDate: Date?
    private var receivedTimestamps: [(id: String, start: Date, end: Date)] = []

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var pollingTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var lastProcessedDate = Date()
    private let container = CKContainer(identifier: "iCloud.Micah-Woodring.TidalLabs")
    private var currentVideoInput: AVCaptureDeviceInput?

    override init() {
        super.init()
    }

    func setup() async {
        setupWatchConnectivity()
        await requestPermissionsAndSetup()
        loadRecordings()
        loadSessions()
    }

    private var sessionsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let sessions = try? JSONDecoder().decode([WaveSession].self, from: data) else { return }
        waveSessions = sessions.sorted { $0.startDate > $1.startDate }
    }

    private func saveSession(_ waveSession: WaveSession) {
        waveSessions.insert(waveSession, at: 0)
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
    }

    func deleteAllSessions() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for session in waveSessions {
            for clip in session.clips {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(clip.filename))
            }
        }
        waveSessions = []
        recordings = []
        try? FileManager.default.removeItem(at: sessionsFileURL)
    }

    func deleteClip(_ clipID: UUID, fromSession sessionID: UUID) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }),
              let ci = waveSessions[si].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let filename = waveSessions[si].clips[ci].filename
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(filename))
        waveSessions[si].clips.remove(at: ci)
        if waveSessions[si].clips.isEmpty { waveSessions.remove(at: si) }
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
    }

    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func loadRecordings() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.creationDateKey], options: []
        )) ?? []
        recordings = files
            .filter { $0.pathExtension == "mov" }
            .compactMap { url -> SessionRecording? in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                return SessionRecording(id: UUID(), url: url, date: date)
            }
            .sorted { $0.date > $1.date }
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

    private var savedResolution: AVCaptureSession.Preset {
        switch UserDefaults.standard.string(forKey: "resolution") {
        case VideoResolution.p720.rawValue:  return .hd1280x720
        case VideoResolution.p1080.rawValue: return .hd1920x1080
        case VideoResolution.k2.rawValue:    return .hd1920x1080
        case VideoResolution.k4.rawValue:    return .hd4K3840x2160
        default:                             return .hd1280x720
        }
    }

    private var savedFPS: Int {
        let v = UserDefaults.standard.integer(forKey: "fps")
        return v > 0 ? v : 30
    }

    private var savedMaxSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "maxRecordingMinutes")
        return (v > 0 ? v : 60.0) * 60.0
    }

    private var savedStartDelayNanos: UInt64 {
        let v = UserDefaults.standard.double(forKey: "startDelay")
        return UInt64(v * 60.0 * 1_000_000_000)
    }

    private var savedCellularWatch: Bool {
        UserDefaults.standard.bool(forKey: "cellularWatch")
    }

    private func applyFPS(_ fps: Int, to device: AVCaptureDevice) {
        let supported = device.activeFormat.videoSupportedFrameRateRanges
        let maxSupported = supported.map { $0.maxFrameRate }.max() ?? 30
        let target = min(Double(fps), maxSupported)
        let dur = CMTime(value: 1, timescale: CMTimeScale(target))
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            device.unlockForConfiguration()
        } catch {}
    }

    private func setupSession() async {
        session.beginConfiguration()
        session.sessionPreset = savedResolution

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

        let initialLens = lenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? lenses.first
        if let lens = initialLens,
           let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device) {
            session.addInput(input)
            currentVideoInput = input
            selectedLens = lens
            maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
            applyFPS(savedFPS, to: device)
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
        movieOutput.connections.first { !$0.audioChannels.isEmpty }?.isEnabled = false
        cameraAuthorized = true

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
            applyFPS(savedFPS, to: device)
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
        guard savedCellularWatch else { return }
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
        guard savedCellularWatch else { return }
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
        recordingStartDate = Date()
        movieOutput.maxRecordedDuration = CMTime(seconds: savedMaxSeconds, preferredTimescale: 600)
        movieOutput.connections.first { !$0.audioChannels.isEmpty }?.isEnabled = true
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
        session.beginConfiguration()
        session.sessionPreset = savedResolution
        if let device = currentVideoInput?.device {
            applyFPS(savedFPS, to: device)
        }
        session.commitConfiguration()

        let isCellular = savedCellularWatch
        let totalSeconds = Int(Double(savedStartDelayNanos) / 1_000_000_000)

        sendSettingsToWatch()
        if WCSession.default.activationState == .activated && WCSession.default.isReachable {
            WCSession.default.sendMessage(["event": "session_started", "delaySeconds": totalSeconds], replyHandler: nil)
        }
        if savedCellularWatch {
            let record = CKRecord(recordType: "SessionEvent")
            record["event"] = "session_started" as CKRecordValue
            record["issuedAt"] = Date() as CKRecordValue
            do {
                try await container.privateCloudDatabase.save(record)
            } catch {
                print("❌ CloudKit write failed: \(error)")
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            self?.session.startRunning()
            guard !isCellular else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if totalSeconds <= 0 {
                    if !self.isRecording { self.startRecording() }
                } else {
                    self.countdownTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        for remaining in stride(from: totalSeconds, through: 1, by: -1) {
                            guard !Task.isCancelled else { return }
                            self.statusMessage = remaining > 60
                                ? "Starting in \(remaining / 60) min..."
                                : "Starting in \(remaining)s..."
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        guard !Task.isCancelled else { return }
                        if !self.isRecording { self.startRecording() }
                    }
                }
            }
        }
    }

    private func sendSettingsToWatch() {
        guard WCSession.default.activationState == .activated else { return }
        let maxMins = UserDefaults.standard.double(forKey: "maxRecordingMinutes")
        try? WCSession.default.updateApplicationContext([
            "cellularWatch": savedCellularWatch,
            "maxRecordingMinutes": maxMins > 0 ? maxMins : 60.0
        ])
    }

    func endSession() async {
        countdownTask?.cancel()
        countdownTask = nil
        statusMessage = "Waiting for watch command..."
        if isRecording {
            stopRecording()
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.session.stopRunning()
        }
        if WCSession.default.activationState == .activated && WCSession.default.isReachable {
            WCSession.default.sendMessage(["event": "session_ended"], replyHandler: nil)
        }
        if savedCellularWatch {
            let record = CKRecord(recordType: "SessionEvent")
            record["event"] = "session_ended" as CKRecordValue
            record["issuedAt"] = Date() as CKRecordValue
            try? await container.privateCloudDatabase.save(record)
        }
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
        let endDate = Date()
        Task { @MainActor in
            self.isRecording = false
            self.movieOutput.connections.first { !$0.audioChannels.isEmpty }?.isEnabled = false
        }

        Task {
            let isCellular = UserDefaults.standard.bool(forKey: "cellularWatch")
            let timestamps = await MainActor.run { self.receivedTimestamps }
            let startDate = await MainActor.run { self.recordingStartDate }

            if !isCellular, !timestamps.isEmpty, let startDate {
                await MainActor.run { self.statusMessage = "Processing \(timestamps.count) wave clips..." }
                await self.processWaveClips(from: outputFileURL, sessionStart: startDate, sessionEnd: endDate, timestamps: timestamps)
            } else if isCellular, let startDate {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let filename = UUID().uuidString + ".mov"
                let destURL = docs.appendingPathComponent(filename)
                do {
                    try FileManager.default.moveItem(at: outputFileURL, to: destURL)
                    let clip = WaveClip(id: UUID(), filename: filename, date: startDate)
                    let waveSession = WaveSession(id: UUID(), startDate: startDate, endDate: endDate, clips: [clip])
                    await MainActor.run {
                        self.saveSession(waveSession)
                        self.loadRecordings()
                        self.statusMessage = "Session saved. Waiting for watch command..."
                    }
                } catch {
                    await MainActor.run {
                        self.statusMessage = "Save failed: \(error.localizedDescription)"
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                await MainActor.run {
                    self.recordingStartDate = nil
                    self.statusMessage = "No waves synced. Waiting for watch command..."
                }
            }
        }
    }

    private func processWaveClips(
        from url: URL,
        sessionStart: Date,
        sessionEnd: Date,
        timestamps: [(id: String, start: Date, end: Date)]
    ) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let asset = AVURLAsset(url: url)
        let confirmedIDs = timestamps.map { $0.id }
        var savedClips: [WaveClip] = []

        for ts in timestamps {
            let startOffset = ts.start.timeIntervalSince(sessionStart)
            let endOffset = ts.end.timeIntervalSince(sessionStart)
            guard startOffset >= 0, endOffset > startOffset else { continue }
            let timeRange = CMTimeRange(
                start: CMTime(seconds: startOffset, preferredTimescale: 600),
                duration: CMTime(seconds: endOffset - startOffset, preferredTimescale: 600)
            )
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { continue }
            let filename = UUID().uuidString + ".mov"
            let destURL = docs.appendingPathComponent(filename)
            exporter.outputURL = destURL
            exporter.outputFileType = .mov
            exporter.timeRange = timeRange
            await exporter.export()
            if exporter.status == .completed {
                savedClips.append(WaveClip(id: UUID(), filename: filename, date: ts.start))
            }
        }

        try? FileManager.default.removeItem(at: url)

        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["confirmedTimestampIDs": confirmedIDs])
        }

        let waveSession = WaveSession(id: UUID(), startDate: sessionStart, endDate: sessionEnd, clips: savedClips)

        await MainActor.run {
            self.saveSession(waveSession)
            self.receivedTimestamps.removeAll { confirmedIDs.contains($0.id) }
            self.recordingStartDate = nil
            self.loadRecordings()
            self.statusMessage = "Waves saved. Waiting for watch command..."
        }
    }
}

// MARK: - WCSessionDelegate

extension CameraManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let event = message["event"] as? String, event == "watch_started_session" else { return }
        Task { @MainActor in self.watchRequestedSessionStart = true }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let payload = userInfo["waveTimestamps"] as? [[String: Any]] else { return }
        let timestamps = payload.compactMap { dict -> (id: String, start: Date, end: Date)? in
            guard let id = dict["id"] as? String,
                  let startInterval = dict["start"] as? Double,
                  let endInterval = dict["end"] as? Double else { return nil }
            return (id: id, start: Date(timeIntervalSince1970: startInterval), end: Date(timeIntervalSince1970: endInterval))
        }
        Task { @MainActor in
            let existingIDs = Set(self.receivedTimestamps.map { $0.id })
            let newOnly = timestamps.filter { !existingIDs.contains($0.id) }
            self.receivedTimestamps.append(contentsOf: newOnly)
            let count = self.receivedTimestamps.count
            self.statusMessage = "\(count) wave\(count == 1 ? "" : "s") synced. End session to generate clips."
        }
    }
}
