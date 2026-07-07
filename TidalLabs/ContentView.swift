//
//  ContentView.swift
//  TidalLabs
//
//  Created by Micah Woodring on 4/11/26.
//

import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var sessionActive = false
    @State private var navPath: [AppScreen] = []
    @State private var homeDetailSession: WaveSession?
    @State private var importToast: String?
    @State private var showDeleteImportedPhoto = false
    @AppStorage("appColorScheme") private var appColorScheme = "light"

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(
                sessions: camera.waveSessions,
                onStart: { sessionActive = true },
                onSessions: { navPath.append(.sessions) },
                onLatestSession: {
                    let latest = camera.waveSessions.first
                    if latest?.isProcessing != true { homeDetailSession = latest }
                },
                onSettings: { navPath.append(.settings) },
                onFavorites: { navPath.append(.favorites) }
            )
            .navigationDestination(for: AppScreen.self) { screen in
                switch screen {
                case .settings: SettingsView(camera: camera)
                case .sessions: SessionsView(camera: camera)
                case .favorites: FavoritesView(camera: camera)
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = importToast {
                Text(toast)
                    .font(.hanken(14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.tlAccent, in: Capsule())
                    .shadow(color: Color.tlAccent.opacity(0.4), radius: 12, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .preferredColorScheme(appColorScheme == "dark" ? .dark : .light)
        .fullScreenCover(isPresented: $sessionActive) {
            SessionStartView(camera: camera, onDismiss: { sessionActive = false })
        }
        .fullScreenCover(item: $homeDetailSession) { session in
            SessionDetailView(
                sessionID: session.id,
                camera: camera,
                onDismiss: { homeDetailSession = nil }
            )
        }
        .confirmationDialog("Delete Original Video?", isPresented: $showDeleteImportedPhoto, titleVisibility: .visible) {
            Button("Delete from Photos", role: .destructive) {
                if let id = camera.lastImportedOriginalAssetID { deletePhotoAsset(id) }
                camera.lastImportedOriginalAssetID = nil
            }
            Button("Keep", role: .cancel) { camera.lastImportedOriginalAssetID = nil }
        } message: {
            Text("Wave clips saved. Remove the original video from your photo library?")
        }
        .onChange(of: camera.latestImportedSessionID) { _, newID in
            guard let id = newID,
                  let session = camera.waveSessions.first(where: { $0.id == id }) else { return }
            navPath = []   // back to home, not into session detail
            let count = session.clips.count
            let msg = session.isProcessing
                ? "Imported — cropping \(count) clip\(count == 1 ? "" : "s")…"
                : "Imported — \(count) wave\(count == 1 ? "" : "s") ready"
            withAnimation { importToast = msg }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { importToast = nil } }
            if camera.lastImportedOriginalAssetID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showDeleteImportedPhoto = true }
            }
        }
        .task { await camera.setup() }
    }

    private func deletePhotoAsset(_ identifier: String) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }
}

#Preview {
    ContentView()
}
