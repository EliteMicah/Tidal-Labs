import SwiftUI
import AVFoundation
import StoreKit

struct SettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("resolution") private var resolution = VideoResolution.p720.rawValue
    @AppStorage("fps") private var fps = 30
    @AppStorage("waveDurationSeconds") private var waveDurationSeconds = 60

    @State private var resolutionLocal = VideoResolution.p720.rawValue
    @State private var fpsLocal = 30
    @State private var supportedResolutions: [VideoResolution] = [.p720, .p1080]
    @State private var supportedFPSOptions: [Int] = [30, 60]
    @State private var appStorageUsed: Int64 = 0
    @State private var deviceFreeStorage: Int64 = 0
    @State private var deviceTotalStorage: Int64 = 0
    @State private var showDeleteAllAlert = false
    @State private var tipProducts: [Product] = []
    @State private var tipPurchasing: String? = nil
    @State private var tipSuccess = false
    @State private var tipError: String? = nil
    @State private var tipLoading = true

    private let tipProductIDs = [
        "com.tidallabs.tip.5",
        "com.tidallabs.tip.15",
        "com.tidallabs.tip.30"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resolution")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Used to estimate storage and battery when recording with the native Camera app.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Picker("Resolution", selection: $resolutionLocal) {
                            ForEach(supportedResolutions, id: \.rawValue) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: resolutionLocal) { _, val in
                            resolution = val
                            let res = VideoResolution(rawValue: val) ?? .p1080
                            supportedFPSOptions = querySupportedFPS(for: res)
                            if !supportedFPSOptions.contains(fpsLocal) {
                                fpsLocal = supportedFPSOptions.first ?? 30
                                fps = fpsLocal
                            }
                        }
                    }
                }

                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Frame Rate")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Used to estimate storage and battery when recording with the native Camera app.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Picker("FPS", selection: $fpsLocal) {
                            ForEach(supportedFPSOptions, id: \.self) { rate in
                                Text("\(rate) fps").tag(rate)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: fpsLocal) { _, val in fps = val }
                    }
                }

                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wave Recording Duration")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("How far back the watch timestamps when you log a wave. Synced to Apple Watch.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        HStack {
                            Text(formatWaveDuration(waveDurationSeconds))
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        Slider(value: Binding(
                            get: { Double(waveDurationSeconds) },
                            set: { waveDurationSeconds = Int($0) }
                        ), in: 30...180, step: 5)
                        .tint(.white)
                        .onChange(of: waveDurationSeconds) { _, val in
                            camera.pushWaveDurationToWatch(val)
                        }
                    }
                }

                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Storage")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)

                        let usedFraction = deviceTotalStorage > 0
                            ? Double(deviceTotalStorage - deviceFreeStorage) / Double(deviceTotalStorage)
                            : 0.0
                        let appFraction = deviceTotalStorage > 0
                            ? Double(appStorageUsed) / Double(deviceTotalStorage)
                            : 0.0

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                    .frame(height: 8)
                                Capsule()
                                    .fill(.white.opacity(0.45))
                                    .frame(width: geo.size.width * usedFraction, height: 8)
                                Capsule()
                                    .fill(.white)
                                    .frame(width: geo.size.width * appFraction, height: 8)
                            }
                        }
                        .frame(height: 8)

                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(.white).frame(width: 8, height: 8)
                                Text("TidalLabs: \(formatBytes(appStorageUsed))")
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(.white.opacity(0.45)).frame(width: 8, height: 8)
                                Text("Other: \(formatBytes(deviceTotalStorage - deviceFreeStorage - appStorageUsed))")
                            }
                        }
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))

                        HStack {
                            Text("\(formatBytes(deviceFreeStorage)) free of \(formatBytes(deviceTotalStorage))")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                            Spacer()
                        }

                        Button(action: { showDeleteAllAlert = true }) {
                            Text("Delete All Clips & Sessions")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.red.opacity(0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(appStorageUsed == 0)
                    }
                }
                .alert("Delete All Clips & Sessions?", isPresented: $showDeleteAllAlert) {
                    Button("Delete All", role: .destructive) {
                        camera.deleteAllSessions()
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: [])) ?? []
                        files.filter { $0.pathExtension == "mov" }.forEach { try? FileManager.default.removeItem(at: $0) }
                        refreshStorage()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All saved session recordings will be permanently deleted. This cannot be undone.")
                }
                donationCard

            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            do {
                tipProducts = try await Product.products(for: tipProductIDs)
                    .sorted { $0.price < $1.price }
            } catch {
                tipError = error.localizedDescription
            }
            tipLoading = false
        }
        .onAppear {
            resolutionLocal = resolution
            fpsLocal = fps
            supportedResolutions = querySupportedResolutions()
            let res = VideoResolution(rawValue: resolution) ?? .p1080
            supportedFPSOptions = querySupportedFPS(for: res)
            if !supportedFPSOptions.contains(fpsLocal) {
                fpsLocal = supportedFPSOptions.first ?? 30
                fps = fpsLocal
            }
            refreshStorage()
        }
        .navigationTitle("Settings")
    }

    private func formatWaveDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let m = seconds / 60
        let s = seconds % 60
        return s == 0 ? "\(m) min" : "\(m) min \(s) sec"
    }

    private func querySupportedResolutions() -> [VideoResolution] {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return [.p720, .p1080]
        }
        let dims = device.formats.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
        var result: [VideoResolution] = []
        if dims.contains(where: { $0.width >= 1280 && $0.height >= 720 })  { result.append(.p720) }
        if dims.contains(where: { $0.width >= 1920 && $0.height >= 1080 }) { result.append(.p1080) }
        if dims.contains(where: { $0.width >= 3840 && $0.height >= 2160 }) { result.append(.k4) }
        return result
    }

    private func querySupportedFPS(for resolution: VideoResolution) -> [Int] {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return [30, 60]
        }
        let (tw, th): (Int32, Int32) = switch resolution {
        case .p720:  (1280, 720)
        case .p1080: (1920, 1080)
        case .k4:    (3840, 2160)
        }
        let maxFPS = device.formats
            .filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width >= tw && d.height >= th
            }
            .flatMap { $0.videoSupportedFrameRateRanges }
            .map { $0.maxFrameRate }
            .max() ?? 30
        var result = [30]
        if maxFPS >= 59 { result.append(60) }
        return result
    }

    private func refreshStorage() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
        appStorageUsed = files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: docs.path)
        deviceTotalStorage = (attrs?[.systemSize] as? Int64) ?? 0
        deviceFreeStorage = (attrs?[.systemFreeSize] as? Int64) ?? 0
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }

    @ViewBuilder
    private var donationCard: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Support TidalLabs")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Enjoying the app? A tip helps keep development going.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))

                if tipSuccess {
                    HStack {
                        Image(systemName: "heart.fill")
                        Text("Thank you!")
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if tipLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else if !tipProducts.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(tipProducts, id: \.id) { product in
                            Button(action: { purchase(product) }) {
                                VStack(spacing: 4) {
                                    Text(tipLabel(for: product.id))
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Text(product.displayPrice)
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    tipPurchasing == product.id
                                        ? .white.opacity(0.05)
                                        : .white.opacity(0.12)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(.white.opacity(0.2), lineWidth: 1)
                                )
                            }
                            .disabled(tipPurchasing != nil)
                        }
                    }
                } else {
                    Text("Donations unavailable right now.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                if let err = tipError {
                    Text(err)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
        }
    }

    private func tipLabel(for productID: String) -> String {
        switch productID {
        case "com.tidallabs.tip.5":  return "$5"
        case "com.tidallabs.tip.15": return "$15"
        case "com.tidallabs.tip.30": return "$30"
        default: return "Tip"
        }
    }

    private func purchase(_ product: Product) {
        tipPurchasing = product.id
        tipError = nil
        Task {
            do {
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        await transaction.finish()
                        tipSuccess = true
                    case .unverified:
                        tipError = "Purchase could not be verified."
                    }
                case .userCancelled:
                    break
                case .pending:
                    break
                @unknown default:
                    break
                }
            } catch {
                tipError = error.localizedDescription
            }
            tipPurchasing = nil
        }
    }

    @ViewBuilder
    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
