import UIKit

final class OrientationManager {
    static let shared = OrientationManager()
    private init() {}

    var allowedOrientations: UIInterfaceOrientationMask = .portrait

    func lock(_ mask: UIInterfaceOrientationMask) {
        allowedOrientations = mask
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.allowedOrientations
    }
}
