//
//  ContentView.swift
//  WristCutWatch Watch App
//
//  Created by Micah Woodring on 4/11/26.
//

import SwiftUI
import CloudKit
import Combine
import WatchKit

// MARK: - Command Sender

@MainActor
class CommandSender: ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "WristCut is waiting for iPhone..."
    @Published var isSending = false
    @Published var sessionActive = false

    private let container = CKContainer(identifier: "iCloud.Micah-Woodring.WristCut")
    private var pollingTask: Task<Void, Never>?
    private var lastPolledDate = Date()

    init() {
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
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
            print("📨 Watch received event: \(event)")
            handleEvent(event)
        } catch {
            print("❌ Watch CloudKit poll failed: \(error)")
        }
    }

    private func playHaptics(count: Int) async {
        for i in 0..<count {
            WKInterfaceDevice.current().play(.notification)
            if i < count - 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func handleEvent(_ event: String) {
        switch event {
        case "session_started":
            sessionActive = true
            statusMessage = "Ready"
            Task { await playHaptics(count: 1) }
        case "session_ended":
            sessionActive = false
            isRecording = false
            isSending = false
            statusMessage = "WristCut is waiting for iPhone..."
            Task { await playHaptics(count: 3) }
        default:
            break
        }
    }

    func toggleRecording() {
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
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var sender = CommandSender()
    @State private var crownValue: Double = 0.0
    private let threshold: Double = 2.0

    var body: some View {
        VStack(spacing: 14) {
            if !sender.sessionActive && !sender.isSending {
                VStack(spacing: 6) {
                    Text("WristCut")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Waiting for iPhone\nto Start Session")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
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

                        let progress = min(abs(crownValue) / threshold, 1.0)
                        let barColor: Color = sender.isRecording ? .red : .green

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                Capsule()
                                    .fill(barColor)
                                    .frame(width: geo.size.width * progress)
                                    .animation(.linear(duration: 0.05), value: progress)
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
        .digitalCrownRotation($crownValue)
        .onChange(of: crownValue) { _, value in
            if !sender.sessionActive {
                crownValue = 0
                return
            }
            if !sender.isRecording && !sender.isSending && value >= threshold {
                crownValue = 0
                sender.toggleRecording()
            } else if sender.isRecording && !sender.isSending && value <= -threshold {
                crownValue = 0
                sender.toggleRecording()
            }
        }
    }
}

#Preview {
    ContentView()
}
