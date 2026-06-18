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
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                OceanThumbnail(index: 0)
                    .overlay(
                        Image(systemName: "video.fill")
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .task {
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

struct SessionPlayerView: View {
    let recording: SessionRecording
    var isFavorite: Bool = false
    let onDismiss: () -> Void
    let onDelete: () -> Void
    var onToggleFavorite: (() -> Void)? = nil
    @State private var showDeleteAlert = false
    @State private var isSaving = false
    @State private var saveStatus: String?
    @State private var player: AVPlayer?
    @State private var localFavorite: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.bricolage(15))
                        .foregroundStyle(.white)
                        .kerning(-0.3)
                    Spacer()
                    if onToggleFavorite != nil {
                        Button {
                            localFavorite.toggle()
                            onToggleFavorite?()
                        } label: {
                            Image(systemName: localFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(localFavorite ? Color.tlCoral : .white)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                    } else {
                        Color.clear.frame(width: 40, height: 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .horizontal)
                }

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    if let status = saveStatus {
                        Text(status)
                            .font(.hanken(13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(spacing: 14) {
                        Button { showDeleteAlert = true } label: {
                            Text("Delete")
                                .font(.hanken(15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(Color(red: 0.898, green: 0.282, blue: 0.302))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        Button { saveToCameraRoll() } label: {
                            Group {
                                if isSaving {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Save to Roll")
                                        .font(.hanken(15, weight: .bold))
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isSaving)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
        }
        .onAppear { player = AVPlayer(url: recording.url); localFavorite = isFavorite }
        .onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
        .alert("Delete Recording?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: { Text("This recording will be permanently deleted.") }
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
