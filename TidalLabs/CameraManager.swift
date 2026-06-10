import Foundation
import AVFoundation
import WatchConnectivity
internal import Combine

@MainActor
class CameraManager: NSObject, ObservableObject {
    @Published var recordings: [SessionRecording] = []
    @Published var waveSessions: [WaveSession] = []
    @Published var pendingWatchSessions: [PendingWatchSession] = []
    @Published var pendingImportVideo: PendingImportVideo? = nil
    @Published var isProcessingImport = false
    @Published var isLoadingVideo = false
    @Published var clipGenerationCompleted: Int = 0

    private let pendingWatchSessionsKey = "pendingWatchSessions"

    override init() {
        super.init()
    }

    func setup() async {
        setupWatchConnectivity()
        loadRecordings()
        loadSessions()
        loadPendingWatchSessions()
    }

    private func loadPendingWatchSessions() {
        guard let data = UserDefaults.standard.data(forKey: pendingWatchSessionsKey),
              let sessions = try? JSONDecoder().decode([PendingWatchSession].self, from: data) else { return }
        pendingWatchSessions = sessions
    }

    private func savePendingWatchSessions() {
        if let data = try? JSONEncoder().encode(pendingWatchSessions) {
            UserDefaults.standard.set(data, forKey: pendingWatchSessionsKey)
        }
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

    func deleteSession(_ sessionID: UUID) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for clip in waveSessions[si].clips {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(clip.filename))
        }
        waveSessions.remove(at: si)
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

    // MARK: - Video Import

    func storeImportedVideo(from url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        guard let videoStart = await getVideoCreationDate(from: asset) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }

        let durationTime: CMTime
        do {
            durationTime = try await asset.load(.duration)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }

        if let existing = pendingImportVideo {
            try? FileManager.default.removeItem(at: existing.url)
        }

        pendingImportVideo = PendingImportVideo(
            url: url,
            creationDate: videoStart,
            durationSeconds: durationTime.seconds
        )

        await tryMatchPendingImport()
        return true
    }

    func pushWaveDurationToWatch(_ seconds: Int) {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["waveDurationSeconds": Double(seconds)])
    }

    func cancelPendingImport() {
        if let pending = pendingImportVideo {
            try? FileManager.default.removeItem(at: pending.url)
        }
        pendingImportVideo = nil
    }

    func tryMatchPendingImport() async {
        guard let pending = pendingImportVideo, !isProcessingImport else { return }

        let videoEnd = pending.creationDate.addingTimeInterval(pending.durationSeconds)

        guard let matchedSession = pendingWatchSessions.first(where: { s in
            let overlapStart = max(s.startDate, pending.creationDate)
            let overlapEnd = min(s.endDate, videoEnd)
            return overlapEnd > overlapStart
        }) else { return }

        let validTimestamps = matchedSession.timestamps.filter { ts in
            ts.start >= pending.creationDate && ts.end <= videoEnd
        }
        guard !validTimestamps.isEmpty else { return }

        isProcessingImport = true
        let tuples = validTimestamps.map { (id: $0.id, start: $0.start, end: $0.end) }
        let clipsGenerated = await processWaveClips(from: pending.url, sessionStart: pending.creationDate, sessionEnd: videoEnd, timestamps: tuples)

        pendingWatchSessions.removeAll { $0.id == matchedSession.id }
        savePendingWatchSessions()

        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["confirmedSessionIDs": [matchedSession.id]])
        }

        pendingImportVideo = nil
        isProcessingImport = false
        if clipsGenerated { clipGenerationCompleted += 1 }
    }

    private func getVideoCreationDate(from asset: AVURLAsset) async -> Date? {
        if let metadata = try? await asset.load(.metadata) {
            let commonItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate)
            if let item = commonItems.first {
                if let date = try? await item.load(.dateValue) { return date }
                if let str = try? await item.load(.stringValue) {
                    let f1 = ISO8601DateFormatter()
                    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = f1.date(from: str) { return d }
                    if let d = ISO8601DateFormatter().date(from: str) { return d }
                }
            }
            let qtItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
            if let item = qtItems.first {
                if let date = try? await item.load(.dateValue) { return date }
                if let str = try? await item.load(.stringValue) {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = f.date(from: str) { return d }
                    if let d = ISO8601DateFormatter().date(from: str) { return d }
                }
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: asset.url.path)
        return attrs?[.creationDate] as? Date
    }
}

// MARK: - Clip Processing

extension CameraManager {
    nonisolated private func exportClip(
        asset: AVURLAsset,
        timeRange: CMTimeRange,
        destURL: URL
    ) async -> Bool {
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            exporter.outputURL = destURL
            exporter.outputFileType = .mov
            exporter.timeRange = timeRange
            await exporter.export()
            if exporter.status == .completed { return true }
            try? FileManager.default.removeItem(at: destURL)
        }
        return false
    }

    @discardableResult
    private func processWaveClips(
        from url: URL,
        sessionStart: Date,
        sessionEnd: Date,
        timestamps: [(id: String, start: Date, end: Date)]
    ) async -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let asset = AVURLAsset(url: url)
        let confirmedIDs = timestamps.map { $0.id }

        struct ClipJob {
            let timeRange: CMTimeRange
            let filename: String
            let destURL: URL
            let date: Date
        }

        let jobs: [ClipJob] = timestamps.compactMap { ts in
            let startOffset = ts.start.timeIntervalSince(sessionStart)
            let endOffset = ts.end.timeIntervalSince(sessionStart)
            guard startOffset >= 0, endOffset > startOffset else { return nil }
            let timeRange = CMTimeRange(
                start: CMTime(seconds: startOffset, preferredTimescale: 600),
                duration: CMTime(seconds: endOffset - startOffset, preferredTimescale: 600)
            )
            let filename = UUID().uuidString + ".mov"
            return ClipJob(timeRange: timeRange, filename: filename, destURL: docs.appendingPathComponent(filename), date: ts.start)
        }

        let savedClips: [WaveClip] = await withTaskGroup(of: WaveClip?.self) { group in
            for job in jobs {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    let success = await self.exportClip(asset: asset, timeRange: job.timeRange, destURL: job.destURL)
                    return success ? WaveClip(id: UUID(), filename: job.filename, date: job.date) : nil
                }
            }
            var results: [WaveClip] = []
            for await clip in group {
                if let clip { results.append(clip) }
            }
            return results.sorted { $0.date < $1.date }
        }

        try? FileManager.default.removeItem(at: url)

        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["confirmedTimestampIDs": confirmedIDs])
        }

        guard !savedClips.isEmpty else {
            await MainActor.run { self.loadRecordings() }
            return false
        }

        let waveSession = WaveSession(id: UUID(), startDate: sessionStart, endDate: sessionEnd, clips: savedClips)

        await MainActor.run {
            self.saveSession(waveSession)
            self.loadRecordings()
        }
        return true
    }
}

// MARK: - WCSessionDelegate

extension CameraManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        let saved = UserDefaults.standard.integer(forKey: "waveDurationSeconds")
        let dur = saved == 0 ? 60.0 : Double(saved)
        try? WCSession.default.updateApplicationContext(["waveDurationSeconds": dur])
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let payload = message["watchSessions"] as? [[String: Any]] {
            handleIncomingWatchSessions(payload)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let payload = message["watchSessions"] as? [[String: Any]] {
            handleIncomingWatchSessions(payload)
            replyHandler(["status": "received"])
        } else {
            replyHandler(["status": "unknown"])
        }
    }

    nonisolated private func handleIncomingWatchSessions(_ sessionsPayload: [[String: Any]]) {
        let sessions: [PendingWatchSession] = sessionsPayload.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let startI = dict["startDate"] as? Double,
                  let endI = dict["endDate"] as? Double,
                  let tsPayload = dict["timestamps"] as? [[String: Any]] else { return nil }
            let timestamps: [PendingWatchTimestamp] = tsPayload.compactMap { ts in
                guard let tsID = ts["id"] as? String,
                      let s = ts["start"] as? Double,
                      let e = ts["end"] as? Double else { return nil }
                return PendingWatchTimestamp(id: tsID, start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e))
            }
            return PendingWatchSession(id: id, startDate: Date(timeIntervalSince1970: startI), endDate: Date(timeIntervalSince1970: endI), timestamps: timestamps)
        }
        Task { @MainActor in
            let existingIDs = Set(self.pendingWatchSessions.map { $0.id })
            let newOnly = sessions.filter { !existingIDs.contains($0.id) }
            self.pendingWatchSessions.append(contentsOf: newOnly)
            self.savePendingWatchSessions()
            await self.tryMatchPendingImport()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let sessionsPayload = userInfo["watchSessions"] as? [[String: Any]] {
            handleIncomingWatchSessions(sessionsPayload)
        }
    }
}
