import SwiftUI
import PhotosUI
import Photos

struct SessionStartView: View {
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void

    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var pendingDeletePhotoID: String?
    @State private var showDeletePhotoAlert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Before You Paddle Out")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)

                    VStack(spacing: 14) {
                        instructionRow(
                            icon: "camera.fill",
                            text: "Open the native Camera app and start recording before entering the water."
                        )
                        instructionRow(
                            icon: "lock.fill",
                            text: "Make sure your phone is not unlocked while recording (in case someone takes it)."
                        )
                        instructionRow(
                            icon: "applewatch",
                            text: "Use your Apple Watch to log waves during your session."
                        )
                        instructionRow(
                            icon: "square.and.arrow.down",
                            text: "When done, come back here, import your video and tap sync session on your watch to generate wave clips."
                        )
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()

                PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                    HStack(spacing: 10) {
                        if isImporting {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.9)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(.body, weight: .semibold))
                        }
                        Text(isImporting ? "Importing..." : "Import Video")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.white)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .disabled(isImporting)
            }
        }
        .onChange(of: selectedVideoItem) { _, item in
            guard let item else { return }
            isImporting = true
            Task {
                await handleVideoImport(item)
                selectedVideoItem = nil
                isImporting = false
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { camera.pendingImportVideo != nil || camera.isLoadingVideo },
            set: { if !$0 { camera.cancelPendingImport(); camera.isLoadingVideo = false } }
        )) {
            PendingImportView(camera: camera)
        }
        .alert("Import Error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            if let err = importError { Text(err) }
        }
        .confirmationDialog(
            "Delete Original Video?",
            isPresented: $showDeletePhotoAlert,
            titleVisibility: .visible
        ) {
            Button("Delete from Photos", role: .destructive) {
                if let id = pendingDeletePhotoID { deletePhotoAsset(id) }
                pendingDeletePhotoID = nil
            }
            Button("Keep", role: .cancel) { pendingDeletePhotoID = nil }
        } message: {
            Text("Wave clips saved. Remove the original video from your photo library?")
        }
        .onChange(of: camera.clipGenerationCompleted) { _, _ in
            if pendingDeletePhotoID != nil { showDeletePhotoAlert = true }
        }
    }

    private func deletePhotoAsset(_ identifier: String) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        })
    }

    @ViewBuilder
    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }

    private func handleVideoImport(_ item: PhotosPickerItem) async {
        pendingDeletePhotoID = item.itemIdentifier
        camera.isLoadingVideo = true
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                camera.isLoadingVideo = false
                importError = "Could not load video."
                pendingDeletePhotoID = nil
                return
            }
            let success = await camera.storeImportedVideo(from: movie.url)
            camera.isLoadingVideo = false
            if !success {
                importError = "Could not read video timestamp."
                pendingDeletePhotoID = nil
            }
        } catch {
            camera.isLoadingVideo = false
            importError = "Could not load video."
            pendingDeletePhotoID = nil
        }
    }
}
