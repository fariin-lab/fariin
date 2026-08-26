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
    /// ⛔ THE CALL WEARS THE PERSON'S OWN COLOUR (owner, 2026-08-20), reversing the flat black of
    /// 2026-07-11. The same extraction the profile page uses, from the same photograph, so a call and
    /// that person's profile read as one surface rather than two screens about one person. Nil until
    /// it resolves and nil for somebody with no photo — both fall back to the black this screen has
    /// always had, which is the right answer when there is nothing to extract from.
    @State private var peerPalette: ProfilePalette?
    // Layout state lives in CallService so minimize/restore keeps the SAME big/small choice and tile
    // position (the fullScreenCover destroys this view on minimize; @State here reset every time).
    private var isLocalExpanded: Bool { get { call.isLocalExpanded } nonmutating set { call.isLocalExpanded = newValue } }
    private var pipOffset: CGSize { get { call.pipOffset } nonmutating set { call.pipOffset = newValue } }
    private var pipBase: CGSize { get { call.pipBase } nonmutating set { call.pipBase = newValue } }
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // Front↔back switch, rebuilt on the reference implementation's mechanics (owner's order: no
    // blur, and never both feeds visible mid-switch). The OLD camera rotates the tile edge-on (or
    // dips fullscreen to black), HOLDS there through the capture restart — that hold is what hides
    // the gap — and swings back only when CallService.cameraSwitchFlip says the NEW camera is
    // delivering. Mirror and content swap while nothing is visible.
    @State private var flippingCamera = false   // a switch is in flight (double-tap guard + fallback reset)
    @State private var flipAngle: Double = 0    // tile: rotates OUT to ±90°, returns from the far side
    @State private var flipDim = false          // fullscreen local video: the crossfade reads as a dip to black
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

    // The switch's OUT half. The return half lives in .onChange(of: call.cameraSwitchFlip): it runs
    // when the new camera is genuinely delivering, and the hold in between is what hides the
    // capture restart. Direction rule matched to the reference: to the back camera turns forward,
    // back to the front turns the other way.
    private func flipCamera() {
        guard !flippingCamera else { return }
        showControls()
        flippingCamera = true
        if showLocalFull {
            withAnimation(.easeIn(duration: 0.1)) { flipDim = true }
        } else {
            withAnimation(.easeIn(duration: 0.1)) { flipAngle = call.usingFrontCamera ? 90 : -90 }
        }
        call.switchCamera()
        // Fallback: a camera that never comes back (hardware refusal) must not leave the tile
        // edge-on forever. The real return path lands first on every normal switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard flippingCamera else { return }
            withAnimation(.easeOut(duration: 0.15)) { flipAngle = 0; flipDim = false }
            flippingCamera = false
        }
    }

    private var statusText: String {
        switch call.state {
        // Accepted beats ringing: the instant they tap Accept the label goes "Connecting…" — the
        // standard messenger order — while the SDP answer is still being built on their phone.
        case .outgoing:     return call.calleeAccepted ? "Connecting…" : (call.calleeRinging ? "Ringing…" : "Calling…")
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
    /// ⛔ "NO ANSWER" WAS TELLING THE CALLER SOMETHING THAT WAS NOT TRUE, and it cost the owner
    /// months of chasing a bug that was partly not ours.
    ///
    /// Two completely different things were showing the same two words:
    ///
    ///   • their phone rang for 45 seconds and nobody picked up      → "No answer" is correct
    ///   • their phone NEVER RANG — silenced by Focus, or iOS refused
    ///     to report the call at all — and ours ended it in 24ms      → "No answer" is a lie
    ///
    /// The second one reads as "he saw me calling and ignored me", which is exactly how the owner
    /// read it, night after night, while the other person's phone had been quiet the whole time.
    /// Measured 2026-08-22: the failed calls ended 0–24ms after arriving. Nobody declines that fast.
    ///
    /// `calleeRinging` is set the moment the other side writes `ringingAt`, so the caller already
    /// knew which of the two had happened and simply never said. Never rang and never accepted
    /// means we could not reach them — their phone, their settings, their signal, and none of it
    /// something either person did.
    private var endedText: String {
        let neverRang = !call.calleeRinging && !call.calleeAccepted
        switch call.endReason {
        case .busy:     return "Busy"
        // A decline reads as a ring-out (owner's order): rejections are never exposed. That rule is
        // untouched — this only splits the case where there was nothing to decline.
        case .declined: return neverRang ? "Couldn't reach them" : "No answer"
        case .failed:   return "Call failed"
        case .missed:   return neverRang ? "Couldn't reach them" : "No answer"
        default:        return "Call ended"
        }
    }
    private var durationText: String {
        guard let start = call.connectedDate else { return "Connecting…" }   // not truly connected until ICE is up (H1)
        return CallDuration.clock(max(0, Int(now.timeIntervalSince(start))))
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
                // zIndex: the video card is the TOP layer, always (owner's side-by-side reference,
                // 2026-08-12: on a voice call that turns on a camera, ours slid UNDER the avatar
                // circle; the standard is avatar behind, card in front). The card's drag bounds
                // keep it clear of the header and control bar, so nothing interactive is covered.
                if call.isVideo { pipLayer(geo).zIndex(2) }

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
            // ⛔ ALWAYS DARK (owner, 2026-08-20). A call is a dark screen whatever the phone is set
            // to — the controls, the name and the glass circles are all drawn for a dark ground, and
            // on a light phone the system-coloured pieces among them came out light on black.
            // `\.colorScheme` rather than `preferredColorScheme`: this is the subtree, not the window.
            .environment(\.colorScheme, .dark)
            // Their colour, the same way the profile page gets it: the warm cache answers on the
            // first frame for anybody seen before, and the full extraction follows for anybody else.
            .task(id: call.otherPhotoUrl ?? "") { await loadPeerPalette() }
            // Connecting, and a voice call turning into a video call, both restart the clock: show the
            // controls for the moment something changes, then get out of the way again.
            .onChange(of: call.state) { _, _ in showControls() }
            .onChange(of: call.isVideo) { _, _ in showControls() }
            // The switch's RETURN half: the new camera is live, mirror already changed while the
            // view was edge-on/black. Come back from the FAR side — the jump across is invisible.
            .onChange(of: call.cameraSwitchFlip) { _, _ in
                guard flippingCamera else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { flipAngle = -flipAngle }
                withAnimation(.easeOut(duration: 0.1)) { flipAngle = 0; flipDim = false }
                flippingCamera = false
            }
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
            // The person's own colour, black when there is none — see `peerPalette`. Still a FLAT
            // fill and never a gradient or a blur of their photo: the 2026-07-11 decision that killed
            // those stands, and this only changes which flat colour it is.
            //
            // ⛔ VOICE ONLY (owner, 2026-08-20). On a video call this is the floor under a camera
            // feed that is about to cover it completely, so all it ever did was flash their colour
            // for the fraction of a second before the picture arrived and then never be seen again
            // — "first time it's showing profile color, after that opened camera". A video call
            // starts black and stays black behind the feed.
            (call.isVideo ? Color.black : (peerPalette.map { Color($0.page) } ?? Color.black))
                .animation(.easeOut(duration: 0.35), value: peerPalette?.key)
            if call.isVideo {
                VideoRendererView(track: full, mirror: showLocalFull && call.usingFrontCamera)
                    .overlay(Color.black.opacity((showLocalFull && flipDim) ? 1 : 0))   // fullscreen switch = dip through black
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
            Button { call.minimized = true } label: {   // no withAnimation: the zoom owns this motion
                // The minimise glyph rather than a bare chevron: this button shrinks the call
                            // into the pill, it does not dismiss or scroll anything.
                            topCircle("arrow.down.right.and.arrow.up.left")
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

    /// The peer's extracted colour. Warm cache first so a person already seen paints on frame one;
    /// the full read follows. Nobody with no photo gets one, and the screen stays black.
    private func loadPeerPalette() async {
        guard let url = call.otherPhotoUrl, !url.isEmpty else { peerPalette = nil; return }
        if let warm = ProfilePalette.warm(url: url) { peerPalette = warm; return }
        peerPalette = await ProfilePalette.resolve(url: url)
    }

    private func topCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            // 18, WHICH IS THE APP'S OWN NUMBER FOR A 48pt HEADER CIRCLE — the share sheet's search
            // and share buttons are exactly 48 and 18, set by him the same week. Left at the old 15
            // the glyph would be 0.31 of the circle instead of 0.375, so growing the button alone
            // would have made these read as two big empty discs rather than as bigger buttons.
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            // ⛔ 48, AND THIS IS THE OWNER REVERSING HIS OWN CALL — DO NOT "RESTORE" THE 40.
            // 48 was the original, he set it to 40 on 2026-08-20, and on 2026-08-21 he circled both
            // buttons and asked for 48 back. Two deliberate decisions a day apart, so the number is
            // not drift and the later one wins. It also puts these two back in step with every other
            // header pair in the app — the share sheet's search and share circles are 48 on his order
            // from the same week.
            .frame(width: 48, height: 48)
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
        // THE TILE BREATHES WITH THE CHROME (owner's 2026-08-12 side-by-side reference, exact
        // numbers read from the reference implementation): menus up → the tile grows; menus away →
        // it shrinks toward the corner, so the tap that toggles the controls is FELT on the tile
        // too. The rule there is a square bounding box — 240pt with chrome, 140pt without — with
        // the camera's own aspect fitted inside; for our 9:16 portrait feed that is 135×240 and
        // 79×140 (the old fixed 104×150 was a squashed crop).
        let tileW: CGFloat = controlsVisible ? 135 : 79
        let tileH: CGFloat = controlsVisible ? 240 : 140
        // HOME IS THE BOTTOM CORNER (owner's report: ours landed on TOP after accept; the standard
        // is the bottom). Gutters are 12pt; with the chrome up the tile clears the control bar,
        // with it away it drops toward the bottom edge. Drag can park it in any corner; these are
        // the travel bounds.
        let bottomPad = safeBottom + (controlsVisible ? 132 : 12)
        let maxLeft = -(geo.size.width - tileW - 24)
        let maxUp = -max(0, geo.size.height - tileH - (winInsets.top + 60) - bottomPad)
        // A dragged offset was stored against ONE set of bounds, and the bounds move when the
        // chrome toggles — the tile grows and its home rises. Clamp at DISPLAY time (his 544
        // report: park the card at the top by hand, tap the screen, and the grown card slid off
        // the top edge). The STORED offset survives untouched, so hiding the chrome returns the
        // card to exactly where he parked it.
        let shownOffset = CGSize(width: max(maxLeft, min(0, pipOffset.width)),
                                 height: max(maxUp, min(0, pipOffset.height)))
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
                        .frame(width: tileEntering ? geo.size.width : tileW,
                               height: tileEntering ? geo.size.height : tileH)
                        // The camera switch is a real edge-on turn of the tile (no blur): the old
                        // frame rotates away, holds hidden through the capture restart, and the new
                        // camera swings in from the far side. See flipCamera + cameraSwitchFlip.
                        .rotation3DEffect(.degrees(pipIsLocal ? flipAngle : 0),
                                          axis: (x: 0, y: 1, z: 0), perspective: 0.3)
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
                .offset(tileEntering ? .zero : shownOffset)
                // Drag (min 10pt) repositions the window; a tap (no move) swaps the feeds.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { v in
                            // Home is the BOTTOM-trailing corner now, so travel is left (negative w)
                            // and UP (negative h) — bounds computed above from the live tile size.
                            let w = pipBase.width + v.translation.width
                            let h = pipBase.height + v.translation.height
                            pipOffset = CGSize(width: min(0, max(maxLeft, w)), height: max(maxUp, min(0, h)))
                        }
                        .onEnded { _ in
                            // SNAP TO THE NEAREST CORNER (standard PiP): the tile must never rest
                            // mid-screen. Choose left/right by which half the tile is in, top/bottom the
                            // same, then spring there.
                            let targetX: CGFloat = pipOffset.width < maxLeft / 2 ? maxLeft : 0
                            let targetY: CGFloat = pipOffset.height < maxUp / 2 ? maxUp : 0
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
                    // TWO STAGES, NEVER ONE (owner's 2026-08-12 spec): a tap on the SMALL tile
                    // (chrome hidden) only grows it — same result as tapping the screen. Only a tap
                    // on the already-grown tile swaps fullscreen. Small → bigger → fullscreen.
                    guard controlsVisible else { showControls(); return }
                    showControls()
                    // The swap's curve, matched to the reference: a quick ease, not a bouncy spring.
                    withAnimation(.easeInOut(duration: 0.25)) { isLocalExpanded.toggle() }
                }
                .padding(.bottom, tileEntering ? 0 : bottomPad)
                .padding(.trailing, tileEntering ? 0 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                // Size and home both move when the chrome toggles — one spring for the whole relayout.
                .animation(.spring(duration: 0.4), value: controlsVisible)
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
                // The external glyph is the DEVICE, not one generic pair of cans — see
                // CallService.externalRouteIcon.
                Image(systemName: call.audioRoute == .external ? call.externalRouteIcon : "speaker.wave.2.fill")
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
// Minimized → the floating card in the bottom corner; otherwise presents the full call screen.
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

    // EVERY minimized call gets the floating card — voice ones too. The green bar that used to sit
    // across the top for voice calls is gone (owner, 2026-08-23, reference in hand): a bar eats the
    // top of whatever screen you moved on to, and it duplicated what the chat list now says by
    // itself. The list carries the words ("Active call", green, top row) and the card carries the
    // faces and the controls, which is the split the reference app uses.
    private var showsFloatingCall: Bool { isActive && call.minimized }
    /// Held at the root because the cover is declared here; handed to the buttons through the
    /// environment. See `CallZoomNamespaceKey`.
    @Namespace private var callZoom

    var body: some View {
        VStack(spacing: 0) {
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
            if showsFloatingCall {
                // ⛔ NO TRANSITION AND NO ANIMATION ON THIS. The card must simply BE THERE the instant
                // `minimized` flips, because it is the shape the zoom is flying into.
                //
                // It used to fade in over a spring of its own while the cover was shrinking into it.
                // Two animations describing the same moment, on two different curves, neither knowing
                // about the other: the zoom landed on a card that was still half transparent and
                // still settling, which is the "not smooth" the owner is pointing at (2026-08-23,
                // beside a messenger whose version of this is clean). Apple's zoom is a real frame
                // interpolation and it is good; it just cannot land on a target that is busy
                // animating itself.
                //
                // The matched-geometry morph between card and tab stays — that is a DIFFERENT moment,
                // with no cover involved and nothing else animating.
                FloatingCallWindow()
            }
        }
        .environment(\.callZoomNamespace, callZoom)
        // ⛔ THE SETTER SWALLOWED THE DISMISS, AND THAT LOST THE CALL.
        //
        // The comment below says this screen "is left by a button", and that stopped being true the
        // moment it was presented with a zoom transition: the system zoom brings its own
        // swipe-down-to-dismiss, which the note itself acknowledges. So the cover could be dismissed
        // by a swipe, SwiftUI reported it through this setter, and `set: { _ in }` threw it away —
        // the screen went, `minimized` stayed false, and the green return bar keys on `minimized`.
        // Result: an active call with nothing anywhere on screen pointing back to it. The owner's
        // report, exactly: "when i swipe down the call, that call will not show in chatlist on top
        // like when you tap X".
        //
        // A swipe now means what the X means. Guarded on `isActive` so the dismissal that happens
        // because the call ENDED does not mark a finished call as minimized on its way out.
        .fullScreenCover(isPresented: Binding(
            get: { isActive && !call.minimized },
            set: { presented in
                guard !presented, isActive else { return }
                call.minimized = true   // no withAnimation: the zoom owns this motion
            }
        )) {
            // GROWS OUT OF THE BUTTON THAT WAS PRESSED (owner, 2026-08-20), rather than sliding up
            // from the bottom edge. `call.isVideo` is already decided by the time this presents, so
            // it names the matching source of the two.
            //
            // ⚠️ Safe here in a way it was NOT on the media viewer, and the difference is worth
            // stating: the system zoom brings its own dismiss pan, which fought that screen's
            // MediaDismissHost drag. This screen has no drag of its own, so there is nothing for it
            // to fight.
            //
            // It does NOT follow that this screen is only ever left by a button — that is what the
            // note used to claim and it is why the dismiss was thrown away above. The zoom's pan is
            // a second way out, and it has to mean the same thing the button means.
            // ⚠️ THE SOURCE SWITCHES ONCE THE CARD HAS EXISTED (owner, 2026-08-23 — he asked whether
            // closing the big screen into the small card was a matched transition; it was not, the
            // cover just faded while the card popped in separately). Before the first minimize the
            // source is the button that placed the call, which is what he asked for on 2026-08-20.
            // After it, the source is the card: the screen shrinks into the card and grows back out
            // of the same card on the way in. A zoom whose source is not on screen falls back to the
            // ordinary presentation on its own, so ending a call is no worse than it was.
            CallView()
                .navigationTransition(.zoom(sourceID: call.everMinimized
                                                ? CallZoomSource.card
                                                : CallZoomSource.id(video: call.isVideo),
                                            in: callZoom))
        }
        // THE SAME HOLE ON THE GROUP SIDE. Tapping the bar clears `minimized` and presents this;
        // GroupCallView's own swipe-down sets `minimized` back to true, but a swipe on the COVER
        // itself only closes the cover, and `minimized` was already false — so the group call lost
        // its return bar too. Restoring the flag on dismiss puts the bar back either way.
        .fullScreenCover(isPresented: $showGroupRestore, onDismiss: {
            if group.isActive { group.minimized = true }
        }) { GroupCallView() }
    }
}

// MARK: - The zoom source

/// ⛔ THE NAMESPACE THE CALL SCREEN GROWS OUT OF, CARRIED IN THE ENVIRONMENT.
///
/// A zoom transition needs the source and the presentation to share one `Namespace`, and these two
/// are nowhere near each other: the button is in the profile, and the cover that answers it is
/// declared once at the root so a call can be restored from any screen. Neither can hold the
/// namespace for the other, so the root holds it and hands it down.
///
/// Nil is a working configuration and most callers are exactly that. The Calls tab, the chat header
/// and an incoming call have no button to grow out of, and a zoom with no source falls back to the
/// ordinary presentation on its own.
private struct CallZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var callZoomNamespace: Namespace.ID? {
        get { self[CallZoomNamespaceKey.self] }
        set { self[CallZoomNamespaceKey.self] = newValue }
    }
}

/// One id per button, because there are two of them side by side and the page has to grow out of
/// the one that was pressed — not out of whichever was registered last.
enum CallZoomSource {
    static func id(video: Bool) -> String { video ? "call.video" : "call.voice" }
    /// The floating card. Once a call has been minimized ONCE, the card is the thing the screen
    /// belongs to and the button that started it is usually not even on screen any more — so from
    /// then on the screen shrinks into the card and grows back out of it. See `everMinimized`.
    static let card = "call.card"
}

// MARK: - FloatingCallWindow

// The minimized VIDEO call: a small draggable window carrying the whole call layout — the big feed
// plus the corner tile, following the same big/small choice as the call screen. Tap it to go back.
struct FloatingCallWindow: View {
    private var call: CallService { CallService.shared }
    /// The card is the call screen's zoom partner: the screen shrinks into it and grows back out of
    /// it. Nil namespace is a working configuration — the zoom just falls back to a plain
    /// presentation — so this never has to be guaranteed, only offered.
    @Environment(\.callZoomNamespace) private var zoomNamespace
    // NOT @State. See CallService.cardOffset: this view dies on every restore, and @State handed the
    // card back to the bottom-right corner each time instead of leaving it where it was dropped.
    private var offset: CGSize {
        get { call.cardOffset } nonmutating set { call.cardOffset = newValue }
    }
    private var base: CGSize {
        get { call.cardBase } nonmutating set { call.cardBase = newValue }
    }

    private let w: CGFloat = 112
    private let h: CGFloat = 199   // 9:16

    // Hiding it to the side.
    private let overshoot: CGFloat = 70   // how far past the edge a drag is allowed to pull it
    private let stashAt: CGFloat = 42     // let go beyond this and it parks as a tab
    private let tabW: CGFloat = 68        // no part of it is buried, so it needs no extra width
    private let tabH: CGFloat = 46        // the wedge loses height at its point, so it starts taller
    private let pullMax: CGFloat = 34     // how far the tab rubber-bands inward before letting go
    private let pullBack: CGFloat = 22    // pulled at least this far → the card comes back

    /// Live inward drag on the tab. Transient by design: it is either mid-gesture or zero, and it
    /// must not survive the tab turning back into a card.
    @State private var tabPull: CGFloat = 0

    /// The card's live drag, as a TRANSFORM. Zero except while a finger is down — see the drag's
    /// `onChanged` for why the settled position and the moving one are kept apart.
    @State private var dragLive: CGSize = .zero

    /// Ties the card and the tab together as one shape for the morph.
    @Namespace private var morph
    private static let morphID = "call.card.morph"

    /// ⚠️ `base` IS THE ANCHOR AND MUST NOT MOVE MID-DRAG. Every gesture update reports the
    /// translation from where the finger went DOWN, so a version of this that wrote `base` on each
    /// change re-added the whole translation to an already-moved anchor and the tab shot off the
    /// screen. `offset` is the live position; `base` is only committed when the finger lifts. The
    /// card's own drag has always worked this way — this is the same contract.
    private func setLiveY(_ y: CGFloat) {
        offset = CGSize(width: offset.width, height: y)
    }

    private func commitY() {
        base = CGSize(width: base.width, height: offset.height)
    }

    /// ⛔ CACHED, BECAUSE THIS IS READ FROM `body`. It walks every connected scene and every window
    /// to find the notch, and `body` re-runs on every frame of a drag — sixty scene-graph walks a
    /// second, for a number that cannot change while a call is on screen. Resolved once when the
    /// card appears and read from memory after that.
    @State private var insetsCache: UIEdgeInsets = .zero

    private var insets: UIEdgeInsets { insetsCache }

    private static func resolveInsets() -> UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .max(by: { $0.top < $1.top }) ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            if call.cardStashed {
                stashTab
                    // ONE OBJECT IN TWO SHAPES. The card does not vanish and a tab appear in its
                    // place: they share an identity, so the card's frame travels to the wedge's frame
                    // and back. Like the card, the tab's position is PADDING rather than `.offset` —
                    // a morph reads layout geometry, and an offset tab would have flown to the corner
                    // instead of to where it is sitting.
                    .matchedGeometryEffect(id: Self.morphID, in: morph)
                    // THE TAB DRAGS TOO (owner, 2026-08-23). Up and down it slides along the edge and
                    // stays where it is put. Pulled INWARD it comes back as the card — the same
                    // gesture that hid it, run backwards. A tap does nothing but bring the card back,
                    // so the two never have to be told apart.
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                let (_, maxDown) = limits(geo.size)
                                setLiveY(min(maxDown, max(0, base.height + v.translation.height)))
                                // Only the inward direction is live. Pushing further out has nowhere
                                // to go, and letting it move would look like it could leave twice.
                                let inward = stashedLeft ? v.translation.width : -v.translation.width
                                let pull = max(0, min(pullMax, inward))
                                tabPull = stashedLeft ? pull : -pull
                            }
                            .onEnded { _ in
                                commitY()
                                let pulled = abs(tabPull)
                                tabPull = 0
                                if pulled >= pullBack {
                                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                        call.cardStashed = false
                                    }
                                }
                            }
                    )
                    // FLUSH WITH THE EDGE, not tucked under it. See `stashTab` for why.
                    // `tabPull` is the live inward drag; its sign already says which way inward is,
                    // so the magnitude is all this side needs.
                    .padding(.top, insets.top + 8 + min(offset.height, max(0, limits(geo.size).1)))
                    .padding(stashedLeft ? .leading : .trailing, abs(tabPull))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: stashedLeft ? .topLeading : .topTrailing)
            } else {
                // ⛔ THE TRANSFORM SITS ON `window`, INSIDE THE GESTURE, which is where the smooth
                // build had it. Hung on the outside it moves the very view the drag is measured on,
                // so the finger's own reference frame travels with the card.
                morphAnchored(zoomAnchored(window.offset(dragLive)))
                    // Plain gesture, not high-priority: the end button inside the window must still get
                    // its own taps.
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                let (maxLeft, maxDown) = limits(geo.size)
                                // Deliberately allowed PAST the edge by `overshoot`. The card sliding
                                // partly off is the only warning that letting go will hide it — clamped
                                // dead at the edge, hiding would happen out of nowhere.
                                let target = CGSize(
                                    width: min(overshoot, max(maxLeft - overshoot, base.width + v.translation.width)),
                                    height: min(maxDown, max(0, base.height + v.translation.height))
                                )
                                // ⛔ THE LIVE DRAG IS A TRANSFORM, NOT LAYOUT, and that is the whole
                                // reason this variable exists (owner, 2026-08-23: "when i drag and
                                // moving the small card it makes shaking, looks something blocks").
                                //
                                // My own regression. Moving the card with PADDING fixed the zoom —
                                // padding is real geometry, so the transition finally knew where the
                                // card was — but padding is also a full LAYOUT PASS, and I was
                                // running one per touch event. Sixty relayouts a second of a view
                                // sitting over the whole screen is the stutter he is feeling.
                                //
                                // Both, then, each where it belongs: the settled position stays
                                // padding, so the frame is honest at rest, which is the ONLY moment a
                                // zoom or a morph ever reads it. The finger moves a transform, which
                                // costs nothing and cannot stutter. On release the transform folds
                                // back into the padding and returns to zero.
                                dragLive = CGSize(width: target.width - base.width,
                                                  height: target.height - base.height)
                            }
                            .onEnded { v in
                                let (maxLeft, maxDown) = limits(geo.size)
                                // ⛔ ONLY THE SIDE SNAPS. Height stays exactly where the finger left
                                // it (owner, 2026-08-23: "only i can drag top left or top right,
                                // bottom left, no middle right or left"). Snapping y as well pinned
                                // the card to four corners, so it could never sit beside the row you
                                // were actually reading — you had to choose between covering the top
                                // of the list or the bottom of it. Apple's own picture-in-picture and
                                // the reference app both do it this way: the edge is decided for you
                                // because a card floating in open space is just in the way; the
                                // height is yours because only you know what is underneath it.
                                // ⛔ WHERE THE THROW WAS GOING, not where the finger stopped. Read
                                // out of Signal's own `animateDecelerationToVerticalEdge`: they take
                                // the pan velocity, ignore anything under a threshold so a slow
                                // release is not a throw at all, project where that speed would
                                // carry the view, and land it on the nearest side at whatever height
                                // the projection reached.
                                //
                                // `predictedEndTranslation` is SwiftUI's version of that same
                                // projection, so a flick up-and-left lands top-left and a careful
                                // drop stays exactly where it was let go. Without it the card simply
                                // stopped dead under the finger, which is what makes a floating
                                // window feel stuck to the glass rather than thrown.
                                let thrown = CGSize(
                                    width: base.width + v.predictedEndTranslation.width,
                                    height: base.height + v.predictedEndTranslation.height
                                )
                                // The finger's real last position still decides the STASH, so shoving
                                // it off the side stays a deliberate push rather than something a
                                // fast flick can trigger by accident.
                                let ended = CGSize(width: base.width + dragLive.width,
                                                   height: base.height + dragLive.height)
                                let y = min(maxDown, max(0, thrown.height))
                                // Shoved far enough past a side → park it there as a tab.
                                if ended.width > stashAt || ended.width < maxLeft - stashAt {
                                    let x: CGFloat = ended.width > stashAt ? 0 : maxLeft
                                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                        base = CGSize(width: x, height: y)
                                        offset = base
                                        dragLive = .zero   // fold the transform back into the layout
                                        call.cardStashed = true
                                    }
                                    return
                                }
                                let x: CGFloat = thrown.width < maxLeft / 2 ? maxLeft : 0
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    base = CGSize(width: x, height: y)
                                    offset = base
                                    dragLive = .zero
                                }
                            }
                    )
                    .onTapGesture {
                        call.minimized = false   // no withAnimation: the zoom owns this motion
                    }
                    // ⛔ PADDING, NOT `.offset`, AND THAT IS THE WHOLE POINT (owner, 2026-08-23: he
                    // dragged the card to the bottom-left, reopened the call, and the zoom still flew
                    // to the top-right corner — "we hard code on top only").
                    //
                    // It was not hardcoded, and the card did land back where he left it. `.offset` is
                    // a DRAW-TIME transform: it moves pixels and leaves the view's LAYOUT frame where
                    // it always was, up in the corner. Both transitions read that layout frame —
                    // matchedTransitionSource for the call screen's zoom, matchedGeometryEffect for
                    // the morph into the tab — so both of them animated to a corner the card had not
                    // occupied since the first drag. The card was right and the flight was wrong.
                    //
                    // Expressed as padding the position is real geometry, so the zoom lands on the
                    // card wherever it actually sits. `offset.width` is zero at the right edge and
                    // negative to the left of it, hence the subtraction; it can also go briefly
                    // POSITIVE while a drag pushes the card past the edge, and negative padding is
                    // exactly the right answer there.
                    //
                    // TOP-RIGHT is only the resting HOME (his 2026-08-23 rule: "most land top right,
                    // that's standard"), which is what zero offset means. The self-tile inside the
                    // call screen still lives bottom-right under his 2026-08-12 rule and has not moved.
                    // The finger's transform is on `window` above; only the settled position is here.
                    .padding(.top, insets.top + 8 + base.height)     // the settled position: real layout
                    .padding(.trailing, 12 - base.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: call.cardStashed)
        // Resolved once. See `insetsCache` for why this is not read live from `body`.
        .onAppear { insetsCache = Self.resolveInsets() }
    }

    /// Which side it was parked on. `cardBase.width` is 0 at the right edge and negative anywhere
    /// left of it, so the drag has already recorded this and there is no second flag to keep in step.
    private var stashedLeft: Bool { base.width < 0 }

    /// THE TAB. Everything the card was saying is gone except the one thing worth a glance from the
    /// corner of your eye: how long you have been on. Green because that is what a live call is
    /// everywhere else in here — the row in the chat list, the talking bubble.
    ///
    /// ⛔ NOT A ROUNDED RECTANGLE WITH A CORNER POKING OUT. That is the reference app's drawing, and
    /// the first build of this was a straight copy of it — the owner asked, fairly, whether it just
    /// looked like theirs (2026-08-23). It is a WEDGE now, his own pick: see `WedgeTab`.
    ///
    /// Tap brings the card back and does nothing else — never the full call screen, which is one more
    /// tap on the card itself. Dragging it is handled where the geometry is, at the call site.
    private var stashTab: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            ZStack {
                tabShape.fill(Color.green)
                tabLabel(context.date)
                    // The clock lives in the ROUND end, the half still facing the screen. Centred in
                    // the frame it would sit halfway down the taper and lose a digit off the point.
                    .padding(stashedLeft ? .leading : .trailing, tabW * 0.26)
            }
        }
        .frame(width: tabW, height: tabH)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { call.cardStashed = false }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .accessibilityLabel("Back to the call")
    }

    /// Parked on the right → the point aims right, out through that edge. Mirrored on the left.
    private var tabShape: WedgeTab { WedgeTab(pointsRight: !stashedLeft) }

    @ViewBuilder private func tabLabel(_ now: Date) -> some View {
        if let start = call.connectedDate {
            Text(CallDuration.clock(max(0, Int(now.timeIntervalSince(start)))))
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        } else {
            // Not connected yet, so there is no duration to report and a zeroed clock would be a
            // lie. The glyph says "a call is going on here" and nothing more.
            Image(systemName: "phone.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    /// ⛔ ALWAYS ATTACHED. IT IS NOT WHAT SHOOK THE CARD, AND SWITCHING IT OFF MID-DRAG IS WHAT
    /// BROKE IT A THIRD TIME (owner, 2026-08-25: "it won't follow smoothly, something is fighting").
    ///
    /// The blame was reasonable and wrong. `matchedGeometryEffect` re-resolves on every LAYOUT pass,
    /// so it can only argue with a drag that is moving LAYOUT — which this one did while the
    /// position was padding, and has not since the finger was moved onto a transform. In the build
    /// he called smooth this modifier was attached the whole time, over exactly the same stable
    /// layout, and there was nothing to argue with.
    ///
    /// What replaced it cost far more than it saved: `if dragging` is a STRUCTURAL branch, so the
    /// card's whole subtree is torn down and rebuilt at the moment the finger starts moving, and
    /// again when it lifts. A live gesture whose view is replaced under it is the hitch he is
    /// describing. Anything that needs switching off mid-drag has to be switched off WITHOUT
    /// changing the shape of the tree.
    private func morphAnchored(_ content: some View) -> some View {
        content.matchedGeometryEffect(id: Self.morphID, in: morph)
    }

    /// Marks the card as the shape the call screen flies into and out of. Same shape as the call
    /// buttons' own modifier, and for the same reason: `matchedTransitionSource` needs a real
    /// namespace, and on a screen that does not host the cover's environment there is not one.
    ///
    /// Its `dragging` branch is gone too, and for the reason written on the morph above: the branch
    /// itself was the cost. The remaining one keys on the namespace, which cannot change while a
    /// finger is down.
    @ViewBuilder private func zoomAnchored(_ content: some View) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: CallZoomSource.card, in: zoomNamespace)
        } else {
            content
        }
    }

    // How far the card may travel from its top-right home: LEFT as negative x, DOWN as positive y.
    // The bottom stop still allows for the tab pill, so dragging it down parks it above the tabs
    // rather than behind them.
    private func limits(_ size: CGSize) -> (CGFloat, CGFloat) {
        let maxLeft = -(size.width - w - 24)
        let maxDown = max(0, size.height - h - (insets.top + 8) - (insets.bottom + 76))
        return (maxLeft, maxDown)
    }

    private var window: some View {
        Group {
            if call.isVideo { videoWindow } else { voiceWindow }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
        // ⛔ NO BUTTONS ON THIS CARD (owner, 2026-08-23: "red end call and mute dont make that").
        // A first pass put mute and End here when the green bar was removed, and the video card had
        // carried a red End since before that. Both are gone: the card is a way BACK to the call, not
        // a second set of controls, and the reference's floating window has nothing on it either.
        // Tapping the card opens the call screen, where every control already lives.
        //
        // The stage sits UNDER the picture on a video card, because the picture is already filling
        // it; the voice card puts the same words under the face instead. Either way a minimized call
        // that has not been answered yet says so.
        .overlay(alignment: .bottom) {
            if call.isVideo, let stage = stageLabel {
                Text(stage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    /// WHAT THE CALL IS DOING, for the card — nil once it is connected, because two faces sitting
    /// there already say "you are on a call" and a label would only repeat it. Owner, 2026-08-23:
    /// minimizing a call that is still ringing used to leave a card that looked identical to a
    /// connected one, so you could not tell whether they had picked up.
    ///
    /// The words are the ones the call screen uses, deliberately: minimizing must not rename the
    /// stage halfway through it.
    private var stageLabel: String? {
        switch call.state {
        case .outgoing:     return call.calleeAccepted ? "Connecting…" : (call.calleeRinging ? "Ringing…" : "Calling…")
        case .incoming:     return "Incoming…"
        case .reconnecting: return "Reconnecting…"
        case .ended:        return "Call ended"
        default:            return nil   // .active — the two faces carry it
        }
    }

    // The minimized VOICE call. Connected: the two people stacked, them on top, you underneath —
    // the shape the reference uses. Still ringing: ONE face, theirs, with the stage under it, which
    // is also what the reference does before somebody answers.
    // A voice call has no picture of its own, so the card says WHO you are on with instead of a
    // phone glyph. Black panels, not coloured ones: this app's palette is black/white (Theme.accent
    // is literally white-or-black) and a blue/peach card would belong to another app.
    @ViewBuilder private var voiceWindow: some View {
        if let stage = stageLabel {
            VStack(spacing: 10) {
                voiceFace(name: call.otherName, photoUrl: call.otherPhotoUrl, size: 54, level: 0)
                Text(stage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)   // "Reconnecting…" must not clip on a 112pt card
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
            .background(Color.black)
        } else {
            VStack(spacing: 0) {
                voicePanel(name: call.otherName, photoUrl: call.otherPhotoUrl,
                           avatar: 46, level: call.remoteLevel)
                Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
                voicePanel(name: call.myName, photoUrl: call.myPhotoUrl,
                           avatar: 38, level: call.localLevel)
            }
            .background(Color.black)
        }
    }

    /// One person's half of the connected voice card.
    private func voicePanel(name: String, photoUrl: String?, avatar: CGFloat,
                            level: Double) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            voiceFace(name: name, photoUrl: photoUrl, size: avatar, level: level)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A face on the card, wearing the wave.
    ///
    /// ⛔ THE WAVE IS ON THE FACE, NOT BESIDE IT, and it is driven by HOW LOUD rather than by
    /// whether (owner, 2026-08-23: "what if we make around avatar wave that take talk", and then
    /// "can that wave be free from a copied look?").
    ///
    /// It replaces a white speech bubble with green bars, which was a straight lift of the reference
    /// app's mark and looked it. This one cannot be copied without first doing the work underneath:
    /// everyone else's talking indicator is a BOOLEAN, so their ring switches on and sits there. We
    /// already read the real audio level to decide whether somebody is speaking at all, so the ring
    /// breathes with the voice instead of blinking with a flag.
    ///
    /// Nothing at all is drawn at level 0 — silence carries no mark, and a call that has not been
    /// answered passes 0 explicitly, because a live ring on a phone nobody picked up would be a lie.
    private func voiceFace(name: String, photoUrl: String?, size: CGFloat, level: Double) -> some View {
        AvatarView(name: name, photoUrl: photoUrl, size: size)
            .background { TalkingWave(level: level, avatar: size) }
    }

    private var videoWindow: some View {
        let feeds = call.pipFeeds
        // bottomTrailing: the self-tile inside this card sits in the BOTTOM corner, matching the
        // call screen and the system PiP (owner's 2026-08-12 rule — the tile's home is the bottom).
        return ZStack(alignment: .bottomTrailing) {
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
        // The card's frame, corner, border, controls and shadow are applied ONCE in `window`, so the
        // voice half and the video half cannot drift apart into two different-looking cards.
    }
}

// MARK: - WedgeTab

/// The shape of the hidden call tab, drawn from the owner's own screenshot (2026-08-23): a round
/// bulge facing INTO the screen, tapering to a point that goes OUT through the edge.
///
/// ⚠️ THIS IS THE OPPOSITE OF THE FIRST BUILD, and the difference is the whole idea. That one was
/// flat on the edge with the point aimed inward, which reads as an arrow telling you to swipe
/// somewhere. This one reads as the card itself being squeezed out through the side of the screen:
/// the fat end is the part still in the room, the point is the part already gone. It also puts the
/// wide half where the clock has to live, so the digits sit in the shape instead of fighting a taper.
///
/// The tip is rounded, never a true apex: a sharp point on a 46pt shape aliases into a whisker at
/// some scale factors and looks like a rendering fault rather than a design.
struct WedgeTab: Shape {
    /// True when the point aims at the RIGHT edge — the tab is parked on the right.
    var pointsRight: Bool

    func path(in r: CGRect) -> Path {
        let bulge = r.height / 2          // the round end is a half-circle's worth of belly
        let tip = r.height * 0.30         // how far back from the point the rounding starts
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: r.minX + bulge, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - tip, y: r.midY - tip * 0.55))
            p.addQuadCurve(to: CGPoint(x: r.maxX - tip, y: r.midY + tip * 0.55),
                           control: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX + bulge, y: r.maxY))
            // Control sits a full bulge OUTSIDE the box on purpose — that is what puts the curve's
            // widest point exactly on the box edge instead of somewhere inside it.
            p.addQuadCurve(to: CGPoint(x: r.minX + bulge, y: r.minY),
                           control: CGPoint(x: r.minX - bulge, y: r.midY))
        } else {
            p.move(to: CGPoint(x: r.maxX - bulge, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + tip, y: r.midY - tip * 0.55))
            p.addQuadCurve(to: CGPoint(x: r.minX + tip, y: r.midY + tip * 0.55),
                           control: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - bulge, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - bulge, y: r.minY),
                           control: CGPoint(x: r.maxX + bulge, y: r.midY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - TalkingWave

/// THE WAVE AROUND A FACE ON THE CALL CARD — his design, 2026-08-23 ("what if we make around avatar
/// wave that take talk"), replacing a white speech bubble with green bars that was a straight lift
/// of the reference app's mark and looked like one.
///
/// ⛔ IT IS DRIVEN BY HOW LOUD, NOT BY WHETHER, and that is the whole answer to his follow-up: "can
/// that wave be free from a copied look?" Every other messenger's talking indicator is a BOOLEAN —
/// their ring switches on and then just sits there, because a flag is all they read. We already
/// sample the real audio level to decide whether somebody is speaking at all (see CallService), so
/// ours breathes with the voice. Nobody can copy the look without first doing that work, and almost
/// nobody bothers.
///
/// Two rings leave the rim and fade as they travel, further and brighter the louder the voice, over
/// a collar that thickens on the rim itself. At level 0 NOTHING is drawn: a silent face carries no
/// mark, which is what makes the card quiet in the gaps instead of decorated.
struct TalkingWave: View {
    /// 0…1 above the room's own noise floor. See CallService.remoteLevel.
    var level: Double
    /// The avatar's diameter — everything else is derived, so one number scales the whole mark.
    var avatar: CGFloat

    /// How far the outermost ring can travel past the rim at full voice.
    private var reach: CGFloat { avatar * 0.42 }

    var body: some View {
        // ⚠️ TimelineView, NOT a repeating animation. The rings have to travel outward continuously
        // AND their size has to track a number that changes several times a second; a
        // `repeatForever` animation would fight every level change and restart mid-flight. A clock
        // plus a pure function of (time, level) has no state to fight over.
        //
        // 20fps: the motion is a slow swell, not a spinner, and this can be on screen for the length
        // of a call. Nothing here is worth 60.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                guard level > 0.02 else { return }   // silence draws nothing at all
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let rim = avatar / 2

                for i in 0..<2 {
                    // The two rings are half a cycle apart, so one is always leaving as the other
                    // arrives — a single ring reads as a pulse, two read as a wave.
                    let phase = ((t / 1.15) + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    let radius = rim + CGFloat(phase) * reach * level
                    // Fades to nothing by the end of its travel, so no ring ever pops out of
                    // existence at the edge.
                    let alpha = (1 - phase) * level * 0.5
                    guard alpha > 0.01 else { continue }
                    let rect = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(.green.opacity(alpha)),
                               lineWidth: 1.5 + 2.5 * level * (1 - phase))
                }

                // A collar on the rim itself, so the face is unmistakably the SOURCE of the rings
                // rather than something that happens to be sitting inside them.
                let collar = rim + 1
                let rect = CGRect(x: c.x - collar, y: c.y - collar, width: collar * 2, height: collar * 2)
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(.green.opacity(0.3 + 0.55 * level)),
                           lineWidth: 1.5 + 2 * level)
            }
            // The canvas has to be wider than the face or the rings would be clipped at the avatar's
            // own bounds, which is exactly where they are supposed to be travelling past.
            .frame(width: avatar + reach * 2 + 6, height: avatar + reach * 2 + 6)
        }
        .allowsHitTesting(false)
    }
}


// MARK: - LiveCallBarBackground

// The "alive" wash for the minimized call bars. HIS 2026-08-11 ORDER, reference open: not a band
// of light — a WAVE. The reference's call banner runs soft undulating curves along the bar's
// bottom edge, constantly rippling, and that motion is what says "this call is still running".
// (This bar's first build was a drifting light sweep; he looked at the reference beside it and
// asked for the wave itself, so the sweep is gone.) Two translucent white curves at different
// wavelengths and opposite directions, each breathing its height a little, over the same green.
// TimelineView-driven at 30fps over a 40pt strip — one Canvas, GPU-trivial, and it only exists
// while a bar is on screen. No C++ anywhere, which he asked about: the reference animates theirs
// with ordinary UI code too; their C++ is the call audio, not the banner.
struct LiveCallBarBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.green))
                // Back wave: taller, slower, left-to-right. Front wave: shorter, quicker, the
                // other way — two directions is what makes it read as liquid rather than a march.
                drawWave(&ctx, size: size, t: t, lift: 4, amp: 5.0, breath: 2.0, len: 130, speed: 1.1, opacity: 0.20)
                drawWave(&ctx, size: size, t: t, lift: 1, amp: 4.0, breath: 1.5, len: 80, speed: -1.7, opacity: 0.14)
            }
        }
    }

    private func drawWave(_ ctx: inout GraphicsContext, size: CGSize, t: Double,
                          lift: CGFloat, amp: CGFloat, breath: CGFloat,
                          len: CGFloat, speed: Double, opacity: Double) {
        // The height itself breathes slowly (amp ± breath), so even a still moment ripples.
        let a = amp + breath * CGFloat(sin(t * 0.9 + Double(len)))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 3 {
            let y = size.height - lift - a * CGFloat(sin(Double(x / len) * 2 * .pi + t * speed))
            p.addLine(to: CGPoint(x: min(x, size.width), y: y))
            x += 3
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        // ⚠️ A GRADIENT FILL, NOT A FLAT ONE — his screenshot from the live build: a flat white
        // wash gave the crest a hard edge, so the wave read as a separate lighter band glued to
        // the bottom of a flat green ("looks two separate"). The reference's bar reads as ONE
        // surface because its swells have no boundary. Filling the wave with a vertical gradient
        // that reaches ZERO just below its own highest possible crest deletes the edge: the swell
        // is brightest at the bar's bottom and dissolves into the green on the way up, and two
        // overlapping swells now blend instead of stacking a visible step.
        let top = size.height - lift - (amp + breath) - 2
        ctx.fill(p, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(opacity)]),
            startPoint: CGPoint(x: 0, y: top),
            endPoint: CGPoint(x: 0, y: size.height)))
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
