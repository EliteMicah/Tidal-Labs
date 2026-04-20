import SwiftUI

struct SessionRow: View {
    let session: WaveSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(session.startDate.formatted(date: .omitted, time: .shortened)) – \(session.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Text("\(session.clips.count) wave\(session.clips.count == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.white.opacity(0.4))
                .font(.system(.caption))
        }
        .padding(12)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SessionDetailView: View {
    let sessionID: UUID
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void
    @State private var selectedClip: SessionRecording?

    private var session: WaveSession? {
        camera.waveSessions.first { $0.id == sessionID }
    }

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    Spacer()
                    if let session {
                        VStack(spacing: 2) {
                            Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("\(session.startDate.formatted(date: .omitted, time: .shortened)) – \(session.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if let session, !session.clips.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(session.clips) { clip in
                                let recording = SessionRecording(
                                    id: clip.id,
                                    url: docs.appendingPathComponent(clip.filename),
                                    date: clip.date
                                )
                                RecordingRow(recording: recording)
                                    .onTapGesture { selectedClip = recording }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                } else {
                    Text("No clips")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.system(.body, design: .rounded))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .fullScreenCover(item: $selectedClip) { recording in
            SessionPlayerView(
                recording: recording,
                onDismiss: { selectedClip = nil },
                onDelete: {
                    camera.deleteClip(recording.id, fromSession: sessionID)
                    selectedClip = nil
                }
            )
        }
    }
}

struct SessionsView: View {
    @ObservedObject var camera: CameraManager
    @State private var selectedSession: WaveSession?

    var body: some View {
        Group {
            if camera.waveSessions.isEmpty {
                Text("No sessions yet")
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.system(.body, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(camera.waveSessions) { session in
                            SessionRow(session: session)
                                .onTapGesture { selectedSession = session }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .background(Color.black.ignoresSafeArea())
            }
        }
        .navigationTitle("Sessions")
        .fullScreenCover(item: $selectedSession) { session in
            SessionDetailView(sessionID: session.id, camera: camera, onDismiss: { selectedSession = nil })
        }
    }
}
