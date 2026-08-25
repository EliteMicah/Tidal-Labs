//
//  TidalLabsApp.swift
//  TidalLabs
//
//  Created by Micah Woodring on 4/11/26.
//

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
