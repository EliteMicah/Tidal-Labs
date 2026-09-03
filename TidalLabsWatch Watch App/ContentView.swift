//
//  ContentView.swift
//  TidalLabsWatch Watch App
//
//  Created by Micah Woodring on 4/11/26.
//

import SwiftUI
import CloudKit
import Combine
import WatchKit
import WatchConnectivity
import HealthKit
import CoreLocation

// MARK: - Wave Timestamp

struct WaveTimestamp: Codable {
    let id: String
    let start: Double
    let end: Double

    init(start: Date, end: Date) {
        self.id = UUID().uuidString
        self.start = start.timeIntervalSince1970
        self.end = end.timeIntervalSince1970
    }
}

// MARK: - GPS Fix

struct GPSFix: Codable {
    let t: Double   // timeIntervalSince1970
    let lat: Double
    let lon: Double
}

// MARK: - Watch Surf Session

struct WatchSurfSession: Codable {
    let id: String
    let startDate: Date
    let endDate: Date
    var timestamps: [WaveTimestamp]
    var gpsTrack: [GPSFix]?   // optional: old persisted sessions decode without it
}

// MARK: - Command Sender

@MainActor
class CommandSender: NSObject, ObservableObject {
    @Published var statusMessage = "Tidal Labs is waiting for iPhone..."
    @Published var isSending = false
    @Published var heartRate: Double? = nil
    @Published var sessionActive = false
    @Published var sessionStartTime: Date?
    @Published var countdownRemaining: Int = 0
    @Published private(set) var countdownEndDate: Date?
    @Published var sessionWaveCount: Int = 0
    @Published var isSyncing = false
    @Published var syncFeedback = ""
    private var waveDurationSeconds: Double = 60.0
    private var maxRecordingMinutes: Double = 60.0
    private var countdownTask: Task<Void, Never>?
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    private let container = CKContainer(identifier: "iCloud.Micah-Woodring.TidalLabs")
    private var pollingTask: Task<Void, Never>?
    private var lastPolledDate = Date()

    private let locationManager = CLLocationManager()

    // Active session (in-memory only, not persisted until finalized)
    private var activeSessionID: String?
    private var activeSessionStart: Date?
    private var activeSessionTimestamps: [WaveTimestamp] = []
    private var activeSessionGPS: [GPSFix] = []

    // Completed sessions persisted until phone confirms receipt
    private var completedSessions: [WatchSurfSession] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "completedWatchSessions"),
                  let sessions = try? JSONDecoder().decode([WatchSurfSession].self, from: data) else { return [] }
            return sessions
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "completedWatchSessions")
            }
        }
    }

    var pendingSessionCount: Int { completedSessions.count }

    var isCellularMode: Bool {
        WCSession.default.receivedApplicationContext["cellularWatch"] as? Bool ?? false
    }

    override init() {
        super.init()
        setupConnectivity()
        startPolling()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        // HealthKit auth requested from the view's .task (app active), not here — see ContentView body.
    }

    deinit {
        pollingTask?.cancel()
    }

    private func setupConnectivity() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                await pollSessionEvents()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func pollSessionEvents() async {
        guard isCellularMode else { return }
        let predicate = NSPredicate(format: "issuedAt > %@", lastPolledDate as CVarArg)
        let query = CKQuery(recordType: "SessionEvent", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "issuedAt", ascending: true)]

        do {
            let (matchResults, _) = try await container.privateCloudDatabase.records(matching: query)
            let records = matchResults
                .compactMap { try? $1.get() }
                .sorted { ($0["issuedAt"] as? Date ?? .distantPast) < ($1["issuedAt"] as? Date ?? .distantPast) }

            guard let latest = records.last,
                  let event = latest["event"] as? String,
                  let issuedAt = latest["issuedAt"] as? Date else { return }

            lastPolledDate = issuedAt
            handleEvent(event)
        } catch {}
    }

    private func playHaptics(count: Int) async {
        for i in 0..<count {
            WKInterfaceDevice.current().play(.directionUp)
            if i < count - 1 {
                try? await Task.sleep(nanoseconds: 175_000_000)
            }
        }
    }

    func requestHealthKitAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]
        try? await healthStore.requestAuthorization(toShare: share, read: read)
    }

    private func startWorkoutSession() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .surfingSports
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())
            // ponytail: no allowsBackgroundLocationUpdates — it throws an uncatchable NSException on watchOS
            // and crashes Start. The active HKWorkoutSession keeps the app alive so location keeps flowing.
            // If true wrist-down background GPS is needed, add CLBackgroundActivitySession (watchOS 9+) and test.
            locationManager.startUpdatingLocation()
        } catch {}
    }

    private func stopWorkoutSession() async {
        locationManager.stopUpdatingLocation()
        guard let session = workoutSession, let builder = workoutBuilder else { return }
        let endDate = Date()
        session.end()
        do {
            try await builder.endCollection(at: endDate)
            _ = try await builder.finishWorkout()
        } catch {}
        workoutSession = nil
        workoutBuilder = nil
        heartRate = nil
    }

    private func startExtendedRuntimeSession() {
        extendedRuntimeSession?.invalidate()
        let ers = WKExtendedRuntimeSession()
        ers.delegate = self
        ers.start()
        extendedRuntimeSession = ers
    }

    private func stopExtendedRuntimeSession() {
        extendedRuntimeSession?.invalidate()
        extendedRuntimeSession = nil
    }

    private func handleEvent(_ event: String, delaySeconds: Int = 0) {
        switch event {
        case "session_started":
            if !sessionActive {
                sessionActive = true
                sessionStartTime = Date()
                sessionWaveCount = 0
                activeSessionID = UUID().uuidString
                activeSessionStart = sessionStartTime
                activeSessionTimestamps = []
                activeSessionGPS = []
                startExtendedRuntimeSession()
                statusMessage = delaySeconds > 0 ? "\(delaySeconds)s" : ""
                // Engage water lock now. Skip only while location auth is still undetermined — that's the one
                // moment the permission alert is up and water lock would collide with it. Once auth is decided
                // the alert is gone, so it's safe. The .running delegate is a backstop but can't engage from
                // background, so relying on it alone left phone-started sessions with no water lock.
                if locationManager.authorizationStatus != .notDetermined {
                    WKInterfaceDevice.current().enableWaterLock()
                }
                Task {
                    await startWorkoutSession()
                    await playHaptics(count: 1)
                }
                if delaySeconds > 0 { startCountdown(delaySeconds) }
            } else if delaySeconds > 0 {
                startCountdown(delaySeconds)
            }
        case "session_ended":
            finalizeCurrentSession()
        default:
            break
        }
    }

    func startSessionFromWatch() {
        guard !sessionActive else { return }
        // Enable water lock synchronously on the Start tap — a direct user gesture while foreground is the
        // one context enableWaterLock() reliably engages. No gate: safe no-op on non-water-resistant devices.
        WKInterfaceDevice.current().enableWaterLock()
        sessionActive = true
        sessionStartTime = Date()
        sessionWaveCount = 0
        activeSessionID = UUID().uuidString
        activeSessionStart = sessionStartTime
        activeSessionTimestamps = []
        activeSessionGPS = []
        startExtendedRuntimeSession()
        statusMessage = ""
        // Water lock enabled from the workout .running delegate — see startWorkoutSession / the delegate.
        Task {
            await startWorkoutSession()
            await playHaptics(count: 1)
        }

        let message: [String: Any] = ["event": "watch_started_session"]
        if WCSession.default.activationState == .activated && WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil)
        }
        if isCellularMode {
            Task {
                let record = CKRecord(recordType: "SessionEvent")
                record["event"] = "watch_started_session" as CKRecordValue
                record["issuedAt"] = Date() as CKRecordValue
                _ = try? await container.privateCloudDatabase.save(record)
            }
        }
    }

    func endSessionFromWatch() {
        finalizeCurrentSession()
    }

    private func finalizeCurrentSession() {
        if let id = activeSessionID, let start = activeSessionStart, !activeSessionTimestamps.isEmpty {
            let watchSession = WatchSurfSession(id: id, startDate: start, endDate: Date(), timestamps: activeSessionTimestamps, gpsTrack: activeSessionGPS)
            var sessions = completedSessions
            sessions.append(watchSession)
            completedSessions = sessions
        }
        activeSessionID = nil
        activeSessionStart = nil
        activeSessionTimestamps = []
        activeSessionGPS = []
        resetSessionState()
    }

    private func resetSessionState() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = 0
        countdownEndDate = nil
        sessionActive = false
        sessionStartTime = nil
        isSending = false
        stopExtendedRuntimeSession()
        Task { await stopWorkoutSession() }
        statusMessage = "Tidal Labs is waiting for iPhone..."
        Task { await playHaptics(count: 3) }
    }

    private func startCountdown(_ seconds: Int) {
        countdownTask?.cancel()
        let endDate = Date().addingTimeInterval(Double(seconds))
        countdownEndDate = endDate
        countdownRemaining = seconds
        statusMessage = "\(seconds)s"
        countdownTask = Task { @MainActor in
            // Sleep for the full duration using continuous clock (wall time)
            try? await Task.sleep(until: .now + .seconds(seconds), clock: .continuous)
            guard !Task.isCancelled, self.sessionActive else { return }
            self.countdownEndDate = nil
            self.countdownRemaining = 0
            self.statusMessage = ""
            await self.playHaptics(count: 2)
        }
    }

    func refreshCountdown() {
        guard let end = countdownEndDate else { return }
        let remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        countdownRemaining = remaining
        statusMessage = remaining > 0 ? "\(remaining)s" : ""
    }

    func recordWave() {
        if isCellularMode {
            recordWaveCellular()
        } else {
            recordWaveNonCellular()
        }
    }

    private func recordWaveCellular() {
        guard !isSending else { return }
        isSending = true
        let now = Date()
        let start = now.addingTimeInterval(-waveDurationSeconds)
        let record = CKRecord(recordType: "WaveRecord")
        record["startTime"] = start.timeIntervalSince1970 as CKRecordValue
        record["endTime"] = now.timeIntervalSince1970 as CKRecordValue
        record["issuedAt"] = now as CKRecordValue
        Task {
            do {
                try await container.privateCloudDatabase.save(record)
                sessionWaveCount += 1
                statusMessage = "Wave \(sessionWaveCount) logged"
                await playHaptics(count: 2)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if sessionActive { statusMessage = "" }
            } catch {
                statusMessage = "Failed — check connection"
            }
            isSending = false
        }
    }

    private func recordWaveNonCellular() {
        let now = Date()
        let start = now.addingTimeInterval(-waveDurationSeconds)
        let ts = WaveTimestamp(start: start, end: now)
        activeSessionTimestamps.append(ts)
        sessionWaveCount += 1
        statusMessage = "Wave \(sessionWaveCount) logged"
        Task {
            await playHaptics(count: 2)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if sessionActive { statusMessage = "" }
        }
    }

    private func buildSessionsPayload() -> [[String: Any]] {
        completedSessions.map { s in
            [
                "id": s.id,
                "startDate": s.startDate.timeIntervalSince1970,
                "endDate": s.endDate.timeIntervalSince1970,
                "timestamps": s.timestamps.map { ts -> [String: Any] in
                    ["id": ts.id, "start": ts.start, "end": ts.end]
                },
                "gpsTrack": (s.gpsTrack ?? []).map { fix -> [String: Any] in
                    ["t": fix.t, "lat": fix.lat, "lon": fix.lon]
                }
            ]
        }
    }

    private func sendPendingSessions() {
        let sessions = completedSessions
        guard !sessions.isEmpty,
              WCSession.default.activationState == .activated else {
            isSyncing = false
            return
        }
        let payload = buildSessionsPayload()

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["watchSessions": payload], replyHandler: { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSyncing = false
                    self?.showSyncFeedback("Sent!")
                }
            }, errorHandler: { [weak self] _ in
                WCSession.default.transferUserInfo(["watchSessions": payload])
                Task { @MainActor [weak self] in
                    self?.isSyncing = false
                    self?.showSyncFeedback("Queued")
                }
            })
        } else {
            WCSession.default.transferUserInfo(["watchSessions": payload])
            isSyncing = false
            showSyncFeedback("Queued — open iPhone app")
        }
    }

    private func showSyncFeedback(_ message: String) {
        syncFeedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncFeedback = ""
        }
    }

    func syncToPhone() {
        guard !completedSessions.isEmpty,
              WCSession.default.activationState == .activated else {
            showSyncFeedback("Nothing to sync")
            return
        }
        isSyncing = true
        syncFeedback = ""
        sendPendingSessions()
    }

    fileprivate func clearConfirmedSessions(ids: [String]) {
        var sessions = completedSessions
        sessions.removeAll { ids.contains($0.id) }
        completedSessions = sessions
    }
}

// MARK: - WCSessionDelegate

extension CommandSender: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let confirmedIDs = applicationContext["confirmedSessionIDs"] as? [String] {
            Task { @MainActor in self.clearConfirmedSessions(ids: confirmedIDs) }
        }
        if let maxMins = applicationContext["maxRecordingMinutes"] as? Double {
            Task { @MainActor in self.maxRecordingMinutes = maxMins }
        }
        if let waveDur = applicationContext["waveDurationSeconds"] as? Double {
            Task { @MainActor in self.waveDurationSeconds = waveDur }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let event = message["event"] as? String {
            let delay = message["delaySeconds"] as? Int ?? 0
            Task { @MainActor in self.handleEvent(event, delaySeconds: delay) }
        }
        if message["requestSync"] as? Bool == true {
            Task { @MainActor in self.sendPendingSessions() }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension CommandSender: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { GPSFix(t: $0.timestamp.timeIntervalSince1970, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        Task { @MainActor in
            guard self.sessionActive else { return }
            self.activeSessionGPS.append(contentsOf: fixes)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension CommandSender: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {}
}

// MARK: - HKWorkoutSessionDelegate

extension CommandSender: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .running {
            // Single reliable water-lock point: workout is running and (for on-watch starts) the app is
            // foreground, so this is the one moment enableWaterLock() actually engages. No wr50 gate — it's
            // a safe no-op on devices without water resistance, and the gate silently skipped the Simulator.
            Task { @MainActor in WKInterfaceDevice.current().enableWaterLock() }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension CommandSender: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType) else { return }
        let bpm = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
        Task { @MainActor in self.heartRate = bpm }
    }
}

// MARK: - Palette
//
// The 1a "ring" direction, straight off the design canvas. The phone target's DesignSystem.swift
// is not a member of the watch target (the project uses file-system-synchronized groups, so a file
// belongs to the folder it lives in) and it depends on UIFontDescriptor for the variable fonts,
// which the watch does not bundle. These are the handful of tokens the two watch screens use.

private extension Color {
    init(tl: UInt32) {
        self.init(
            red: Double((tl >> 16) & 0xFF) / 255,
            green: Double((tl >> 8) & 0xFF) / 255,
            blue: Double(tl & 0xFF) / 255
        )
    }

    static let tlNight     = Color(tl: 0x050D18)   // recording backdrop
    static let tlNightTop  = Color(tl: 0x0B1D33)   // idle gradient, top
    static let tlNightBot  = Color(tl: 0x071322)   // idle gradient, bottom
    static let tlCyan      = Color(tl: 0x56CDEC)   // the accent — ring fill, Start, crown hint
    static let tlOnCyan    = Color(tl: 0x06202F)   // ink on a cyan fill
    static let tlInk       = Color(tl: 0xEEF5FC)
    static let tlInkSoft   = Color(tl: 0x9FB6CE)
    static let tlSyncInk   = Color(tl: 0x9FC0FF)
    static let tlSyncEdge  = Color(tl: 0x5B86FF)
    static let tlHeart     = Color(tl: 0xFF3B4E)
    static let tlHeartInk  = Color(tl: 0xFFB2A0)
    static let tlDanger    = Color(tl: 0xE5484D)
    static let tlDangerInk = Color(tl: 0xFF8A8E)
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var sender = CommandSender()
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    @State private var barProgress: Double = 0.0
    @State private var idleTask: Task<Void, Never>? = nil
    @State private var isTriggering: Bool = false
    @State private var now = Date()
    @FocusState private var crownFocused: Bool

    private static func elapsed(since start: Date, now: Date) -> String {
        let t = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private let deadZone: Double = 1
    private let crownStep: Double = 0.03

    private var isRecording: Bool { sender.sessionActive || sender.isSending }

    var body: some View {
        ZStack {
            background
            if isRecording {
                recordingScreen
            } else {
                idleScreen
            }
        }
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation($crownValue)
        .onAppear { crownFocused = true }
        // HealthKit auth here, not in init(): init runs during view construction before the app is
        // frontmost-active, and that early request silently drops the prompt (location tolerates it, HK doesn't).
        .task { await sender.requestHealthKitAuthorization() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
            if sender.countdownEndDate != nil { sender.refreshCountdown() }
        }
        .onChange(of: crownValue) { _, value in
            let rawDelta = value - lastCrownValue
            lastCrownValue = value

            guard sender.sessionActive, sender.countdownRemaining == 0 else {
                crownValue = 0
                lastCrownValue = 0
                barProgress = 0
                return
            }

            guard !sender.isSending, !isTriggering else { return }

            let effectiveDelta = -rawDelta

            guard effectiveDelta > deadZone else { return }

            barProgress = min(1.0, barProgress + crownStep)

            // Schedule idle decay after 2s of no scrolling
            idleTask?.cancel()
            idleTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.5)) {
                    barProgress = 0.0
                }
            }

            if barProgress >= 1.0 {
                isTriggering = true
                barProgress = 0.0
                crownValue = 0
                lastCrownValue = 0
                idleTask?.cancel()
                sender.recordWave()
                // Lockout period so rapid crown events can't re-trigger before state flips
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    isTriggering = false
                }
            }
        }
    }

    // MARK: Backdrop

    @ViewBuilder
    private var background: some View {
        if isRecording {
            Color.tlNight.ignoresSafeArea()
        } else {
            ZStack {
                LinearGradient(
                    colors: [.tlNightTop, .tlNightBot],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // The cyan wash the idle screen carries above the wordmark.
                RadialGradient(
                    colors: [Color.tlCyan.opacity(0.14), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 170
                )
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Idle

    private var idleScreen: some View {
        VStack(spacing: 10) {
            Text("Tidal Labs")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tlInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Button(action: { sender.startSessionFromWatch() }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .black))
                    Text("Start")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(Color.tlOnCyan)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.tlCyan, in: Capsule())
            }
            .buttonStyle(.plain)

            if sender.pendingSessionCount > 0 {
                Button(action: { sender.syncToPhone() }) {
                    HStack(spacing: 6) {
                        if sender.isSyncing {
                            ProgressView()
                                .tint(Color.tlSyncInk)
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Text(sender.isSyncing ? "Syncing" : "Sync \(sender.pendingSessionCount)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.tlSyncInk)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Color.tlSyncEdge.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.tlSyncEdge.opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(sender.isSyncing)
            }

            if !sender.syncFeedback.isEmpty {
                Text(sender.syncFeedback)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tlInkSoft.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Recording

    private var recordingScreen: some View {
        VStack(spacing: 6) {
            statBar
            crownRing
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    //! Heart rate left, wave count right, on the one line above the ring.
    private var statBar: some View {
        HStack(spacing: 0) {
            if let bpm = sender.heartRate {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tlHeart)
                    Text("\(Int(bpm))")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.tlHeartInk)
                    Text("BPM")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tlHeartInk.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Text(String(format: "%02d", sender.sessionWaveCount))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.tlInk)
                Text("WAVES")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(0.6)
                    .foregroundStyle(Color.tlInkSoft.opacity(0.8))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    //! The crown fill *is* the face: the progress that used to be a bar under the clock is now
    //! the ring around it, so the thing you are winding up and the thing you are reading are one
    //! element. Squares itself to whatever height the stat bar and footer leave over.
    private var crownRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0, to: barProgress)
                .stroke(Color.tlCyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: barProgress)

            if sender.isSending {
                ProgressView().tint(.white)
            } else if sender.statusMessage.isEmpty, let start = sender.sessionStartTime {
                Text(Self.elapsed(since: start, now: now))
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
            } else {
                // Countdown and one-shot status ("Wave 3 logged") take the middle of the ring.
                Text(sender.statusMessage)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tlInkSoft)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 16)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        Button(action: { sender.endSessionFromWatch() }) {
            Text("End Session")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tlDangerInk)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(Color.tlDanger.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.tlDanger.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
