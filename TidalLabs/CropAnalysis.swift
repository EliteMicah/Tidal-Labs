import Foundation
import CoreLocation
import CoreGraphics

// MARK: - Tunables

// ASSUMPTION: back wide (1x) lens, landscape, ~68° horizontal FOV. 0.5x/2x break this.
let HORIZONTAL_FOV_DEGREES = 68.0

// Distance → zoom. cropWidth is the fraction of frame width kept (smaller = tighter). Values are further
// floored by MIN_CROP_WIDTH at use so a distant subject never upscales into mush. Retune on real footage.
struct CropTier { let maxMeters: Double; let cropWidth: Double }

let CROP_TIERS = [
    CropTier(maxMeters: 15,        cropWidth: 0.80), // <50ft   minimal
    CropTier(maxMeters: 30,        cropWidth: 0.55), // 50–100ft moderate
    CropTier(maxMeters: 61,        cropWidth: 0.40), // 100–200ft tighter
    CropTier(maxMeters: .infinity, cropWidth: 0.28)  // 200ft+  tightest
]

// MARK: - Pure geometry (unit-testable)

/// Standard great-circle initial bearing, degrees 0–360.
func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let deg = atan2(y, x) * 180 / .pi
    return (deg + 360).truncatingRemainder(dividingBy: 360)
}

func distanceMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
}

func tier(forMeters m: Double) -> CropTier {
    CROP_TIERS.first { m <= $0.maxMeters } ?? CROP_TIERS[CROP_TIERS.count - 1]
}

func nearestFix(track: [GPSFix], at t: Double) -> GPSFix? {
    track.min { abs($0.t - t) < abs($1.t - t) }
}

/// Linear interp of the GPS track at wall time `t` (track assumed ascending in `t`).
/// Between fixes it interpolates (kills the ~1Hz staircase that made nearestFix trail the subject);
/// past either end it extrapolates along the adjacent segment's velocity, so feeding `t + lead`
/// predicts where the subject WILL be — the offline analogue of "look ahead". Downstream
/// expectedCenterX + crop clamps bound the result, so runaway extrapolation just pins to an edge.
func predictedCoord(track: [GPSFix], at t: Double) -> CLLocationCoordinate2D? {
    guard let first = track.first else { return nil }
    if track.count == 1 { return CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon) }
    var i = track.firstIndex { $0.t >= t } ?? track.count
    if i == 0 { i = 1 }                       // before start → extrapolate back along first segment
    if i >= track.count { i = track.count - 1 } // after end → extrapolate forward along last segment
    let a = track[i - 1], b = track[i]
    let span = b.t - a.t
    let f = span > 0 ? (t - a.t) / span : 0    // <0 or >1 when extrapolating
    return CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * f,
                                  longitude: a.lon + (b.lon - a.lon) * f)
}

/// Signed angular deviation (wrap to −180…180) ÷ FOV, mapped to normalized x = 0.5 + deviation/FOV, clamped 0…1.
func expectedCenterX(bearing b: Double, cameraCenterBearing c: Double) -> Double {
    var dev = (b - c).truncatingRemainder(dividingBy: 360)
    if dev > 180 { dev -= 360 }
    if dev < -180 { dev += 360 }
    let x = 0.5 + dev / HORIZONTAL_FOV_DEGREES
    return min(1, max(0, x))
}

/// Normalized crop (origin top-left) of width `tier.cropWidth`. Height uses the same fraction, which
/// preserves the source aspect ratio (crop w/h in pixels = cw*W / cw*H = W/H). Centered + clamped.
func cropRect(centerX: Double, centerY: Double, tier: CropTier, frameSize: CGSize) -> CGRect {
    let w = min(tier.cropWidth, 1)
    let h = w
    let x = min(max(0, centerX - w / 2), 1 - w)
    let y = min(max(0, centerY - h / 2), 1 - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

// MARK: - Motion-correlation subject selection (Pass 2)
//
// GPS position at close range is ±5–20m ≈ up to ~29° of frame width, so instantaneous "which box is
// nearest the GPS point" picks the wrong person and drifts. But the subject's MOTION over the whole clip
// (how they sweep laterally + how their range changes) is a fingerprint that survives that position noise.
// We associate Vision boxes into tracklets and score each tracklet's motion against the GPS motion; the
// best match is the subject, everyone else is a bystander.

// One Vision detection: normalized center (top-left origin), apparent size (box height fraction), confidence.
struct DetBox { let x: Double; let y: Double; let size: Double; let conf: Float }

// A tracklet: one person followed across samples. `idx[k]` is the sample index of `boxes[k]`.
struct Tracklet { var idx: [Int]; var boxes: [DetBox] }

/// First difference (length n-1). Correlating differences turns "position over time" into "motion over time".
func firstDiff(_ v: [Double]) -> [Double] {
    guard v.count >= 2 else { return [] }
    return (1..<v.count).map { v[$0] - v[$0 - 1] }
}

/// Unwrap a degrees series so a 359→1 step reads as +2, not −358 (bearing can cross 0 mid-clip).
func unwrapDegrees(_ deg: [Double]) -> [Double] {
    guard !deg.isEmpty else { return [] }
    var out = [deg[0]]
    for i in 1..<deg.count {
        var d = deg[i] - deg[i - 1]
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        out.append(out[i - 1] + d)
    }
    return out
}

/// Pearson correlation. 0 for <2 points or zero variance (flat signal can't discriminate).
func pearson(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count)
    guard n >= 2 else { return 0 }
    let ma = a.prefix(n).reduce(0, +) / Double(n)
    let mb = b.prefix(n).reduce(0, +) / Double(n)
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<n {
        let xa = a[i] - ma, xb = b[i] - mb
        num += xa * xb; da += xa * xa; db += xb * xb
    }
    let den = (da * db).squareRoot()
    return den > 0 ? num / den : 0
}

/// Greedy nearest-neighbor association: extend each open tracklet to the nearest unused box within `gate`
/// (normalized-x), allowing gaps up to `maxGap` samples; unmatched boxes seed new tracklets.
/// ponytail: greedy NN by x + size, no Kalman / full MOT. Fine offline at ~0.4s sampling; if fast crossings
/// swap identities, upgrade to Hungarian assignment or a motion model.
func associateTracklets(perSampleBoxes: [[DetBox]], maxGap: Int = 2, gate: Double = 0.15) -> [Tracklet] {
    var open: [Tracklet] = []
    var done: [Tracklet] = []
    for i in perSampleBoxes.indices {
        // Retire tracklets whose gap since last hit exceeds maxGap.
        var stillOpen: [Tracklet] = []
        for t in open {
            if i - (t.idx.last ?? i) > maxGap + 1 { done.append(t) } else { stillOpen.append(t) }
        }
        open = stillOpen
        let boxes = perSampleBoxes[i]
        var usedBox = Array(repeating: false, count: boxes.count)
        var matchedT = Array(repeating: false, count: open.count)
        // Rank all (tracklet, box) pairs within the x-gate by combined x+size distance, assign greedily.
        var pairs: [(cost: Double, ti: Int, bi: Int)] = []
        for (ti, t) in open.enumerated() {
            guard let last = t.boxes.last else { continue }
            for (bi, b) in boxes.enumerated() where abs(last.x - b.x) <= gate {
                pairs.append((abs(last.x - b.x) + abs(last.size - b.size), ti, bi))
            }
        }
        pairs.sort { $0.cost < $1.cost }
        for p in pairs where !matchedT[p.ti] && !usedBox[p.bi] {
            open[p.ti].idx.append(i)
            open[p.ti].boxes.append(boxes[p.bi])
            matchedT[p.ti] = true
            usedBox[p.bi] = true
        }
        for (bi, b) in boxes.enumerated() where !usedBox[bi] {
            open.append(Tracklet(idx: [i], boxes: [b]))
        }
    }
    done.append(contentsOf: open)
    return done
}

/// Score a tracklet's motion against the GPS motion, time-aligned on the tracklet's own sample indices.
/// `gpsLateral` = unwrapped bearing (deg); `gpsProximity` = −distance (m) so it rises as the subject nears,
/// matching apparent box size. Subject: dx tracks d(bearing) and d(size) tracks d(proximity) → both ≈ +1.
/// Lateral is weighted higher (Vision box size is noisier than its x). Returns −1 for tracklets too short.
func trackletScore(_ t: Tracklet, gpsLateral: [Double], gpsProximity: [Double]) -> Double {
    guard t.idx.count >= 3 else { return -1 }
    let dx = firstDiff(t.boxes.map { $0.x })
    let dsz = firstDiff(t.boxes.map { $0.size })
    let dlat = firstDiff(t.idx.map { gpsLateral[$0] })
    let dpr = firstDiff(t.idx.map { gpsProximity[$0] })
    return 0.7 * pearson(dx, dlat) + 0.3 * pearson(dsz, dpr)
}

/// Fingerprint is only usable if the subject actually swept in bearing or changed range over the clip.
/// A near-straight, constant-speed pass gives a flat derivative that correlation can't tell from noise →
/// caller falls back to nearest-box. Thresholds (5° of bearing travel OR 5m of range change) are tunable.
func gpsMotionIsDiscriminative(lateral: [Double], proximity: [Double]) -> Bool {
    let latSpread = (lateral.max() ?? 0) - (lateral.min() ?? 0)
    let proxSpread = (proximity.max() ?? 0) - (proximity.min() ?? 0)
    return latSpread >= 5.0 || proxSpread >= 5.0
}

// MARK: - Self-check

#if DEBUG
func cropAnalysisSelfCheck() {
    let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    assert(abs(bearing(from: origin, to: .init(latitude: 1, longitude: 0)) - 0) < 0.5, "due north ≈ 0°")
    assert(abs(bearing(from: origin, to: .init(latitude: 0, longitude: 1)) - 90) < 0.5, "due east ≈ 90°")
    assert(abs(expectedCenterX(bearing: 0, cameraCenterBearing: 0) - 0.5) < 0.001, "on-center → 0.5")
    assert(abs(expectedCenterX(bearing: HORIZONTAL_FOV_DEGREES / 2, cameraCenterBearing: 0) - 1.0) < 0.001, "+FOV/2 → 1.0")
    assert(tier(forMeters: 5).cropWidth == 0.80, "close tier")
    assert(tier(forMeters: 500).cropWidth == 0.28, "far tier")
    // predictedCoord: interp at t=1.5 between (t0,lat0) and (t2,lat2) → halfway; extrapolate past end.
    let trk = [GPSFix(t: 0, lat: 0, lon: 0), GPSFix(t: 1, lat: 1, lon: 0), GPSFix(t: 2, lat: 2, lon: 0)]
    assert(abs((predictedCoord(track: trk, at: 1.5)?.latitude ?? -9) - 1.5) < 1e-9, "interp mid")
    assert(abs((predictedCoord(track: trk, at: 3.0)?.latitude ?? -9) - 3.0) < 1e-9, "extrapolate ahead")

    // Motion-correlation helpers.
    assert(abs(pearson([1, 2, 3], [2, 4, 6]) - 1) < 1e-9, "perfect + corr")
    assert(abs(pearson([1, 2, 3], [6, 4, 2]) + 1) < 1e-9, "perfect − corr")
    assert(pearson([1, 1, 1], [1, 2, 3]) == 0, "flat → 0 corr")
    let uw = unwrapDegrees([350, 355, 5, 10])
    assert(abs(uw[3] - 370) < 1e-9, "unwrap across 0/360")

    // Two well-separated people → two tracklets, each spanning all samples.
    let two = (0..<4).map { i in [DetBox(x: 0.30 + 0.01 * Double(i), y: 0.5, size: 0.4, conf: 0.9),
                                  DetBox(x: 0.70 - 0.01 * Double(i), y: 0.5, size: 0.3, conf: 0.9)] }
    let tks = associateTracklets(perSampleBoxes: two)
    assert(tks.count == 2, "two people → two tracklets")
    assert(tks.allSatisfy { $0.idx.count == 4 }, "each tracklet spans all samples")

    // Subject tracklet whose x tracks the GPS bearing sweep outscores a bystander that wobbles randomly.
    let bearings = unwrapDegrees([100, 102, 105, 109, 114, 120])   // accelerating rightward sweep
    let prox = Array(repeating: -30.0, count: 6)                    // constant range → size term ≈ 0
    let subject = Tracklet(idx: Array(0..<6),
        boxes: [0.30, 0.32, 0.35, 0.39, 0.44, 0.50].map { DetBox(x: $0, y: 0.5, size: 0.4, conf: 0.9) })
    let bystander = Tracklet(idx: Array(0..<6),
        boxes: [0.50, 0.48, 0.51, 0.47, 0.52, 0.49].map { DetBox(x: $0, y: 0.5, size: 0.4, conf: 0.9) })
    let sSub = trackletScore(subject, gpsLateral: bearings, gpsProximity: prox)
    let sBy = trackletScore(bystander, gpsLateral: bearings, gpsProximity: prox)
    assert(sSub > sBy, "subject motion outscores bystander")
    assert(sSub > 0.5, "subject correlates strongly")
    assert(gpsMotionIsDiscriminative(lateral: bearings, proximity: prox), "20° sweep is discriminative")
    assert(!gpsMotionIsDiscriminative(lateral: [100, 100.5, 101], proximity: [-30, -31, -32]), "flat pass not discriminative")
}
#endif
