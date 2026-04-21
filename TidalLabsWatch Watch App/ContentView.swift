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

// MARK: - Command Sender

@MainActor
class CommandSender: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Tidal Labs is waiting for iPhone..."
    @Published var isSending = false
    @Published var sessionActive = false
    @Published var sessionStartTime: Date?
    @Published var countdownRemaining: Int = 0
    @Published private(set) var countdownEndDate: Date?
    private var maxRecordingMinutes: Double = 60.0
    private var countdownTask: Task<Void, Never>?
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    private let container = CKContainer(identifier: "iCloud.Micah-Woodring.TidalLabs")
    private var pollingTask: Task<Void, Never>?
    private var lastPolledDate = Date()
    private var currentWaveStart: Date?

    private var storedTimestamps: [WaveTimestamp] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "waveTimestamps"),
                  let ts = try? JSONDecoder().decode([WaveTimestamp].self, from: data) else { return [] }
            return ts
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "waveTimestamps")
            }
        }
    }

    var isCellularMode: Bool {
        WCSession.default.receivedApplicationContext["cellularWatch"] as? Bool ?? false
    }

    override init() {
        super.init()
        setupConnectivity()
        startPolling()
        Task { await requestHealthKitAuthorization() }
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
        let read: Set<HKObjectType> = [HKObjectType.workoutType()]
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
            workoutSession = session
            workoutBuilder = builder
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())
        } catch {}
    }

    private func stopWorkoutSession() {
        workoutSession?.end()
        workoutSession = nil
        workoutBuilder = nil
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
            if sessionActive && delaySeconds > 0 {
                startCountdown(delaySeconds)
            }
        case "session_ended":
            countdownTask?.cancel()
            countdownTask = nil
            countdownRemaining = 0
            countdownEndDate = nil
            sessionActive = false
            sessionStartTime = nil
            isRecording = false
            isSending = false
            stopExtendedRuntimeSession()
            stopWorkoutSession()
            statusMessage = "Tidal Labs is waiting for iPhone..."
            Task { await playHaptics(count: 3) }
        default:
            break
        }
    }

    func startSessionFromWatch() {
        guard !sessionActive else { return }
        sessionActive = true
        sessionStartTime = Date()
        startExtendedRuntimeSession()
        statusMessage = "Ready"
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
            self.statusMessage = "Ready"
            await self.playHaptics(count: 2)
        }
    }

    func refreshCountdown() {
        guard let end = countdownEndDate else { return }
        let remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        countdownRemaining = remaining
        statusMessage = remaining > 0 ? "\(remaining)s" : "Ready"
    }

    func toggleRecording() {
        if isCellularMode {
            toggleCellularRecording()
        } else {
            toggleNonCellularRecording()
        }
    }

    private func toggleCellularRecording() {
        guard !isSending else { return }
        let command = isRecording ? "stop" : "start"
        isSending = true
        statusMessage = command == "start" ? "Starting..." : "Stopping..."

        let record = CKRecord(recordType: "RecordingCommand")
        record["command"] = command as CKRecordValue
        record["issuedAt"] = Date() as CKRecordValue

        Task {
            do {
                try await container.privateCloudDatabase.save(record)
                isRecording = !isRecording
                statusMessage = isRecording ? "Recording" : "Stopped"
                await playHaptics(count: isRecording ? 2 : 3)
            } catch {
                statusMessage = "Failed — check connection"
            }
            isSending = false
        }
    }

    private func toggleNonCellularRecording() {
        if !isRecording {
            currentWaveStart = Date()
            isRecording = true
            statusMessage = "Recording"
            Task { await playHaptics(count: 2) }
        } else {
            guard let start = currentWaveStart else { return }
            let ts = WaveTimestamp(start: start, end: Date())
            var stored = storedTimestamps
            stored.append(ts)
            storedTimestamps = stored
            currentWaveStart = nil
            isRecording = false
            statusMessage = "Stopped"
            Task { await playHaptics(count: 3) }
            sendPendingTimestamps()
        }
    }

    private func sendPendingTimestamps() {
        let timestamps = storedTimestamps
        guard !timestamps.isEmpty,
              WCSession.default.activationState == .activated else { return }
        let payload = timestamps.map { ["id": $0.id, "start": $0.start, "end": $0.end] as [String: Any] }
        WCSession.default.transferUserInfo(["waveTimestamps": payload])
    }

    var pendingWaveCount: Int { storedTimestamps.count }

    var estimatedEndTime: Date? {
        guard let start = sessionStartTime else { return nil }
        return start.addingTimeInterval(maxRecordingMinutes * 60.0)
    }

    func syncToPhone() {
        guard !storedTimestamps.isEmpty,
              WCSession.default.activationState == .activated else {
            statusMessage = "Nothing to sync"
            return
        }
        statusMessage = "Syncing \(storedTimestamps.count) waves..."
        sendPendingTimestamps()
        statusMessage = "Sync sent!"
    }

    fileprivate func clearConfirmedTimestamps(ids: [String]) {
        var stored = storedTimestamps
        stored.removeAll { ids.contains($0.id) }
        storedTimestamps = stored
    }
}

// MARK: - WCSessionDelegate

extension CommandSender: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            Task { @MainActor in self.sendPendingTimestamps() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let confirmedIDs = applicationContext["confirmedTimestampIDs"] as? [String] {
            Task { @MainActor in self.clearConfirmedTimestamps(ids: confirmedIDs) }
        }
        if let maxMins = applicationContext["maxRecordingMinutes"] as? Double {
            Task { @MainActor in self.maxRecordingMinutes = maxMins }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let event = message["event"] as? String {
            let delay = message["delaySeconds"] as? Int ?? 0
            Task { @MainActor in self.handleEvent(event, delaySeconds: delay) }
        }
    }
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
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var sender = CommandSender()
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    @State private var barProgress: Double = 0.0
    @State private var idleTask: Task<Void, Never>? = nil
    @State private var isTriggering: Bool = false
    @FocusState private var crownFocused: Bool

    private let deadZone: Double = 1
    private let crownStep: Double = 0.03

    var body: some View {
        VStack(spacing: 14) {
            if !sender.sessionActive && !sender.isSending {
                VStack(spacing: 10) {
                    Text("Tidal Labs")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    Button(action: { sender.startSessionFromWatch() }) {
                        Text("Start Session")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                if let endTime = sender.estimatedEndTime {
                    Text("Ends \(endTime.formatted(date: .omitted, time: .shortened))")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    if sender.isRecording {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                    }
                    Text(sender.statusMessage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .animation(.easeInOut(duration: 0.2), value: sender.isRecording)

                if !sender.isCellularMode && sender.pendingWaveCount > 0 && !sender.isRecording && !sender.sessionActive {
                    Button(action: { sender.syncToPhone() }) {
                        Text("Sync \(sender.pendingWaveCount) Wave\(sender.pendingWaveCount == 1 ? "" : "s")")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if sender.isSending {
                    ProgressView()
                        .tint(.white)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: sender.isRecording ? "chevron.up" : "chevron.down")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(sender.isRecording ? .red : .green)

                        Text(sender.isRecording ? "Scroll Up to Stop" : "Scroll Down to Start")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)

                        let barColor: Color = sender.isRecording ? .red : .green

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                Capsule()
                                    .fill(barColor)
                                    .frame(width: geo.size.width * barProgress)
                                    .animation(.linear(duration: 0.05), value: barProgress)
                            }
                        }
                        .frame(height: 6)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding()
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation($crownValue)
        .onAppear { crownFocused = true }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
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

            // Flip delta so "correct direction" is always positive
            let effectiveDelta = sender.isRecording ? -rawDelta : rawDelta

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
                sender.toggleRecording()
                // Lockout period so rapid crown events can't re-trigger before state flips
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    isTriggering = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
