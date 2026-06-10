//
//  ContentView.swift
//  TidalLabs
//
//  Created by Micah Woodring on 4/11/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var sessionActive = false
    @State private var navPath: [AppScreen] = []

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(onStart: {
                sessionActive = true
            }, onSessions: {
                navPath.append(.sessions)
            }, onSettings: {
                navPath.append(.settings)
            })
            .navigationDestination(for: AppScreen.self) { screen in
                switch screen {
                case .settings: SettingsView(camera: camera)
                case .sessions: SessionsView(camera: camera)
                }
            }
        }
        .fullScreenCover(isPresented: $sessionActive) {
            SessionStartView(camera: camera, onDismiss: { sessionActive = false })
        }
        .task { await camera.setup() }
    }
}

#Preview {
    ContentView()
}
