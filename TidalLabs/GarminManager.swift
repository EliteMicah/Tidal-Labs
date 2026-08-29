import Foundation
import ConnectIQ
internal import Combine

//! The phone half of the Garmin sync in `garmin/`.
//!
//! `Communications.transmit` on the watch can only deliver to a phone app that links the Connect IQ
//! Mobile SDK. Nothing linked it, which is why the watch reported "Phone not connected" no matter
//! what — the watch side was already correct.
//!
//! Two things make this unlike WatchConnectivity:
//!
//! - The SDK talks straight to the watch over BLE. Garmin Connect Mobile is only the broker that
//!   hands over the devices the user agreed to share, so pairing is a one-time trip out to GCM and
//!   back in through our URL scheme.
//! - Delivery needs a live process. `bluetooth-central` plus the state-restoration identifier let
//!   iOS wake the app for watch traffic; that is the closest the SDK gets to WCSession's background
//!   delivery, and it is why sync is most reliable with TidalLabs open.
@MainActor
final class GarminManager: NSObject, ObservableObject {

    static let shared = GarminManager()

    /// Must match CFBundleURLSchemes in `Config/PhoneInfo.plist`.
    static let urlScheme = "tidallabs-ciq"

    /// Watch-app ids out of `garmin/manifest.xml`, dashed for NSUUID. Both listings are registered
    /// because the manifest has been published under two ids and the installed build may carry
    /// either. A mismatch here fails silently and is only debuggable on hardware, so the second
    /// registration buys a lot for two lines.
    private static let appUUIDs: [UUID] = [
        UUID(uuidString: "B608F363-360C-46F3-AB95-5E4551BF8B67")!,
        UUID(uuidString: "C80BB06A-039F-41E3-A94E-B4D4DF22BAF2")!
    ]

    private static let devicesKey = "garminDevices"

    @Published private(set) var deviceNames: [String] = []
    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage: String?

    private var devices: [IQDevice] = []
    /// Held only so the registrations outlive the loop that made them — the SDK is not documented
    /// to retain the IQApp it is handed.
    private var apps: [IQApp] = []
    private weak var camera: CameraManager?

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Call once from the app delegate. The SDK singleton has to exist before any device or app
    /// registration, and registration has to survive a background relaunch, so both happen here
    /// rather than when the Settings screen appears.
    func initializeSDK() {
        ConnectIQ.sharedInstance()?.initialize(withUrlScheme: Self.urlScheme,
                                               uiOverrideDelegate: self,
                                               stateRestorationIdentifier: Self.urlScheme)
        apply(devices: loadDevices(), persist: false)
    }

    func attach(_ camera: CameraManager) {
        self.camera = camera
    }

    // MARK: - Pairing

    /// Bounces out to Garmin Connect Mobile. Expect this app to be suspended while the user picks.
    func pairDevices() {
        statusMessage = nil
        ConnectIQ.sharedInstance()?.showDeviceSelection()
    }

    /// GCM returns the chosen devices by opening our URL scheme.
    func handle(url: URL) {
        guard url.scheme == Self.urlScheme,
              let picked = ConnectIQ.sharedInstance()?.parseDeviceSelectionResponse(from: url) as? [IQDevice]
        else { return }
        // Replace wholesale rather than merge: GCM's latest answer is the only authorization that
        // counts, and a device the user just revoked must not linger in our cache.
        apply(devices: picked, persist: true)
        statusMessage = picked.isEmpty ? "No watch shared from Garmin Connect" : nil
    }

    private func apply(devices new: [IQDevice], persist: Bool) {
        let ciq = ConnectIQ.sharedInstance()
        ciq?.unregister(forAllDeviceEvents: self)
        ciq?.unregister(forAllAppMessages: self)

        devices = new
        deviceNames = new.map { $0.friendlyName ?? $0.modelName ?? "Garmin watch" }
        apps = new.flatMap { device in
            Self.appUUIDs.map { IQApp(uuid: $0, store: $0, device: device) }
        }

        for device in new {
            ciq?.register(forDeviceEvents: device, delegate: self)
        }
        for app in apps {
            ciq?.register(forAppMessages: app, delegate: self)
        }
        if persist { saveDevices(new) }
        refreshConnected()
    }

    private func refreshConnected() {
        isConnected = devices.contains { ConnectIQ.sharedInstance()?.getDeviceStatus($0) == .connected }
    }

    private func saveDevices(_ list: [IQDevice]) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: list,
                                                           requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: Self.devicesKey)
    }

    private func loadDevices() -> [IQDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.devicesKey),
              let list = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: IQDevice.self, from: data)
        else { return [] }
        return list
    }

    // MARK: - Incoming waves

    /// One finished surf session as the watch sends it: epoch seconds throughout, one wave time per
    /// lap. See `SessionController.sync()` in `garmin/`.
    private struct GarminSession: Sendable {
        let start: Double
        let end: Double
        let waves: [Double]
    }

    private func ingest(_ sessions: [GarminSession]) {
        guard let camera, !sessions.isEmpty else { return }

        // Same window the Apple Watch uses: a wave is the clip ending at the button press.
        let saved = UserDefaults.standard.integer(forKey: "waveDurationSeconds")
        let duration = Double(saved == 0 ? 60 : saved)

        let payload: [[String: Any]] = sessions.map { session in
            let key = "garmin-\(Int(session.start))"
            return [
                // The watch sends no id. Derive a stable one from the start time — CameraManager
                // dedupes on it, and pressing Sync Waves again after a half-failed drain must not
                // import the same session twice.
                "id": key,
                "startDate": session.start,
                "endDate": session.end,
                "timestamps": session.waves.map { wave in
                    ["id": "\(key)-\(Int(wave))", "start": wave - duration, "end": wave]
                },
                // Empty on purpose. Garmin's GPS track rides the FIT file to Garmin Connect, not to
                // us, so auto-follow crop falls back to full frame for these sessions.
                "gpsTrack": []
            ]
        }

        camera.handleIncomingWatchSessions(payload)
        let waves = sessions.reduce(0) { $0 + $1.waves.count }
        statusMessage = "Received \(waves) wave\(waves == 1 ? "" : "s")"
    }

    /// Runs off the SDK's thread, so it decodes into Sendable values before hopping to the actor.
    private nonisolated static func parse(_ message: Any?) -> [GarminSession] {
        guard let dict = message as? [AnyHashable: Any],
              let raw = dict["sessions"] as? [[AnyHashable: Any]] else { return [] }
        return raw.compactMap { session in
            guard let start = (session["start"] as? NSNumber)?.doubleValue,
                  let end = (session["end"] as? NSNumber)?.doubleValue else { return nil }
            let waves = (session["waves"] as? [NSNumber])?.map { $0.doubleValue } ?? []
            return GarminSession(start: start, end: end, waves: waves)
        }
    }
}

// MARK: - IQDeviceEventDelegate

extension GarminManager: IQDeviceEventDelegate {
    nonisolated func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        Task { @MainActor in self.refreshConnected() }
    }
}

// MARK: - IQAppMessageDelegate

extension GarminManager: IQAppMessageDelegate {
    nonisolated func receivedMessage(_ message: Any, from app: IQApp) {
        let sessions = Self.parse(message)
        Task { @MainActor in self.ingest(sessions) }
    }
}

// MARK: - IQUIOverrideDelegate

extension GarminManager: IQUIOverrideDelegate {
    nonisolated func needsToInstallConnectMobile() {
        // Only ever reached from an explicit tap on Connect watch, so going straight to the store
        // page is the answer the user was already asking for. No extra prompt.
        Task { @MainActor in
            self.statusMessage = "Garmin Connect Mobile is required"
            ConnectIQ.sharedInstance()?.showAppStoreForConnectMobile()
        }
    }
}

#if DEBUG
/// The payload shape is the whole contract with the watch and it is only exercised on hardware, so
/// it gets the one runnable check.
func garminPayloadSelfCheck() {
    let message: [AnyHashable: Any] = [
        "sessions": [
            ["start": NSNumber(value: 1_000), "end": NSNumber(value: 2_000),
             "waves": [NSNumber(value: 1_100), NSNumber(value: 1_500)]],
            ["end": NSNumber(value: 9)]   // malformed, must be dropped rather than crash
        ]
    ]
    let parsed = GarminManager.parseForTesting(message)
    assert(parsed.count == 1, "malformed session should be dropped")
    assert(parsed[0].startTime == 1_000 && parsed[0].endTime == 2_000)
    assert(parsed[0].waveTimes == [1_100, 1_500])
    assert(GarminManager.parseForTesting(["nope": 1]).isEmpty)
}

extension GarminManager {
    struct ParsedSession { let startTime: Double; let endTime: Double; let waveTimes: [Double] }
    static func parseForTesting(_ message: Any?) -> [ParsedSession] {
        parse(message).map { ParsedSession(startTime: $0.start, endTime: $0.end, waveTimes: $0.waves) }
    }
}
#endif
