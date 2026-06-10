import SwiftUI
import PhotosUI
import AVKit
import Photos

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

// MARK: - Pending Import View

struct PendingImportView: View {
    @ObservedObject var camera: CameraManager
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isLoadingVideo && camera.pendingImportVideo == nil {
                VStack(spacing: 0) {
                    HStack {
                        Color.clear.frame(width: 38, height: 38)
                        Spacer()
                        Text("Import Video")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Color.clear.frame(width: 38, height: 38)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                        Text("Copying video...")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                            .foregroundStyle(.white)
                        Text("This may take a moment.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
            } else if let pending = camera.pendingImportVideo {
                VStack(spacing: 0) {
                    HStack {
                        if !camera.isProcessingImport {
                            Button(action: { camera.cancelPendingImport() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.white.opacity(0.15))
                                    .clipShape(Circle())
                            }
                        } else {
                            Color.clear.frame(width: 38, height: 38)
                        }
                        Spacer()
                        Text("Import Video")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Color.clear.frame(width: 38, height: 38)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    if let player {
                        VideoPlayer(player: player)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 20)
                    }

                    VStack(spacing: 4) {
                        Text(pending.creationDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(formatDuration(pending.durationSeconds))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.top, 16)

                    Spacer()

                    if camera.isProcessingImport {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                            Text("Trimming wave clips...")
                                .font(.system(.callout, design: .rounded, weight: .medium))
                                .foregroundStyle(.white)
                            Text("This may take a moment.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "applewatch")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("Sync your Apple Watch")
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Press \"Sync Waves\" on your watch.\nThe app will auto-trim based on your timestamps.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 32)
                    }

                    Spacer()
                }
                .onAppear {
                    player = AVPlayer(url: pending.url)
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}

// MARK: - Sessions View

struct SessionsView: View {
    @ObservedObject var camera: CameraManager
    @State private var selectedSession: WaveSession?
    @State private var sessionToDelete: WaveSession?
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var pendingDeletePhotoID: String?
    @State private var showDeletePhotoAlert = false

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
                                .onLongPressGesture { sessionToDelete = session }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 36, height: 36)
                        if isImporting {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                        }
                    }
                }
                .disabled(isImporting)
            }
        }
        .onChange(of: selectedVideoItem) { _, item in
            guard let item else { return }
            isImporting = true
            Task {
                await handleVideoImport(item)
                selectedVideoItem = nil
                isImporting = false
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { camera.pendingImportVideo != nil || camera.isLoadingVideo },
            set: { if !$0 { camera.cancelPendingImport(); camera.isLoadingVideo = false } }
        )) {
            PendingImportView(camera: camera)
        }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            if let err = importError { Text(err) }
        }
        .fullScreenCover(item: $selectedSession) { session in
            SessionDetailView(sessionID: session.id, camera: camera, onDismiss: { selectedSession = nil })
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = sessionToDelete { camera.deleteSession(s.id) }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: {
            if let s = sessionToDelete {
                Text("\(s.clips.count) wave\(s.clips.count == 1 ? "" : "s") will be permanently deleted.")
            }
        }
        .confirmationDialog(
            "Delete Original Video?",
            isPresented: $showDeletePhotoAlert,
            titleVisibility: .visible
        ) {
            Button("Delete from Photos", role: .destructive) {
                if let id = pendingDeletePhotoID { deletePhotoAsset(id) }
                pendingDeletePhotoID = nil
            }
            Button("Keep", role: .cancel) { pendingDeletePhotoID = nil }
        } message: {
            Text("Wave clips saved. Remove the original video from your photo library?")
        }
        .onChange(of: camera.clipGenerationCompleted) { _, _ in
            if pendingDeletePhotoID != nil { showDeletePhotoAlert = true }
        }
    }

    private func deletePhotoAsset(_ identifier: String) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        })
    }

    private func handleVideoImport(_ item: PhotosPickerItem) async {
        pendingDeletePhotoID = item.itemIdentifier
        camera.isLoadingVideo = true
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                camera.isLoadingVideo = false
                importError = "Could not load video."
                pendingDeletePhotoID = nil
                return
            }
            let success = await camera.storeImportedVideo(from: movie.url)
            camera.isLoadingVideo = false
            if !success {
                importError = "Could not read video timestamp."
                pendingDeletePhotoID = nil
            }
        } catch {
            camera.isLoadingVideo = false
            importError = "Could not load video."
            pendingDeletePhotoID = nil
        }
    }
}
