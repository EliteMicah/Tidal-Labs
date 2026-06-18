import SwiftUI
import AVKit
import Photos

// MARK: - Sessions list

struct SessionsView: View {
    @ObservedObject var camera: CameraManager
    @State private var selectedSession: WaveSession?
    @State private var sessionToDelete: WaveSession?
    @State private var sessionForContextMenu: WaveSession?
    @State private var sessionToRename: WaveSession?
    @State private var renameDraft = ""
    @State private var showVideoPicker = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showSettingsRedirect = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private var totalWaves: Int { camera.waveSessions.reduce(0) { $0 + $1.clips.count } }

    var body: some View {
        ZStack(alignment: .bottom) {
            TLBackground()

            VStack(spacing: 0) {
                // Header
                TLScreenHeader(
                    title: "Your Sessions",
                    onBack: { dismiss() },
                    trailing: AnyView(
                        Button {
                            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                                DispatchQueue.main.async { showVideoPicker = true }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.tlAccent)
                                    .frame(width: 44, height: 44)
                                    .shadow(color: Color.tlAccent.opacity(0.35), radius: 8, x: 0, y: 4)
                                if isImporting {
                                    ProgressView().tint(.white).scaleEffect(0.75)
                                } else {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .disabled(isImporting)
                    )
                )
                .padding(.top, 8)
                .padding(.bottom, 10)

                if camera.waveSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }

            ZStack(alignment: .bottom) {
                WaveStrip(
                    color: scheme == .dark ? Color(tlHex: "56CDEC") : Color.tlCyan,
                    height: 92, opacity: 0.25, dur: 11
                )
                WaveStrip(
                    color: Color.tlAccent,
                    height: 74, opacity: scheme == .dark ? 0.5 : 0.85, dur: 7
                )
            }
            .frame(height: 92)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationBarHidden(true)
        .enableSwipeBack()
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(
                onProgress: { progress in
                    camera.iCloudDownloadProgress = progress
                },
                onResult: { result in
                    isImporting = true
                    camera.isLoadingVideo = true
                    Task {
                        switch result {
                        case .success(let (asset, tempURL, assetID)):
                            camera.lastImportedOriginalAssetID = assetID
                            let success = await camera.storeImportedVideo(asset: asset, tempURL: tempURL)
                            camera.isLoadingVideo = false
                            if !success { importError = "Could not read video timestamp." }
                        case .failure(let error):
                            print("[VideoImport] SessionsView: picker error=\(error)")
                            camera.isLoadingVideo = false
                            importError = "Could not load video."
                        }
                        isImporting = false
                    }
                }
            )
        }
        .fullScreenCover(isPresented: Binding(
            get: { camera.pendingImportVideo != nil || camera.isLoadingVideo },
            set: { if !$0 { camera.cancelPendingImport(); camera.isLoadingVideo = false } }
        )) { PendingImportView(camera: camera) }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            if let err = importError { Text(err) }
        }
        .alert("Photos Access Required", isPresented: $showSettingsRedirect) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TidalLabs needs Photos access to import videos. Enable it in Settings > TidalLabs > Photos.")
        }
        .fullScreenCover(item: $selectedSession) { session in
            SessionDetailView(
                sessionID: session.id,
                camera: camera,
                onDismiss: { selectedSession = nil },
                shouldPromptDelete: camera.lastImportedOriginalAssetID != nil,
                onDeleteConfirm: {
                    if let id = camera.lastImportedOriginalAssetID { deletePhotoAsset(id) }
                    camera.lastImportedOriginalAssetID = nil
                },
                onDeleteDecline: { camera.lastImportedOriginalAssetID = nil }
            )
        }
        .confirmationDialog("Delete Session?", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }), titleVisibility: .visible) {
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
        .confirmationDialog("Session Options", isPresented: Binding(
            get: { sessionForContextMenu != nil },
            set: { if !$0 { sessionForContextMenu = nil } }
        ), titleVisibility: .hidden) {
            Button("Rename") {
                renameDraft = sessionForContextMenu?.displayName ?? ""
                sessionToRename = sessionForContextMenu
                sessionForContextMenu = nil
            }
            Button("Delete", role: .destructive) {
                sessionToDelete = sessionForContextMenu
                sessionForContextMenu = nil
            }
            Button("Cancel", role: .cancel) { sessionForContextMenu = nil }
        }
        .alert("Rename Session", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField("Session name", text: $renameDraft)
            Button("Save") {
                if let s = sessionToRename { camera.renameSession(s.id, name: renameDraft) }
                sessionToRename = nil
            }
            Button("Cancel", role: .cancel) { sessionToRename = nil }
        } message: {
            Text("Enter a name for this session.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.tlAccent.opacity(0.12))
                        .frame(width: 116, height: 116)
                    Image(systemName: "water.waves")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(Color.tlAccent)
                }
                Text("Flat for now")
                    .font(.bricolage(26))
                    .foregroundStyle(Color.tlDynamicInk(scheme))
                    .kerning(-0.5)
                    .padding(.top, 18)
                Text("No sessions logged yet. Paddle out, tag a few waves, and your clips roll in right here.")
                    .font(.hanken(15, weight: .medium))
                    .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .padding(.horizontal, 40)

                Button {
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                        DispatchQueue.main.async { showVideoPicker = true }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Import a session")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 15)
                    .background(Color.tlAccent)
                    .clipShape(Capsule())
                    .shadow(color: Color.tlAccent.opacity(0.45), radius: 14, x: 0, y: 7)
                }
                .padding(.top, 24)
            }
            Spacer()
        }
    }

    private var sessionList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(totalWaves) \(totalWaves == 1 ? "wave" : "waves") · \(camera.waveSessions.count) \(camera.waveSessions.count == 1 ? "session" : "sessions")")
                    .font(.hanken(12.5, weight: .bold))
                    .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                LazyVStack(spacing: 12) {
                    ForEach(Array(camera.waveSessions.enumerated()), id: \.element.id) { idx, session in
                        SessionCard(session: session, index: idx)
                            .onTapGesture { selectedSession = session }
                            .onLongPressGesture { sessionForContextMenu = session }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 44)
            }
        }
    }

    private func deletePhotoAsset(_ identifier: String) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }

}

// MARK: - Session card

private struct SessionCard: View {
    @Environment(\.colorScheme) private var scheme
    let session: WaveSession
    let index: Int

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                OceanThumbnail(index: index)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                VStack(spacing: 1) {
                    Text("\(session.clips.count)")
                        .font(.bricolage(24))
                        .foregroundStyle(.white)
                    Text("WAVES")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .tracking(0.8)
                }
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.displayName)
                        .font(.bricolage(19))
                        .foregroundStyle(Color.tlDynamicInk(scheme))
                        .kerning(-0.3)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(relativeDate(session.startDate))
                        .font(.hanken(12.5, weight: .bold))
                        .foregroundStyle(Color.tlAccent)
                        .lineLimit(1)
                }

                if let spot = session.spotName {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.tlAccent)
                        Text(spot)
                            .font(.hanken(13, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                        Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.hanken(13, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                        Text("·")
                            .font(.hanken(13, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                        Text(session.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.hanken(13, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 6) {
                    TLChip("\(session.clips.count) wave\(session.clips.count == 1 ? "" : "s")",
                           systemIcon: "waveform", iconColor: .tlCyan)
                    TLChip(sessionDuration(session), systemIcon: "clock", iconColor: .tlSand)
                }
                .padding(.top, 9)
            }
        }
        .padding(14)
        .background(scheme == .dark ? Color.white.opacity(0.05) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.tlHairline, lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.08), radius: 14, x: 0, y: 6)
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private func sessionDuration(_ s: WaveSession) -> String {
        let mins = Int(s.endDate.timeIntervalSince(s.startDate)) / 60
        return "\(mins)m out"
    }
}

// MARK: - Session detail

struct SessionDetailView: View {
    let sessionID: UUID
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void
    var shouldPromptDelete: Bool = false
    var onDeleteConfirm: (() -> Void)? = nil
    var onDeleteDecline: (() -> Void)? = nil
    @State private var selectedClip: SessionRecording?
    @State private var showDeletePhotoAlert = false
    @Environment(\.colorScheme) private var scheme

    private var session: WaveSession? { camera.waveSessions.first { $0.id == sessionID } }
    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var body: some View {
        ZStack {
            TLBackground()

            VStack(spacing: 0) {
                // Header
                HStack {
                    TLRoundel(systemName: "xmark", action: onDismiss)
                    Spacer()
                    if let s = session {
                        VStack(spacing: 2) {
                            Text(s.displayName)
                                .font(.bricolage(16))
                                .foregroundStyle(Color.tlDynamicInk(scheme))
                                .kerning(-0.3)
                            Text("\(s.startDate.formatted(date: .abbreviated, time: .omitted)) · \(s.startDate.formatted(date: .omitted, time: .shortened)) – \(s.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.hanken(12, weight: .semibold))
                                .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                        }
                    }
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                if let s = session, !s.clips.isEmpty {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            // Stat tiles
                            HStack(spacing: 10) {
                                DetailStatTile(value: "\(s.clips.count)", label: "Waves", color: Color.tlAccent)
                                DetailStatTile(value: durationLabel(s), label: "Session", color: Color.tlCyan)
                                DetailStatTile(value: "\(s.clips.filter { $0.isFavorite }.count)", label: "Favorites", color: Color.tlCoral)
                            }
                            .padding(.horizontal, 22)

                            // Clip grid
                            TLSectionHeader(title: "The set", systemIcon: "waveform")
                                .padding(.horizontal, 22)

                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 11) {
                                ForEach(Array(s.clips.enumerated()), id: \.element.id) { idx, clip in
                                    let recording = SessionRecording(id: clip.id, url: docs.appendingPathComponent(clip.filename), date: clip.date)
                                    ClipCard(
                                        recording: recording,
                                        waveNumber: idx + 1,
                                        isFavorite: clip.isFavorite,
                                        onToggleFavorite: { camera.toggleFavorite(clipID: clip.id, sessionID: sessionID) }
                                    )
                                    .onTapGesture { selectedClip = recording }
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 44)
                        }
                        .padding(.top, 8)
                    }
                } else {
                    Spacer()
                    Text("No clips")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.tlInkSoft)
                    Spacer()
                }
            }
        }
        .fullScreenCover(item: $selectedClip) { recording in
            let isFav = camera.waveSessions.first(where: { $0.id == sessionID })?.clips.first(where: { $0.id == recording.id })?.isFavorite ?? false
            SessionPlayerView(
                recording: recording,
                isFavorite: isFav,
                onDismiss: { selectedClip = nil },
                onDelete: { camera.deleteClip(recording.id, fromSession: sessionID); selectedClip = nil },
                onToggleFavorite: { camera.toggleFavorite(clipID: recording.id, sessionID: sessionID) }
            )
        }
        .confirmationDialog("Delete Original Video?", isPresented: $showDeletePhotoAlert, titleVisibility: .visible) {
            Button("Delete from Photos", role: .destructive) {
                onDeleteConfirm?()
            }
            Button("Keep", role: .cancel) {
                onDeleteDecline?()
            }
        } message: {
            Text("Wave clips saved. Remove the original video from your photo library?")
        }
        .task {
            if shouldPromptDelete {
                try? await Task.sleep(for: .milliseconds(600))
                showDeletePhotoAlert = true
            }
        }
    }

    private func durationLabel(_ s: WaveSession) -> String {
        let mins = Int(s.endDate.timeIntervalSince(s.startDate)) / 60
        return "\(mins)m"
    }
}

// MARK: - Detail stat tile

private struct DetailStatTile: View {
    @Environment(\.colorScheme) private var scheme
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.bricolage(21))
                .foregroundStyle(color)
                .kerning(-0.4)
            Text(label)
                .font(.hanken(11, weight: .bold))
                .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                .kerning(0.4)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme == .dark ? Color.white.opacity(0.05) : Color.tlInk.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Clip card

private struct ClipCard: View {
    let recording: SessionRecording
    let waveNumber: Int
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    @State private var thumbnail: UIImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail or ocean gradient fallback
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                OceanThumbnail(index: waveNumber, label: "WAVE \(String(format: "%02d", waveNumber))")
            }

            // Gradient overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Footer
            HStack {
                Text("\(recording.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 10)

            // Wave label
            VStack {
                HStack {
                    Text("WAVE \(String(format: "%02d", waveNumber))")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .tracking(1)
                        .padding(.leading, 10)
                        .padding(.top, 10)
                    Spacer()
                }
                Spacer()
            }

            // Play overlay
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.tlInk)
                        .offset(x: 2)
                )
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)

            // Favorite button
            if let toggle = onToggleFavorite {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: toggle) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(isFavorite ? Color.tlCoral : .white)
                                .padding(7)
                                .background(.black.opacity(0.35))
                                .clipShape(Circle())
                        }
                        .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .aspectRatio(0.89, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 14, x: 0, y: 6)
        .task {
            guard thumbnail == nil else { return }
            let asset = AVURLAsset(url: recording.url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 300, height: 300)
            if let cgImg = try? await gen.image(at: .zero).image {
                thumbnail = UIImage(cgImage: cgImg)
            }
        }
    }
}

// MARK: - Pending import view

struct PendingImportView: View {
    @ObservedObject var camera: CameraManager
    @State private var player: AVPlayer?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            TLBackground()

            if camera.isLoadingVideo && camera.pendingImportVideo == nil {
                VStack(spacing: 16) {
                    if let progress = camera.iCloudDownloadProgress {
                        ProgressView(value: progress)
                            .tint(Color.tlAccent)
                            .padding(.horizontal, 48)
                        Text("Downloading from iCloud... \(Int(progress * 100))%")
                            .font(.bricolage(16))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                    } else {
                        ProgressView()
                            .tint(Color.tlAccent)
                            .scaleEffect(1.3)
                        Text("Loading video...")
                            .font(.bricolage(16))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                    }
                    Text("This may take a moment.")
                        .font(.hanken(13, weight: .medium))
                        .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                }
            } else if let pending = camera.pendingImportVideo {
                VStack(spacing: 0) {
                    HStack {
                        if !camera.isProcessingImport {
                            TLRoundel(systemName: "xmark") { camera.cancelPendingImport(); camera.isLoadingVideo = false }
                        } else {
                            Color.clear.frame(width: 44, height: 44)
                        }
                        Spacer()
                        Text("Import Video")
                            .font(.bricolage(18))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    if let player {
                        VideoPlayer(player: player)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .padding(.horizontal, 20)
                    }

                    VStack(spacing: 4) {
                        Text(pending.creationDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.bricolage(16))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                        Text(formatDuration(pending.durationSeconds))
                            .font(.hanken(13, weight: .medium))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    }
                    .padding(.top, 16)

                    Spacer()

                    if camera.isProcessingImport {
                        VStack(spacing: 12) {
                            ProgressView().tint(Color.tlAccent).scaleEffect(1.2)
                            Text("Trimming wave clips...")
                                .font(.bricolage(16))
                                .foregroundStyle(Color.tlDynamicInk(scheme))
                            Text("This may take a moment.")
                                .font(.hanken(13, weight: .medium))
                                .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "applewatch")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.tlAccent)
                            Text("Sync your Apple Watch")
                                .font(.bricolage(20))
                                .foregroundStyle(Color.tlDynamicInk(scheme))
                                .kerning(-0.4)
                            Text("Press \"Sync Waves\" on your watch.\nThe app will auto-trim based on your timestamps.")
                                .font(.hanken(14, weight: .medium))
                                .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                        .padding(.horizontal, 36)
                    }

                    Spacer()
                }
                .onAppear { player = AVPlayer(playerItem: AVPlayerItem(asset: pending.asset)) }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}

// MARK: - Recording row (kept for compatibility)

struct RecordingRow: View {
    let recording: SessionRecording
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: recording.url)
                .frame(width: 80, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tlDynamicInk(scheme))
                Text("Session Recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tlDynamicInkSoft(scheme))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                .font(.system(size: 12))
        }
        .padding(12)
        .background(scheme == .dark ? Color.white.opacity(0.07) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.tlHairline, lineWidth: 1))
    }
}
