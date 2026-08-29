import SwiftUI
import AVFoundation
import AVKit
import Photos
import UIKit

struct ThumbnailView: View {
    let url: URL?
    /// Ocean-gradient fallback variant, so cards in a list don't all share one color.
    var fallbackIndex: Int = 0
    /// The video glyph reads as "no clip yet"; hide it where the tile carries its own label.
    var showsPlaceholderIcon: Bool = true
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let img = thumbnail {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                OceanThumbnail(index: fallbackIndex)
                    .overlay {
                        if showsPlaceholderIcon {
                            Image(systemName: "video.fill")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
            }
        }
        .task(id: url) {
            guard let url else { return }
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            if let cgImage = try? await gen.image(at: .zero).image {
                thumbnail = UIImage(cgImage: cgImage)
            }
        }
    }
}

// MARK: - AVPlayerLayer host (VideoPlayer brings its own chrome; the editor supplies its own)

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Fires with the layer's `isReadyForDisplay`, so the caller can keep the layer hidden until it
    /// actually holds a frame of the current item instead of the last one.
    var onReadyChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(player: player)
        view.onReadyChange = onReadyChange
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        view.onReadyChange = onReadyChange
        view.playerLayer.player = player
    }

    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onReadyChange: ((Bool) -> Void)?
        private var readyObservation: NSKeyValueObservation?

        init(player: AVPlayer) {
            super.init(frame: .zero)
            backgroundColor = .clear
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { [weak self] in self?.onReadyChange?(ready) }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    }
}

// MARK: - Landscape clip editor

enum ClipTool: String, CaseIterable { case watch = "Watch", trim = "Trim", crop = "Crop" }
/// What a drag on the trim strip is moving.
private enum TrimGrab { case start, end, playhead }
enum ClipAspect: String, CaseIterable {
    case r169 = "16:9", r916 = "9:16", free = "Free"
    /// Display aspect (w/h); nil = free-form.
    var ratio: Double? {
        switch self {
        case .r169: return 16.0 / 9.0
        case .r916: return 9.0 / 16.0
        case .free: return nil
        }
    }
}

private let defaultCrop = CGRect(x: 0.09, y: 0.09, width: 0.82, height: 0.82)
/// One clip in the list the viewer was opened from.
struct ClipRef: Identifiable {
    let recording: SessionRecording
    var waveNumber: Int? = nil
    var isFavorite: Bool = false
    /// GPS + Vision framing from the import pipeline, offered as "Auto-frame" when it was not
    /// already baked into the clip file.
    var autoCrop: CGRect? = nil
    /// Crop already applied to this clip, restored when the viewer comes back to it.
    var userCrop: CGRect? = nil
    var id: UUID { recording.id }
}

// MARK: - Whole-session player

/// Opens a session straight at its first wave: the set list screen is gone, the picker inside
/// the player covers moving between clips.
struct SessionClipsPlayer: View {
    let sessionID: UUID
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var body: some View {
        let clips = camera.waveSessions.first { $0.id == sessionID }?.clips ?? []
        SessionPlayerView(
            clips: clips.enumerated().map { idx, c in
                ClipRef(
                    recording: SessionRecording(id: c.id, url: docs.appendingPathComponent(c.filename), date: c.date),
                    waveNumber: idx + 1,
                    isFavorite: c.isFavorite,
                    // Already baked into the file by the import pipeline → nothing left to offer here.
                    autoCrop: c.cropApplied ? nil : c.cropRect,
                    userCrop: c.userCrop
                )
            },
            startID: clips.first?.id ?? sessionID,
            onDismiss: onDismiss,
            onDelete: { id in camera.deleteClip(id, fromSession: sessionID); onDismiss() },
            onToggleFavorite: { id in camera.toggleFavorite(clipID: id, sessionID: sessionID) },
            onCropChange: { id, rect in camera.setUserCrop(rect, clipID: id, sessionID: sessionID) }
        )
    }
}

struct SessionPlayerView: View {
    /// The whole list the clip was opened from, so the picker can move between them.
    let clips: [ClipRef]
    let startID: UUID
    let onDismiss: () -> Void
    let onDelete: (UUID) -> Void
    var onToggleFavorite: ((UUID) -> Void)? = nil
    /// Applied crop for one clip, in its own source space. nil = original framing.
    var onCropChange: ((UUID, CGRect?) -> Void)? = nil

    @State private var index: Int
    /// First frame of the current clip, covering the black gap while its item loads.
    @State private var posters: [UUID: UIImage] = [:]
    /// The clip picker: the whole set as a grid, in place of the old side-swipe.
    @State private var showPicker = false
    @State private var durations: [UUID: Double] = [:]
    /// False until the layer holds a frame of the clip now on screen.
    @State private var videoReady = false

    init(clips: [ClipRef], startID: UUID, onDismiss: @escaping () -> Void,
         onDelete: @escaping (UUID) -> Void, onToggleFavorite: ((UUID) -> Void)? = nil,
         onCropChange: ((UUID, CGRect?) -> Void)? = nil) {
        self.clips = clips
        self.startID = startID
        self.onDismiss = onDismiss
        self.onDelete = onDelete
        self.onToggleFavorite = onToggleFavorite
        self.onCropChange = onCropChange
        let start = clips.firstIndex { $0.id == startID } ?? 0
        _index = State(initialValue: start)
        opened = clips.indices.contains(start) ? clips[start]
            : ClipRef(recording: SessionRecording(id: startID, url: URL(fileURLWithPath: "/dev/null"), date: .now))
    }

    /// Snapshot of the clip that was tapped, so a list that empties out mid-dismiss can't index-crash.
    private let opened: ClipRef
    private var clip: ClipRef { clips.indices.contains(index) ? clips[index] : opened }
    private var recording: SessionRecording { clip.recording }
    private var isFavorite: Bool { clip.isFavorite }
    private var waveNumber: Int? { clip.waveNumber }
    private var autoCrop: CGRect? { clip.autoCrop }

    @State private var player: AVPlayer = { let p = AVPlayer(); p.isMuted = true; return p }()
    @State private var timeObserver: Any?
    @State private var duration: Double = 0
    @State private var now: Double = 0
    @State private var playing = true

    @State private var tool: ClipTool = .watch
    @State private var trimIn: Double = 0
    @State private var trimOut: Double = 1
    /// What the current strip drag grabbed; nil while not dragging.
    @State private var trimGrab: TrimGrab?
    /// Playback state before the drag, restored when it ends.
    @State private var trimWasPlaying = false
    @State private var showTrimAlert = false
    @State private var isTrimming = false

    @State private var zoom: Double = 1
    @State private var pan: CGPoint = .zero        // normalized to the on-screen video size
    @State private var pinchBase: Double = 1
    @State private var panBase: CGPoint = .zero

    @State private var crop = defaultCrop
    @State private var cropBase = defaultCrop
    /// Crop the player and the export are actually using, in source space. nil = whole frame.
    /// The clip file is never rewritten, so clearing this brings the original framing straight back.
    @State private var appliedCrop: CGRect?
    @State private var aspect: ClipAspect = .r169
    @State private var videoAspect: Double = 16.0 / 9.0
    @State private var sourceSize = CGSize(width: 1920, height: 1080)

    @State private var strip: [UIImage] = []
    @State private var showDeleteAlert = false
    @State private var isSaving = false
    @State private var toast: String?
    @State private var localFavorite = false

    private var isCrop: Bool { tool == .crop }
    private var trimmed: Bool { trimIn > 0.001 || trimOut < 0.999 }
    private var dirty: Bool { trimmed || zoom > 1.01 || appliedCrop != nil }

    /// What the crop tool's pending rect would cut, in source space.
    private var pendingSource: CGRect { sourceCropRect(crop: crop, zoom: zoom, pan: pan) }
    /// What is on screen (and what exports): the applied crop, narrowed by the current zoom/pan.
    private var effectiveSource: CGRect {
        nestRect(visibleSourceRect(zoom: zoom, pan: pan),
                 in: appliedCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    private func pixels(_ s: CGRect) -> CGSize {
        CGSize(width: (s.width * sourceSize.width).rounded(),
               height: (s.height * sourceSize.height).rounded())
    }
    private var cropPixels: CGSize { pixels(pendingSource) }

    /// Aspect of the frame on screen. The crop tool always works over the untouched frame, so an
    /// applied crop only reshapes the viewport outside it.
    private var displayAspect: Double {
        guard !isCrop, let a = appliedCrop else { return videoAspect }
        let h = a.height * sourceSize.height
        return h > 0 ? (a.width * sourceSize.width) / h : videoAspect
    }

    var body: some View {
        GeometryReader { geo in
            let side = max(40, geo.size.width * 0.055)
            let box = mediaBox(geo.size)
            let video = AVMakeRect(aspectRatio: CGSize(width: displayAspect, height: 1), insideRect: box)
            // The window rotates a beat after the view appears. Until it agrees with the clip's
            // orientation the bars would lay out squashed, so hold them back and show black.
            let settled = (geo.size.width >= geo.size.height) == (videoAspect >= 1)

            ZStack {
                Color.black

                mediaLayer(video, geo.size)
                    .opacity(settled ? 1 : 0)

                if settled {
                    if isCrop {
                        cropOverlay(video)
                    } else {
                        topBar(side: side)
                        if zoom > 1.02 { zoomChip }
                    }

                    bottomBar(side: side)

                    if showPicker { clipPicker(side: side, screen: geo.size.height) }
                }

                if let toast {
                    Text(toast)
                        .font(.hanken(13.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.75), in: Capsule())
                        .position(x: geo.size.width / 2, y: geo.size.height - 118)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: tool)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: showPicker)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .background(Color.black)
        .task(id: index) { await loadPosters() }
        .task(id: showPicker) { if showPicker { await loadDurations() } }
        .task(id: clip.id) {
            unhook()
            resetEdits()
            await load()
        }
        .onDisappear { teardown() }
        .alert("Delete Clip?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { onDelete(recording.id) }
            Button("Cancel", role: .cancel) { play() }
        } message: { Text("This clip will be permanently deleted.") }
        .alert("Save Trim?", isPresented: $showTrimAlert) {
            Button("Save Trim", role: .destructive) { Task { await applyTrim() } }
            Button("Cancel", role: .cancel) { play() }
        } message: {
            Text(String(format: "The clip is replaced with the selected %.1fs. This can't be undone.",
                        (trimOut - trimIn) * duration))
        }
    }

    // MARK: layout

    /// Crop insets the frame (as iOS Photos does) so the rect, its handles and the size readout
    /// can never fall under the control bar.
    private func mediaBox(_ size: CGSize) -> CGRect {
        guard isCrop else { return CGRect(origin: .zero, size: size) }
        let h = max(60, size.width * 0.10)
        return CGRect(x: h, y: 14, width: size.width - h * 2, height: max(80, size.height - 14 - 122))
    }

    // MARK: media

    /// Gestures live on the full-screen layer, not on the video rect: a cropped clip draws into a
    /// narrow strip, and a pinch that starts in the black beside it still has to zoom it.
    private func mediaLayer(_ video: CGRect, _ full: CGSize) -> some View {
        ZStack {
            currentPage(video)
        }
        .frame(width: full.width, height: full.height)
        .contentShape(Rectangle())
        .gesture(isCrop ? nil : zoomPanGesture(video))
        .onTapGesture(count: 2) {
            guard !isCrop else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                zoom = zoom > 1.05 ? 1 : 2.2
                pan = .zero
            }
        }
        .onTapGesture {
            if showPicker { showPicker = false }
            else if tool == .watch { togglePlay() }
        }
    }

    /// `crop` frames the poster the same way `croppedPlayer` frames the layer, so returning to a
    /// cropped clip doesn't flash the full frame before the first video frame lands.
    private func poster(_ c: ClipRef, size: CGSize, crop a: CGRect? = nil) -> some View {
        let w = a.map { size.width / $0.width } ?? size.width
        let h = a.map { size.height / $0.height } ?? size.height
        return ZStack {
            Color.black
            if let img = posters[c.id] {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: w, height: h)
                    .offset(x: a.map { (0.5 - $0.midX) * w } ?? 0,
                            y: a.map { (0.5 - $0.midY) * h } ?? 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private func currentPage(_ video: CGRect) -> some View {
        ZStack {
            // Sits behind the player layer, covering the black gap while the next item loads.
            poster(clip, size: video.size, crop: isCrop ? nil : appliedCrop)

            croppedPlayer(video)
                .opacity(videoReady ? 1 : 0)
                .scaleEffect(zoom)
                .offset(x: pan.x * video.width, y: pan.y * video.height)
        }
        .frame(width: video.width, height: video.height)
        .clipped()
        .overlay {
            if tool == .watch && !playing {
                Image(systemName: "play.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.white.opacity(0.16), in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .position(x: video.midX, y: video.midY)
    }

    /// Blows the layer up so the applied crop region alone fills `video`, then clips to it. The
    /// file is untouched: dropping `appliedCrop` restores the full frame with no re-encode.
    private func croppedPlayer(_ video: CGRect) -> some View {
        let a = isCrop ? nil : appliedCrop
        let w = a.map { video.width / $0.width } ?? video.width
        let h = a.map { video.height / $0.height } ?? video.height
        return ZStack {
            PlayerLayerView(player: player, onReadyChange: { videoReady = $0 })
                .frame(width: w, height: h)
                .offset(x: a.map { (0.5 - $0.midX) * w } ?? 0,
                        y: a.map { (0.5 - $0.midY) * h } ?? 0)
        }
        .frame(width: video.width, height: video.height)
        .clipped()
    }

    /// Closes the picker and swaps to the chosen clip. Any pending trim/crop goes with it, the
    /// same as before — but only ever on a deliberate tap, never on a stray drag.
    private func pick(_ i: Int) {
        showPicker = false
        guard clips.indices.contains(i), i != index else { return }
        tool = .watch
        unhook()
        player.replaceCurrentItem(with: nil)
        videoReady = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { index = i }
    }

    private func zoomPanGesture(_ video: CGRect) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { g in
                zoom = min(4, max(1, pinchBase * Double(g.magnification)))
                pan = clampPan(pan, zoom: zoom)
            }
            .onEnded { _ in pinchBase = zoom }
        let drag = DragGesture()
            .onChanged { g in
                guard zoom > 1 else { return }
                pan = clampPan(CGPoint(x: panBase.x + g.translation.width / video.width,
                                       y: panBase.y + g.translation.height / video.height), zoom: zoom)
            }
            .onEnded { _ in if zoom > 1 { panBase = pan } }
        return magnify.simultaneously(with: drag)
    }

    private var zoomChip: some View {
        HStack(spacing: 10) {
            Text(String(format: "%.1f×", zoom))
                .font(.bricolage(14)).kerning(-0.2).foregroundStyle(.white)
            Text("BAKED INTO EXPORT")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(0.8).foregroundStyle(.white.opacity(0.55))
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
                }
            } label: {
                Text("Reset")
                    .font(.hanken(11.5, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.16), in: Capsule())
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
    }

    // MARK: top bar

    private func topBar(side: CGFloat) -> some View {
        VStack {
            HStack {
                roundel("xmark", 19) { onDismiss() }
                Spacer()
                VStack(spacing: 1) {
                    Text(waveNumber.map { "Wave \($0)" } ?? "Wave clip")
                        .font(.bricolage(17)).kerning(-0.3).foregroundStyle(.white)
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.hanken(11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if clips.count > 1 {
                        Text("WAVE \(waveNumber ?? index + 1) OF \(clips.count)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .tracking(0.9).foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 2)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    if onToggleFavorite != nil {
                        roundel(localFavorite ? "heart.fill" : "heart", 17,
                                tint: localFavorite ? Color.tlCoral : .white) {
                            localFavorite.toggle(); onToggleFavorite?(recording.id)
                        }
                    }
                    if clips.count > 1 { pickerPill }
                    roundel("trash", 17) { pause(); showDeleteAlert = true }
                }
            }
            .padding(.horizontal, side)
            .padding(.top, 18)
            Spacer()
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        )
    }

    /// Opens the whole set as a grid. Replaces paging between clips by dragging the media layer.
    private var pickerPill: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(index + 1)/\(clips.count)")
                    .font(.hanken(13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 11).padding(.trailing, 13)
            .frame(height: 38)
            .background(showPicker ? Color.tlAccent : .white.opacity(0.15), in: Capsule())
        }
    }

    // MARK: clip picker

    private func clipPicker(side: CGFloat, screen: CGFloat) -> some View {
        // 3 columns of 16:9 inside the panel: 12pt padding each side, 8pt gutters.
        let width: CGFloat = 340
        let cell: CGFloat = (width - 24 - 16) / 3
        let rowH: CGFloat = cell * 9 / 16
        let rows = CGFloat((clips.count + 2) / 3)
        // Whatever is left between the top bar and the controls, minus the panel's own chrome
        // (24pt padding + header + spacing). A longer session scrolls rather than growing into them.
        let room: CGFloat = max(rowH, screen - 64 - 124 - 48)
        let gridH: CGFloat = min(room, rows * rowH + max(0, rows - 1) * 8)
        return VStack(spacing: 10) {
            HStack {
                Text("\(clips.count) WAVES")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.9).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if durations.count == clips.count {
                    Text("\(fmt(durations.values.reduce(0, +))) total")
                        .font(.hanken(11.5, weight: .bold))
                        .foregroundStyle(Color.tlDarkCyan)
                }
            }
            .padding(.horizontal, 2)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                          spacing: 8) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                        pickerCell(i, c)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: gridH)
        }
        .padding(12)
        .frame(width: width)
        .background(Color.tlDarkBg.opacity(0.93), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 25, y: 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, side)
        .padding(.top, 64)
        .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
    }

    private func pickerCell(_ i: Int, _ c: ClipRef) -> some View {
        let current = i == index
        return Button { pick(i) } label: {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { ThumbnailView(url: c.recording.url) }
                .overlay(LinearGradient(colors: [.black.opacity(0.65), .clear],
                                        startPoint: .bottom, endPoint: .top))
                .overlay(alignment: .bottomLeading) {
                    Text("\(c.waveNumber ?? i + 1)")
                        .font(.hanken(13, weight: .heavy)).foregroundStyle(.white)
                        .padding(.leading, 7).padding(.bottom, 5)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let d = durations[c.id] {
                        Text(fmt(d))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.trailing, 7).padding(.bottom, 5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if current ? localFavorite : c.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10)).foregroundStyle(Color.tlCoral)
                            .padding(.trailing, 7).padding(.top, 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(current ? Color.tlAccent : .white.opacity(0.1),
                                  lineWidth: current ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func roundel(_ icon: String, _ size: CGFloat, tint: Color = .white,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.15), in: Circle())
        }
    }

    // MARK: bottom bar

    private func bottomBar(side: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                switch tool {
                case .watch: watchControls
                case .trim: trimStrip
                case .crop: cropControls
                }

                HStack(spacing: 12) {
                    segmented(ClipTool.allCases.map(\.rawValue),
                              selection: ClipTool.allCases.firstIndex(of: tool) ?? 0,
                              width: 72, fill: .white.opacity(0.9),
                              ink: { $0 ? Color.tlInk : .white.opacity(0.8) }) { i in
                        setTool(ClipTool.allCases[i])
                    }

                    switch tool {
                    case .trim:
                        Button(action: togglePlay) {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.1fs", (trimOut - trimIn) * duration))
                                .font(.bricolage(20)).kerning(-0.4).foregroundStyle(Color.tlSand)
                            Text("SELECTED OF \(fmt(duration))")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .tracking(0.9).foregroundStyle(.white.opacity(0.5))
                        }
                    case .watch:
                        Text("PINCH TO ZOOM · DRAG TO PAN")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .tracking(0.9).foregroundStyle(.white.opacity(0.42))
                    case .crop:
                        EmptyView()
                    }

                    Spacer(minLength: 0)

                    if tool == .trim && trimmed {
                        Button { pause(); showTrimAlert = true } label: {
                            Group {
                                if isTrimming { ProgressView().tint(.black) }
                                else { Text("Save Trim").font(.hanken(14, weight: .bold)).foregroundStyle(.black) }
                            }
                            .padding(.horizontal, 18).padding(.vertical, 13)
                            .background(Color.tlSand, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(isTrimming)
                    }
                    if dirty {
                        Button(action: revert) {
                            Text("Revert")
                                .font(.hanken(14, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 13)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    Button {
                        pause()
                        Task { await saveToCameraRoll() }
                    } label: {
                        Group {
                            if isSaving { ProgressView().tint(.black) }
                            else { Text("Save to Roll").font(.hanken(14, weight: .bold)).foregroundStyle(.black) }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 13)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isSaving)
                }
            }
            .padding(.horizontal, side)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.5), .black.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
        }
    }

    private var watchControls: some View {
        HStack(spacing: 14) {
            Button(action: togglePlay) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.15), in: Circle())
            }
            Text(fmt(now))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white)
                .frame(width: 38, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 6)
                    Capsule().fill(Color.tlCyan).frame(width: g.size.width * progress, height: 6)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                        .offset(x: g.size.width * progress - 7)
                }
                .frame(height: g.size.height, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = min(trimOut, max(trimIn, v.location.x / g.size.width))
                    seek(f * duration)
                })
            }
            .frame(height: 26)
            Text(fmt(duration))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var trimStrip: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                // Fixed cell width: a flexible frame around an aspect-fill image reports the
                // image's oversized width, which pushed the whole strip off both screen edges.
                let cell = max(1, (w - 2 * 11) / 12)
                HStack(spacing: 2) {
                    ForEach(0..<12, id: \.self) { i in
                        Group {
                            if i < strip.count {
                                Image(uiImage: strip[i]).resizable().scaledToFill()
                            } else {
                                OceanThumbnail(index: i)
                            }
                        }
                        .frame(width: cell, height: g.size.height)
                        .clipped()
                    }
                }
                .frame(width: w, height: g.size.height, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Rectangle().fill(.black.opacity(0.6)).frame(width: w * trimIn)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: w * (1 - trimOut)).offset(x: w * trimOut)

                RoundedRectangle(cornerRadius: 8).stroke(Color.tlSand, lineWidth: 3)
                    .frame(width: w * (trimOut - trimIn), height: g.size.height + 6)
                    .offset(x: w * trimIn, y: -3)

                trimHandle(leading: true, w: w, h: g.size.height)
                trimHandle(leading: false, w: w, h: g.size.height)

                Rectangle().fill(.white).frame(width: 2, height: g.size.height + 12)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .offset(x: w * progress - 1, y: -6)
                    .allowsHitTesting(false)
            }
            .frame(width: w, height: g.size.height)
            .contentShape(Rectangle())
            // One gesture across the whole strip: grabs whichever of the two handles or the
            // playhead the touch started nearest to. Per-handle gestures missed, because a handle
            // parked at 0 or 1 sits outside the strip.
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let f = min(1, max(0, v.location.x / w))
                    let grab = trimGrab ?? nearestGrab(to: f)
                    if trimGrab == nil {
                        trimGrab = grab
                        trimWasPlaying = playing
                        pause()
                    }
                    switch grab {
                    case .start:
                        trimIn = min(f, trimOut - 0.06)
                        seek(trimIn * duration, exact: false)
                    case .end:
                        trimOut = max(f, trimIn + 0.06)
                        seek(trimOut * duration, exact: false)
                    case .playhead:
                        seek(min(trimOut, max(trimIn, f)) * duration, exact: false)
                    }
                }
                .onEnded { _ in
                    trimGrab = nil
                    seek(now)                       // settle on the exact frame
                    if trimWasPlaying { play() }
                })
        }
        .frame(height: 58)
    }

    /// Drawn inside the selection so it always stays within the strip's own bounds.
    private func trimHandle(leading: Bool, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.tlSand)
            .frame(width: 18, height: h + 6)
            .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 2, height: 18))
            .offset(x: leading ? w * trimIn : w * trimOut - 18, y: -3)
            .allowsHitTesting(false)
    }

    /// Handles win ties, so a playhead parked on top of one never blocks trimming.
    private func nearestGrab(to f: Double) -> TrimGrab {
        let d: [(TrimGrab, Double)] = [(.start, abs(f - trimIn)), (.end, abs(f - trimOut)),
                                       (.playhead, abs(f - progress))]
        return d.min { $0.1 < $1.1 }?.0 ?? .playhead
    }

    private var cropControls: some View {
        HStack(spacing: 10) {
            segmented(ClipAspect.allCases.map(\.rawValue),
                      selection: ClipAspect.allCases.firstIndex(of: aspect) ?? 0,
                      width: 64, fill: Color.tlAccent,
                      ink: { _ in .white }) { i in
                let a = ClipAspect.allCases[i]
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    aspect = a
                    crop = fitCrop(crop, aspect: a.ratio, videoAspect: videoAspect)
                }
            }

            if let autoCrop {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
                        crop = fitCrop(autoCrop, aspect: aspect.ratio, videoAspect: videoAspect)
                    }
                    say("Auto-framed from the GPS track")
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 12)).foregroundStyle(Color.tlCyan)
                        Text("Auto-frame").font(.hanken(12.5, weight: .bold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25), lineWidth: 1))
                }
                Text("AUTO FRAME · GPS + VISION")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.9).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)

            if appliedCrop != nil {
                Button(action: clearCrop) {
                    Text("Reset Crop")
                        .font(.hanken(13, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Button(action: applyCrop) {
                Text(appliedCrop == nil ? "Apply Crop" : "Update Crop")
                    .font(.hanken(13, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 17).padding(.vertical, 10)
                    .background(Color.tlSand, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func segmented(_ titles: [String], selection: Int, width: CGFloat, fill: some ShapeStyle,
                           ink: @escaping (Bool) -> Color, onPick: @escaping (Int) -> Void) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9).fill(fill)
                .frame(width: width, height: 32)
                .offset(x: CGFloat(selection) * width)
            HStack(spacing: 0) {
                ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                    Button { onPick(i) } label: {
                        Text(t)
                            .font(.hanken(12.5, weight: .bold))
                            .foregroundStyle(ink(i == selection))
                            .frame(width: width, height: 32)
                    }
                }
            }
        }
        .padding(3)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selection)
    }

    // MARK: crop overlay

    private func cropOverlay(_ video: CGRect) -> some View {
        let r = CGRect(x: crop.minX * video.width, y: crop.minY * video.height,
                       width: crop.width * video.width, height: crop.height * video.height)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: video.size))
                p.addRect(r)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle().stroke(.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .offset(x: r.minX, y: r.minY)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = v.translation.width / video.width
                        let dy = v.translation.height / video.height
                        crop.origin = CGPoint(x: min(max(0, cropBase.minX + dx), 1 - crop.width),
                                              y: min(max(0, cropBase.minY + dy), 1 - crop.height))
                    }
                    .onEnded { _ in cropBase = crop })
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in }
                    .onEnded { _ in cropBase = crop })

            // rule of thirds
            ForEach(1..<3) { i in
                Rectangle().fill(.white.opacity(0.35))
                    .frame(width: 1, height: r.height)
                    .offset(x: r.minX + r.width * CGFloat(i) / 3, y: r.minY)
                Rectangle().fill(.white.opacity(0.35))
                    .frame(width: r.width, height: 1)
                    .offset(x: r.minX, y: r.minY + r.height * CGFloat(i) / 3)
            }
            .allowsHitTesting(false)

            ForEach(Corner.allCases, id: \.self) { c in
                cornerHandle(c, rect: r, video: video)
            }

            Text("\(Int(cropPixels.width)) × \(Int(cropPixels.height))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                .offset(x: r.minX + 9, y: r.maxY - 20)
                .allowsHitTesting(false)
        }
        .frame(width: video.width, height: video.height)
        .position(x: video.midX, y: video.midY)
        .onAppear { cropBase = crop }
    }

    private enum Corner: CaseIterable { case tl, tr, bl, br
        var isLeft: Bool { self == .tl || self == .bl }
        var isTop: Bool { self == .tl || self == .tr }
    }

    private func cornerHandle(_ c: Corner, rect r: CGRect, video: CGRect) -> some View {
        Path { p in
            let s: CGFloat = 26
            if c.isTop { p.move(to: .init(x: c.isLeft ? 0 : s, y: 2)); p.addLine(to: .init(x: c.isLeft ? s : 0, y: 2)) }
            else { p.move(to: .init(x: c.isLeft ? 0 : s, y: s - 2)); p.addLine(to: .init(x: c.isLeft ? s : 0, y: s - 2)) }
            p.move(to: .init(x: c.isLeft ? 2 : s - 2, y: c.isTop ? 0 : s))
            p.addLine(to: .init(x: c.isLeft ? 2 : s - 2, y: c.isTop ? s : 0))
        }
        .stroke(.white, lineWidth: 4)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle().inset(by: -12))
        .offset(x: (c.isLeft ? r.minX : r.maxX - 26), y: (c.isTop ? r.minY : r.maxY - 26))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in crop = resizedCrop(c, drag: v, video: video) }
            .onEnded { _ in cropBase = crop })
    }

    /// Anchor the opposite corner, drag this one, then re-fit to the locked aspect and clamp to frame.
    private func resizedCrop(_ c: Corner, drag v: DragGesture.Value, video: CGRect) -> CGRect {
        let ax = c.isLeft ? cropBase.maxX : cropBase.minX
        let ay = c.isTop ? cropBase.maxY : cropBase.minY
        let nx = min(1, max(0, (c.isLeft ? cropBase.minX : cropBase.maxX) + v.translation.width / video.width))
        let ny = min(1, max(0, (c.isTop ? cropBase.minY : cropBase.maxY) + v.translation.height / video.height))
        var w = max(0.1, abs(nx - ax))
        var h = max(0.1, abs(ny - ay))
        if let a = aspect.ratio {
            let n = a / videoAspect
            w = max(w, h * n); h = w / n
            // shrink to whatever still fits between the anchor and the frame edge
            let roomW = c.isLeft ? ax : 1 - ax
            let roomH = c.isTop ? ay : 1 - ay
            w = min(w, min(roomW, roomH * n)); h = w / n
        } else {
            w = min(w, c.isLeft ? ax : 1 - ax)
            h = min(h, c.isTop ? ay : 1 - ay)
        }
        return CGRect(x: c.isLeft ? ax - w : ax, y: c.isTop ? ay - h : ay, width: w, height: h)
    }

    // MARK: playback

    private var progress: Double { duration > 0 ? now / duration : 0 }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func togglePlay() { playing ? pause() : play() }
    private func play() { playing = true; player.play() }
    private func pause() { playing = false; player.pause() }
    /// `exact: false` scrubs with tolerance, so dragging stays responsive on long clips.
    private func seek(_ s: Double, exact: Bool = true) {
        now = s
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600),
                    toleranceBefore: tol, toleranceAfter: tol)
    }

    private func setTool(_ t: ClipTool) {
        if t == .crop {
            pause()
            // Re-cropping starts from the crop already applied, over the untouched frame.
            if let a = appliedCrop {
                zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
                crop = a
            }
            crop = fitCrop(crop, aspect: aspect.ratio, videoAspect: videoAspect)
            cropBase = crop
        } else if t == .watch {
            play()
        }
        tool = t
    }

    /// Single funnel for the applied crop, so every path that changes it also saves it against
    /// this clip's id. Nothing is written to the video file.
    private func setAppliedCrop(_ rect: CGRect?) {
        appliedCrop = rect
        onCropChange?(recording.id, rect)
    }

    /// Bakes the pending rect into the viewer and the export. Source stays untouched on disk.
    private func applyCrop() {
        let s = pendingSource
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            setAppliedCrop(s)
            zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
            crop = s; cropBase = s
            tool = .watch
        }
        play()
        let p = pixels(s)
        say("Crop applied · \(Int(p.width)) × \(Int(p.height)) · original kept")
    }

    private func clearCrop() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            setAppliedCrop(nil)
            zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
            crop = fitCrop(defaultCrop, aspect: aspect.ratio, videoAspect: videoAspect)
            cropBase = crop
        }
        say("Original framing restored")
    }

    private func revert() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            trimIn = 0; trimOut = 1
            zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
            aspect = .r169
            setAppliedCrop(nil)
            crop = fitCrop(defaultCrop, aspect: ClipAspect.r169.ratio, videoAspect: videoAspect)
            cropBase = crop
        }
        seek(0)
    }

    private func say(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }

    // MARK: load / teardown

    /// Everything the previous clip left behind, cleared before the next one loads.
    private func resetEdits() {
        trimIn = 0; trimOut = 1
        zoom = 1; pan = .zero; pinchBase = 1; panBase = .zero
        // Crop is per clip: whatever the previous one had is dropped, and this clip's own saved
        // crop (if any) comes back. Not routed through setAppliedCrop — nothing changed to save.
        appliedCrop = clip.userCrop
        crop = appliedCrop ?? defaultCrop; cropBase = crop
        now = 0; duration = 0; strip = []
        playing = true
    }

    private func loadPosters() async {
        for i in [index] where clips.indices.contains(i) {
            let c = clips[i]
            guard posters[c.id] == nil else { continue }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: c.recording.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1400, height: 1400)
            if let cg = try? await gen.image(at: .zero).image {
                posters[c.id] = UIImage(cgImage: cg)
            }
        }
    }

    /// Clip lengths for the picker cells. Loaded once, the first time the picker opens.
    private func loadDurations() async {
        for c in clips where durations[c.id] == nil {
            guard let d = try? await AVURLAsset(url: c.recording.url).load(.duration),
                  d.seconds.isFinite else { continue }
            durations[c.id] = d.seconds
        }
    }

    private func load() async {
        localFavorite = isFavorite
        let asset = AVURLAsset(url: recording.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause
        play()

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let pt = try? await track.load(.preferredTransform) {
            let d = CGRect(origin: .zero, size: natural).applying(pt)
            let size = CGSize(width: abs(d.width), height: abs(d.height))
            sourceSize = size
            videoAspect = size.height > 0 ? size.width / size.height : 16.0 / 9
            OrientationLock.mask = size.width >= size.height ? .landscape : .portrait
        }
        // Match the aspect chip to a restored crop, otherwise reopening the crop tool would refit
        // the saved rect to whatever chip happened to be selected.
        if let a = appliedCrop {
            let r = pixels(a)
            aspect = ClipAspect.allCases.first { c in
                c.ratio.map { abs(r.width / max(1, r.height) - $0) < 0.02 } ?? false
            } ?? .free
        } else {
            aspect = .r169
        }
        crop = appliedCrop ?? fitCrop(defaultCrop, aspect: aspect.ratio, videoAspect: videoAspect)
        cropBase = crop

        if let d = try? await asset.load(.duration) { duration = max(0.1, d.seconds) }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { time in
            let s = time.seconds
            guard duration > 0 else { return }
            // While a handle or the playhead is being dragged the loop must not fight the drag.
            guard trimGrab == nil else { now = s; return }
            if s >= trimOut * duration - 0.02 || s < trimIn * duration - 0.02 {
                seek(trimIn * duration)
                if playing { player.play() }
            } else {
                now = s
            }
        }

        await loadStrip(asset)
    }

    private func loadStrip(_ asset: AVURLAsset) async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 180, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [UIImage] = []
        for i in 0..<12 {
            let s = duration * (Double(i) + 0.5) / 12
            guard let cg = try? await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)).image else { continue }
            out.append(UIImage(cgImage: cg))
        }
        strip = out
    }

    private func unhook() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
    }

    private func teardown() {
        unhook()
        player.replaceCurrentItem(with: nil)
        OrientationLock.mask = .portrait
    }

    // MARK: trim in place

    /// Overwrites the clip file with the selected range, then reloads the editor on the new file.
    private func applyTrim() async {
        isTrimming = true
        defer { isTrimming = false }
        let range = CMTimeRange(start: CMTime(seconds: trimIn * duration, preferredTimescale: 600),
                                end: CMTime(seconds: trimOut * duration, preferredTimescale: 600))
        let url = recording.url
        unhook()
        player.replaceCurrentItem(with: nil)
        videoReady = false
        guard await Self.trimInPlace(url: url, range: range) else {
            await load(); say("Trim failed."); return
        }
        posters[clip.id] = nil
        trimIn = 0; trimOut = 1
        await load()
        say("Trim saved")
    }

    // ponytail: re-encodes so the cut lands on the chosen frame. Passthrough would be instant but
    // snaps the start back to the previous keyframe.
    nonisolated private static func trimInPlace(url: URL, range: CMTimeRange) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard range.duration.seconds > 0.05,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { return false }
        exporter.timeRange = range
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try await exporter.export(to: tmp, as: .mov)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: export

    /// Exports exactly what is on screen: the visible region at its own source resolution, so the
    /// crop decides the shape. Even dimensions, H.264 rejects odd ones.
    private func exportSize(_ s: CGRect) -> CGSize {
        let p = pixels(s)
        return CGSize(width: max(16, (p.width / 2).rounded() * 2),
                      height: max(16, (p.height / 2).rounded() * 2))
    }

    private func saveToCameraRoll() async {
        isSaving = true
        defer { isSaving = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            say("Photos permission denied."); return
        }

        let source = effectiveSource
        let range = CMTimeRange(start: CMTime(seconds: trimIn * duration, preferredTimescale: 600),
                                end: CMTime(seconds: trimOut * duration, preferredTimescale: 600))
        let size = exportSize(source)
        guard let out = await Self.renderEdit(url: recording.url, source: source,
                                              output: size, range: range) else {
            say("Export failed."); return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out)
            }
            say(String(format: "Saved to Camera Roll · %.1fs · %d × %d",
                       (trimOut - trimIn) * duration, Int(size.width), Int(size.height)))
        } catch {
            say("Save failed.")
        }
        try? FileManager.default.removeItem(at: out)
    }

    /// Re-encode `url` keeping only `range`, with the normalized `source` region filling `output`.
    nonisolated private static func renderEdit(url: URL, source: CGRect, output: CGSize,
                                              range: CMTimeRange) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let pt = try? await track.load(.preferredTransform),
              let dur = try? await asset.load(.duration) else { return nil }
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30

        // Normalize the preferred transform so the oriented frame starts at (0,0).
        let d = CGRect(origin: .zero, size: natural).applying(pt)
        let display = CGSize(width: abs(d.width), height: abs(d.height))
        let base = pt.concatenating(CGAffineTransform(translationX: -d.minX, y: -d.minY))

        let comp = AVMutableVideoComposition()
        comp.renderSize = output
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: dur)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(exportTransform(source: source, displaySize: display,
                                           output: output, preferred: base), at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        exporter.videoComposition = comp
        exporter.timeRange = range
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try await exporter.export(to: tmp, as: .mov)
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }
}
