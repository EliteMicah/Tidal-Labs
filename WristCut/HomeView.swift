import SwiftUI

struct SurfboardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.5, y: 0))

        path.addCurve(
            to: CGPoint(x: w * 0.88, y: h * 0.38),
            control1: CGPoint(x: w * 0.65, y: h * 0.04),
            control2: CGPoint(x: w * 0.88, y: h * 0.18)
        )

        path.addCurve(
            to: CGPoint(x: w * 0.63, y: h),
            control1: CGPoint(x: w * 0.88, y: h * 0.66),
            control2: CGPoint(x: w * 0.76, y: h * 0.88)
        )

        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.93))
        path.addLine(to: CGPoint(x: w * 0.37, y: h))

        path.addCurve(
            to: CGPoint(x: w * 0.12, y: h * 0.38),
            control1: CGPoint(x: w * 0.24, y: h * 0.88),
            control2: CGPoint(x: w * 0.12, y: h * 0.66)
        )

        path.addCurve(
            to: CGPoint(x: w * 0.5, y: 0),
            control1: CGPoint(x: w * 0.12, y: h * 0.18),
            control2: CGPoint(x: w * 0.35, y: h * 0.04)
        )

        path.closeSubpath()
        return path
    }
}

struct HomeView: View {
    let onStart: () -> Void
    let onSessions: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SurfboardShape()
                .stroke(.white.opacity(0.55), lineWidth: 3)
                .frame(width: 260, height: 670)

            VStack(spacing: 20) {
                Text("WristCut")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.bottom, 20)

                Button(action: onStart) {
                    Text("Start Session")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 16)
                        .background(.white)
                        .clipShape(Capsule())
                }

                Button(action: onSessions) {
                    Text("Waves")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 16)
                        .background(.white)
                        .clipShape(Capsule())
                }

                Button(action: onSettings) {
                    Text("Settings")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 16)
                        .background(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
