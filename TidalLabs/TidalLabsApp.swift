//
//  TidalLabsApp.swift
//  TidalLabs
//
//  Created by Micah Woodring on 4/11/26.
//

import AVFoundation
import SwiftUI
import UIKit

// Locked to portrait everywhere except while a landscape wave clip is playing.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait {
        didSet {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Clips are silent, so the app never needs to own the audio session. .ambient mixes instead of
        // interrupting, which keeps the user's music playing when they tap a clip.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        GarminManager.shared.initializeSDK()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

@main
struct TidalLabsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
