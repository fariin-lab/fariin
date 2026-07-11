import SwiftUI
import UIKit
import AVKit
import WebRTC

// Full-screen in-app call UI — rebuilt from scratch to match the reference:
//   • Top bar: back (minimize) · centered name + timer · ⋯ menu
//   • Voice: purple gradient + centered avatar
//   • Video: full-screen remote feed + draggable bottom-right self-PiP (with flip glyph)
//   • Bottom: dark frosted control capsule (icon-only circular buttons, red end)
// NOTE: only the UI is new. All bindings go to CallService.shared exactly as before — no call
// logic, WebRTC, signaling, or CallKit code was touched. Controls shown match what actually
// works per mode (no dead buttons): voice = mic·speaker·end, video = mic·camera·flip·speaker·end.
struct CallView: View {
    private var call = CallService.shared
    @State private var now = Date()
    @State private var isLocalExpanded = false      // tap the PiP to swap which feed is fullscreen
    @State private var pipOffset = CGSize.zero
    @State private var pipBase = CGSize.zero
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .outgoing:     return call.calleeRinging ? "Ringing…" : "Calling…"
        case .incoming:     return "Incoming…"
        case .active:       return durationText
        case .reconnecting: return "Reconnecting…"
        case .ended:        return endedText
        default:            return ""
        }
    }
    private var endedText: String {
        switch call.endReason {
        case .busy:     return "Busy"
        case .declined: return "Declined"
        case .failed:   return "Call failed"
        case .missed:   return "No answer"
        default:        return "Call ended"
        }
    }
    private var durationText: String {
        guard let start = call.connectedDate else { return "Connecting…" }   // not truly connected until ICE is up (H1)
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    private var bgImage: UIImage? {
        guard let url = call.otherPhotoUrl, !url.isEmpty else { return nil }
        return DiskImageCache.shared.memoryImage(url)
    }

    // REAL device safe-area insets. GeometryReader sits under `.ignoresSafeArea()`, so its
    // proxy reports ZERO insets — padding with those shoved the top buttons under the clock
    // and battery (the reported overlap). Read the window's insets instead.
    private var winInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .max(by: { $0.top < $1.top }) ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background(geo)
                if call.isVideo {
                    CallPiPHost(track: call.remoteVideoTrack).allowsHitTesting(false)   // native PiP source
                    pipLayer(geo)
                }

                VStack(spacing: 0) {
                    topBar(safeTop: winInsets.top)
                        .frame(maxWidth: .infinity)        // full-width header (centered name/status)
                    Spacer()
                    if showAvatar {
                        AvatarView(name: call.otherName, photoUrl: call.otherPhotoUrl, size: 180)
                            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                            // Soft expanding rings while the other side hasn't picked up yet —
                            // the frozen avatar read as "dead"; big apps pulse here.
                            .background { if call.state == .outgoing { PulsingRings(diameter: 180) } }
                            .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
                            .frame(maxWidth: .infinity)    // guarantee horizontal centering
                        Spacer()
                    }
                    controlBar
                        .frame(maxWidth: .infinity)        // centered control pill
                        .padding(.bottom, winInsets.bottom + 22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the screen (never collapse/offset)
            }
            .onReceive(ticker) { now = $0 }
            .animation(.easeInOut(duration: 0.25), value: call.state)
            .animation(.easeInOut(duration: 0.2), value: call.cameraOn)
            .animation(.easeInOut(duration: 0.2), value: call.isMuted)
            .animation(.easeInOut(duration: 0.2), value: call.isSpeaker)
            .animation(.easeInOut(duration: 0.3), value: hasRemote)        // smooth shrink-to-PiP on connect
            .animation(.easeInOut(duration: 0.3), value: isLocalExpanded)  // smooth tap-to-swap
            // No swipe-to-minimize: the screen is locked. The only way to minimize is the
            // top-left chevron-down button (so a stray swipe can never minimize/break the call).
        }
        .ignoresSafeArea()
        .onDisappear { CallPiPController.shared.teardown() }
    }

    // Invisible host whose UIView is the PiP "source view"; binds the remote track to the controller.
    struct CallPiPHost: UIViewRepresentable {
        let track: RTCVideoTrack?
        func makeUIView(context: Context) -> UIView {
            let v = UIView(); v.isUserInteractionEnabled = false; v.backgroundColor = .clear
            return v
        }
        func updateUIView(_ uiView: UIView, context: Context) {
            CallPiPController.shared.configure(sourceView: uiView, remoteTrack: track)
        }
    }

    // Their video shows only when their camera is actually on (the track object lingers even after
    // they turn the camera off, so gate on the signalled camera state, not just the track).
    private var hasRemote: Bool { call.remoteCameraOn && call.remoteVideoTrack != nil }
    // Show MY camera full-screen until the other side's video arrives (or when I tap to swap).
    private var showLocalFull: Bool { call.isVideo && (!hasRemote || isLocalExpanded) }
    // Fall back to the avatar when a video call has nothing displayable full-screen.
    private var showAvatar: Bool {
        if !call.isVideo { return true }
        return !hasRemote && (!call.cameraOn || call.localVideoTrack == nil) && !isLocalExpanded
    }

    // MARK: - Background (video feed, or avatar/gradient fallback)

    @ViewBuilder private func background(_ geo: GeometryProxy) -> some View {
        let full: RTCVideoTrack? = showLocalFull ? call.localVideoTrack
                                                 : (call.isVideo ? call.remoteVideoTrack : nil)
        let canShow = full != nil && !(showLocalFull && !call.cameraOn)
        // STABILITY (LiveKit pattern): never swap view-tree branches. The gradient/avatar-blur is
        // a permanent base, and ONE Metal renderer stays mounted on top for the whole video call —
        // we toggle it by opacity + swap its track in place (no recreate), so connect / camera-
        // toggle / stream-swap don't tear down + rebuild the Metal view (which caused black flicker).
        ZStack {
            // Always a solid BLACK base (user decision 2026-07-11) — no more purple gradient /
            // avatar-blur wash. Video still renders on top for video calls.
            Color.black
            if call.isVideo {
                VideoRendererView(track: full, mirror: showLocalFull && call.usingFrontCamera)
                    // Pin to the screen size: RTCMTLVideoView reports an intrinsic size (the video's
                    // natural dimensions) that can exceed the screen and oversize the ZStack, which
                    // GeometryReader then top-leading-aligns — pushing the centered avatar/controls
                    // off the right/bottom edges (the reported layout break). Framing + clipping fixes it.
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(canShow ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: canShow)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private func topBar(safeTop: CGFloat) -> some View {
        HStack {
            // The ONLY way to minimize the call (swipe-to-minimize removed — screen is locked).
            Button { withAnimation(.easeInOut(duration: 0.25)) { call.minimized = true } } label: {
                topCircle("chevron.down")
            }
            .buttonStyle(CallControlStyle())

            Spacer()
            // Big bold name over a smaller status (WhatsApp/FaceTime scale — 18pt read as a toolbar label).
            VStack(spacing: 3) {
                Text(call.otherName).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(statusText).font(.system(size: 15)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
            Spacer()

            Menu {
                Button { withAnimation { call.minimized = true } } label: { Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left") }
                Button(role: .destructive) { CallKitManager.shared.end() } label: { Label("End Call", systemImage: "phone.down.fill") }
            } label: { topCircle("ellipsis") }
            .buttonStyle(CallControlStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 14)   // clear the iOS status-bar call indicator (green pill)
        .padding(.bottom, 14)
        .background(   // dark top scrim so white buttons + name stay legible over bright video (L1)
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        )
    }

    private func topCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 48, height: 48)   // 48px top buttons (user spec, matches the app's glass controls)
            // NON-interactive glass: `.interactive()` glass consumes the touch itself, so the
            // wrapping Button's action never fired — the minimize chevron did nothing when tapped.
            .liquidGlass(Circle(), interactive: false)
    }


    // MARK: - Video self-PiP (draggable, with flip glyph)

    private func pipLayer(_ geo: GeometryProxy) -> some View {
        let safeBottom = winInsets.bottom
        let pipIsLocal = !isLocalExpanded                                   // small window = the OTHER feed
        let pipTrack = isLocalExpanded ? call.remoteVideoTrack : call.localVideoTrack
        // PiP only appears once the remote video is here (before that, MY camera is full-screen).
        // Then hide a local PiP if the camera is off; a remote PiP always shows.
        let visible = hasRemote && pipTrack != nil && (pipIsLocal ? call.cameraOn : true)
        return Group {
            if visible, let track = pipTrack {
                ZStack(alignment: .topTrailing) {
                    VideoRendererView(track: track, mirror: pipIsLocal && call.usingFrontCamera)
                        .frame(width: 104, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                    if pipIsLocal {
                        Button { call.switchCamera() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .padding(6).background(.black.opacity(0.45), in: Circle())
                        }
                        .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                .offset(pipOffset)
                // Drag (min 10pt) repositions the window; a tap (no move) swaps the feeds.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { v in
                            let w = pipBase.width + v.translation.width
                            let h = pipBase.height + v.translation.height
                            let maxLeft = -(geo.size.width - 104 - 28)
                            // Real geometry (PiP is 150 tall, sits at safeTop+70, control bar ~120) — no magic 300 that inverts on small screens.
                            let maxDown = max(0, geo.size.height - 150 - (winInsets.top + 70) - safeBottom - 120)
                            pipOffset = CGSize(width: min(0, max(maxLeft, w)), height: min(maxDown, max(0, h)))
                        }
                        .onEnded { _ in pipBase = pipOffset }
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isLocalExpanded.toggle() }
                }
                .padding(.top, winInsets.top + 70)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    // MARK: - Control capsule (dark, icon-only, red end)

    private var controlBar: some View {
        HStack(spacing: 14) {
            callCircle(call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted) { call.toggleMute() }
            // MY camera — turn it on/off freely (Signal-style; the other side just sees it, no
            // permission). Only once CONNECTED; dimmed while still Calling/Ringing.
            callCircle(call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn) { call.toggleCamera() }
                .disabled(call.state != .active)
                .opacity(call.state == .active ? 1 : 0.4)
            // Flip front/back only while my camera is on.
            if call.cameraOn {
                callCircle("arrow.triangle.2.circlepath", active: false) { call.switchCamera() }
            }
            speakerCircle
            endCircle
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                .overlay(Capsule().fill(Color.black.opacity(0.25)))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .padding(.horizontal, 18)
    }

    // Smart speaker (WhatsApp/FaceTime): no external device → plain earpiece/speaker toggle.
    // AirPods/Bluetooth/wired connected → the glyph shows the LIVE route and the tap opens the
    // NATIVE system route picker (AVRoutePickerView) to choose iPhone / AirPods / Speaker.
    @ViewBuilder private var speakerCircle: some View {
        if call.externalAudioAvailable {
            ZStack {
                Image(systemName: call.audioRoute == .external ? "headphones" : "speaker.wave.2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(call.audioRoute == .earpiece ? .white : .black)
                    .frame(width: 52, height: 52)
                    .background(call.audioRoute == .earpiece ? AnyShapeStyle(.clear) : AnyShapeStyle(.white), in: Circle())
                    .liquidGlass(Circle(), interactive: true, enabled: call.audioRoute == .earpiece)
                // Invisible native picker on top — owns the tap, opens the system route sheet.
                AudioRoutePicker().frame(width: 52, height: 52).clipShape(Circle())
            }
        } else {
            // One steady speaker glyph; ON = filled white circle (the slash icon looked like
            // something was muted even when it wasn't).
            callCircle("speaker.wave.2.fill", active: call.isSpeaker) { call.toggleSpeaker() }
        }
    }

    private func callCircle(_ icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))   // mic/speaker/camera slash morphs in
                .foregroundStyle(active ? .black : .white)
                .frame(width: 52, height: 52)
                // Idle = real Liquid Glass circle (was a flat white-16% fill); active keeps the
                // solid white pop (WhatsApp look), where glass would just mute the contrast.
                .background(active ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: Circle())
                .liquidGlass(Circle(), interactive: true, enabled: !active)
        }
        .buttonStyle(CallControlStyle())
    }

    private var endCircle: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            CallKitManager.shared.end()
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                // Red Liquid Glass (still unmistakably the hang-up button, but native glass).
                .liquidGlass(Circle(), interactive: true, tint: Color(.systemRed))
        }
        .buttonStyle(CallControlStyle())
    }
}

// The system audio-route picker (the exact FaceTime one), rendered invisible so our own
// glyph shows underneath; the view stays fully tappable and presents the native picker.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .clear
        v.activeTintColor = .clear
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

// MARK: - CallContainer

// Root-level wrapper: lives above every screen so an active call survives all navigation.
// Minimized → shows MiniCallBar at top; otherwise presents the full call screen.
struct CallContainer<Content: View>: View {
    @ViewBuilder var content: Content
    private var call: CallService { CallService.shared }

    private var isActive: Bool {
        switch call.state {
        case .outgoing, .active, .reconnecting, .ended: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isActive && call.minimized {
                MiniCallBar()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { call.minimized = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .fullScreenCover(isPresented: Binding(
            get: { isActive && !call.minimized },
            set: { _ in }
        )) {
            CallView()
        }
    }
}

// MARK: - MiniCallBar

// WhatsApp/Signal-style 40pt green bar at the top when the call is minimized.
struct MiniCallBar: View {
    private var call: CallService { CallService.shared }
    @State private var now = Date()
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .active:
            if let start = call.connectedDate {
                let s = max(0, Int(now.timeIntervalSince(start)))
                return String(format: "%d:%02d", s / 60, s % 60)
            }
            return "Connected"
        case .outgoing:     return call.calleeRinging ? "Ringing…" : "Calling…"
        case .reconnecting: return "Reconnecting…"
        case .ended:        return "Call ended"
        default:            return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                .font(.system(size: 13, weight: .bold))
            Text(call.otherName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 13))
                .monospacedDigit()
                .opacity(0.9)
            Spacer(minLength: 6)
            Text("Tap to return")
                .font(.system(size: 12))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Color.green)
        .onReceive(ticker) { now = $0 }
    }
}

// MARK: - PulsingRings

// Soft rings expanding out from the avatar while the call is still unanswered — the
// "alive" cue every big call UI has. Two staggered rings, GPU-cheap, removed on connect.
struct PulsingRings: View {
    let diameter: CGFloat
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(animate ? 1.45 : 1.0)
                    .opacity(animate ? 0 : 0.7)
                    .animation(.easeOut(duration: 2.0).repeatForever(autoreverses: false).delay(Double(i)),
                               value: animate)
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

// MARK: - CallControlStyle

// Press feedback: dips + dims on press, springs back.
struct CallControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
