import SwiftUI

// SCREEN SHARE DEMO SCREEN (owner, 2026-10-08). Opened from Settings > "Screen Share Demo". The real
// system share comes back through a WebRTC loopback (ScreenShareDemoEngine) and is shown with the
// call's own ScreenShareStageView, so zoom, the blurred backdrop and rotation are the real ones.
// Minimal on purpose: close, Start / Stop, a quality pick, and one stats line.

struct ScreenShareDemoView: View {
    @StateObject private var engine = ScreenShareDemoEngine()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var chromeVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.phase == .live, let track = engine.receivedTrack {
                ScreenShareStageView(track: track, onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                })
                .ignoresSafeArea()
            } else {
                placeholder
            }

            // The system broadcast picker, invisible: ScreenSharePicker.show() presses its button.
            // It has to be in the window for its sheet to present (same as the call screen).
            ScreenSharePickerView()
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)

            if chromeVisible || engine.phase != .live {
                chrome.transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(engine.phase == .live && !chromeVisible)
        .onChange(of: engine.phase) { _, phase in
            // Landscape only while a received picture is on screen; portrait again otherwise.
            OrientationLock.allowLandscape(phase == .live)
            if phase != .live { chromeVisible = true }
        }
        .onChange(of: CallService.shared.state) { _, state in
            if state != .idle { engine.callStarted() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: engine.didEnterBackground()
            case .active: engine.didBecomeActive()
            default: break
            }
        }
        .onDisappear {
            engine.shutdown()
            OrientationLock.allowLandscape(false)
        }
    }

    // MARK: - Pieces

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: engine.phase == .picking ? "hourglass" : "rectangle.on.rectangle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
            Text(engine.phase == .picking
                 ? "Waiting for the broadcast to start…"
                 : "Your screen is sent through the real video pipeline and shown here as the other person would see it.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let note = engine.note {
                Text(note)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")
                Text("DEMO")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                qualityMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 10) {
                if engine.phase == .live, !engine.statsLine.isEmpty {
                    Text(engine.statsLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                mainButton
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch engine.phase {
        case .idle:
            Button { engine.start() } label: {
                Text("Start Screen Share")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Color.accentColor, in: Capsule())
            }
        case .picking:
            Button { engine.stopSharing() } label: {
                Text("Cancel")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        case .live:
            Button { engine.stopSharing() } label: {
                Text("Stop Sharing")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Color.red, in: Capsule())
            }
        }
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { engine.quality },
                                                 set: { engine.setQuality($0) })) {
                ForEach(ScreenShareDemoEngine.QualityChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
        } label: {
            Text(qualityLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// "Auto · Good" while Auto runs (the tier it picked), else the pinned tier's name.
    private var qualityLabel: String {
        let tierName = ScreenShareDemoEngine.QualityChoice(rawValue: engine.tierIndex)?.title ?? ""
        return engine.quality == .auto ? "Auto · \(tierName)" : engine.quality.title
    }

    private func close() {
        engine.shutdown()
        OrientationLock.allowLandscape(false)
        dismiss()
    }
}
