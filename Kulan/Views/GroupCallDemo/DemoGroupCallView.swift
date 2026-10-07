import SwiftUI

// GROUP CALL DEMO SCREEN (owner, 2026-10-07). Opened from Settings > "Group Call Demo". It follows
// the real GroupCallView's look (black stage, chevron / title / people header, the bottom capsule
// of glass circles with the "..." menu) without touching that file: the pieces are small copies.
// Everything it shows comes from `DemoGroupCallEngine`; nothing here reaches the real call system.

struct DemoGroupCallView: View {
    @StateObject private var engine = DemoGroupCallEngine()
    @Environment(\.dismiss) private var dismiss
    @State private var showPeople = false
    @State private var showScenarios = false
    @State private var selfExpanded = false
    /// The down button on a live call shrinks the demo into `DemoMiniCard` over a see-through cover,
    /// so the app shows behind it (owner, 2026-10-07: see a minimized group call). It used to close.
    @State private var minimized = false

    var body: some View {
        ZStack {
            if !minimized {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 0) {
                        header.padding(.horizontal, 14)
                        DemoStageView(selfExpanded: $selfExpanded)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .top) { toastView }
                        controls.padding(.horizontal, 14)
                    }
                    .padding(.vertical, 10)

                    if engine.state == .idle {
                        DemoStartCard(onClose: close).transition(.opacity)
                    } else if engine.state == .ended {
                        DemoEndedCard(onClose: close).transition(.opacity)
                    }
                }
                .transition(.scale(scale: 0.3, anchor: .topTrailing).combined(with: .opacity))
            } else {
                DemoMiniCard(onRestore: { setMinimized(false) })
                    .transition(.scale(scale: 0.3, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .presentationBackground(minimized ? Color.clear : Color.black)
        // The call ending while minimized comes back up, so its ended card is seen.
        .onChange(of: engine.state.isLive) { _, live in if !live && minimized { setMinimized(false) } }
        .animation(GroupCallMotion.fade, value: engine.state)
        .environmentObject(engine)
        .preferredColorScheme(.dark)
        .task { await engine.loadOwnerProfile() }
        .onDisappear { engine.shutdown() }
        .sheet(isPresented: $showPeople) {
            DemoPeopleSheet().environmentObject(engine)
        }
        .sheet(isPresented: $showScenarios) {
            DemoScenarioSheet().environmentObject(engine)
        }
        // An alert cannot show from under a sheet, so while one is up the sheet carries it instead.
        .modifier(DemoRemovalAlert(engine: engine, enabled: !showPeople && !showScenarios))
    }

    private func close() {
        engine.shutdown()
        dismiss()
    }

    private func setMinimized(_ on: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { minimized = on }
    }

    // MARK: - Header (the real header's shape, plus the Scenarios button)

    private var header: some View {
        HStack(spacing: 10) {
            Button { engine.state.isLive ? setMinimized(true) : close() } label: {
                Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
            .accessibilityLabel(engine.state.isLive ? "Minimize" : "Close demo")
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                subtitle.font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { showScenarios = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
            .accessibilityLabel("Scenarios")
            Button { showPeople = true } label: {
                Image(systemName: "person.2.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
            .accessibilityLabel("Participants")
        }
    }

    private var title: String {
        let others = engine.tiles.filter { !$0.isLocal }
        if others.count == 1, let one = others.first { return one.name }
        let names = (others.isEmpty ? engine.ringing.map(\.name) : others.map(\.name))
        switch names.count {
        case 0: return "Group Call Demo"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// The real header's second line, same order: Reconnecting > Connecting > alone (ringing names,
    /// else "No one else is here") > two people: the clock > "N in call".
    @ViewBuilder
    private var subtitle: some View {
        switch engine.state {
        case .reconnecting: Text("Reconnecting…")
        case .connecting: Text("Connecting…")
        case .idle, .ended: Text(" ")
        case .ringing, .connected:
            if engine.remoteCount == 0 {
                Text(GroupCallWords.alone(ringing: engine.ringing.map(\.name)))
            } else if engine.remoteCount == 1, let since = engine.connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(CallDuration.clock(Int(max(0, engine.now.timeIntervalSince(since)))))
                        .monospacedDigit()
                }
            } else {
                Text("\(engine.inCallCount) in call")
            }
        }
    }

    // MARK: - Toast (the real top toast's place, under the header)

    @ViewBuilder
    private var toastView: some View {
        if let toast = engine.toast {
            Text(toast)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(.top, 8)
                .transition(.opacity)
                .id(toast)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Controls (the real capsule: camera, mic, speaker, more, end)

    private var controls: some View {
        HStack(spacing: 12) {
            ctrl(engine.cameraOn ? "video.fill" : "video.slash.fill") { engine.toggleCamera() }
                .disabled(!engine.isVideoCall)
                .opacity(engine.isVideoCall ? 1 : 0.35)
                .accessibilityLabel(engine.isVideoCall ? (engine.cameraOn ? "Turn camera off" : "Turn camera on")
                                                       : "Camera unavailable on a voice call")
            ctrl(engine.micOn ? "mic.fill" : "mic.slash.fill") { engine.toggleMic() }
                .accessibilityLabel(engine.micOn ? "Mute" : "Unmute")
            ctrl(speakerOn ? "speaker.wave.2.fill" : "speaker.fill") { speakerOn.toggle() }
                .opacity(speakerOn ? 1 : 0.7)
                .accessibilityLabel(speakerOn ? "Turn speaker off" : "Turn speaker on")
            moreMenu
            ctrl("phone.down.fill", tint: Color(.systemRed)) { engine.leave() }
                .accessibilityLabel("Leave call")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .disabled(engine.state == .idle || engine.state == .ended)
    }

    /// Visual only in the demo: there is no audio session to route.
    @State private var speakerOn = true

    private var moreMenu: some View {
        Menu {
            Button { engine.toggleHand() } label: {
                Label(engine.handRaised ? "Lower Hand" : "Raise Hand", systemImage: "hand.raised")
            }
            Button { engine.flipCamera() } label: {
                Label("Flip Camera", systemImage: "arrow.triangle.2.circlepath.camera")
            }
            .disabled(!engine.cameraOn)
            Button { engine.switchCallKind() } label: {
                Label(engine.isVideoCall ? "Switch to Voice Call" : "Switch to Video Call",
                      systemImage: engine.isVideoCall ? "phone" : "video")
            }
            if engine.myRole == .owner {
                Button(role: .destructive) { engine.endForEveryone() } label: {
                    Label("End Call for Everyone", systemImage: "phone.down")
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title3).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .liquidGlass(Circle(), interactive: true)
        }
        .disabled(!engine.state.isLive && engine.state != .reconnecting)
        .opacity(engine.state.isLive || engine.state == .reconnecting ? 1 : 0.35)
        .accessibilityLabel("More")
    }

    private func ctrl(_ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .liquidGlass(Circle(), interactive: true, tint: tint)
        }
    }
}

// MARK: - Remove confirm (the real screen asks before anyone is removed)

struct DemoRemovalAlert: ViewModifier {
    @ObservedObject var engine: DemoGroupCallEngine
    let enabled: Bool

    private var shown: Binding<Bool> {
        Binding(get: { enabled && engine.removalRequest != nil },
                set: { if !$0 { engine.removalRequest = nil } })
    }

    func body(content: Content) -> some View {
        content.alert("Remove from the call?", isPresented: shown, presenting: engine.removalRequest) { request in
            Button(request.block ? "Remove and Block" : "Remove", role: .destructive) {
                engine.remove(request.tile.id, block: request.block)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.block
                 ? "\(request.tile.name) will be removed and can't join this call again."
                 : "\(request.tile.name) will be removed from the call.")
        }
    }
}

// MARK: - Start and end cards

private struct DemoStartCard: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text("Group Call Demo").font(.title2.weight(.semibold)).foregroundStyle(.white)
            Text("A simulated call on this phone only. Nobody is called, nothing is sent. The layout, active speaker and priority logic are the real call's.")
                .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                preset("2 people", total: 2)
                preset("3 people", total: 3)
                preset("10 people", total: 10)
            }
            Button { engine.startRinging() } label: {
                Text("Start a call and ring 3").frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            Button("Close", action: onClose).foregroundStyle(.white.opacity(0.8))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.12)))
        .padding(.horizontal, 24)
    }

    private func preset(_ title: String, total: Int) -> some View {
        Button { engine.startPreset(total: total) } label: {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.bordered).tint(.white)
    }
}

private struct DemoEndedCard: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(engine.endReason?.title ?? "Call ended").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(engine.endReason?.message ?? "").font(.footnote).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button { engine.reset() } label: {
                Text("Start Again").frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            Button("Close", action: onClose).foregroundStyle(.white.opacity(0.8))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.12)))
        .padding(.horizontal, 24)
    }
}
