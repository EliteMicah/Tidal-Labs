//
//  ContentView.swift
//  WristCutWatch Watch App
//
//  Created by Micah Woodring on 4/11/26.
//

import SwiftUI
import CloudKit
import Combine

// MARK: - Command Sender

@MainActor
class CommandSender: ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Ready"
    @Published var isSending = false

    private let container = CKContainer(identifier: "iCloud.Micah-Woodring.WristCut")

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

    var body: some View {
        VStack(spacing: 12) {
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

            Button {
                sender.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(sender.isRecording ? Color.red : Color.green)
                        .frame(width: 72, height: 72)
                    Image(systemName: sender.isRecording ? "stop.fill" : "video.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(sender.isSending)
            .opacity(sender.isSending ? 0.5 : 1.0)
            .overlay {
                if sender.isSending {
                    ProgressView()
                        .tint(.white)
                }
            }

            Text(sender.isRecording ? "Tap to Stop" : "Tap to Record")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
