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
    // Owner audit 2026-10-06 #18: the tile's CORNER, not an offset — see CallService.pipCornerLeft.
    private var pipCornerLeft: Bool { get { call.pipCornerLeft } nonmutating set { call.pipCornerLeft = newValue } }
    private var pipCornerTop: Bool { get { call.pipCornerTop } nonmutating set { call.pipCornerTop = newValue } }
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // Front↔back switch, rebuilt on the reference implementation's mechanics (owner's order: no
    // blur, and never both feeds visible mid-switch). The OLD camera rotates the tile edge-on (or
    // dips fullscreen to black), HOLDS there through the capture restart — that hold is what hides
    // the gap — and swings back only when CallService.cameraSwitchFlip says the NEW camera is
    // delivering. Mirror and content swap while nothing is visible.
    @State private var flippingCamera = false   // a switch is in flight (double-tap guard + fallback reset)
    @State private var flipAngle: Double = 0    // tile: rotates OUT to ±90°, returns from the far side
    @State private var flipDim = false          // fullscreen local video: the crossfade reads as a dip to black
    // Owner audit 2026-10-06 (area 11): the 1.2s fallback of one switch used to land in the middle of
    // the NEXT one (flip, camera back at 0.5s, flip again at 0.9s: the first timer fired 0.3s into the
    // second switch and swung the tile back early). Each switch gets a number; a stale timer stands down.
    @State private var flipGeneration = 0
    // The ACCEPT hand-off (user report: "you feel your face left on big screen, [then] a moment when
    // it drops [to the] small one" — a hard cut). While true, the corner tile renders FULL SCREEN over
    // everything, holding the same local feed the big view just gave up; releasing it with a spring
    // shrinks your preview continuously into the corner, revealing the other person underneath —
    // FaceTime's connect transition. Live video the whole way; no snapshot, no branch swap.
    @State private var tileEntering = false
    /// Audit M-056, 2026-10-07: this screen showed MY ringing self-preview full screen, which is the
    /// only thing the accept hand-off exists to shrink away. Set while a video call rings out, spent
    /// by the hand-off. Without it the hand-off also ran when the OTHER camera came on mid-call (the
    /// tile newly appears then too), and blew my avatar or my black tile up over their new video.
    @State private var ringingPreviewShown = false

    // MARK: - Auto-hiding controls (the standard video-call behaviour)

    // On a video call the buttons get out of the way: they show when the call connects, fade out on
    // their own a few seconds later, and come back on a tap anywhere. Tap again to send them away.
    // Gated on CallService.everVideo, which is STICKY — a call that has been a video call keeps
    // behaving like one even after both cameras go off, so the controls do not start living on top of
    // the screen again the moment someone closes their camera.
    @State private var controlsVisible = true
    @State private var hideTask: DispatchWorkItem?
    @State private var showAddPeople = false   // "…" › Add people
    private static let autoHideAfter: TimeInterval = 5

    // Owner audit 2026-10-06 #19: never under VoiceOver. Hidden controls are taken out of the
    // accessibility tree (below), and a VoiceOver user has no way to find the tap-anywhere surface to
    // bring them back, so for them the buttons simply stay.
    private var autoHideEnabled: Bool { call.everVideo && connectedCall && !UIAccessibility.isVoiceOverRunning }

    private func armAutoHide() {
        hideTask?.cancel()
        guard autoHideEnabled else {
            // Voice call, or not connected yet: the controls simply stay.
            if !controlsVisible { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true } }
            return
        }
        // Owner audit 2026-10-06 #40: no clock while the Add people sheet is up. It used to run on
        // under the sheet, so dismissing it landed on a screen whose buttons had already gone. The
        // sheet's dismissal restarts it (`.onChange(of: showAddPeople)`).
        guard !showAddPeople else { return }
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
        flipGeneration &+= 1
        let generation = flipGeneration
        // Fallback: a camera that never comes back (hardware refusal) must not leave the tile
        // edge-on forever. The real return path lands first on every normal switch. Only THIS
        // switch's fallback may act (see flipGeneration).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard flippingCamera, flipGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.15)) { flipAngle = 0; flipDim = false }
            flippingCamera = false
        }
    }

    private var statusText: String {
        switch call.state {
        // Accepted beats ringing: the instant they tap Accept the label goes "Connecting…" — the
        // standard messenger order — while the SDP answer is still being built on their phone.
        case .outgoing:     return CallStageWords.progress(call) ?? ""   // M-055: one source of words
        // 2026-09-24 fix-all #107: no `.incoming` label. This screen is never up while a call is
        // incoming (`CallContainer.isActive` leaves that state out on purpose: the system's own
        // incoming-call screen answers it), so "Incoming…" could not be drawn. Decision: incoming
        // stays the system's screen; the dead label is removed rather than half-building a second one.
        // The weak-signal notice displaces the duration deliberately: while the camera is down, WHY it
        // is down is the only thing the user actually wants, and without it a paused camera reads as
        // the app being broken. The timer comes straight back when the link recovers.
        // Audit M-057, 2026-10-07: a call put on hold by a phone call also pauses the video, and it
        // was labelled "Video paused, weak signal", which blames the network for the user's own hold.
        // Hold says so; the weak-signal words are only for a real network pause.
        case .active:
            if call.isHeld { return "On hold" }
            return call.videoPausedForNetwork ? "Video paused, weak signal" : durationText
        case .reconnecting: return CallStageWords.progress(call) ?? ""
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
        // Audit 2026-09-24: a refused mic used to end here as "Couldn't reach them" / "Call failed".
        // Wording reused from the voice-message alert.
        if call.micDenied { return "Microphone access is off" }
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
                // The system broadcast picker, invisible: "..." › Share Screen presses its button
                // (CallService.toggleScreenShare -> ScreenSharePicker.show). It has to be in the window
                // for its sheet to present, so it is mounted, 1pt and transparent, not left out.
                ScreenSharePickerView()
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
                        // Owner audit 2026-10-06 #19: opacity 0 left them in the accessibility
                        // tree, so VoiceOver focused invisible buttons that did nothing.
                        .accessibilityHidden(!controlsVisible)
                    Spacer()
                    if showAvatar {
                        // WHOSE photo follows who is on the big screen, not always theirs.
                        AvatarView(name: showLocalFull ? call.myName : call.otherName,
                                   photoUrl: showLocalFull ? call.myPhotoUrl : call.otherPhotoUrl,
                                   size: 180)
                            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                            // No pulsing rings while Calling: the owner had them removed 2026-10-04.
                            .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
                            .frame(maxWidth: .infinity)    // guarantee horizontal centering
                            .allowsHitTesting(false)       // decoration: let the show/hide tap through
                        Spacer()
                    }
                    // Audit M-011, 2026-10-07: the camera was refused, so the camera button cannot do
                    // anything and the other side sees no video. Say where to fix it, just above the
                    // controls, in the status line's style. `cameraDenied` is set by CallService.
                    if call.cameraDenied {
                        Text("Allow camera access in Settings")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 10)
                            .opacity(controlsVisible ? 1 : 0)
                            .accessibilityHidden(!controlsVisible)
                            .allowsHitTesting(false)
                    }
                    controlBar
                        .frame(maxWidth: .infinity)        // centered control pill
                        .padding(.bottom, winInsets.bottom + 22)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)   // #19, as the top bar
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
            .onChange(of: call.state) { _, state in
                showControls()
                if state == .outgoing, call.cameraOn { ringingPreviewShown = true }   // M-056
            }
            .onAppear { if call.state == .outgoing, call.cameraOn { ringingPreviewShown = true } }
            .onChange(of: call.isVideo) { _, _ in showControls() }
            // #40: the sheet pauses the clock (see armAutoHide); closing it brings the controls
            // back and starts it again. #19: VoiceOver turned on mid-call brings hidden controls back.
            .onChange(of: showAddPeople) { _, up in
                if up { hideTask?.cancel() } else { showControls() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                showControls()
            }
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
        .sheet(isPresented: $showAddPeople) {
            AddPeopleSheet(alreadyIn: [AuthService.shared.uid ?? "", call.otherUid]) { people in
                // The sheet closes itself first; the move tears this screen down, so let the sheet
                // finish leaving before the cover under it goes too.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    CallService.shared.moveToGroup(adding: people)
                }
            }
        }
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
        if showLocalFull { return !(call.cameraOn || call.screenSharing) }   // my feed owns the big view
        return !hasRemote
    }

    // MARK: - Background (video feed, or avatar/gradient fallback)

    @ViewBuilder private func background(_ geo: GeometryProxy) -> some View {
        let full: RTCVideoTrack? = showLocalFull ? call.localVideoTrack
                                                 : (hasRemote ? call.remoteVideoTrack : nil)
        // Only show a fullscreen feed that is ACTUALLY LIVE. Otherwise hide the renderer (opacity 0) so
        // the shared Metal view doesn't keep its last frame on screen — that stale frame was YOUR frozen
        // ringing-preview showing as the background behind the avatar when the other camera is off.
        let canShow = full != nil && (showLocalFull ? (call.cameraOn || call.screenSharing) : hasRemote)
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
            (call.isVideo ? Color.black : (shownPalette.map { Color($0.page) } ?? Color.black))
                .animation(.easeOut(duration: 0.35), value: shownPalette?.key)
            if call.isVideo {
                // A shared screen is never mirrored (mine) and never cropped (theirs: shown whole).
                VideoRendererView(track: full,
                                  mirror: showLocalFull && call.usingFrontCamera && !call.screenSharing,
                                  fit: !showLocalFull && call.remoteScreenSharing)
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
            // The reference app's 0.2s shrink into the card (`CallPipMorph`).
            Button { CallPipMorph.minimize { call.minimized = true } } label: {
                // The minimise glyph rather than a bare chevron: this button shrinks the call
                            // into the pill, it does not dismiss or scroll anything.
                            topCircle("arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(CallControlStyle())
            .accessibilityLabel("Minimize call")   // owner audit 2026-10-06 #19

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
                            .accessibilityLabel("Muted")
                        // Owner audit 2026-10-06 #42: "Muted" used to replace the weak-signal notice
                        // outright, and that notice is the one thing that explains a frozen camera.
                        // Both apply → the slashed mic still says muted, the words say why the video
                        // stopped.
                        // M-057: hold is named as hold, not as a weak signal.
                        Text(call.isHeld ? "On hold"
                             : (call.videoPausedForNetwork ? "Video paused, weak signal" : "Muted"))
                            .font(.system(size: 15, weight: .medium))
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
                // Only once the call is really connected: moving a ringing call onto a
                // multi-person one would invite people to a conversation that never started.
                if CallFeatures.groupCalls {
                    Button { showAddPeople = true } label: { Label("Add people", systemImage: "person.badge.plus") }
                        .disabled(!(call.state == .active && call.connectedDate != nil))
                }
                // Same rule as Add people: a call that has not connected has nobody to show it to.
                // Starting opens the system's broadcast sheet; its countdown is the consent.
                Button { call.toggleScreenShare() } label: {
                    Label(call.screenSharing ? "Stop Sharing" : "Share Screen",
                          systemImage: call.screenSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                }
                // Audit M-165, 2026-10-07: STOPPING is never disabled. During "Reconnecting…" the
                // rule above greyed out Stop Sharing too, and the share could not be ended from here.
                .disabled(!call.screenSharing && !(call.state == .active && call.connectedDate != nil))
                Button(role: .destructive) { CallKitManager.shared.end() } label: { Label("End Call", systemImage: "phone.down.fill") }
            } label: { topCircle("ellipsis") }
            .buttonStyle(CallControlStyle())
            .accessibilityLabel("More options")   // #19
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
    /// The colour on the FIRST frame (owner, 2026-10-06: black first, their colour seconds later).
    /// `peerPalette` is filled by a task that runs after the screen is first drawn; until then the
    /// colour is read here from the caches the avatar itself is drawn from (memory hits, cheap).
    private var shownPalette: ProfilePalette? {
        if let peerPalette { return peerPalette }
        guard let url = call.otherPhotoUrl, !url.isEmpty else { return nil }
        if let warm = ProfilePalette.warm(url: url) { return warm }
        guard let shown = ProfilePhotoLoader.shared.cachedAvatar(url) else { return nil }
        return ProfilePalette.now(shown, url: url)
    }

    private func loadPeerPalette() async {
        guard let url = call.otherPhotoUrl, !url.isEmpty else { peerPalette = nil; return }
        if let warm = ProfilePalette.warm(url: url) { peerPalette = warm; return }
        // The avatar on this screen comes from the avatar loader's memory, which `warm` does not
        // read; take the colour from that same picture so both land on the first frame.
        if let shown = ProfilePhotoLoader.shared.cachedAvatar(url),
           let p = ProfilePalette.now(shown, url: url) { peerPalette = p; return }
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
        // The bounds move when the chrome toggles — the tile grows and its home rises (his 544
        // report: park the card at the top by hand, tap the screen, and the grown card slid off the
        // top edge). Owner audit 2026-10-06 #18: so the stored thing is the CORNER, and the offset is
        // worked out from it against the bounds of this very render. A stored offset fixed only one
        // direction (hidden → shown); shown → hidden left the tile 68pt off the side or mid-screen.
        let restOffset = CGSize(width: pipCornerLeft ? maxLeft : 0, height: pipCornerTop ? maxUp : 0)
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
                        .accessibilityLabel("Flip camera")   // owner audit 2026-10-06 #19
                        .padding(6)
                    }
                }
                .shadow(color: .black.opacity(tileEntering ? 0 : 0.45), radius: 14, y: 5)
                // Drag (min 10pt) repositions the window; a tap (no move) swaps the feeds. The offset
                // and the drag live in `PipTileDrag`, whose own state carries the finger — see there.
                .modifier(PipTileDrag(
                    rest: restOffset, maxLeft: maxLeft, maxUp: maxUp, entering: tileEntering,
                    // Owner audit 2026-10-06 #41: the hide clock fired mid-drag and the tile
                    // shrank under the finger. Stopped while a finger is down, restarted on release.
                    onBegin: { hideTask?.cancel() },
                    onSnap: { left, top in pipCornerLeft = left; pipCornerTop = top },
                    onFinish: { armAutoHide() }
                ))
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
            // M-056: only the first connect of a call that was showing my live camera full screen.
            // Round 2 (verify V3 N4), 2026-10-07: the flag is SPENT at the first tile appearance
            // whatever happens next. Checked together with `cameraOn`, a camera turned off while
            // ringing out (allowed since M-052) left it set, and the flash came back later in the call
            // the first time my camera came on with the tile newly showing.
            guard ringingPreviewShown else { return }
            ringingPreviewShown = false
            guard call.cameraOn, call.localVideoTrack != nil else { return }
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
            VideoRendererView(track: track,
                              mirror: isLocal && call.usingFrontCamera && !call.screenSharing,
                              fit: !isLocal && call.remoteScreenSharing)
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

    /// Audit M-052, 2026-10-07: the camera button worked only in `.active`, so during "Reconnecting…"
    /// (and while a video call rang out) there was no way to turn the camera OFF. Now: on or off while
    /// connected or reconnecting, and off (never on) while still ringing out. The service applies the
    /// same rule in `setMyCamera`. Still dimmed while my screen is shared (the share owns the video).
    private var cameraButtonEnabled: Bool {
        guard !call.screenSharing else { return false }
        switch call.state {
        case .active, .reconnecting: return true
        case .outgoing:              return call.cameraOn
        default:                     return false
        }
    }

    // MARK: - Control capsule (dark, icon-only, red end)

    private var controlBar: some View {
        HStack(spacing: 14) {
            // Labels: owner audit 2026-10-06 #19 — icon-only buttons read as "button" or the raw
            // symbol name under VoiceOver. Each says what a tap does now.
            callCircle(call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted,
                       label: call.isMuted ? "Unmute" : "Mute") { call.toggleMute() }
            // MY camera — turn it on/off freely (the other side just sees it, no
            // permission). When it can be pressed: see `cameraButtonEnabled` (M-052).
            callCircle(call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn,
                       label: call.cameraOn ? "Turn camera off" : "Turn camera on") { call.toggleCamera() }
                // Dimmed while my screen is shared too: the share owns my video until it stops, and
                // stopping brings the camera back exactly as it was.
                .disabled(!cameraButtonEnabled)
                .opacity(cameraButtonEnabled ? 1 : 0.4)
            // Flip front/back only while my camera is on (and actually showing, not a shared screen).
            if call.cameraOn && !call.screenSharing {
                callCircle("arrow.triangle.2.circlepath", active: false, label: "Flip camera") { flipCamera() }
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
                    .accessibilityHidden(true)   // #19: the picker on top is the one control
                // Invisible native picker on top — owns the tap, opens the system route sheet.
                AudioRoutePicker().frame(width: 52, height: 52).clipShape(Circle())
                    .accessibilityLabel("Audio output")
            }
        } else {
            // One steady speaker glyph; ON = filled white circle (the slash icon looked like
            // something was muted even when it wasn't).
            callCircle("speaker.wave.2.fill", active: call.isSpeaker, label: "Speaker") { call.toggleSpeaker() }
                .accessibilityAddTraits(call.isSpeaker ? .isSelected : [])
        }
    }

    private func callCircle(_ icon: String, active: Bool, label: String, _ action: @escaping () -> Void) -> some View {
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
        .accessibilityLabel(label)
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
        .accessibilityLabel("End call")   // #19
    }
}

/// The corner tile's position and drag. Home is the BOTTOM-trailing corner, so travel is left
/// (negative width) and UP (negative height), within bounds the call screen computes from the live
/// tile size.
///
/// Owner audit 2026-10-06 (area 11): the live drag used to be written into CallService, which the
/// whole call screen observes, so every drag frame re-ran the entire CallView body (the video
/// layers, the scene scan for insets, the PiP feeds). It is this modifier's own @State now, which
/// re-renders only the modifier; the call screen hears about the drag once, when it lands.
/// #18: the drag starts from `rest`, the corner worked out against TODAY's bounds, never from an
/// offset stored against older ones (that was the dead zone and jump after the chrome toggled).
struct PipTileDrag: ViewModifier {   // also the two-person group call's tile (GroupCallDuoView)
    let rest: CGSize
    let maxLeft: CGFloat
    let maxUp: CGFloat
    let entering: Bool
    let onBegin: () -> Void
    let onSnap: (_ left: Bool, _ top: Bool) -> Void
    let onFinish: () -> Void

    /// Where the finger has the tile, or nil at rest.
    @State private var live: CGSize?

    private func clamped(_ s: CGSize) -> CGSize {
        CGSize(width: min(0, max(maxLeft, s.width)), height: max(maxUp, min(0, s.height)))
    }

    func body(content: Content) -> some View {
        content
            .offset(entering ? .zero : (live.map { clamped($0) } ?? rest))
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { v in
                        if live == nil { onBegin() }
                        live = clamped(CGSize(width: rest.width + v.translation.width,
                                              height: rest.height + v.translation.height))
                    }
                    .onEnded { v in
                        // SNAP TO THE NEAREST CORNER (standard PiP): the tile must never rest
                        // mid-screen. #41: decided on where the THROW was going, not where the finger
                        // stopped, so a short fast flick toward another corner lands there.
                        // `predictedEndTranslation` equals the plain translation on a slow release.
                        let thrown = clamped(CGSize(width: rest.width + v.predictedEndTranslation.width,
                                                    height: rest.height + v.predictedEndTranslation.height))
                        let left = thrown.width < maxLeft / 2
                        let top = thrown.height < maxUp / 2
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            onSnap(left, top)
                            live = nil
                        }
                        onFinish()
                    }
            )
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
    /// Audit M-087, 2026-10-07: a multi-person call that is up OR still joining. The card, its tap
    /// and the restore cover all follow this, so a call minimized mid-join can be brought back.
    private var groupLive: Bool { group.isActive || group.connecting }

    private var isActive: Bool {
        switch call.state {
        case .outgoing, .active, .reconnecting: return true
        // Audit M-012, 2026-10-07: `.ended` counts only for a call this phone was already SHOWING,
        // on the cover or on the card. Keyed on state alone, a callee who never answered (the caller
        // cancelled, or it rang out) had the black call cover hard-cut over whatever they were doing
        // for the 1s end label, with the caller's wording ("Couldn't reach them") and the keyboard
        // dropped. A call that was on screen keeps its end label exactly as before. The service's end
        // path is untouched; this only decides whether the root puts anything up for it.
        case .ended: return coverUp || call.minimized
        default: return false
        }
    }

    // EVERY minimized call gets the floating card — voice ones too. The green bar that used to sit
    // across the top for voice calls is gone (owner, 2026-08-23, reference in hand): a bar eats the
    // top of whatever screen you moved on to, and it duplicated what the chat list now says by
    // itself. The list carries the words ("Active call", green, top row) and the card carries the
    // faces and the controls, which is the split the reference app uses.
    private var showsFloatingCall: Bool { isActive && call.minimized }
    /// Should the full call screen be up? The cover follows it through `coverUp`, set inside a
    /// no-animation transaction so the cut is instant both ways.
    private var wantsCover: Bool { isActive && !call.minimized }
    @State private var coverUp = false
    /// Audit M-032, 2026-10-07: the call screen really reached the window (its own appear), and the
    /// number of the latest request for it, so a late check only judges the request it belongs to.
    @State private var coverShown = false
    @State private var coverAsk = 0
    @State private var groupRestoreShown = false   // the same pair for the group restore cover
    @State private var groupRestoreAsk = 0
    /// Shared by the cover's zoom and the card. See `CallZoomNamespaceKey`.
    @Namespace private var callZoom

    var body: some View {
        content
        // ONGOING MULTI-PERSON CALL, swiped down: a live call (mic possibly hot) must NEVER be
        // invisible. It gets the same floating card a 1:1 call does (owner, 2026-10-04: the green
        // full-width "Return to call" bar was the old UI). Tapping it clears `minimized`, and the
        // onChange below re-presents the call screen from HERE, so it works from any screen.
        .overlay {
            // Audit M-087, 2026-10-07: also while the join is still in flight. Minimized during
            // "Connecting…" there was no card at all (`isActive` waits for the room), so a call
            // that was joining, mic about to open, had nothing on screen pointing back to it.
            if groupLive && group.minimized { GroupFloatingCallWindow() }
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
        // An invite to a multi-person call, over whatever screen is open. Last overlay = top-most.
        .overlay { IncomingGroupCallLayer() }
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
            get: { coverUp },
            set: { presented in
                guard !presented else { return }
                coverUp = false
                if isActive { call.minimized = true }   // any other way out means minimize
            }
        )) {
            // ⛔ ONE WAY IN FOR EVERY CALL (owner, 2026-10-04: "do not make the call page appear as if
            // it is expanding directly from the Call button"). This REPLACES the 2026-08-20 zoom that
            // grew the screen out of whichever button was pressed. Every dial site (chat header,
            // profile, Calls tab, card restore, incoming answer) lands here, and nothing about the
            // way in depends on where the tap came from.
            //
            // ⛔ NO MOTION AT ALL, AND THAT IS THE REFERENCE APP'S PRESENTATION (owner, 2026-10-04,
            // second report: "still not like" it). Read from its source (WindowManager.startCall,
            // CallUIAdapter): the call screen is pushed `animated: false` into a call WINDOW of its
            // own, which is made key and visible while the app's window is hidden in the same beat.
            // There is no fade, no scale and no slide: the app is simply replaced by the black call
            // screen. The first attempt here (scale 1.04 + fade, from another messenger) was the
            // wrong reference. The cover goes up and down inside a transaction with animations
            // disabled, which is that same hard cut.
            //
            // ⛔ EXCEPT BETWEEN THE SCREEN AND ITS CARD (owner, 2026-10-05: minimize "just call page
            // make zoom out", and tapping the card "make it smooth, opening there like zoom in").
            // Minimizing zooms the screen down into the card and tapping the card zooms it back
            // out. Placing a call and ending one stay hard cuts; see `presentCover(animated:)`.
            // ⛔ 2026-10-06: the system zoom to and from the card is gone. The cover is a hard cut
            // both ways now, and the reference app's 0.2s frame shrink/grow is drawn around it by
            // `CallPipMorph`; the probe hands a pending restore the presented view.
            CallView()
                .background(CallPipMorphProbe())
                .presentationBackground(.black)
                .onAppear { coverShown = true }      // M-032: see `askForCover`
                .onDisappear { coverShown = false }
        }
        .onAppear { if wantsCover { presentCover(animated: false) } }
        .onChange(of: wantsCover) { _, want in
            // In: animated only when coming back from the card (it has existed this call).
            // Out: animated only when minimizing; a call that has ended just goes.
            // Both ways a hard cut; the card flight is `CallPipMorph`'s (2026-10-06).
            // Audit M-147, 2026-10-07: wanted back while still shrinking into the card (their camera
            // came on mid-flight) → the flight's overlay goes first, or it draws over the call screen.
            if want { CallPipMorph.cancelMinimizeFlight(); presentCover(animated: false) } else { dismissCover(animated: false) }
        }
        // THE SAME HOLE ON THE GROUP SIDE. Tapping the bar clears `minimized` and presents this;
        // GroupCallView's own swipe-down sets `minimized` back to true, but a swipe on the COVER
        // itself only closes the cover, and `minimized` was already false — so the group call lost
        // its return bar too. Restoring the flag on dismiss puts the bar back either way.
        .fullScreenCover(isPresented: $showGroupRestore, onDismiss: {
            if groupLive { group.minimized = true }
        }) {
            // The probe picks up a pending restore from the card (`CallPipMorph.restore`), so the
            // group call grows out of its card like a 1:1 call instead of cutting in (owner,
            // 2026-10-07: "the opening animation is too fast").
            GroupCallView().background(CallPipMorphProbe())
                .onAppear { groupRestoreShown = true }      // M-032, as the 1:1 cover
                .onDisappear { groupRestoreShown = false }
        }
        // 2026-09-24 decision D26: clearing `minimized` from anywhere else (the Calls tab row) brings
        // the group call forward the same way the bar's tap does. Only `disconnect()` also clears it,
        // and by then the call is no longer active.
        .onChange(of: group.minimized) { _, minimized in
            // Same hard cut as the 1:1 cover (the reference app uses one call window for both).
            if !minimized, groupLive, !showGroupRestore {
                CallPipMorph.cancelMinimizeFlight()   // M-147, as the 1:1 cover
                presentGroupRestore()
            }
        }
        // A multi-person (ad-hoc or link) call's FIRST screen is put up by `IncomingGroupCallLayer`
        // (it follows `presentsRoomScreen`). This root only re-presents it from the return bar.
    }

    /// Hard cut in: the system's slide switched off, nothing of ours in its place. The keyboard is
    /// put away first, as the reference app does by hiding the whole app window.
    /// `animated` lets the system zoom run (from the card); otherwise it is the hard cut.
    private func presentCover(animated: Bool) {
        guard !coverUp else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // Audit M-032, 2026-10-07: a cover asked for while something else is still on its way in or
        // out (a sheet closing on the same tap, a notification tap mid-transition) is dropped by
        // UIKit. `coverUp` was already true, so nothing retried, and `minimized` was false, so there
        // was no card either: a live call with nothing on screen. Wait for the top to settle first
        // (the same check `IncomingGroupCallLayer` makes, capped at 0.8s); with nothing in motion this
        // goes straight on, so the usual hard cut is unchanged.
        if Self.topIsMoving() {
            Task { @MainActor in
                for _ in 0..<16 {
                    guard Self.topIsMoving() else { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard wantsCover, !coverUp else { return }
                askForCover(animated: animated)
            }
            return
        }
        askForCover(animated: animated)
    }

    private func askForCover(animated: Bool) {
        if animated { coverUp = true } else { InstantCover.run { coverUp = true } }
        // M-032, the net: UIKit can still refuse (a sheet that is up and staying). If the call screen
        // has not appeared half a second later, give the call back its card instead of nothing. The
        // card is what a minimize leaves, and tapping it asks again.
        coverAsk &+= 1
        let ask = coverAsk
        // Judged only in the foreground: a cover asked for while the app is in the background (their
        // camera came on, `CallService` clears `minimized` so the return lands on the call) may be
        // put up only when the app comes back, and must not be turned into a card before that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard ask == coverAsk, coverUp, !coverShown,
                  UIApplication.shared.applicationState == .active else { return }
            coverUp = false
            switch call.state {
            case .outgoing, .active, .reconnecting: call.minimized = true
            default: break
            }
        }
    }

    /// A presentation or dismissal is in flight at the top of the stack (M-032).
    @MainActor private static func topIsMoving() -> Bool {
        guard let top = WebLink.topViewController() else { return false }
        return top.isBeingDismissed || top.isBeingPresented
            || top.presentingViewController?.isBeingDismissed == true
            || top.transitionCoordinator != nil
    }

    /// M-032 on the group side: the same wait for a settled top, the same hard cut, and the same net.
    /// A refused restore used to leave the group call with `minimized` false (so no card) and no
    /// screen; it now falls back to the card.
    private func presentGroupRestore() {
        Task { @MainActor in
            for _ in 0..<16 {
                guard Self.topIsMoving() else { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !group.minimized, groupLive, !showGroupRestore else { return }
            InstantCover.run { showGroupRestore = true }
            groupRestoreAsk &+= 1
            let ask = groupRestoreAsk
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard ask == groupRestoreAsk, showGroupRestore, !groupRestoreShown,
                  UIApplication.shared.applicationState == .active else { return }
            showGroupRestore = false
            if groupLive { group.minimized = true }
        }
    }

    /// Out, the same way: the zoom into the card when minimizing, a hard cut when the call is over.
    private func dismissCover(animated: Bool) {
        guard coverUp else { return }
        if animated { coverUp = false; return }
        InstantCover.run { coverUp = false }
    }
}

/// ⛔ THE CALL SCREEN APPEARS, IT DOES NOT SLIDE UP — owner, 2026-10-06, screenshots of the screen
/// half way up over the profile and over the chat: "the call page appears by sliding up from the
/// bottom ... make it work exactly like" the reference app, which shows its call screen in one cut.
///
/// A no-animation transaction alone did not stop the system cover's slide on device. UIKit's own
/// switch is turned off as well, for the beat in which SwiftUI hands the cover to UIKit, so the
/// presentation's animation block runs at once. Turned back on right after, so nothing else in the
/// app is held still.
@MainActor
enum InstantCover {
    private static var depth = 0

    static func run(_ change: () -> Void) {
        depth += 1
        UIView.setAnimationsEnabled(false)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { change() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            depth = max(0, depth - 1)
            if depth == 0 { UIView.setAnimationsEnabled(true) }
        }
    }

    /// The card flight (`CallPipMorph`) starts inside that beat and must move, so it ends the hold
    /// first. The cover has been handed to UIKit by then.
    static func release() {
        guard depth > 0 else { return }
        depth = 0
        UIView.setAnimationsEnabled(true)
    }
}

// MARK: - The zoom between the call screen and the card

/// The root holds the namespace (the cover is declared there) and hands it to the card through the
/// environment, because the two are nowhere near each other in the view tree.
private struct CallZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var callZoomNamespace: Namespace.ID? {
        get { self[CallZoomNamespaceKey.self] }
        set { self[CallZoomNamespaceKey.self] = newValue }
    }
}

enum CallZoomSource {
    /// The floating card: the ONLY zoom source. A call is never zoomed out of the button that
    /// placed it (owner, 2026-10-04); it zooms only between the screen and its own card.
    static let card = "call.card"
}

// MARK: - FloatingCallWindow

// The minimized VIDEO call: a small draggable window carrying the whole call layout — the big feed
// plus the corner tile, following the same big/small choice as the call screen. Tap it to go back.
struct FloatingCallWindow: View {
    private var call: CallService { CallService.shared }
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

    /// The call screen's zoom partner: the screen shrinks into this card and grows back out of it.
    /// Nil is a working configuration (the zoom falls back to a plain presentation).
    @Environment(\.callZoomNamespace) private var zoomNamespace

    @ViewBuilder private func zoomAnchored(_ content: some View) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: CallZoomSource.card, in: zoomNamespace)
        } else {
            content
        }
    }

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
    @State private var insetsCache: UIEdgeInsets

    private var insets: UIEdgeInsets { insetsCache }

    /// Owner audit 2026-10-06 #43: resolved HERE, before the first layout, not in `onAppear`. Starting
    /// from `.zero` laid the card out once under the notch (y = 8) and only then moved it down, and the
    /// minimize flight, which reads the card's frame 30ms after the cover goes, could land on that
    /// first position and see the real card appear 59pt lower. This view is rebuilt on every
    /// minimize, so that was every minimize, not just the first.
    init() {
        _insetsCache = State(initialValue: Self.resolveInsets())
    }

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
                morphAnchored(zoomAnchored(window
                    // Where the minimize/restore flight lands and starts (`CallPipMorph`). At rest
                    // `dragLive` is zero, which is the only time a flight reads it.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { call.cardFrame = $0 }
                    .onDisappear { call.cardFrame = .zero }
                    .opacity(call.cardHiddenForMorph ? 0 : 1)
                    .offset(dragLive)))
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
                                // out of the reference implementation's own edge-deceleration: they take
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
                        // Audit M-146, 2026-10-07: the card stays up for the 1s end label, and a tap in
                        // that second grew a dead call back to full screen. Over is over: ignored.
                        guard call.state != .ended, call.state != .idle else { return }
                        // The reference app's 0.2s grow out of the card (`CallPipMorph`).
                        CallPipMorph.restore { call.minimized = false }
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
        // Audit M-053, 2026-10-07: the PiP source view lived only on the video CARD, so a video call
        // parked as this tab had none, and leaving the app then had no window to detach into: the
        // capture was interrupted and the other side dropped to the avatar. The tab carries one too
        // (only one of card / tab exists at a time, so there is still a single source).
        .background {
            if call.isVideoCall {
                CallView.CallPiPHost(feeds: call.pipFeeds).allowsHitTesting(false)
            }
        }
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
        // Audit M-055, 2026-10-07: a clock only while the call screen would show one. `connectedDate`
        // stays set through "Reconnecting…" and the end label, so the tab kept counting on a call
        // that was frozen or already over.
        if call.state == .active, CallStageWords.progress(call) == nil, let start = call.connectedDate {
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
            if call.isVideoCall { videoWindow } else { voiceWindow }
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
            if call.isVideoCall, let stage = stageLabel {
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
        // 2026-09-24 fix-all #107: `.incoming` removed here too; the card is never shown in that state.
        case .ended:        return "Call ended"
        // Audit M-055, 2026-10-07: the same words as the call screen, from the same helper. An
        // accepted call still forming its connection (`.active`, no `connectedDate`) used to fall
        // to nil here, so the card looked connected while the screen said "Connecting…".
        default:            return CallStageWords.progress(call)   // nil = connected, the faces carry it
        }
    }

    // The minimized VOICE call. Connected: the two people stacked, them on top, you underneath —
    // the shape the reference uses. Still ringing: ONE face, theirs, with the stage under it, which
    // is also what the reference does before somebody answers.
    // A voice call has no picture of its own, so the card says WHO you are on with instead of a
    // phone glyph. On the person's own colour, the same one the full call screen paints: the card
    // is that screen shrunk, and it went black on the way down (owner, 2026-10-07). Black only when
    // there is no photo to take a colour from, which is the screen's rule too.
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
            .background(voiceCardColor)
        } else {
            VStack(spacing: 0) {
                voicePanel(name: call.otherName, photoUrl: call.otherPhotoUrl,
                           avatar: 46, level: call.remoteLevel)
                Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
                voicePanel(name: call.myName, photoUrl: call.myPhotoUrl,
                           avatar: 38, level: call.localLevel)
            }
            .background(voiceCardColor)
        }
    }

    /// The colour the full screen is showing for this person (`CallView.shownPalette`), read from the
    /// same caches that screen has already filled by the time anyone can minimize it: the palette's
    /// own, then the avatar loader's picture. Memory lookups only, safe in a body.
    private var voiceCardColor: Color {
        guard let url = call.otherPhotoUrl, !url.isEmpty else { return .black }
        if let warm = ProfilePalette.warm(url: url) { return Color(warm.page) }
        if let shown = ProfilePhotoLoader.shared.cachedAvatar(url),
           let p = ProfilePalette.now(shown, url: url) { return Color(p.page) }
        return .black
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
                VideoRendererView(track: big,
                                  mirror: feeds.mirrorBig && !call.screenSharing,
                                  fit: call.remoteScreenSharing && big === call.remoteVideoTrack)
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
                        VideoRendererView(track: tile,
                                          mirror: feeds.mirrorTile && !call.screenSharing,
                                          fit: call.remoteScreenSharing && tile === call.remoteVideoTrack)
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

// MARK: - CallStageWords

/// Audit M-055, 2026-10-07: ONE place that says what a 1:1 call is doing, read by the call screen,
/// the floating card and the side tab, so minimizing never renames the stage or starts a clock the
/// screen is not showing. Returns nil only for a connected call that is simply counting.
enum CallStageWords {
    static func progress(_ call: CallService) -> String? {
        switch call.state {
        // Accepted beats ringing: the instant they tap Accept the label goes "Connecting…".
        case .outgoing:     return call.calleeAccepted ? "Connecting…" : (call.calleeRinging ? "Ringing…" : "Calling…")
        // Signalled but no media yet (the callee right after Accept): not connected, so no clock.
        case .active:       return call.connectedDate == nil ? "Connecting…" : nil
        case .reconnecting: return "Reconnecting…"
        default:            return nil
        }
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
