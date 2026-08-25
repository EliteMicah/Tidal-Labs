import SwiftUI
import Photos

struct SessionStartView: View {
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void

    @State private var isImporting = false
    @State private var showVideoPicker = false
    @State private var importError: String?
    @Environment(\.colorScheme) private var scheme

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("camera.fill",            "Hit record",        "Open the native Camera, frame the lineup, and set your phone down facing the break."),
        ("lock.fill",              "Lock it down",      "Keep the phone locked while it films — safer if a stranger picks it up."),
        ("applewatch",             "Tag from your wrist","Caught one? Tag your Apple Watch. We remember the moment you rode."),
        ("square.and.arrow.down",  "Reel it in",        "Back on the sand, import the clip and sync your watch — we slice out every wave."),
    ]

    var body: some View {
        ZStack {
            TLBackground()

            // Accent glow
            RadialGradient(
                colors: [Color.tlAccent.opacity(0.20), .clear],
                center: .init(x: 0.5, y: 0),
                startRadius: 0, endRadius: 280
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button
                HStack {
                    TLRoundel(systemName: "xmark", action: onDismiss)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)

                VStack(spacing: 0) {
                        // Shield icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color.tlAccent)
                                .frame(width: 78, height: 78)
                                .shadow(color: Color.tlAccent.opacity(0.45), radius: 20, x: 0, y: 10)
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 8)

                        // Title
                        Text("Before you\npaddle out")
                            .font(.bricolage(32))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .kerning(-0.8)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .padding(.top, 18)

                        // Subtitle
                        HStack(spacing: 10) {
                            WaveRule()
                            Text("Four moves to a session full of clips")
                                .font(.hanken(14, weight: .medium))
                                .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                        }
                        .padding(.top, 12)

                        // Steps
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                                PaddleStepRow(
                                    number: idx + 1,
                                    icon: step.icon,
                                    title: step.title,
                                    detail: step.detail,
                                    isLast: idx == steps.count - 1
                                )
                            }
                        }
                        .padding(.top, 28)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                }

                // CTA
                VStack(spacing: 8) {
                    Button {
                        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                            DispatchQueue.main.async { showVideoPicker = true }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isImporting {
                                ProgressView().tint(.white).scaleEffect(0.85)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            Text(isImporting ? "Importing..." : "Import video & sync")
                                .font(.hanken(17, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.tlAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: Color.tlAccent.opacity(0.45), radius: 16, x: 0, y: 8)
                    }
                    .disabled(isImporting)

                    Text("Pulls the latest clip from your camera roll")
                        .font(.hanken(12.5, weight: .semibold))
                        .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 36)
                .background(
                    LinearGradient(
                        colors: [.clear, scheme == .dark ? Color(tlHex: "071322") : Color(tlHex: "F4ECDC")],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(
                onProgress: { progress in
                    camera.iCloudDownloadProgress = progress
                },
                onResult: { result in
                    isImporting = true
                    camera.isLoadingVideo = true
                    Task {
                        switch result {
                        case .success(let (asset, tempURL, assetID)):
                            camera.lastImportedOriginalAssetID = assetID
                            let success = await camera.storeImportedVideo(asset: asset, tempURL: tempURL)
                            camera.isLoadingVideo = false
                            if !success { importError = "Could not read video timestamp." }
                        case .failure(let error):
                            print("[VideoImport] SessionStartView: picker error=\(error)")
                            camera.isLoadingVideo = false
                            importError = "Could not load video."
                        }
                        isImporting = false
                    }
                }
            )
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { camera.pendingImportVideo != nil || camera.isLoadingVideo },
                set: { if !$0 { camera.cancelPendingImport(); camera.isLoadingVideo = false } }
            )
        ) {
            PendingImportView(camera: camera)
        }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            if let err = importError { Text(err) }
        }
        .onChange(of: camera.clipGenerationCompleted) { _, _ in
            onDismiss()
        }
    }

}

// MARK: - Step row

private struct PaddleStepRow: View {
    @Environment(\.colorScheme) private var scheme
    let number: Int
    let icon: String
    let title: String
    let detail: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.tlInk.opacity(0.05))
                        .frame(width: 46, height: 46)
                        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.tlHairline, lineWidth: 1))
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.tlAccent)
                        .frame(width: 46, height: 46)
                    ZStack {
                        Circle().fill(Color.tlAccent).frame(width: 20, height: 20)
                        Text("\(number)")
                            .font(.bricolage(11))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 7, y: -7)
                }

                if !isLast {
                    Rectangle()
                        .fill(Color.tlHairline)
                        .frame(width: 2, height: 32)
                        .padding(.top, 4)
                        .mask(
                            LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom)
                        )
                }
            }
            .frame(width: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.bricolage(17))
                    .foregroundStyle(Color.tlDynamicInk(scheme))
                    .kerning(-0.3)
                Text(detail)
                    .font(.hanken(14))
                    .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 20)
        }
    }
}
