import SwiftUI
import AVFoundation
import AVKit
import Photos

struct ThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.1)
                    .overlay(
                        Image(systemName: "video.fill")
                            .foregroundStyle(.white.opacity(0.4))
                    )
            }
        }
        .task {
            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            if let cgImage = try? await gen.image(at: .zero).image {
                thumbnail = UIImage(cgImage: cgImage)
            }
        }
    }
}

struct RecordingRow: View {
    let recording: SessionRecording

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: recording.url)
                .frame(width: 80, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Session Recording")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
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

struct SessionPlayerView: View {
    let recording: SessionRecording
    let onDismiss: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteAlert = false
    @State private var isSaving = false
    @State private var saveStatus: String?
    @State private var player: AVPlayer?

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
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .horizontal)
                }

                VStack(spacing: 12) {
                    if let status = saveStatus {
                        Text(status)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(spacing: 16) {
                        Button {
                            showDeleteAlert = true
                        } label: {
                            Text("Delete")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.red.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button {
                            saveToCameraRoll()
                        } label: {
                            Group {
                                if isSaving {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Save to Camera Roll")
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(isSaving)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
        }
        .onAppear { player = AVPlayer(url: recording.url) }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .alert("Delete Recording?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This recording will be permanently deleted.")
        }
    }

    private func saveToCameraRoll() {
        isSaving = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run { isSaving = false; saveStatus = "Photos permission denied." }
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: recording.url)
                }
                await MainActor.run { isSaving = false; saveStatus = "Saved to Camera Roll!" }
            } catch {
                await MainActor.run { isSaving = false; saveStatus = "Save failed." }
            }
        }
    }
}
