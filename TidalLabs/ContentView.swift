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
                UIApplication.shared.isIdleTimerDisabled = true
                Task { await camera.startSession() }
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
            RecordingView(camera: camera) {
                Task { await camera.endSession() }
                sessionActive = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: camera.watchRequestedSessionStart) { _, requested in
            guard requested else { return }
            camera.watchRequestedSessionStart = false
            sessionActive = true
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await camera.startSession() }
        }
        .task { await camera.setup() }
    }
}

#Preview {
    ContentView()
}
