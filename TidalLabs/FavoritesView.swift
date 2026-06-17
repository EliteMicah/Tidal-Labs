import SwiftUI
import AVKit

struct FavoritesView: View {
    @ObservedObject var camera: CameraManager
    @State private var selectedFavorite: FavoriteClipItem?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private var favorites: [FavoriteClipItem] {
        camera.favoritedClips.enumerated().map { idx, pair in
            FavoriteClipItem(
                id: pair.clip.id,
                clip: pair.clip,
                sessionID: pair.sessionID,
                url: docs.appendingPathComponent(pair.clip.filename),
                index: idx
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TLBackground()

            VStack(spacing: 0) {
                TLScreenHeader(title: "Favorites", onBack: { dismiss() })
                    .padding(.top, 8)

                if favorites.isEmpty {
                    emptyState
                } else {
                    favoriteGrid
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
        .fullScreenCover(item: $selectedFavorite) { item in
            let recording = SessionRecording(id: item.clip.id, url: item.url, date: item.clip.date)
            SessionPlayerView(
                recording: recording,
                isFavorite: true,
                onDismiss: { selectedFavorite = nil },
                onDelete: {
                    camera.deleteClip(item.clip.id, fromSession: item.sessionID)
                    selectedFavorite = nil
                },
                onToggleFavorite: {
                    camera.toggleFavorite(clipID: item.clip.id, sessionID: item.sessionID)
                    selectedFavorite = nil
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.tlCoral.opacity(0.12))
                        .frame(width: 116, height: 116)
                    Image(systemName: "heart")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(Color.tlCoral)
                }
                Text("No favorites yet")
                    .font(.bricolage(26))
                    .foregroundStyle(Color.tlDynamicInk(scheme))
                    .kerning(-0.5)
                    .padding(.top, 18)
                Text("Tap the heart on any wave clip to save it here.")
                    .font(.hanken(15, weight: .medium))
                    .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
    }

    private var favoriteGrid: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(favorites.count) wave\(favorites.count == 1 ? "" : "s") favorited")
                    .font(.hanken(12.5, weight: .bold))
                    .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 11) {
                    ForEach(favorites) { item in
                        FavoriteClipCard(item: item)
                            .onTapGesture { selectedFavorite = item }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 44)
            }
        }
    }
}

// MARK: - Favorite clip item

struct FavoriteClipItem: Identifiable {
    let id: UUID
    let clip: WaveClip
    let sessionID: UUID
    let url: URL
    let index: Int
}

// MARK: - Favorite clip card

private struct FavoriteClipCard: View {
    let item: FavoriteClipItem
    @State private var thumbnail: UIImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottom) {
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                OceanThumbnail(index: item.index)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack {
                Text(item.clip.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 10)

            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.tlCoral)
                        .padding(6)
                        .background(.black.opacity(0.35))
                        .clipShape(Circle())
                        .padding(8)
                }
                Spacer()
            }

            VStack {
                HStack {
                    Text(item.clip.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .tracking(0.5)
                        .padding(.leading, 10)
                        .padding(.top, 10)
                    Spacer()
                }
                Spacer()
            }

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
        }
        .aspectRatio(0.89, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 14, x: 0, y: 6)
        .task {
            guard thumbnail == nil else { return }
            let asset = AVAsset(url: item.url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 300, height: 300)
            if let cgImg = try? await gen.image(at: .zero).image {
                thumbnail = UIImage(cgImage: cgImg)
            }
        }
    }
}
