import Foundation
import CoreGraphics

// Geometry shared by the landscape clip editor and its exporter.
//
// Two normalized spaces are in play:
//   • source space — the whole video frame, 0…1, origin top-left.
//   • view space   — what the user currently sees after pinch-zoom/pan. The crop rect lives here,
//                    because that is what the handles are dragged over.
// `sourceCropRect` is the bridge: it composes the zoom/pan window with the crop rect so the export
// re-encodes exactly the pixels that were on screen.

/// Normalized source rect visible at `zoom` with normalized `pan` (fraction of the on-screen video size).
func visibleSourceRect(zoom: Double, pan: CGPoint) -> CGRect {
    let s = 1 / zoom
    return CGRect(x: 0.5 - pan.x / zoom - s / 2,
                  y: 0.5 - pan.y / zoom - s / 2,
                  width: s, height: s)
}

/// `inner` (normalized inside `base`) expressed in the same space `base` lives in.
func nestRect(_ inner: CGRect, in base: CGRect) -> CGRect {
    CGRect(x: base.minX + inner.minX * base.width,
           y: base.minY + inner.minY * base.height,
           width: inner.width * base.width,
           height: inner.height * base.height)
}

/// Crop rect (normalized inside the on-screen video) mapped back into normalized source coordinates.
func sourceCropRect(crop: CGRect, zoom: Double, pan: CGPoint) -> CGRect {
    nestRect(crop, in: visibleSourceRect(zoom: zoom, pan: pan))
}

/// Pan limit that keeps the zoomed frame covering the view: |pan| ≤ (zoom − 1) / 2.
func clampPan(_ p: CGPoint, zoom: Double) -> CGPoint {
    let l = max(0, (zoom - 1) / 2)
    return CGPoint(x: min(l, max(-l, p.x)), y: min(l, max(-l, p.y)))
}

/// Resize `c` to display aspect `a` (width/height in points) over a video of aspect `videoAspect`,
/// keeping its center and staying inside 0…1. `nil` aspect = free-form, returned unchanged.
func fitCrop(_ c: CGRect, aspect a: Double?, videoAspect: Double) -> CGRect {
    guard let a else { return c }
    let n = a / videoAspect                 // crop w/h in *normalized* units
    let cx = c.midX, cy = c.midY
    var w = c.width, h = w / n
    if h > 1 { h = 1; w = h * n }
    if w > 1 { w = 1; h = w / n }
    let x = min(max(0, cx - w / 2), 1 - w)
    let y = min(max(0, cy - h / 2), 1 - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

/// Transform that lifts the normalized `source` region of a `displaySize` frame onto an `output`
/// canvas, aspect-filling and centering. `preferred` orients natural → display coordinates first.
func exportTransform(source: CGRect, displaySize: CGSize, output: CGSize,
                     preferred: CGAffineTransform) -> CGAffineTransform {
    let region = CGRect(x: source.minX * displaySize.width,
                        y: source.minY * displaySize.height,
                        width: max(1, source.width * displaySize.width),
                        height: max(1, source.height * displaySize.height))
    let scale = max(output.width / region.width, output.height / region.height)
    let dx = -region.minX * scale + (output.width - region.width * scale) / 2
    let dy = -region.minY * scale + (output.height - region.height * scale) / 2
    return preferred
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: dx, y: dy))
}

// MARK: - Self-check

#if DEBUG
func clipEditorSelfCheck() {
    let full = visibleSourceRect(zoom: 1, pan: .zero)
    assert(abs(full.minX) < 1e-9 && abs(full.width - 1) < 1e-9, "zoom 1 sees the whole frame")
    let v2 = visibleSourceRect(zoom: 2, pan: .zero)
    assert(abs(v2.minX - 0.25) < 1e-9 && abs(v2.width - 0.5) < 1e-9, "zoom 2 centered → middle half")

    let c = sourceCropRect(crop: CGRect(x: 0, y: 0, width: 1, height: 1), zoom: 1, pan: .zero)
    assert(abs(c.minX) < 1e-9 && abs(c.width - 1) < 1e-9, "full crop at zoom 1 is the whole source")
    let half = sourceCropRect(crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), zoom: 2, pan: .zero)
    assert(abs(half.minX - 0.25) < 1e-9 && abs(half.width - 0.25) < 1e-9, "crop compounds with zoom")

    // Applying a crop, then zooming inside it, composes into one source rect.
    let base = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)
    let nested = nestRect(visibleSourceRect(zoom: 2, pan: .zero), in: base)
    assert(abs(nested.minX - 0.325) < 1e-9 && abs(nested.width - 0.25) < 1e-9, "zoom nests inside applied crop")
    assert(nestRect(CGRect(x: 0, y: 0, width: 1, height: 1), in: base) == base, "unit nest is identity")

    let p = clampPan(CGPoint(x: 5, y: -5), zoom: 2)
    assert(abs(p.x - 0.5) < 1e-9 && abs(p.y + 0.5) < 1e-9, "pan clamped to ±(z−1)/2")
    assert(clampPan(CGPoint(x: 0.3, y: 0), zoom: 1) == .zero, "no pan at zoom 1")

    // 9:16 crop inside a 16:9 video: normalized w/h = (9/16)/(16/9).
    let f = fitCrop(CGRect(x: 0.09, y: 0.09, width: 0.82, height: 0.82), aspect: 9.0 / 16, videoAspect: 16.0 / 9)
    assert(abs(f.width / f.height - (9.0 / 16) / (16.0 / 9)) < 1e-6, "9:16 fit")
    assert(f.minX >= -1e-9 && f.maxX <= 1 + 1e-9 && f.minY >= -1e-9 && f.maxY <= 1 + 1e-9, "fit stays in bounds")
    let sq = fitCrop(CGRect(x: 0.09, y: 0.09, width: 0.82, height: 0.4), aspect: 16.0 / 9, videoAspect: 16.0 / 9)
    assert(abs(sq.width - sq.height) < 1e-9, "matching aspect → equal normalized sides")

    // Middle quarter of 4K → 1080p: scale 2, region origin lands on the canvas origin.
    let t = exportTransform(source: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                            displaySize: CGSize(width: 3840, height: 2160),
                            output: CGSize(width: 1920, height: 1080),
                            preferred: .identity)
    let tl = CGPoint(x: 960, y: 540).applying(t)
    let br = CGPoint(x: 2880, y: 1620).applying(t)
    assert(abs(tl.x) < 1e-6 && abs(tl.y) < 1e-6, "region top-left → canvas origin")
    assert(abs(br.x - 1920) < 1e-6 && abs(br.y - 1080) < 1e-6, "region bottom-right → canvas corner")
}
#endif
