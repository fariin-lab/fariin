import SwiftUI
import UIKit
import AVKit
import WebRTC

// Full-screen in-app call UI — rebuilt from scratch to match the reference:
//   • Top bar: back (minimize) · centered name + timer · ⋯ menu
//   • Voice: purple gradient + centered avatar
//   • Video: full-screen remote feed + draggable self-PiP anchored TOP-right (with flip glyph)
//   • Bottom: dark frosted control capsule (icon-only circular buttons, red end)
// NOTE: only the UI is new. All bindings go to CallService.shared exactly as before — no call
// logic, WebRTC, signaling, or CallKit code was touched. Controls shown match what actually
// works per mode (no dead buttons): voice = mic·speaker·end, video = mic·camera·flip·speaker·end.
struct CallView: View {
    private var call = CallService.shared
    @State private var now = Date()
    // Layout state lives in CallService so minimize/restore keeps the SAME big/small choice and tile
    // position (the fullScreenCover destroys this view on minimize; @State here reset every time).
    private var isLocalExpanded: Bool { get { call.isLocalExpanded } nonmutating set { call.isLocalExpanded = newValue } }
    private var pipOffset: CGSize { get { call.pipOffset } nonmutating set { call.pipOffset = newValue } }
    private var pipBase: CGSize { get { call.pipBase } nonmutating set { call.pipBase = newValue } }
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var flippingCamera = false   // brief blur mask over the front/back capture restart
    // The ACCEPT hand-off (user report: "you feel your face left on big screen, [then] a moment when
    // it drops [to the] small one" — a hard cut). While true, the corner tile renders FULL SCREEN over
    // everything, holding the same local feed the big view just gave up; releasing it with a spring
    // shrinks your preview continuously into the corner, revealing the other person underneath —
    // FaceTime's connect transition. Live video the whole way; no snapshot, no branch swap.
    @State private var tileEntering = false

    // MARK: - Auto-hiding controls (the standard video-call behaviour)

    // On a video call the buttons get out of the way: they show when the call connects, fade out on
    // their own a few seconds later, and come back on a tap anywhere. Tap again to send them away.
    // Gated on CallService.everVideo, which is STICKY — a call that has been a video call keeps
    // behaving like one even after both cameras go off, so the controls do not start living on top of
    // the screen again the moment someone closes their camera.
    @State private var controlsVisible = true
    @State private var hideTask: DispatchWorkItem?
    private static let autoHideAfter: TimeInterval = 5

    private var autoHideEnabled: Bool { call.everVideo && connectedCall }

    private func armAutoHide() {
        hideTask?.cancel()
        guard autoHideEnabled else {
            // Voice call, or not connected yet: the controls simply stay.
            if !controlsVisible { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true } }
            return
        }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.28)) { controlsVisible = false }
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideAfter, execute: work)
    }

    // Bring the controls back and restart the clock. Used by the tap and by every button press, so
    // hitting mute never leaves you two seconds from losing the rest of the buttons.
    private func showControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        armAutoHide()
    }

    private func toggleControls() {
        guard autoHideEnabled else { return }
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.28)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    // Smooth camera flip: blur the local feed, restart the capturer (mirror already flipped), clear the
    // blur after the new camera is running — so the ~200ms restart reads as a transition, not a freeze.
    private func flipCamera() {
        guard !flippingCamera else { return }
        showControls()
        withAnimation(.easeOut(duration: 0.12)) { flippingCamera = true }
        call.switchCamera()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeIn(duration: 0.22)) { flippingCamera = false }
        }
    }

    private var statusText: String {
        switch call.state {
        case .outgoing:     return call.calleeRinging ? "Ringing…" : "Calling…"
        case .incoming:     return "Incoming…"
        // The weak-signal notice displaces the duration deliberately: while the camera is down, WHY it
        // is down is the only thing the user actually wants, and without it a paused camera reads as
        // the app being broken. The timer comes straight back when the link recovers.
        case .active:       return call.videoPausedForNetwork ? "Video paused, weak signal" : durationText
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
                    // The whole layout, not one feed — see CallService.pipFeeds.
                    CallPiPHost(feeds: call.pipFeeds).allowsHitTesting(false)   // native PiP source
                }
                // Tap anywhere that is not a button or the tile to show/hide the controls. It sits
                // ABOVE the video and BELOW everything interactive, so the buttons and the corner tile
                // keep their own taps.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                if call.isVideo { pipLayer(geo) }

                VStack(spacing: 0) {
                    topBar(safeTop: winInsets.top)
                        .frame(maxWidth: .infinity)        // full-width header (centered name/status)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible) // hidden buttons must not eat the tap
                    Spacer()
                    if showAvatar {
                        // WHOSE photo follows who is on the big screen, not always theirs.
                        AvatarView(name: showLocalFull ? call.myName : call.otherName,
                                   photoUrl: showLocalFull ? call.myPhotoUrl : call.otherPhotoUrl,
                                   size: 180)
                            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                            // Soft expanding rings while the other side hasn't picked up yet —
                            // the frozen avatar read as "dead"; big apps pulse here.
                            .background { if call.state == .outgoing { PulsingRings(diameter: 180) } }
                            .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
                            .frame(maxWidth: .infinity)    // guarantee horizontal centering
                            .allowsHitTesting(false)       // decoration: let the show/hide tap through
                        Spacer()
                    }
                    controlBar
                        .frame(maxWidth: .infinity)        // centered control pill
                        .padding(.bottom, winInsets.bottom + 22)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the screen (never collapse/offset)
            }
            .onReceive(ticker) { now = $0 }
            .onAppear { armAutoHide() }
            .onDisappear { hideTask?.cancel() }
            // Connecting, and a voice call turning into a video call, both restart the clock: show the
            // controls for the moment something changes, then get out of the way again.
            .onChange(of: call.state) { _, _ in showControls() }
            .onChange(of: call.isVideo) { _, _ in showControls() }
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
        .onDisappear {
            // Tear down native PiP only when the call is actually OVER — minimize must keep it available.
            if call.state == .idle || call.state == .ended { CallPiPController.shared.teardown() }
        }
    }

    // Invisible host whose UIView is the PiP "source view"; binds both feeds to the controller so the
    // floating window carries the same big + corner-tile layout as the call screen.
    struct CallPiPHost: UIViewRepresentable {
        let feeds: CallService.PiPFeeds
        func makeUIView(context: Context) -> UIView {
            let v = UIView(); v.isUserInteractionEnabled = false; v.backgroundColor = .clear
            return v
        }
        func updateUIView(_ uiView: UIView, context: Context) {
            CallPiPController.shared.configure(sourceView: uiView, feeds: feeds)
        }
    }

    // Their video shows only when their camera is actually on (the track object lingers even after
    // they turn the camera off, so gate on the signalled camera state, not just the track).
    private var hasRemote: Bool { call.remoteCameraOn && call.remoteVideoTrack != nil }
    // Show MY camera full-screen while RINGING (self-preview) or when I tapped to swap. Once the
    // call is CONNECTED and their camera is off, THEY own the big view (avatar) and I go to the PiP —
    // my video never fills the screen just because they turned their camera off (they'd "vanish").
    private var connectedCall: Bool { call.state == .active || call.state == .reconnecting }
    private var showLocalFull: Bool {
        call.isVideo && (isLocalExpanded || (!hasRemote && !connectedCall))
    }
    // Avatar fills the big view whenever there is no remote video to show (voice call, or their
    // camera is off mid-call) and I haven't swapped my own feed fullscreen.
    // The photo fills the big view whenever whoever is BIG has no live camera — including MYSELF, now
    // that you can swap your own switched-off camera up there. It used to hard-return false for
    // `isLocalExpanded`, which left that case as a black screen.
    private var showAvatar: Bool {
        if !call.isVideo { return true }
        if showLocalFull { return !call.cameraOn }   // my feed owns the big view
        return !hasRemote
    }

    // MARK: - Background (video feed, or avatar/gradient fallback)

    @ViewBuilder private func background(_ geo: GeometryProxy) -> some View {
        let full: RTCVideoTrack? = showLocalFull ? call.localVideoTrack
                                                 : (hasRemote ? call.remoteVideoTrack : nil)
        // Only show a fullscreen feed that is ACTUALLY LIVE. Otherwise hide the renderer (opacity 0) so
        // the shared Metal view doesn't keep its last frame on screen — that stale frame was YOUR frozen
        // ringing-preview showing as the background behind the avatar when the other camera is off.
        let canShow = full != nil && (showLocalFull ? call.cameraOn : hasRemote)
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
                    .blur(radius: (showLocalFull && flippingCamera) ? 18 : 0)   // mask the flip restart
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
            // Big bold name over a smaller status (18pt read as a toolbar label).
            VStack(spacing: 3) {
                // The mark matters here as much as anywhere: an incoming call from a stranger is the
                // one screen where somebody decides whether to trust a name in under three seconds.
                HStack(spacing: 6) {
                    Text(call.otherName).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        .minimumScaleFactor(0.6)
                    VerifiedMark(uid: call.otherUid, size: 20)
                }
                // THEIR mute, shown in place of the duration. Muting was never signalled at all, so the
                // other person just heard silence and could not tell it apart from a broken connection.
                if call.remoteMuted, call.state == .active {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.slash.fill").font(.system(size: 12, weight: .semibold))
                        Text("Muted").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity)
                } else {
                    Text(statusText).font(.system(size: 15)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer()

            // No "Minimize" here: the chevron on the left already does it, and two controls for the
            // same thing on one bar just read as one of them being broken.
            Menu {
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
            // The whole 48pt circle takes the tap. A `.frame` around an Image is only hit-testable
            // where the glyph is drawn, and the glass behind it is an effect, not a shape — so the
            // real target was the ~17pt chevron itself, which is why this button felt dead.
            .contentShape(Circle())
    }


    // MARK: - Video self-PiP (draggable, with flip glyph)

    private func pipLayer(_ geo: GeometryProxy) -> some View {
        let safeBottom = winInsets.bottom
        let pipIsLocal = !isLocalExpanded                                   // small window = the OTHER feed
        let feeds = call.pipFeeds
        let pipTrack = feeds.tile
        // THE TILE BELONGS TO THE CALL, NOT TO A LIVE CAMERA. It used to vanish the moment that camera
        // went off, which left an empty corner and — because the tile is also the tap target for the
        // swap — took the only way back with it. Now it stays, holding that person's photo instead of
        // their video, exactly like FaceTime.
        let visible = feeds.showsTile
        return Group {
            if visible {
                ZStack(alignment: .topTrailing) {
                    tileContent(track: pipTrack, isLocal: pipIsLocal, feeds: feeds)
                        // THE ACCEPT HAND-OFF: while entering, the tile IS the full screen — the same
                        // local feed the big view showed during ringing — and the spring release
                        // shrinks it into the corner (see tileEntering). One view, one live renderer,
                        // every property below interpolates: size, corner radius, offset, padding.
                        .frame(width: tileEntering ? geo.size.width : 104,
                               height: tileEntering ? geo.size.height : 150)
                        // Blur the local feed briefly during a camera flip so the ~200ms capture restart
                        // (a frozen last frame) is masked into a smooth transition instead of a hard cut.
                        .blur(radius: (pipIsLocal && flippingCamera) ? 14 : 0)
                        .clipShape(RoundedRectangle(cornerRadius: tileEntering ? 0 : 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: tileEntering ? 0 : 18, style: .continuous)
                            .stroke(.white.opacity(tileEntering ? 0 : 0.25), lineWidth: 1))
                    // The flip glyph belongs to a LIVE local camera only — and never to the hand-off.
                    if pipIsLocal, pipTrack != nil, !tileEntering {
                        Button { flipCamera() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .padding(6).background(.black.opacity(0.45), in: Circle())
                        }
                        .padding(6)
                    }
                }
                .shadow(color: .black.opacity(tileEntering ? 0 : 0.45), radius: 14, y: 5)
                .offset(tileEntering ? .zero : pipOffset)
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
                        .onEnded { _ in
                            // SNAP TO THE NEAREST CORNER (standard PiP): the tile must never rest
                            // mid-screen. Choose left/right by which half the tile is in, top/bottom the
                            // same, then spring there.
                            let maxLeft = -(geo.size.width - 104 - 28)
                            let maxDown = max(0, geo.size.height - 150 - (winInsets.top + 70) - safeBottom - 120)
                            let targetX: CGFloat = pipOffset.width < maxLeft / 2 ? maxLeft : 0
                            let targetY: CGFloat = pipOffset.height > maxDown / 2 ? maxDown : 0
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                pipOffset = CGSize(width: targetX, height: targetY)
                            }
                            pipBase = CGSize(width: targetX, height: targetY)
                        }
                )
                // SWAP ONLY BETWEEN TWO LIVE FEEDS. A photo tile is not tappable: blowing a still photo
                // up to full screen while a live feed shrinks into the corner is worse in both
                // directions, and it is how tapping once stranded the user full screen on their own
                // face with the other person gone and no way back.
                .onTapGesture {
                    // SWAP IS ALWAYS ALLOWED while the tile is up, video or photo. It was once gated on
                    // two live feeds because a swap could strand you: the tile HID itself when its
                    // camera went off, taking the only way back with it. The tile never hides now, so
                    // any swap can always be undone by tapping it again.
                    guard feeds.showsTile else { toggleControls(); return }
                    showControls()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isLocalExpanded.toggle() }
                }
                .padding(.top, tileEntering ? 0 : winInsets.top + 70)
                .padding(.trailing, tileEntering ? 0 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // The trigger: the tile appearing on a VIDEO call is the accept moment — my preview owned the
        // big view a frame ago. Mount the tile at FULL SCREEN without animation (covering the big
        // view's under-the-hood swap to the other person), then release it with a spring on the next
        // runloop tick — two phases, or SwiftUI collapses both writes into one transaction and nothing
        // animates. Voice calls and re-appearances (minimize/restore) don't qualify: the guard keys on
        // the tile NEWLY appearing while the call is video and the local feed is not user-expanded.
        .onChange(of: visible) { was, shows in
            guard shows, !was, call.isVideo, !isLocalExpanded else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { tileEntering = true }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { tileEntering = false }
            }
        }
    }

    // The corner tile's inside: that person's video while their camera is sending, their photo on a
    // dark card when it is not.
    @ViewBuilder
    private func tileContent(track: RTCVideoTrack?, isLocal: Bool, feeds: CallService.PiPFeeds) -> some View {
        if let track {
            VideoRendererView(track: track, mirror: isLocal && call.usingFrontCamera)
        } else {
            ZStack {
                Color.black
                AvatarView(name: feeds.tileName, photoUrl: feeds.tilePhotoUrl, size: 54)
                VStack {
                    Spacer()
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Control capsule (dark, icon-only, red end)

    private var controlBar: some View {
        HStack(spacing: 14) {
            callCircle(call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted) { call.toggleMute() }
            // MY camera — turn it on/off freely (the other side just sees it, no
            // permission). Only once CONNECTED; dimmed while still Calling/Ringing.
            callCircle(call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn) { call.toggleCamera() }
                .disabled(call.state != .active)
                .opacity(call.state == .active ? 1 : 0.4)
            // Flip front/back only while my camera is on.
            if call.cameraOn {
                callCircle("arrow.triangle.2.circlepath", active: false) { flipCamera() }
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

    // Smart speaker: no external device → plain earpiece/speaker toggle.
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
            showControls()          // using a button restarts the clock, never cuts it short
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))   // mic/speaker/camera slash morphs in
                .foregroundStyle(active ? .black : .white)
                .frame(width: 52, height: 52)
                // Idle = real Liquid Glass circle (was a flat white-16% fill); active keeps the
                // solid white pop, where glass would just mute the contrast.
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

// The system audio-route picker (the exact native one), rendered invisible so our own
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
    @ObservedObject private var group = GroupCallService.shared
    @State private var showGroupRestore = false   // bar tap re-presents the group call UI

    private var isActive: Bool {
        switch call.state {
        case .outgoing, .active, .reconnecting, .ended: return true
        default: return false
        }
    }

    // A minimized VIDEO call gets the floating video window; only a voice call gets the green bar.
    // Minimizing used to drop every call into that same bar, so a video call looked like it had
    // turned into a voice one — the video was still running, nothing on screen was showing it.
    private var showsFloatingVideo: Bool { isActive && call.minimized && call.isVideo }

    var body: some View {
        VStack(spacing: 0) {
            if isActive && call.minimized && !call.isVideo {
                MiniCallBar()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { call.minimized = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // ONGOING GROUP CALL, swiped down: a live call (mic possibly hot) must NEVER be invisible.
            // Green return bar at root level — tap re-presents the group call screen from HERE, so it
            // works from any screen, not just the chat that started it.
            if group.isActive && group.minimized {
                HStack(spacing: 8) {
                    Image(systemName: group.isVideo ? "video.fill" : "phone.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(group.callTitle.isEmpty ? "Group call" : group.callTitle)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("Return to call").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(LiveCallBarBackground())   // same living sweep as the 1:1 bar
                .contentShape(Rectangle())
                .onTapGesture {
                    group.minimized = false
                    showGroupRestore = true
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .overlay {
            if showsFloatingVideo {
                FloatingCallWindow()
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: showsFloatingVideo)
        .fullScreenCover(isPresented: Binding(
            get: { isActive && !call.minimized },
            set: { _ in }
        )) {
            CallView()
        }
        .fullScreenCover(isPresented: $showGroupRestore) { GroupCallView() }
    }
}

// MARK: - FloatingCallWindow

// The minimized VIDEO call: a small draggable window carrying the whole call layout — the big feed
// plus the corner tile, following the same big/small choice as the call screen. Tap it to go back.
struct FloatingCallWindow: View {
    private var call: CallService { CallService.shared }
    @State private var offset: CGSize = .zero
    @State private var base: CGSize = .zero

    private let w: CGFloat = 112
    private let h: CGFloat = 199   // 9:16

    private var insets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .max(by: { $0.top < $1.top }) ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            window
                .offset(offset)
                // Plain gesture, not high-priority: the end button inside the window must still get
                // its own taps.
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            let (maxLeft, maxDown) = limits(geo.size)
                            offset = CGSize(
                                width: min(0, max(maxLeft, base.width + v.translation.width)),
                                height: min(maxDown, max(0, base.height + v.translation.height))
                            )
                        }
                        .onEnded { _ in
                            let (maxLeft, maxDown) = limits(geo.size)
                            let x: CGFloat = offset.width < maxLeft / 2 ? maxLeft : 0
                            let y: CGFloat = offset.height > maxDown / 2 ? maxDown : 0
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                offset = CGSize(width: x, height: y)
                            }
                            base = CGSize(width: x, height: y)
                        }
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { call.minimized = false }
                }
                .padding(.top, insets.top + 8)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea()
    }

    // How far the window may travel from its top-right resting place.
    private func limits(_ size: CGSize) -> (CGFloat, CGFloat) {
        let maxLeft = -(size.width - w - 24)
        let maxDown = max(0, size.height - h - (insets.top + 8) - insets.bottom - 8)
        return (maxLeft, maxDown)
    }

    private var window: some View {
        let feeds = call.pipFeeds
        return ZStack(alignment: .topTrailing) {
            Color.black
            if let big = feeds.big {
                VideoRendererView(track: big, mirror: feeds.mirrorBig)
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                // That camera is off (or the call hasn't connected): the photo owns the big view,
                // exactly like the call screen.
                AvatarView(name: feeds.bigName, photoUrl: feeds.bigPhotoUrl, size: 56)
                    .frame(width: w, height: h)
            }
            if feeds.showsTile {
                let tw = w * 0.34
                Group {
                    if let tile = feeds.tile {
                        VideoRendererView(track: tile, mirror: feeds.mirrorTile)
                    } else {
                        ZStack {
                            Color.black
                            AvatarView(name: feeds.tileName, photoUrl: feeds.tilePhotoUrl, size: 22)
                        }
                    }
                }
                .frame(width: tw, height: tw * 16 / 9)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 0.5)
                )
                .padding(5)
            }
            // KEEP A PiP SOURCE VIEW ALIVE WHILE MINIMIZED. The only other CallPiPHost lives inside
            // CallView, which the cover DESTROYS on minimize — so minimizing silently turned off
            // background video: leaving the app then had no PiP window to detach into, the capture
            // session was interrupted, and the other side dropped to the avatar. Apple wants a real
            // on-screen view here, and this window is exactly that.
            CallView.CallPiPHost(feeds: feeds)
                .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
        // End stays reachable without reopening the call — a live mic and camera must always have
        // a one-tap kill.
        .overlay(alignment: .bottom) {
            Button {
                CallKitManager.shared.end()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .accessibilityLabel("End call")
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

// MARK: - LiveCallBarBackground

// The "alive" wash for the minimized call bars (user reference: the reference app's animated call banner): a
// soft band of light drifting across the green every ~3s, so the bar reads as a LIVE call rather
// than a static banner. (The sign-up logo used the same trick until its sweep was removed on
// 2026-08-05; this one stays, because here the movement means the call is still running.)
// TimelineView-driven at
// 30fps over a 40pt strip — GPU-trivial, and it only exists while a bar is on screen.
struct LiveCallBarBackground: View {
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t.truncatingRemainder(dividingBy: 2.6) / 2.6)
                // 0.32 white, wide band: the first pass used 0.16 and was invisible on a bright
                // screen (user: "still sees no wave"). This reads clearly without shouting.
                Color.green.overlay(
                    LinearGradient(colors: [.clear, .white.opacity(0.32), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.75)
                        .offset(x: -geo.size.width * 0.75 + phase * (geo.size.width * 1.75)),
                    alignment: .leading
                )
                .clipped()
            }
        }
    }
}

// MARK: - MiniCallBar

// A 40pt green bar at the top when the call is minimized.
struct MiniCallBar: View {
    private var call: CallService { CallService.shared }
    @State private var now = Date()
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .active:
            if call.videoPausedForNetwork { return "Video paused" }   // no room for the full sentence here
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
            VerifiedMark(uid: call.otherUid, size: 12)
            Text(statusText)
                .font(.system(size: 13))
                .monospacedDigit()
                .opacity(0.9)
            Spacer(minLength: 6)
            // Mute + End live HERE, not only behind a tap-to-return. The bar used to be a label with no
            // controls at all, which meant a live mic (and a live camera) with no way to kill either
            // without first reopening the call screen.
            Button {
                call.toggleMute()
            } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(call.isMuted ? 0.28 : 0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(call.isMuted ? "Unmute" : "Mute")

            Button {
                CallKitManager.shared.end()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(LiveCallBarBackground())   // reference-style living sweep, not a static green
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
