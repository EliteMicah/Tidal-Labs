import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var orientationObserver: NSObjectProtocol?

        var session: AVCaptureSession? {
            get { previewLayer.session }
            set {
                previewLayer.session = newValue
                previewLayer.videoGravity = .resizeAspectFill
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateRotation()
            }
            updateRotation()
        }

        override func removeFromSuperview() {
            super.removeFromSuperview()
            if let obs = orientationObserver {
                NotificationCenter.default.removeObserver(obs)
                orientationObserver = nil
            }
        }

        private func updateRotation() {
            guard let connection = previewLayer.connection else { return }
            let angle: CGFloat
            switch UIDevice.current.orientation {
            case .landscapeRight:        angle = 180
            case .landscapeLeft:         angle = 0
            case .portraitUpsideDown:    angle = 360
            default:                     angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }
}
