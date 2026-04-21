import SwiftUI
import AVFoundation

struct RecordingView: View {
    @ObservedObject var camera: CameraManager
    let onEnd: () -> Void
    @State private var screenDimmed = false
    @State private var isLandscape = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if camera.cameraAuthorized {
                    CameraPreviewView(session: camera.session)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                if isLandscape {
                    landscapeControls
                } else {
                    portraitControls
                }
            }
            .onAppear {
                isLandscape = geo.size.width > geo.size.height
                OrientationManager.shared.lock([.portrait, .landscapeLeft, .landscapeRight])
            }
            .onDisappear {
                OrientationManager.shared.lock(.portrait)
            }
            .onChange(of: geo.size) { _, size in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isLandscape = size.width > size.height
                }
            }
        }
    }

    private var portraitControls: some View {
        VStack {
            Spacer()

            if !camera.availableLenses.isEmpty {
                HStack(spacing: 8) {
                    ForEach(camera.availableLenses) { lens in
                        lensButton(lens)
                    }
                    customZoomButton
                }
                .padding(.bottom, 12)
            }

            if camera.showCustomZoom {
                HStack(spacing: 10) {
                    Text("1×")
                        .foregroundStyle(.white)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                    Slider(value: $camera.customZoom, in: 1...camera.maxZoom, step: 0.1)
                        .tint(.white)
                        .onChange(of: camera.customZoom) { _, value in
                            camera.applyCustomZoom(value)
                        }
                    Text(String(format: "%.1f×", camera.maxZoom))
                        .foregroundStyle(.white)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            statusBadge
                .padding(.bottom, 24)

            HStack(spacing: 12) {
                dimButton
                endSessionButton
            }
            .padding(.bottom, 48)
        }
    }

    private var landscapeControls: some View {
        VStack(spacing: 0) {
            if camera.showCustomZoom {
                HStack(spacing: 10) {
                    Text("1×")
                        .foregroundStyle(.white)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                    Slider(value: $camera.customZoom, in: 1...camera.maxZoom, step: 0.1)
                        .tint(.white)
                        .frame(maxWidth: 200)
                        .onChange(of: camera.customZoom) { _, value in
                            camera.applyCustomZoom(value)
                        }
                    Text(String(format: "%.1f×", camera.maxZoom))
                        .foregroundStyle(.white)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 10)
            }

            HStack {
                if !camera.availableLenses.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(camera.availableLenses) { lens in
                            lensButton(lens)
                        }
                        customZoomButton
                    }
                }

                Spacer()

                statusBadge

                Spacer()

                HStack(spacing: 12) {
                    dimButton
                    endSessionButton
                }
            }
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            if camera.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .transition(.scale)
            }
            Text(camera.statusMessage)
                .foregroundStyle(.white)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
        }
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var dimButton: some View {
        Button {
            screenDimmed.toggle()
            UIScreen.main.brightness = screenDimmed ? 0 : 1
        } label: {
            Image(systemName: screenDimmed ? "sun.max.fill" : "sun.min")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(screenDimmed ? .black : .white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(screenDimmed ? .white : .white.opacity(0.2))
                .clipShape(Capsule())
        }
    }

    private var endSessionButton: some View {
        Button(action: {
            if screenDimmed { UIScreen.main.brightness = 1 }
            onEnd()
        }) {
            Text("End Session")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(.red)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func lensButton(_ lens: CameraLens) -> some View {
        let isSelected = camera.selectedLens == lens && !camera.showCustomZoom
        Button {
            camera.switchToLens(lens)
        } label: {
            Text(lens.label)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? .white : .white.opacity(0.2))
                .clipShape(Capsule())
        }
        .disabled(camera.isRecording)
    }

    private var customZoomButton: some View {
        let isSelected = camera.showCustomZoom
        return Button {
            if !camera.isRecording {
                camera.showCustomZoom.toggle()
            }
        } label: {
            Text(isSelected ? String(format: "%.1f×", camera.customZoom) : "Custom")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? .white : .white.opacity(0.2))
                .clipShape(Capsule())
        }
        .disabled(camera.isRecording)
    }
}
