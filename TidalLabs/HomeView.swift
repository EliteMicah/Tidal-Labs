import SwiftUI

struct HomeView: View {
    let sessions: [WaveSession]
    let onStart: () -> Void
    let onSessions: () -> Void
    let onSettings: () -> Void
    let onFavorites: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var totalWaves: Int { sessions.reduce(0) { $0 + $1.clips.count } }
    private var latestSession: WaveSession? { sessions.first }
    private var favoritesCount: Int { sessions.flatMap(\.clips).filter(\.isFavorite).count }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 11 { return "Dawn patrol" }
        if h < 16 { return "Midday glass" }
        if h < 20 { return "Evening session" }
        return "Night surf"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TLBackground()

            // Sun glow
            RadialGradient(
                colors: [scheme == .dark ? Color(tlHex: "5B86FF").opacity(0.30) : Color.tlSand.opacity(0.40), .clear],
                center: .init(x: 1.15, y: -0.15),
                startRadius: 0, endRadius: 320
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {

                    // Top bar + wordmark aligned at top
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Tidal")
                                .font(.bricolage(66))
                                .foregroundStyle(Color.tlDynamicInk(scheme))
                                .kerning(-2)
                                .lineLimit(1)
                            Text("Labs")
                                .font(.bricolage(66))
                                .foregroundStyle(Color.tlAccent)
                                .kerning(-2)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image("TidalLabsLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .shadow(color: Color.tlAccent.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)

                    // Tagline
                    HStack(spacing: 12) {
                        WaveRule()
                        Text("Leave the phone. Tag your waves. Get the clips.")
                            .font(.hanken(15, weight: .medium))
                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 14)

                    // Stats strip
                    HStack(spacing: 10) {
                        TLStatBox(value: "\(sessions.count)", label: "Sessions")
                        TLStatBox(value: "\(totalWaves)", label: "Waves")
                        Button(action: onFavorites) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Text("\(favoritesCount)")
                                        .font(.bricolage(26))
                                        .foregroundStyle(Color.tlDynamicInk(scheme))
                                        .kerning(-0.6)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Image(systemName: favoritesCount > 0 ? "heart.fill" : "heart")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.tlCoral)
                                }
                                Text("Favorites")
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
                    .padding(.horizontal, 26)
                    .padding(.top, 18)

                    // Latest session shortcut
                    if let latest = latestSession {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pick up where you left off")
                                .font(.hanken(12, weight: .bold))
                                .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                                .kerning(0.6)
                                .textCase(.uppercase)

                            Button(action: onSessions) {
                                HStack(spacing: 13) {
                                    RoundedRectangle(cornerRadius: 15)
                                        .fill(Color.clear)
                                        .frame(width: 58, height: 58)
                                        .overlay(
                                            OceanThumbnail(index: 1)
                                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                        )
                                        .overlay(
                                            Text("\(latest.clips.count)")
                                                .font(.bricolage(20))
                                                .foregroundStyle(.white)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(latest.startDate.formatted(date: .abbreviated, time: .omitted))
                                            .font(.bricolage(17))
                                            .foregroundStyle(Color.tlDynamicInk(scheme))
                                            .kerning(-0.3)
                                        Text("\(latest.clips.count) wave\(latest.clips.count == 1 ? "" : "s") · \(latest.startDate.formatted(date: .omitted, time: .shortened))")
                                            .font(.hanken(13, weight: .semibold))
                                            .foregroundStyle(Color.tlDynamicInkSoft(scheme))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                                }
                                .padding(12)
                                .background(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.78))
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.tlDynamicHairline(scheme), lineWidth: 1))
                                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 14, x: 0, y: 6)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 18)
                    }

                    Spacer(minLength: 16)

                    // Primary CTA
                    Button(action: onStart) {
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.white.opacity(0.20))
                                    .frame(width: 52, height: 52)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start a session")
                                    .font(.bricolage(23))
                                    .foregroundStyle(.white)
                                    .kerning(-0.4)
                                Text("Set up & paddle out")
                                    .font(.hanken(13.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 17)
                        .background(Color.tlAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                        .shadow(color: Color.tlAccent.opacity(0.55), radius: 20, x: 0, y: 10)
                    }
                    .padding(.horizontal, 22)

                    // Secondary grid
                    HStack(spacing: 12) {
                        HomeSecondaryCard(
                            systemIcon: "film.fill",
                            iconColor: .tlCyan,
                            title: "Waves",
                            subtitle: "\(sessions.count) session\(sessions.count == 1 ? "" : "s")",
                            action: onSessions
                        )
                        HomeSecondaryCard(
                            systemIcon: "gearshape.fill",
                            iconColor: .tlSand,
                            title: "Settings",
                            subtitle: "Quality & storage",
                            action: onSettings
                        )
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                    Spacer().frame(height: 104)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Animated ocean — two layers matching design (foam + accent)
            ZStack(alignment: .bottom) {
                WaveStrip(
                    color: scheme == .dark ? Color(tlHex: "56CDEC") : Color.tlCyan,
                    height: 92, opacity: 0.25, dur: 11
                )
                WaveStrip(
                    color: Color.tlAccent,
                    height: 74, opacity: scheme == .dark ? 0.5 : 0.85, dur: 7
                )
            }
            .frame(height: 92)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationBarHidden(true)
    }
}

// MARK: - Secondary card

private struct HomeSecondaryCard: View {
    @Environment(\.colorScheme) private var scheme
    let systemIcon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.bricolage(18))
                    .foregroundStyle(Color.tlDynamicInk(scheme))
                    .kerning(-0.3)
                    .padding(.top, 10)
                Text(subtitle)
                    .font(.hanken(12.5, weight: .semibold))
                    .foregroundStyle(Color.tlDynamicInkFaint(scheme))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.80))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.tlDynamicHairline(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.07), radius: 12, x: 0, y: 5)
        }
    }
}
