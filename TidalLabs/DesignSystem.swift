import SwiftUI
import UIKit

// MARK: - Custom font helpers

extension Font {
    // Bricolage Grotesque — display/headlines
    static func bricolage(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        let name = bricolageName(weight)
        return UIFont(name: name, size: size).map { Font($0) }
            ?? .system(size: size, weight: weight, design: .rounded)
    }

    // Hanken Grotesk — body
    static func hanken(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = hankenName(weight)
        return UIFont(name: name, size: size).map { Font($0) }
            ?? .system(size: size, weight: weight)
    }

    private static func bricolageName(_ w: Font.Weight) -> String {
        switch w {
        case .bold:     return "BricolageGrotesque-Bold"
        case .semibold: return "BricolageGrotesque-SemiBold"
        default:        return "BricolageGrotesque-ExtraBold"
        }
    }

    private static func hankenName(_ w: Font.Weight) -> String {
        switch w {
        case .heavy, .black:  return "HankenGrotesk-ExtraBold"
        case .bold:           return "HankenGrotesk-Bold"
        case .semibold:       return "HankenGrotesk-SemiBold"
        case .medium:         return "HankenGrotesk-Medium"
        case .light:          return "HankenGrotesk-Light"
        default:              return "HankenGrotesk-Regular"
        }
    }
}

// MARK: - Color tokens

extension Color {
    static let tlBg        = Color(tlHex: "FBF6EC")
    static let tlSurface   = Color.white
    static let tlInk       = Color(tlHex: "0E2440")
    static let tlInkSoft   = Color(tlHex: "5B6E84")
    static let tlInkFaint  = Color(tlHex: "5B6E84").opacity(0.55)
    static let tlAccent    = Color(tlHex: "2F62F4")
    static let tlCyan      = Color(tlHex: "16A6CE")
    static let tlSand      = Color(tlHex: "E0A954")
    static let tlCoral     = Color(tlHex: "FF6A45")
    static let tlDanger    = Color(tlHex: "E5484D")
    static let tlHairline  = Color(tlHex: "10243F").opacity(0.10)

    // Dark mode tokens
    static let tlDarkBg       = Color(tlHex: "081627")
    static let tlDarkSurface  = Color(tlHex: "102A47")
    static let tlDarkInk      = Color(tlHex: "EEF5FC")
    static let tlDarkInkSoft  = Color(tlHex: "9FB6CE")
    static let tlDarkInkFaint = Color(tlHex: "9FB6CE").opacity(0.65)
    static let tlDarkAccentBlue = Color(tlHex: "5B86FF")
    static let tlDarkCyan     = Color(tlHex: "56CDEC")

    static func tlDynamicBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .tlDarkBg : .tlBg
    }
    static func tlDynamicSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .tlDarkSurface : .tlSurface
    }
    static func tlDynamicInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .tlDarkInk : .tlInk
    }
    static func tlDynamicInkSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .tlDarkInkSoft : .tlInkSoft
    }
    static func tlDynamicInkFaint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .tlDarkInkFaint : .tlInkFaint
    }
    static func tlDynamicHairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : .tlHairline
    }

    init(tlHex hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Background gradient

struct TLBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(tlHex: "0B1D33"), Color(tlHex: "071322")]
                : [Color(tlHex: "FFFDF8"), Color(tlHex: "F4ECDC")],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Ocean gradient thumbnail

private let oceanGradients: [[Color]] = [
    [Color(tlHex: "1A4C8F"), Color(tlHex: "0E2C57"), Color(tlHex: "0A1F3D")],
    [Color(tlHex: "1B7FA8"), Color(tlHex: "125E86"), Color(tlHex: "0C3554")],
    [Color(tlHex: "2C6FD6"), Color(tlHex: "1A4795"), Color(tlHex: "11295C")],
    [Color(tlHex: "16998C"), Color(tlHex: "0E5E72"), Color(tlHex: "0A3550")],
]

struct OceanThumbnail: View {
    var index: Int = 0
    var label: String? = nil

    var body: some View {
        let colors = oceanGradients[abs(index) % oceanGradients.count]
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { ctx, size in
                var p = Path()
                p.move(to: .init(x: -10, y: size.height * 0.72))
                p.addCurve(
                    to: .init(x: size.width + 10, y: size.height * 0.62),
                    control1: .init(x: size.width * 0.3, y: size.height * 0.55),
                    control2: .init(x: size.width * 0.7, y: size.height * 0.78)
                )
                ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 2)
                var p2 = Path()
                p2.move(to: .init(x: -10, y: size.height * 0.85))
                p2.addCurve(
                    to: .init(x: size.width + 10, y: size.height * 0.78),
                    control1: .init(x: size.width * 0.35, y: size.height * 0.92),
                    control2: .init(x: size.width * 0.7, y: size.height * 0.72)
                )
                ctx.stroke(p2, with: .color(.white.opacity(0.25)), lineWidth: 1.5)
            }
            if let label {
                VStack {
                    HStack {
                        Text(label)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .tracking(1)
                            .padding(.leading, 10)
                            .padding(.top, 8)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Wave decoration strip

struct WaveStrip: View {
    let color: Color
    let height: CGFloat
    let opacity: Double
    var dur: Double = 9

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let cycle = t.truncatingRemainder(dividingBy: dur)
                let offset = CGFloat(cycle / dur) * size.width
                for i in 0...1 {
                    let dx = CGFloat(i) * size.width - offset
                    ctx.fill(wavePath(size: size, dx: dx), with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(height: height)
        .clipped()
    }

    // Bezier path matching SVG: M0,60 C180,110 360,10 540,55 C720,100 900,15 1080,55 C1260,95 1380,40 1440,60
    private func wavePath(size: CGSize, dx: CGFloat) -> Path {
        let w = size.width
        let h = size.height
        func sx(_ v: CGFloat) -> CGFloat { v / 1440 * w + dx }
        func sy(_ v: CGFloat) -> CGFloat { v / 120 * h }
        var p = Path()
        p.move(to: CGPoint(x: sx(0), y: sy(60)))
        p.addCurve(
            to: CGPoint(x: sx(540), y: sy(55)),
            control1: CGPoint(x: sx(180), y: sy(110)),
            control2: CGPoint(x: sx(360), y: sy(10))
        )
        p.addCurve(
            to: CGPoint(x: sx(1080), y: sy(55)),
            control1: CGPoint(x: sx(720), y: sy(100)),
            control2: CGPoint(x: sx(900), y: sy(15))
        )
        p.addCurve(
            to: CGPoint(x: sx(1440), y: sy(60)),
            control1: CGPoint(x: sx(1260), y: sy(95)),
            control2: CGPoint(x: sx(1380), y: sy(40))
        )
        p.addLine(to: CGPoint(x: sx(1440), y: h))
        p.addLine(to: CGPoint(x: dx, y: h))
        p.closeSubpath()
        return p
    }
}

// MARK: - Wave rule decoration

struct WaveRule: View {
    var color: Color = .tlCyan
    var width: CGFloat = 64
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let pts: [(CGFloat, CGFloat)] = [(0,7),(10,3),(20,7),(30,3),(40,7),(50,3),(60,7),(70,3),(80,7)]
            p.move(to: .init(x: pts[0].0, y: pts[0].1))
            var i = 0
            while i + 1 < pts.count {
                let c = pts[i]; let n = pts[i+1]
                p.addCurve(to: .init(x: n.0, y: n.1),
                           control1: .init(x: c.0 + 5, y: c.1),
                           control2: .init(x: n.0 - 5, y: n.1))
                i += 1
            }
            ctx.stroke(p, with: .color(color), style: .init(lineWidth: 2.4, lineCap: .round))
        }
        .frame(width: width, height: 12)
    }
}

// MARK: - TL Card

struct TLCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 18
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .background(Color.tlDynamicSurface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.tlDynamicHairline(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.07), radius: 14, x: 0, y: 6)
    }
}

// MARK: - Roundel button

struct TLRoundel: View {
    @Environment(\.colorScheme) private var scheme
    let systemName: String
    var size: CGFloat = 44
    var accent: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent ? .white : Color.tlDynamicInk(scheme))
                .frame(width: size, height: size)
                .background(
                    accent
                        ? Color.tlAccent
                        : (scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.85))
                )
                .clipShape(Circle())
                .overlay(Circle().stroke(accent ? .clear : Color.tlDynamicHairline(scheme), lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10), radius: 8, x: 0, y: 4)
        }
    }
}

// MARK: - Condition chip

struct TLChip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var systemIcon: String? = nil
    var iconColor: Color? = nil

    init(_ text: String, systemIcon: String? = nil, iconColor: Color? = nil) {
        self.text = text
        self.systemIcon = systemIcon
        self.iconColor = iconColor
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = systemIcon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor ?? Color.tlInkSoft)
            }
            Text(text)
                .font(.hanken(12, weight: .semibold))
                .foregroundStyle(Color.tlDynamicInkSoft(scheme))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(scheme == .dark ? Color.white.opacity(0.06) : Color.tlInk.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Section header

struct TLSectionHeader: View {
    let title: String
    var systemIcon: String? = nil
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 8) {
            if let icon = systemIcon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.tlAccent)
            }
            Text(title)
                .font(.bricolage(19))
                .foregroundStyle(Color.tlDynamicInk(scheme))
                .kerning(-0.4)
            Rectangle()
                .fill(Color.tlDynamicHairline(scheme))
                .frame(height: 1)
        }
    }
}

// MARK: - Stat box (home screen)

struct TLStatBox: View {
    @Environment(\.colorScheme) private var scheme
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.bricolage(26))
                .foregroundStyle(Color.tlDynamicInk(scheme))
                .kerning(-0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.hanken(11, weight: .semibold))
                .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                .kerning(0.4)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.66))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.tlDynamicHairline(scheme), lineWidth: 1))
    }
}

// MARK: - Screen header (back + title + trailing)

struct TLScreenHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let onBack: () -> Void
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 12) {
            TLRoundel(systemName: "chevron.left", action: onBack)
            Text(title)
                .font(.bricolage(26))
                .foregroundStyle(Color.tlDynamicInk(scheme))
                .kerning(-0.6)
                .frame(maxWidth: .infinity, alignment: .center)
            if let t = trailing {
                t.frame(width: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Settings card

struct TLSettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        TLCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.tlAccent)
                        Text(title)
                            .font(.bricolage(19))
                            .foregroundStyle(Color.tlDynamicInk(scheme))
                            .kerning(-0.3)
                    }
                    if let sub = subtitle {
                        Text(sub)
                            .font(.hanken(13.5, weight: .medium))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                            .lineSpacing(2)
                    }
                }
                content()
            }
        }
    }
}

// MARK: - Custom segmented control

struct TLSegmented: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { opt in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { selection = opt.value }
                } label: {
                    Text(opt.label)
                        .font(.hanken(15, weight: .bold))
                        .foregroundStyle(selection == opt.value ? .white : Color.tlDynamicInkSoft(scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            selection == opt.value
                                ? Color.tlAccent.clipShape(RoundedRectangle(cornerRadius: 11))
                                    .shadow(color: Color.tlAccent.opacity(0.4), radius: 8, x: 0, y: 4)
                                : nil
                        )
                }
            }
        }
        .padding(4)
        .background(scheme == .dark ? Color.white.opacity(0.07) : Color.tlInk.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Swipe-back gesture (re-enable after hiding nav bar)

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async {
            vc.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            vc.navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

extension View {
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}

// MARK: - Rating dots

struct TLRatingDots: View {
    let rating: Int
    var light: Bool = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= rating
                        ? (light ? Color.white : Color.tlAccent)
                        : (light ? Color.white.opacity(0.3) : Color.tlHairline))
                    .frame(width: 5, height: 5)
            }
        }
    }
}
