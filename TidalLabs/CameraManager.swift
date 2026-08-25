import Foundation
import AVFoundation
import CoreLocation
import WatchConnectivity
import Vision
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
    @Published var iCloudDownloadProgress: Double? = nil
    @Published var lastImportedOriginalAssetID: String? = nil
    @Published var latestImportedSessionID: UUID? = nil

    private let pendingWatchSessionsKey = "pendingWatchSessions"
    private let locationManager = LocationManager()

    override init() {
        super.init()
    }

    func setup() async {
        #if DEBUG
        cropAnalysisSelfCheck()
        clipEditorSelfCheck()
        #endif
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
        // ponytail: best-effort crash recovery — a session still flagged isProcessing means the
        // background crop task was killed. Unlock it with whatever clips finished. Full resume is future work.
        var unlocked = sessions
        let hadStuck = unlocked.contains { $0.isProcessing }
        for i in unlocked.indices { unlocked[i].isProcessing = false }
        waveSessions = unlocked.sorted { $0.startDate > $1.startDate }
        if hadStuck, let d = try? JSONEncoder().encode(waveSessions) { try? d.write(to: sessionsFileURL) }
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

    func clearPendingWatchSessions() {
        let ids = pendingWatchSessions.map { $0.id }
        pendingWatchSessions = []
        savePendingWatchSessions()
        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["confirmedSessionIDs": ids])
        }
    }

    func requestWatchSync() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["requestSync": true], replyHandler: nil, errorHandler: nil)
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

    var favoritedClips: [(clip: WaveClip, sessionID: UUID)] {
        waveSessions.flatMap { session in
            session.clips.filter(\.isFavorite).map { (clip: $0, sessionID: session.id) }
        }
    }

    func toggleFavorite(clipID: UUID, sessionID: UUID) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }),
              let ci = waveSessions[si].clips.firstIndex(where: { $0.id == clipID }) else { return }
        waveSessions[si].clips[ci].isFavorite.toggle()
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
    }

    /// Stores the viewer's crop for one clip. `nil` clears it, restoring the original framing.
    func setUserCrop(_ rect: CGRect?, clipID: UUID, sessionID: UUID) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }),
              let ci = waveSessions[si].clips.firstIndex(where: { $0.id == clipID }) else { return }
        guard waveSessions[si].clips[ci].userCrop != rect else { return }
        waveSessions[si].clips[ci].userCrop = rect
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
    }

    func renameSession(_ sessionID: UUID, name: String) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        waveSessions[si].name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces)
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
    }

    func updateSessionSpot(_ sessionID: UUID, spotName: String) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        waveSessions[si].spotName = spotName
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
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

    func storeImportedVideo(asset: AVAsset, tempURL: URL? = nil) async -> Bool {
        print("[VideoImport] storeImportedVideo: asset=\(type(of: asset)) tempURL=\(tempURL?.lastPathComponent ?? "nil")")
        guard let videoStart = await getVideoCreationDate(from: asset) else {
            print("[VideoImport] storeImportedVideo: getVideoCreationDate returned nil — cannot determine timestamp")
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            return false
        }
        print("[VideoImport] storeImportedVideo: videoStart=\(videoStart)")
        let durationTime: CMTime
        do {
            durationTime = try await asset.load(.duration)
            print("[VideoImport] storeImportedVideo: duration=\(durationTime.seconds)s")
        } catch {
            print("[VideoImport] storeImportedVideo: failed to load duration: \(error)")
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            return false
        }
        pendingImportVideo = PendingImportVideo(
            asset: asset,
            creationDate: videoStart,
            durationSeconds: durationTime.seconds,
            tempURL: tempURL
        )
        await tryMatchPendingImport()
        return true
    }

    func pushWaveDurationToWatch(_ seconds: Int) {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["waveDurationSeconds": Double(seconds)])
    }

    func cancelPendingImport() {
        if let tempURL = pendingImportVideo?.tempURL {
            try? FileManager.default.removeItem(at: tempURL)
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

        let validTimestamps = matchedSession.timestamps.compactMap { ts -> PendingWatchTimestamp? in
            let clampedStart = max(ts.start, pending.creationDate)
            let clampedEnd = min(ts.end, videoEnd)
            guard clampedEnd > clampedStart else { return nil }
            return PendingWatchTimestamp(id: ts.id, start: clampedStart, end: clampedEnd)
        }
        guard !validTimestamps.isEmpty else { return }

        isProcessingImport = true
        let tuples = validTimestamps.map { (id: $0.id, start: $0.start, end: $0.end) }
        // Phone position: prefer the video's own GPS metadata; fall back to a one-shot fix (phone is still at the beach).
        var phoneCoord = await videoLocation(from: pending.asset)
        if phoneCoord == nil { phoneCoord = (await locationManager.requestLocation())?.coordinate }
        let clipsGenerated = await processWaveClips(asset: pending.asset, sessionStart: pending.creationDate, sessionEnd: videoEnd, timestamps: tuples, gpsTrack: matchedSession.gpsTrack, phoneCoord: phoneCoord)

        pendingWatchSessions.removeAll { $0.id == matchedSession.id }
        savePendingWatchSessions()

        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["confirmedSessionIDs": [matchedSession.id]])
        }

        let tempURL = pending.tempURL
        pendingImportVideo = nil
        isProcessingImport = false
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        if clipsGenerated {
            latestImportedSessionID = waveSessions.first?.id
            clipGenerationCompleted += 1
        }
    }

    private func getVideoCreationDate(from asset: AVAsset) async -> Date? {
        print("[VideoImport] getVideoCreationDate: loading metadata")
        if let metadata = try? await asset.load(.metadata) {
            print("[VideoImport] getVideoCreationDate: metadata count=\(metadata.count)")
            let commonItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate)
            print("[VideoImport] getVideoCreationDate: common creation date items=\(commonItems.count)")
            if let item = commonItems.first {
                if let date = try? await item.load(.dateValue) {
                    print("[VideoImport] getVideoCreationDate: common dateValue=\(date)")
                    return date
                }
                if let str = try? await item.load(.stringValue) {
                    print("[VideoImport] getVideoCreationDate: common stringValue=\(str)")
                    let f1 = ISO8601DateFormatter()
                    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = f1.date(from: str) { return d }
                    if let d = ISO8601DateFormatter().date(from: str) { return d }
                    print("[VideoImport] getVideoCreationDate: common string could not be parsed")
                }
            }
            let qtItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
            print("[VideoImport] getVideoCreationDate: QT creation date items=\(qtItems.count)")
            if let item = qtItems.first {
                if let date = try? await item.load(.dateValue) {
                    print("[VideoImport] getVideoCreationDate: QT dateValue=\(date)")
                    return date
                }
                if let str = try? await item.load(.stringValue) {
                    print("[VideoImport] getVideoCreationDate: QT stringValue=\(str)")
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = f.date(from: str) { return d }
                    if let d = ISO8601DateFormatter().date(from: str) { return d }
                    print("[VideoImport] getVideoCreationDate: QT string could not be parsed")
                }
            }
        } else {
            print("[VideoImport] getVideoCreationDate: failed to load metadata")
        }
        if let urlAsset = asset as? AVURLAsset {
            print("[VideoImport] getVideoCreationDate: trying file attributes for \(urlAsset.url.lastPathComponent)")
            let attrs = try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)
            let date = attrs?[.creationDate] as? Date
            print("[VideoImport] getVideoCreationDate: file creationDate=\(String(describing: date))")
            return date
        }
        print("[VideoImport] getVideoCreationDate: all paths exhausted, returning nil")
        return nil
    }

    // Reads the phone's position from the video's own ISO-6709 location metadata (it filmed stationary).
    private func videoLocation(from asset: AVAsset) async -> CLLocationCoordinate2D? {
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let ids: [AVMetadataIdentifier] = [.commonIdentifierLocation, .quickTimeMetadataLocationISO6709]
        for id in ids {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id)
            if let item = items.first,
               let str = try? await item.load(.stringValue),
               let coord = Self.parseISO6709(str) {
                return coord
            }
        }
        return nil
    }

    // ISO-6709, e.g. "+37.7749-122.4194+010.000/" — leading signed lat then signed lon.
    static func parseISO6709(_ s: String) -> CLLocationCoordinate2D? {
        let scanner = Scanner(string: s)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble() else { return nil }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Clip Processing

extension CameraManager {
    // Scans backward up to 10s to find the nearest keyframe at or before `time`.
    // Passthrough export requires the start to land on a keyframe boundary.
    nonisolated private func nearestKeyframeBefore(_ time: CMTime, in asset: AVAsset) async -> CMTime {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return time }
        let scanStart = CMTimeMaximum(.zero, time - CMTime(seconds: 10, preferredTimescale: 600))
        let scanRange = CMTimeRange(start: scanStart, end: time)
        guard scanRange.duration.seconds > 0,
              let reader = try? AVAssetReader(asset: asset) else { return time }
        reader.timeRange = scanRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return time }
        var lastKeyframe = scanStart
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
               let first = rawAttachments.first {
                let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers as String] as? Bool ?? false
                if !dependsOnOthers { lastKeyframe = pts }
            }
        }
        reader.cancelReading()
        return lastKeyframe
    }

    nonisolated private func exportClip(
        asset: AVAsset,
        timeRange: CMTimeRange,
        destURL: URL
    ) async -> Bool {
        let snappedStart = await nearestKeyframeBefore(timeRange.start, in: asset)
        let snappedRange = CMTimeRange(start: snappedStart, end: timeRange.end)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        exporter.timeRange = snappedRange
        do {
            try await exporter.export(to: destURL, as: .mov)
            return true
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            return false
        }
    }

    @discardableResult
    private func processWaveClips(
        asset: AVAsset,
        sessionStart: Date,
        sessionEnd: Date,
        timestamps: [(id: String, start: Date, end: Date)],
        gpsTrack: [GPSFix] = [],
        phoneCoord: CLLocationCoordinate2D? = nil
    ) async -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let confirmedIDs = timestamps.map { $0.id }

        struct ClipJob {
            let timeRange: CMTimeRange
            let filename: String
            let destURL: URL
            let date: Date
            let midpointWall: Double   // timeIntervalSince1970 of the clip midpoint
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
            let mid = (ts.start.timeIntervalSince1970 + ts.end.timeIntervalSince1970) / 2
            return ClipJob(timeRange: timeRange, filename: filename, destURL: docs.appendingPathComponent(filename), date: ts.start, midpointWall: mid)
        }

        struct Exported { let clip: WaveClip; let midpointWall: Double }
        let exported: [Exported] = await withTaskGroup(of: Exported?.self) { group in
            for job in jobs {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    let success = await self.exportClip(asset: asset, timeRange: job.timeRange, destURL: job.destURL)
                    return success ? Exported(clip: WaveClip(id: UUID(), filename: job.filename, date: job.date), midpointWall: job.midpointWall) : nil
                }
            }
            var results: [Exported] = []
            for await e in group {
                if let e { results.append(e) }
            }
            return results.sorted { $0.clip.date < $1.clip.date }
        }

        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["confirmedTimestampIDs": confirmedIDs])
        }

        guard !exported.isEmpty else {
            await MainActor.run { self.loadRecordings() }
            return false
        }

        // Crop only if the user turned auto-follow on (off by default, beta) AND we have both the phone position and a watch GPS
        // track; otherwise clips stay full-frame.
        let autoFollow = UserDefaults.standard.object(forKey: "autoFollowCrop") as? Bool ?? false
        let canCrop = autoFollow && phoneCoord != nil && !gpsTrack.isEmpty
        print("[Crop] canCrop=\(canCrop) autoFollow=\(autoFollow) phoneCoord=\(phoneCoord != nil) gpsFixes=\(gpsTrack.count) clips=\(exported.count)")
        let savedClips = exported.map { $0.clip }
        let waveSession = WaveSession(id: UUID(), startDate: sessionStart, endDate: sessionEnd, clips: savedClips, isProcessing: canCrop)
        let sessionID = waveSession.id

        await MainActor.run {
            self.saveSession(waveSession)
            self.loadRecordings()
        }

        if let loc = await locationManager.requestLocation(),
           let spot = await SurflineService.nearestSpotName(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude) {
            updateSessionSpot(sessionID, spotName: spot)
        }

        // Import is done — passthrough clips are saved and the UI can go home. The crop analysis +
        // re-encode runs in the background; the session stays locked until it flips isProcessing off.
        if canCrop, let phoneCoord {
            let cropInputs = exported.map { (clipID: $0.clip.id, filename: $0.clip.filename, midpointWall: $0.midpointWall) }
            Task { await self.cropSessionInBackground(sessionID: sessionID, cropInputs: cropInputs, gpsTrack: gpsTrack, phoneCoord: phoneCoord) }
        }

        return true
    }
}

// MARK: - Background Crop Pipeline

extension CameraManager {
    private func cropSessionInBackground(
        sessionID: UUID,
        cropInputs: [(clipID: UUID, filename: String, midpointWall: Double)],
        gpsTrack: [GPSFix],
        phoneCoord: CLLocationCoordinate2D
    ) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // ponytail: cap concurrency at 2 — re-encode is heavy and the phone throttles; higher just thrashes.
        let cap = 2
        var iterator = cropInputs.makeIterator()
        await withTaskGroup(of: (UUID, CGRect?, Bool).self) { group in
            for _ in 0..<min(cap, cropInputs.count) {
                if let input = iterator.next() {
                    group.addTask { await Self.cropOne(input: input, docs: docs, gpsTrack: gpsTrack, phoneCoord: phoneCoord) }
                }
            }
            while let result = await group.next() {
                updateClipCrop(sessionID: sessionID, clipID: result.0, cropRect: result.1, cropApplied: result.2)
                if let input = iterator.next() {
                    group.addTask { await Self.cropOne(input: input, docs: docs, gpsTrack: gpsTrack, phoneCoord: phoneCoord) }
                }
            }
        }
        finishCropping(sessionID: sessionID)
    }

    private func updateClipCrop(sessionID: UUID, clipID: UUID, cropRect: CGRect?, cropApplied: Bool) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }),
              let ci = waveSessions[si].clips.firstIndex(where: { $0.id == clipID }) else { return }
        waveSessions[si].clips[ci].cropRect = cropRect
        waveSessions[si].clips[ci].cropApplied = cropApplied
        persistSessions()
    }

    private func finishCropping(sessionID: UUID) {
        guard let si = waveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        waveSessions[si].isProcessing = false
        persistSessions()
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(waveSessions) {
            try? data.write(to: sessionsFileURL)
        }
    }

    // MARK: analysis + re-encode (nonisolated, runs off the main actor)

    nonisolated static func cropOne(
        input: (clipID: UUID, filename: String, midpointWall: Double),
        docs: URL, gpsTrack: [GPSFix], phoneCoord: CLLocationCoordinate2D
    ) async -> (UUID, CGRect?, Bool) {
        let url = docs.appendingPathComponent(input.filename)
        guard let plan = await buildCropPlan(clipURL: url, midpointWall: input.midpointWall, gpsTrack: gpsTrack, phoneCoord: phoneCoord) else {
            return (input.clipID, nil, false)
        }
        let applied = await recropClipFile(url: url, plan: plan)
        print("[Crop] clip re-encode applied=\(applied) keys=\(plan.keys.count)")
        // Representative rect (midpoint keyframe) — only a non-nil flag for the model; playback uses the re-encoded file.
        let mid = plan.keys[plan.keys.count / 2]
        let rep = CGRect(x: mid.cx - mid.cw / 2, y: mid.cy - mid.cw / 2, width: mid.cw, height: mid.cw)
        return (input.clipID, rep, applied)
    }

    // A follow plan: per-time center to pan, AND per-time crop width to zoom. renderSize stays constant
    // (= the tightest crop over the clip); each frame's larger crop is scaled down to fit → dynamic zoom.
    struct CropPlan {
        let renderW: Double                                            // normalized render size = min crop width over clip
        let keys: [(t: Double, cx: Double, cy: Double, cw: Double)]    // t = s into clip; cx/cy center (top-left origin); cw = crop width fraction
    }

    // ASSUMPTION: sample the subject ~every 0.4s and pan the crop between samples. Vision supplies the true
    // in-frame position when it finds a person; GPS (via a Vision-calibrated heading) fills the frames it misses.
    static let FOLLOW_SAMPLE_INTERVAL = 0.4
    static let FOLLOW_MAX_SAMPLES = 40  // was 20 → 60s clip sampled every 1.5s not 3s; finer follow, less undershoot
    static let FOLLOW_SMOOTHING = 0.6   // EMA weight; zero-phase pass below cancels the lag it would add
    static let VISION_MIN_CONFIDENCE: Float = 0.5  // floor so a weak/false person box can't yank the crop off the surfer
    // Once heading is calibrated, a Vision box is accepted as "you" only if it sits within this normalized-x gap
    // of where GPS says you are. Rejects a bystander walking through frame (their box is nowhere near your bearing).
    static let VISION_GPS_MATCH_X = 0.25
    // Max time after a real Vision lock that GPS is allowed to bridge a gap. Beyond it, hold the last seen
    // position instead of chasing noisy GPS (which drifts hard at close range). Lower if drift still shows.
    static let FOLLOW_GPS_BRIDGE_SECONDS = 2.0
    // Zoom floor: never crop below this fraction of frame width (~2x max). Tighter would upscale a tiny distant
    // subject into pixel mush. Distant clips where Vision can't lock just fall back to full-frame anyway.
    static let MIN_CROP_WIDTH = 0.5
    // Crop the clip if the subject is on-screen for at least this fraction OR this many absolute seconds.
    // Kept low: a brief ride-through is still worth following. Set SECONDS to 0 to crop on any detection at all.
    static let FOLLOW_MIN_ONSCREEN = 0.15
    static let FOLLOW_MIN_ONSCREEN_SECONDS = 1.5
    // Even the best-matching tracklet must clear this correlation to be trusted as the subject. Below it, no
    // tracklet's motion resembles the GPS motion (subject wasn't detected, or only bystanders were) → fall
    // back to nearest-box rather than lock onto a bystander. Tunable.
    static let MIN_TRACKLET_SCORE = 0.1

    nonisolated static func buildCropPlan(
        clipURL: URL, midpointWall: Double, gpsTrack: [GPSFix],
        phoneCoord: CLLocationCoordinate2D
    ) async -> CropPlan? {
        guard let midFix = nearestFix(track: gpsTrack, at: midpointWall) else {
            print("[Crop] plan: no GPS fix near clip midpoint, staying full-frame")
            return nil
        }
        // GPS sizes the zoom (distance) and, once Vision calibrates a heading, aims the crop when Vision loses
        // you. An imported native video carries no camera heading, so absolute framing comes from Vision.
        let midDist = distanceMeters(from: phoneCoord, to: CLLocationCoordinate2D(latitude: midFix.lat, longitude: midFix.lon))

        let asset = AVURLAsset(url: clipURL)
        guard let dur = try? await asset.load(.duration), dur.seconds > 0 else {
            print("[Crop] plan: bad duration, staying full-frame")
            return nil
        }

        let n = max(2, min(FOLLOW_MAX_SAMPLES, Int(dur.seconds / FOLLOW_SAMPLE_INTERVAL)))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let startWall = midpointWall - dur.seconds / 2

        // Pass 1: per sample collect the GPS bearing, the distance-driven crop width (zoom), and ALL person
        // boxes Vision finds (not just the best — we need candidates to disambiguate you from a bystander).
        struct Sample { let t: Double; let bearing: Double?; let dist: Double; let cw: Double; let boxes: [DetBox] }
        var samples: [Sample] = []
        for i in 0..<n {
            let ti = dur.seconds * Double(i) / Double(n - 1)
            let coord = predictedCoord(track: gpsTrack, at: startWall + ti)
            let brg = coord.map { bearing(from: phoneCoord, to: $0) }
            let dist = coord.map { distanceMeters(from: phoneCoord, to: $0) } ?? midDist
            let cw = min(1, max(MIN_CROP_WIDTH, tier(forMeters: dist).cropWidth))  // floor caps zoom → no pixel mush
            var boxes: [DetBox] = []
            if let cg = try? await gen.image(at: CMTime(seconds: ti, preferredTimescale: 600)).image {
                let req = VNDetectHumanRectanglesRequest()
                if #available(iOS 15.0, *) { req.upperBodyOnly = false }
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                boxes = (req.results ?? []).filter { $0.confidence >= VISION_MIN_CONFIDENCE }
                    // bottom-left → top-left; size = box height fraction (apparent size ∝ 1/distance)
                    .map { DetBox(x: Double($0.boundingBox.midX), y: Double(1 - $0.boundingBox.midY), size: Double($0.boundingBox.height), conf: $0.confidence) }
            }
            samples.append(Sample(t: ti, bearing: brg, dist: dist, cw: cw, boxes: boxes))
        }

        // Calibrate camera heading. Prefer frames with exactly ONE person + a GPS fix (unambiguously you, no
        // bystander to confuse). heading = bearing - (x-0.5)*FOV, circular-meaned. Fall back to best-box frames.
        let clean = samples.compactMap { s -> (vx: Double, b: Double)? in
            guard s.boxes.count == 1, let b = s.bearing else { return nil }
            return (s.boxes[0].x, b)
        }
        let calib: [(vx: Double, b: Double)] = clean.count >= 3 ? clean : samples.compactMap { s in
            guard let b = s.bearing, let best = s.boxes.max(by: { $0.conf < $1.conf }) else { return nil }
            return (best.x, b)
        }
        var headingEst: Double? = nil
        if calib.count >= 3 {
            var sx = 0.0, sy = 0.0
            for p in calib {
                let h = (p.b - (p.vx - 0.5) * HORIZONTAL_FOV_DEGREES) * .pi / 180
                sx += cos(h); sy += sin(h)
            }
            headingEst = (atan2(sy, sx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
        print("[Crop] plan: midDist=\(Int(midDist))m calib=\(calib.count)/\(n) heading=\(headingEst.map { String(Int($0)) } ?? "nil")")

        // Pass 2: pick the subject by MOTION CORRELATION, not instantaneous position. GPS position is too
        // noisy at close range to pick the right box per-frame, but the subject's motion *pattern* over the
        // whole clip is a fingerprint. Associate all Vision boxes into tracklets, score each tracklet's
        // motion against the GPS motion, and let the winner drive the crop. Bystanders (someone walking
        // through frame) score low and are ignored. Falls back to the old nearest-box logic when it can't
        // discriminate (too few tracklets, flat GPS motion, or no tracklet clears MIN_TRACKLET_SCORE).
        let gpsLateral = unwrapDegrees(samples.map { $0.bearing ?? 0 })   // bearing sweep (deg)
        let gpsProximity = samples.map { -$0.dist }                        // −distance: rises as subject nears, ∝ box size
        let tracklets = associateTracklets(perSampleBoxes: samples.map { $0.boxes })
        let discriminative = gpsMotionIsDiscriminative(lateral: gpsLateral, proximity: gpsProximity)

        var winner: Tracklet? = nil
        if tracklets.count >= 2 && discriminative {
            let scored = tracklets.map { trackletScore($0, gpsLateral: gpsLateral, gpsProximity: gpsProximity) }
            if let bi = scored.indices.max(by: { scored[$0] < scored[$1] }), scored[bi] >= MIN_TRACKLET_SCORE {
                winner = tracklets[bi]
                let fmt = scored.map { String(format: "%.2f", $0) }.joined(separator: ",")
                print("[Crop] tracklets: \(tracklets.count) candidates, scores=[\(fmt)] picked #\(bi)")
            } else {
                print("[Crop] tracklets: \(tracklets.count) candidates, best score < \(MIN_TRACKLET_SCORE) → fallback nearest-box")
            }
        } else {
            print("[Crop] tracklets: \(tracklets.count) candidates, discriminative=\(discriminative) → fallback nearest-box")
        }

        var raw: [(t: Double, cx: Double, cy: Double, cw: Double)] = []
        var onScreenCount = 0
        var lastCX = 0.5, lastCY = 0.5
        var lastLockT: Double? = nil

        if let winner {
            // Winning tracklet drives the crop. Where it has a box, use it. Where it's missing (gap), bridge
            // with GPS-predicted x within FOLLOW_GPS_BRIDGE_SECONDS of the last real box, else hold last
            // position (no GPS chasing — same anti-drift rule as before).
            let boxAt = Dictionary(uniqueKeysWithValues: zip(winner.idx, winner.boxes))
            for (i, s) in samples.enumerated() {
                var cx = lastCX, cy = lastCY, onScreen = false
                if let box = boxAt[i] {
                    cx = box.x; cy = box.y; onScreen = true; lastLockT = s.t
                } else if let h = headingEst, let b = s.bearing, let lt = lastLockT, s.t - lt <= FOLLOW_GPS_BRIDGE_SECONDS {
                    let ex = expectedCenterX(bearing: b, cameraCenterBearing: h)
                    cx = ex; onScreen = ex > 0.03 && ex < 0.97
                }
                if onScreen { onScreenCount += 1 }
                lastCX = cx; lastCY = cy
                raw.append((s.t, cx, cy, s.cw))
            }
        } else {
            // Fallback: original nearest-box-to-GPS-bearing selection with the same bridge/hold behavior.
            for s in samples {
                let expectedX = (headingEst != nil && s.bearing != nil)
                    ? expectedCenterX(bearing: s.bearing!, cameraCenterBearing: headingEst!) : nil
                let pick = expectedX.map { ex in s.boxes.min { abs($0.x - ex) < abs($1.x - ex) } }
                    ?? s.boxes.max { $0.conf < $1.conf }
                var cx = lastCX, cy = lastCY, onScreen = false
                if let box = pick, expectedX == nil || abs(box.x - expectedX!) <= VISION_GPS_MATCH_X {
                    cx = box.x; cy = box.y; onScreen = true; lastLockT = s.t
                } else if let ex = expectedX, let lt = lastLockT, s.t - lt <= FOLLOW_GPS_BRIDGE_SECONDS {
                    cx = ex; onScreen = ex > 0.03 && ex < 0.97
                }
                if onScreen { onScreenCount += 1 }
                lastCX = cx; lastCY = cy
                raw.append((s.t, cx, cy, s.cw))
            }
        }

        // Subject out of frame for most of the clip AND for too little absolute time → leave it full-frame.
        let onFrac = Double(onScreenCount) / Double(n)
        let onSecs = onFrac * dur.seconds
        guard onFrac >= FOLLOW_MIN_ONSCREEN || onSecs >= FOLLOW_MIN_ONSCREEN_SECONDS else {
            print("[Crop] plan: subject on-screen only \(onScreenCount)/\(n) (\(Int(onSecs))s), staying full-frame")
            return nil
        }

        // Offline pipeline: whole clip is known, so smooth zero-phase (forward + backward EMA, averaged).
        // A one-way EMA only adds phase lag → the crop trails the surfer ("delayed"). Averaging both
        // directions kills jitter without the lag. Applied to pan (x,y) AND zoom (cw) so neither judders.
        let a = FOLLOW_SMOOTHING
        func ema(_ vals: [Double], reversed: Bool) -> [Double] {
            let seq = reversed ? Array(vals.reversed()) : vals
            var out: [Double] = []; out.reserveCapacity(seq.count)
            var p = seq[0]
            for v in seq { p = a * p + (1 - a) * v; out.append(p) }
            return reversed ? out.reversed() : out
        }
        func smooth(_ vals: [Double]) -> [Double] {
            let f = ema(vals, reversed: false), b = ema(vals, reversed: true)
            return vals.indices.map { (f[$0] + b[$0]) / 2 }
        }
        let sxs = smooth(raw.map { $0.cx }), sys = smooth(raw.map { $0.cy }), sws = smooth(raw.map { $0.cw })
        let keys: [(t: Double, cx: Double, cy: Double, cw: Double)] = raw.indices.map {
            (t: raw[$0].t, cx: sxs[$0], cy: sys[$0], cw: sws[$0])
        }
        return CropPlan(renderW: sws.min() ?? MIN_CROP_WIDTH, keys: keys)
    }

    nonisolated static func recropClipFile(url: URL, plan: CropPlan) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let pt = try? await track.load(.preferredTransform),
              let dur = try? await asset.load(.duration) else { return false }
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30

        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(pt)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        // renderSize is constant = the tightest crop over the clip. Every frame's (>= this) crop region is
        // scaled down to fill it → the subject holds a roughly constant on-screen size as distance changes.
        let renderW = (plan.renderW * displaySize.width).rounded()
        let renderH = (plan.renderW * displaySize.height).rounded()
        guard renderW >= 16, renderH >= 16 else { return false }

        // Transform for one keyframe: take the cw-sized region centered at (cx,cy), clamp inside the frame,
        // shift its origin to (0,0), then scale it up to renderSize. cw == renderW/scale ⇒ dynamic zoom.
        func transform(cx: Double, cy: Double, cw: Double) -> CGAffineTransform {
            let regionW = cw * displaySize.width
            let regionH = cw * displaySize.height
            let ox = min(max(0, cx * displaySize.width - regionW / 2), displaySize.width - regionW).rounded()
            let oy = min(max(0, cy * displaySize.height - regionH / 2), displaySize.height - regionH).rounded()
            let scale = renderW / regionW  // isotropic; maps the crop region onto the constant render canvas
            // ponytail: assumes landscape source (native camera). Orient via preferredTransform, then shift, then zoom.
            return pt.concatenating(CGAffineTransform(translationX: -ox, y: -oy))
                     .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        }

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: renderW, height: renderH)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: dur)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        // Ramp the transform between consecutive keyframes → smooth pan + zoom. Times relative to clip (starts at 0).
        let keys = plan.keys
        layer.setTransform(transform(cx: keys[0].cx, cy: keys[0].cy, cw: keys[0].cw), at: .zero)
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            let range = CMTimeRange(
                start: CMTime(seconds: a.t, preferredTimescale: 600),
                end: CMTime(seconds: b.t, preferredTimescale: 600))
            layer.setTransformRamp(fromStart: transform(cx: a.cx, cy: a.cy, cw: a.cw), toEnd: transform(cx: b.cx, cy: b.cy, cw: b.cw), timeRange: range)
        }
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return false }
        exporter.videoComposition = comp
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try await exporter.export(to: tmp, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
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
            let gpsTrack: [GPSFix] = (dict["gpsTrack"] as? [[String: Any]] ?? []).compactMap { fix in
                guard let t = fix["t"] as? Double,
                      let lat = fix["lat"] as? Double,
                      let lon = fix["lon"] as? Double else { return nil }
                return GPSFix(t: t, lat: lat, lon: lon)
            }
            return PendingWatchSession(id: id, startDate: Date(timeIntervalSince1970: startI), endDate: Date(timeIntervalSince1970: endI), timestamps: timestamps, gpsTrack: gpsTrack)
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
