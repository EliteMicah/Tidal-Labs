import SwiftUI
import AVFoundation
import StoreKit

struct SettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("appColorScheme") private var appColorScheme = "light"
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
    @State private var confirmDelete = false
    @State private var confirmClearSyncs = false
    @State private var tipProducts: [Product] = []
    @State private var tipPurchasing: String? = nil
    @State private var tipSuccess = false
    @State private var tipError: String? = nil
    @State private var tipLoading = true
    @State private var storagePulse = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private let tipProductIDs = ["com.tidallabs.app.tip.5", "com.tidallabs.app.tip.15", "com.tidallabs.app.tip.30"]

    var body: some View {
        ZStack {
            TLBackground()

            VStack(spacing: 0) {
                TLScreenHeader(title: "Settings", onBack: { dismiss() })
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {

                        // Appearance
                        TLSettingsCard(icon: "sun.max.fill", title: "Appearance",
                                       subtitle: "Pick your light. Dawn patrol or midday glass.") {
                            TLSegmented(
                                options: [
                                    (value: "light", label: "Daybreak"),
                                    (value: "dark", label: "Dawn Patrol")
                                ],
                                selection: $appColorScheme
                            )
                        }

                        // Wave recording duration
                        TLSettingsCard(icon: "clock.arrow.circlepath", title: "Wave recording duration",
                                       subtitle: "How far back the watch reaches when you tag a wave. Timestamps recorded by Apple Watch.") {
                            HStack {
                                Text(formatWaveDuration(waveDurationSeconds))
                                    .font(.bricolage(28))
                                    .foregroundStyle(Color.tlDynamicInk(scheme))
                                    .kerning(-0.6)
                                Spacer()
                                Text("per clip, looking back")
                                    .font(.hanken(12.5, weight: .semibold))
                                    .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                            }
                            .padding(.bottom, 2)

                            TLSlider(value: Binding(
                                get: { Double(waveDurationSeconds) },
                                set: { waveDurationSeconds = Int($0) }
                            ), range: 30...180, step: 5, pulse: storagePulse)
                            .onChange(of: waveDurationSeconds) { _, val in camera.pushWaveDurationToWatch(val) }

                            HStack {
                                Text("30 sec")
                                Spacer()
                                Text("3 min")
                            }
                            .font(.hanken(11.5, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                            .padding(.top, 2)
                        }

                        // Resolution
                        TLSettingsCard(icon: "slider.horizontal.3", title: "Resolution",
                                       subtitle: "For estimates only. These settings don't change your camera. Match them to what you set in the Camera app.") {
                            TLSegmented(
                                options: supportedResolutions.map { (value: $0.rawValue, label: $0.rawValue) },
                                selection: $resolutionLocal
                            )
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

                        // Frame rate
                        TLSettingsCard(icon: "timer", title: "Frame rate",
                                       subtitle: "Higher frame rates mean buttery slow-mo — and bigger files.") {
                            TLSegmented(
                                options: supportedFPSOptions.map { (value: "\($0)", label: "\($0) fps") },
                                selection: Binding(
                                    get: { "\(fpsLocal)" },
                                    set: { fpsLocal = Int($0) ?? 30; fps = fpsLocal }
                                )
                            )
                        }

                        // Recording estimates
                        recordingEstimatesCard

                        // Storage
                        storageCard

                        // Support
                        donationCard

                        Text("TidalLabs · v1.0 · Made on the coast")
                            .font(.hanken(12, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                }
            }
        }
        .navigationBarHidden(true)
        .enableSwipeBack()
        .task {
            do {
                tipProducts = try await Product.products(for: tipProductIDs).sorted { $0.price < $1.price }
            } catch { tipError = error.localizedDescription }
            tipLoading = false
        }
        .onAppear {
            resolutionLocal = resolution
            fpsLocal = fps
            supportedResolutions = querySupportedResolutions()
            let res = VideoResolution(rawValue: resolution) ?? .p1080
            supportedFPSOptions = querySupportedFPS(for: res)
            if !supportedFPSOptions.contains(fpsLocal) { fpsLocal = supportedFPSOptions.first ?? 30; fps = fpsLocal }
            refreshStorage()
            DispatchQueue.main.async { storagePulse = true }
            camera.requestWatchSync()
        }
    }

    // MARK: - Recording estimates card

    private var estimatedGBPerHour: (low: Double, high: Double) {
        let res = VideoResolution(rawValue: resolutionLocal) ?? .p1080
        switch (res, fpsLocal) {
        case (.p720, 60): return (low: 4.5, high: 6.5)
        case (.p720, _): return (low: 3.0, high: 4.5)
        case (.p1080, 60): return (low: 10.0, high: 14.0)
        case (.p1080, _): return (low: 6.5, high: 9.5)
        case (.k4, 60): return (low: 30.0, high: 42.0)
        case (.k4, _): return (low: 20.0, high: 28.0)
        default: return (low: 6.5, high: 9.5)
        }
    }

    private var estimatedBatteryPerHour: (low: Int, high: Int) {
        // Low = cool/shaded. High = direct sun + thermal throttling (~+20-25%).
        // Based on real-world tests: 4K60 drains ~60-67%/hr, 1080p30 ~45-52%/hr.
        let res = VideoResolution(rawValue: resolutionLocal) ?? .p1080
        switch (res, fpsLocal) {
        case (.p720, 60): return (low: 32, high: 52)
        case (.p720, _): return (low: 25, high: 45)
        case (.p1080, 60): return (low: 52, high: 75)
        case (.p1080, _): return (low: 42, high: 65)
        case (.k4, 60): return (low: 62, high: 90)
        case (.k4, _): return (low: 55, high: 80)
        default: return (low: 42, high: 65)
        }
    }

    private func formatGB(_ gb: Double) -> String {
        gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    private var recordingEstimatesCard: some View {
        TLCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.tlAccent.opacity(0.12))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.tlAccent)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1 hr recording estimates")
                            .font(.bricolage(16))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .kerning(-0.3)
                        Text("Ranges vary by scene. Match settings to your Camera app — they don't change it.")
                            .font(.hanken(12.5, weight: .medium))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    }
                }

                Rectangle()
                    .fill(Color.tlHairline)
                    .frame(height: 1)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Storage")
                            .font(.hanken(11.5, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                        Text("\(formatGB(estimatedGBPerHour.low)) – \(formatGB(estimatedGBPerHour.high))")
                            .font(.bricolage(18))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .kerning(-0.4)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Battery drain")
                            .font(.hanken(11.5, weight: .semibold))
                            .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                        Text("\(estimatedBatteryPerHour.low) – \(estimatedBatteryPerHour.high)%")
                            .font(.bricolage(18))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .kerning(-0.4)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Text("Upper end assumes direct sunlight — heat speeds up battery drain.")
                        .font(.hanken(11.5, weight: .medium))
                        .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Storage card

    private var storageCard: some View {
        TLSettingsCard(icon: "film.fill", title: "Storage") {
            let usedFraction = deviceTotalStorage > 0 ? Double(deviceTotalStorage - deviceFreeStorage) / Double(deviceTotalStorage) : 0.0
            let appFraction = deviceTotalStorage > 0 ? Double(appStorageUsed) / Double(deviceTotalStorage) : 0.0

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tlHairline).frame(height: 14)
                    Capsule()
                        .fill(LinearGradient(colors: [Color.tlAccent, Color.tlCyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * usedFraction, height: 14)
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.6), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.45, height: 14)
                    .clipShape(Capsule())
                    .offset(x: storagePulse ? geo.size.width * 1.75 : -geo.size.width * 0.45)
                    .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: storagePulse)
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)

            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color.tlAccent).frame(width: 8, height: 8)
                    Text("TidalLabs · \(formatBytes(appStorageUsed))")
                        .font(.hanken(13.5, weight: .bold))
                        .foregroundStyle(Color.tlDynamicInk(scheme))
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.tlDynamicInkFaint(scheme)).frame(width: 8, height: 8)
                    Text("Other · \(formatBytes(deviceTotalStorage - deviceFreeStorage - appStorageUsed))")
                        .font(.hanken(13.5, weight: .bold))
                        .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                }
            }
            .padding(.top, 4)

            Text("\(formatBytes(deviceFreeStorage)) free of \(formatBytes(deviceTotalStorage))")
                .font(.hanken(12.5, weight: .semibold))
                .foregroundStyle(Color.tlDynamicInkFaint(scheme))

            if !confirmDelete {
                Button { withAnimation { confirmDelete = true } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash.fill")
                        Text("Delete all clips & sessions")
                    }
                    .font(.hanken(15.5, weight: .bold))
                    .foregroundStyle(Color.tlDanger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.tlDanger.opacity(scheme == .dark ? 0.14 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tlDanger.opacity(0.3), lineWidth: 1))
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 10) {
                    Button { withAnimation { confirmDelete = false } } label: {
                        Text("Keep them")
                            .font(.hanken(15, weight: .bold))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(scheme == .dark ? Color.white.opacity(0.08) : Color.tlInk.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button {
                        confirmDelete = false
                        camera.deleteAllSessions()
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
                        files.filter { $0.pathExtension == "mov" }.forEach { try? FileManager.default.removeItem(at: $0) }
                        refreshStorage()
                    } label: {
                        Text("Delete everything")
                            .font(.hanken(15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.tlDanger)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.top, 4)
            }

            if !camera.pendingWatchSessions.isEmpty {
                if !confirmClearSyncs {
                    Button { withAnimation { confirmClearSyncs = true } } label: {
                        let count = camera.pendingWatchSessions.count
                        HStack(spacing: 8) {
                            Image(systemName: "applewatch.slash")
                            Text("Clear \(count) pending watch sync\(count == 1 ? "" : "s")")
                        }
                        .font(.hanken(15.5, weight: .bold))
                        .foregroundStyle(Color.tlDanger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.tlDanger.opacity(scheme == .dark ? 0.14 : 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tlDanger.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.top, 4)
                } else {
                    HStack(spacing: 10) {
                        Button { withAnimation { confirmClearSyncs = false } } label: {
                            Text("Keep them")
                                .font(.hanken(15, weight: .bold))
                                .foregroundStyle(Color.tlDynamicInk(scheme))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(scheme == .dark ? Color.white.opacity(0.08) : Color.tlInk.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        Button {
                            confirmClearSyncs = false
                            camera.clearPendingWatchSessions()
                        } label: {
                            Text("Clear syncs")
                                .font(.hanken(15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.tlDanger)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Donation card

    private var donationCard: some View {
        TLCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.tlSand.opacity(0.2))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "heart.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.tlSand)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Support TidalLabs")
                            .font(.bricolage(18))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .kerning(-0.3)
                        Text("Built by surfers, on dawn-patrol time.")
                            .font(.hanken(13, weight: .medium))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                    }
                }

                if tipSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                        Text("Thank you!")
                    }
                    .font(.hanken(15, weight: .bold))
                    .foregroundStyle(Color.tlSand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.tlSand.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if tipLoading {
                    ProgressView().tint(Color.tlAccent).frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if !tipProducts.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(tipProducts, id: \.id) { product in
                            Button { purchase(product) } label: {
                                VStack(spacing: 4) {
                                    Text(tipLabel(for: product.id))
                                        .font(.hanken(12, weight: .semibold))
                                        .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                                    Text(product.displayPrice)
                                        .font(.bricolage(16))
                                        .foregroundStyle(Color.tlDynamicInk(scheme))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(tipPurchasing == product.id
                                    ? Color.tlHairline
                                    : (scheme == .dark ? Color.white.opacity(0.08) : Color.tlInk.opacity(0.05)))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.tlHairline, lineWidth: 1))
                            }
                            .disabled(tipPurchasing != nil)
                        }
                    }
                } else {
                    Text("Donations unavailable right now.")
                        .font(.hanken(13, weight: .medium))
                        .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                if let err = tipError {
                    Text(err).font(.system(size: 12)).foregroundStyle(Color.tlDanger)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatWaveDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let m = seconds / 60; let s = seconds % 60
        return s == 0 ? "\(m) min" : "\(m)m \(s)s"
    }

    private func querySupportedResolutions() -> [VideoResolution] {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return [.p720, .p1080] }
        let dims = device.formats.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
        var result: [VideoResolution] = []
        if dims.contains(where: { $0.width >= 1280 && $0.height >= 720 })  { result.append(.p720) }
        if dims.contains(where: { $0.width >= 1920 && $0.height >= 1080 }) { result.append(.p1080) }
        if dims.contains(where: { $0.width >= 3840 && $0.height >= 2160 }) { result.append(.k4) }
        return result
    }

    private func querySupportedFPS(for resolution: VideoResolution) -> [Int] {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return [30, 60] }
        let (tw, th): (Int32, Int32) = switch resolution {
        case .p720: (1280, 720); case .p1080: (1920, 1080); case .k4: (3840, 2160)
        }
        let maxFPS = device.formats
            .filter { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width >= tw && d.height >= th }
            .flatMap { $0.videoSupportedFrameRateRanges }
            .map { $0.maxFrameRate }.max() ?? 30
        var result = [30]; if maxFPS >= 59 { result.append(60) }; return result
    }

    private func refreshStorage() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
        appStorageUsed = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: docs.path)
        deviceTotalStorage = (attrs?[.systemSize] as? Int64) ?? 0
        deviceFreeStorage = (attrs?[.systemFreeSize] as? Int64) ?? 0
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }

    private func tipLabel(for id: String) -> String {
        switch id {
        case "com.tidallabs.app.tip.5": return "Small wave"
        case "com.tidallabs.app.tip.15": return "Overhead"
        case "com.tidallabs.app.tip.30": return "Double overhead"
        default: return "Tip"
        }
    }

    private func purchase(_ product: Product) {
        tipPurchasing = product.id; tipError = nil
        Task {
            do {
                let result = try await product.purchase()
                switch result {
                case .success(let v):
                    switch v {
                    case .verified(let t): await t.finish(); tipSuccess = true
                    case .unverified: tipError = "Purchase could not be verified."
                    }
                case .userCancelled, .pending: break
                @unknown default: break
                }
            } catch { tipError = error.localizedDescription }
            tipPurchasing = nil
        }
    }
}

// MARK: - Custom slider

private struct TLSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let pulse: Bool
    @Environment(\.colorScheme) private var scheme

    private var pct: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.tlInk.opacity(0.07))
                        .frame(height: 12)

                    Capsule()
                        .fill(LinearGradient(colors: [Color.tlAccent, Color.tlCyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * pct, height: 12)

                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.6), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.45, height: 12)
                    .clipShape(Capsule())
                    .offset(x: pulse ? geo.size.width * 1.75 : -geo.size.width * 0.45)
                    .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: pulse)
                }
                .frame(height: 12)
                .clipShape(Capsule())

                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.tlAccent, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                    .offset(x: geo.size.width * pct - 13)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let p = max(0, min(1, drag.location.x / geo.size.width))
                let raw = range.lowerBound + p * (range.upperBound - range.lowerBound)
                value = (raw / step).rounded() * step
                value = max(range.lowerBound, min(range.upperBound, value))
            })
        }
        .frame(height: 30)
    }
}
