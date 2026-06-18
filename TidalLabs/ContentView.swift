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
    @State private var importedSession: WaveSession?
    @State private var homeDetailSession: WaveSession?
    @AppStorage("appColorScheme") private var appColorScheme = "light"

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(
                sessions: camera.waveSessions,
                onStart: { sessionActive = true },
                onSessions: { navPath.append(.sessions) },
                onLatestSession: { homeDetailSession = camera.waveSessions.first },
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
        .fullScreenCover(item: $importedSession) { session in
            SessionDetailView(
                sessionID: session.id,
                camera: camera,
                onDismiss: { importedSession = nil },
                shouldPromptDelete: camera.lastImportedOriginalAssetID != nil,
                onDeleteConfirm: {
                    if let id = camera.lastImportedOriginalAssetID { deletePhotoAsset(id) }
                    camera.lastImportedOriginalAssetID = nil
                },
                onDeleteDecline: { camera.lastImportedOriginalAssetID = nil }
            )
        }
        .onChange(of: camera.latestImportedSessionID) { _, newID in
            guard let id = newID,
                  let session = camera.waveSessions.first(where: { $0.id == id }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                importedSession = session
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
