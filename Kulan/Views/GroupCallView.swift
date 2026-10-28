import SwiftUI
import LiveKit
import AVFoundation

// Group call screen: header, the stage (Views/GroupCall/, owner spec §8-16), frosted-capsule
// controls to match the 1:1 call UI. ⛔ Owner, 2026-10-06: the header and the controls capsule stay
// exactly as they are; only the stage between them was rebuilt. The stage object walks the LiveKit
// room once for the tiles, the subtitle and the people sheet, so they all agree.
//
// Owner, 2026-10-06 (group call build plan, the screen package): this file is where the pieces the
// other packages build are put on screen. The one change to the capsule is the "…" button he
// allowed (five buttons, spacing 12). Everything else here is placement and the chrome's hide rule:
//
//   alone (joined)      GroupCallDuoView, my camera edge to edge
//   two people          GroupCallDuoView, the 1:1 look
//   three or more       GroupCallStagePager (the grid; a tapped person large)
//   under the header    GroupCallStatusBanner, GroupCallTopToast, GroupCallRaisedHandsPill
//   above the controls  GroupCallReactionsOverlay, CallLinkRequestStack, GroupCallMoreMenu
struct GroupCallView: View {
    @ObservedObject private var service = GroupCallService.shared
    // One stage for the life of this screen; the people sheet shares it (same speaker, same pin).
    @StateObject private var stage = GroupCallStage(room: GroupCallService.shared.room)
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    // `body` is a chain of short steps (layers -> screen -> watched -> presented -> synced), each a
    // few modifiers long: the type checker gave up on one long body here once (2026-10-06). Keep
    // any new modifier in the step it belongs to, and keep closures to one call.
    var body: some View { synced }

    // MARK: - Layers

    private var layers: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The system broadcast picker, invisible: Share Screen presses its button
            // (GroupCallService.toggleScreenShare -> ScreenSharePicker.show). It has to be in the
            // window for its sheet to present (owner 2026-10-23, share did nothing).
            ScreenSharePickerView()
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            frontLayer
            groupWaitingLayer
            hiddenChromeCatcher   // UNDER the chrome stack: see its note
            chromeStack
            moreLayer
        }
    }

    /// Alone or two people: the 1:1 call's look, edge to edge under the chrome (GroupCallDuoView).
    @ViewBuilder
    private var frontLayer: some View {
        if let f = front {
            GroupCallDuoView(stage: stage, local: f.local, remote: f.remote,
                             swapped: $duoSwapped, chromeVisible: chromeVisible, insets: winInsets,
                             onBackgroundTap: toggleChrome,
                             onTileTouch: { hideTask?.cancel() },
                             onTileRelease: armAutoHide,
                             onShowChrome: showChrome,
                             onFlipCamera: { service.flipCamera() })
                .environment(\.groupCallIAmSharing, service.screenSharing)
                .transition(.opacity)
            if f.remote == nil, !service.isGroupChatCall {
                // Alone in a call I started: who is being rung, over the alone view. On a clock,
                // because the ring window ends by time alone.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ringingLayer(at: ctx.date, myVideo: f.local.hasVideo)
                }
            }
        }
    }

    /// The ringing screen (owner, 2026-10-07, plan #4), nothing once nobody is being rung.
    @ViewBuilder
    private func ringingLayer(at now: Date, myVideo: Bool) -> some View {
        let rung = service.ringingMembers(at: now)
        if !rung.isEmpty {
            GroupCallRingingView(people: rung.map { .init(name: $0.name, photoUrl: $0.photoUrl) },
                                 overVideo: myVideo)
                .transition(.opacity)
        }
    }

    /// Owner 2026-10-27: a group chat's call showed four screens in its first two seconds (my own
    /// photo while connecting, then the alone view, then the rung people's photo and colour, then
    /// the same again in the server's order). Now one screen, the group's photo on black, from the
    /// tap until somebody comes, and again once everyone has left. My camera on: my camera instead,
    /// as the reference app does.
    private var groupWaiting: Bool {
        guard service.isGroupChatCall, !service.cameraOn else { return false }
        switch service.joinState {
        case .joined: return remoteCount == 0
        case .joining: return true
        case .notJoined: return service.connecting
        case .pending: return false
        }
    }

    @ViewBuilder
    private var groupWaitingLayer: some View {
        if groupWaiting {
            // On a clock, because the ring minute ends by time alone.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                GroupCallRingingView(people: [.init(name: service.callTitle, photoUrl: service.groupPhotoUrl)],
                                     overVideo: false,
                                     subtitle: service.callingNow(at: ctx.date) ? "Calling…" : nil,
                                     plainGround: true)
            }
            .transition(.opacity)
        }
    }

    private var chromeStack: some View {
        VStack(spacing: 16) {
            headerBar
            // Edge to edge: the stage keeps its own 6pt inset (the reference app's grid). Drawn
            // UNDER the header (zIndex): the stage now runs up behind it (`middle`).
            middle.zIndex(-1)
            bottomBar
        }
        .padding(.vertical, 10)
    }

    /// How far the stage reaches up past its slot to the top of the screen: the safe top, the
    /// stack's 10pt padding, the header and the 16pt gap under it.
    private var stageLift: CGFloat { winInsets.top + 10 + headerHeight + 16 }

    /// Audit M-101, 2026-10-07: with the stage running up behind the header (the full-screen stage
    /// the owner asked for, 2026-10-07 plan #1), a top-row tile's badges and the focus tile's
    /// "Pinned" / "Presenting" label sat under the status bar and the Dynamic Island. The stage
    /// stays full screen; only those top marks move down, measured from the screen's top edge:
    /// under the header while it shows, under the status bar while the chrome is away.
    /// Nothing to clear any more: the stage starts below the header (owner 2026-10-28).
    private var topClearance: CGFloat { 0 }

    private var headerBar: some View {
        header.padding(.horizontal, 14)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .accessibilityHidden(!chromeVisible)
    }

    /// The people asking to join a link call (the creator's cards, nothing when nobody waits) and
    /// the controls under them. The cards are not part of the hiding chrome: while one shows, the
    /// chrome stays up anyway (`chromeHeld`).
    private var bottomBar: some View {
        VStack(spacing: 0) {
            CallLinkRequestStack()
                .padding(.horizontal, 14)
                .padding(.bottom, requestCardShowing ? 12 : 0)
            sharePill
                .padding(.bottom, ((service.screenSharing && front != nil) || service.sharePending) ? 12 : 0)
                .animation(.easeInOut(duration: 0.2), value: service.screenSharing)
                .animation(.easeInOut(duration: 0.2), value: service.sharePending)
            controls.padding(.horizontal, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .accessibilityHidden(!chromeVisible)
        }
    }

    /// ⛔ YOU ARE SHARING, SAID ON THE SCREEN — owner 2026-10-28: he shared his screen in a group
    /// call without knowing it; only the share button's white fill said so. The 1:1 call's signs
    /// (`CallView.sharePill`): "Starting…" while the share comes up, then one red Stop Sharing pill
    /// above the controls for as long as it runs, shown with the controls hidden too.
    @ViewBuilder private var sharePill: some View {
        // Live, the Stop Sharing button is inside the large sharing card (GroupCallSharingCard); this
        // stays for the two-person look and anywhere the card is not on screen.
        if service.screenSharing && front != nil {
            Button {
                Haptics.impact(.light)
                service.toggleScreenShare()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 14, weight: .semibold))
                    Text("Stop Sharing").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Color(.systemRed), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop sharing screen")
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if service.sharePending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Starting…").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .liquidGlass(Capsule(), interactive: false)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .accessibilityElement(children: .combine)
        }
    }

    /// Group stage with the chrome away: a tap where the header or the controls were brings them
    /// back. It sits UNDER the chrome stack, so it only gets the taps that stack lets through (the
    /// hidden header and controls take none). The stage itself answers its own first tap
    /// (`stageArea`'s high-priority tap), which leaves its swipe between the grid and the speaker
    /// page working while the chrome is away; a catcher over the whole screen swallowed that swipe.
    /// Alone / two people, GroupCallDuoView has the 1:1 screen's own tap surface and this is not drawn.
    @ViewBuilder
    private var hiddenChromeCatcher: some View {
        if !chromeVisible && front == nil {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { showChrome() }
                .accessibilityLabel("Show call controls")
                .accessibilityAddTraits(.isButton)
        }
    }

    /// The "…" panel just above the capsule, over a clear layer that closes it on a tap outside.
    @ViewBuilder
    private var moreLayer: some View {
        if showMore {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { showMore = false }
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                // Under the header now, where its button is (Kasim 2026-10-22).
                GroupCallMoreMenu(onClose: { showMore = false })
                    .padding(.top, Self.moreMenuDrop + headerHeight)
                    .padding(.trailing, 14)
            }
            .transition(.opacity)
        }
    }
    /// The header's top padding (10) and an 8pt gap: the panel hangs under the header.
    private static let moreMenuDrop: CGFloat = 18

    // MARK: - Screen (layout switches and the hide clock's own triggers)

    /// The screen and its alone / two-person behaviour, apart from `body` so neither is too long
    /// for the type checker (it gave up on a long body here once, 2026-10-06).
    private var screen: some View {
        layers
            // 2 <-> 3 people (and alone <-> the stage): one cross-fade between the 1:1 look and the
            // group stage; the shorter plain fade with Reduce Motion.
            .animation(frontFade, value: frontKind)
            .animation(GroupCallMotion.fade, value: showMore)
            .background(insetsReader)
            .onChange(of: frontKind) { _, kind in frontChanged(kind) }
            .onChange(of: duoHasVideo) { _, video in duoVideoChanged(video) }
            .onChange(of: service.joinState) { _, state in joinStateChanged(state) }
            .onAppear { armAutoHide() }
            .onDisappear { hideTask?.cancel() }
    }

    private var frontFade: Animation {
        reduceMotion ? GroupCallMotion.fade : .easeInOut(duration: 0.3)
    }

    private var insetsReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { winInsets = geo.safeAreaInsets }
                .onChange(of: geo.safeAreaInsets) { _, v in winInsets = v }
        }
    }

    private func frontChanged(_ kind: Int) {
        if kind != 2 { duoSwapped = false }
        showChrome()
    }

    /// Audit M-100, 2026-10-07: both cameras off hides the corner tile, the only way to swap back,
    /// so a swap made earlier is dropped then (GroupCallDuoView also ignores it without the tile).
    private func duoVideoChanged(_ video: Bool) {
        if !video { duoSwapped = false }
        showChrome()
    }

    private func joinStateChanged(_ state: GroupJoinState) {
        if state != .joined { showMore = false }
        showChrome()
    }

    /// What brings the chrome back: someone joined or left, a new request to join, the connection
    /// dropped, a short note arrived, VoiceOver was switched on; and anything that holds it up
    /// (a sheet, the "…" panel, a request card, the remove question) opening or closing.
    private var watched: some View {
        screen
            .onChange(of: remoteCount) { _, _ in showChrome() }
            .onChange(of: service.pendingRequests.count) { _, _ in showChrome() }
            .onChange(of: isReconnecting) { _, _ in showChrome() }
            .onChange(of: service.toast) { _, toast in toastChanged(toast) }
            .onChange(of: chromeHeld) { _, _ in showChrome() }
            .onReceive(Self.voiceOverChanged) { _ in showChrome() }
    }

    private static let voiceOverChanged = NotificationCenter.default
        .publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)

    /// A note arriving brings the chrome back; the note clearing itself must not (it would undo a
    /// tap that hid the chrome three seconds earlier).
    private func toastChanged(_ toast: String?) {
        if toast != nil { showChrome() }
        if let toast { accessCheck(after: toast) }
    }

    // MARK: - Mic / camera access (A12, 2026-10-23)

    private enum AccessOff { case mic, camera }
    /// A refused microphone or camera, asked in a centred alert with a way to Settings (the 1:1
    /// call's rule) instead of a toast that goes by while nobody hears me.
    @State private var accessOff: AccessOff?

    private static var micDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }
    private static var cameraDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    /// The service says a mic or camera switch failed (a toast); when the cause is access turned off,
    /// the alert says where to fix it.
    private func accessCheck(after toast: String) {
        let t = toast.lowercased()
        if t.contains("microphone"), !service.micOn, Self.micDenied { accessOff = .mic }
        else if t.contains("camera"), !service.cameraOn, Self.cameraDenied { accessOff = .camera }
    }

    private func micTapped() {
        if !service.micOn, Self.micDenied { accessOff = .mic; return }
        service.toggleMic()
    }

    private func cameraTapped() {
        if !service.cameraOn, Self.cameraDenied { accessOff = .camera; return }
        service.toggleCamera()
    }

    private var accessOffShown: Binding<Bool> {
        Binding(get: { accessOff != nil }, set: { if !$0 { accessOff = nil } })
    }
    private var accessOffTitle: String {
        accessOff == .camera ? "Camera Access Is Off" : "Microphone Access Is Off"
    }
    private var accessOffMessage: String {
        accessOff == .camera ? "Allow Kulan to use the camera in Settings so others can see you."
                             : "Allow Kulan to use the microphone in Settings so others can hear you."
    }

    // MARK: - Alerts, sheets, lifetime

    private var presented: some View {
        watched
            // Always dark, for the same reason the 1:1 call is — see `CallView`. A call is drawn for a
            // dark ground whatever the phone is set to.
            .environment(\.colorScheme, .dark)
            .onChange(of: service.activeCid) { _, cid in if cid == nil { dismiss() } }
            // owner audit 2026-10-06 #4: swiped away while still connecting. Three different covers
            // present this screen (chat, group info, the root layer) and only one had an onDismiss, so
            // the join carried on into a live call with no screen and no card. Leaving is decided in
            // one place; a live call is untouched here (its covers minimize it).
            .onDisappear { screenGone() }
            // 2026-09-24 decision D25: a start that failed or was refused says so, and OK closes the
            // screen. Held until the cover has finished coming up: a refusal lands within the same beat
            // as the tap, and an alert asked for mid-presentation is dropped by UIKit.
            .task { await settle() }
            .alert(noticeTitle, isPresented: noticeShown) {
                Button("OK", role: .cancel) {}
            } message: {
                noticeMessage
            }
            // A tile's long-press "Remove…" (the stage sets `removeCandidate`); asked here.
            .alert(removeTitle, isPresented: removeShown, presenting: stage.removeCandidate) { t in
                removeButtons(t)
            } message: { _ in
                Text(removeMessage)
            }
            .alert(accessOffTitle, isPresented: accessOffShown) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(accessOffMessage)
            }
            .sheet(isPresented: $showParticipants) { GroupCallParticipantsSheet(stage: stage) }
    }

    /// Audit M-031, 2026-10-07: "a live call is untouched here (its covers minimize it)" held for
    /// only two of the four covers. The chat's and the group page's covers have no onDismiss, so
    /// when that page itself went away (a notification tap to another chat, removed from the
    /// group, the chat deleted elsewhere) the call ran on with no screen and no card. Any screen
    /// that goes while its call is live and was not minimized or ended hands it to the card.
    private func screenGone() {
        service.screenClosed()
        if service.isActive, !service.minimized, !service.leaving { service.minimized = true }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        settled = true
    }

    private var noticeTitle: String { service.notice?.title ?? "" }
    private var noticeShown: Binding<Bool> {
        // Audit M-159, 2026-10-07: OK closes the screen only for a call that is not running (a
        // failed or refused start, D25). On a live call it closed the call screen over a call that
        // went on (in-call failures are toasts now; this is the backstop).
        Binding(get: { settled && service.notice != nil },
                set: { if !$0 { service.notice = nil; if !service.isActive { dismiss() } } })
    }
    @ViewBuilder
    private var noticeMessage: some View {
        if let m = service.notice?.message { Text(m) }
    }

    private var removeTitle: String {
        guard let t = stage.removeCandidate else { return "" }
        return "Remove \(t.name) from the call?"
    }
    private var removeShown: Binding<Bool> {
        Binding(get: { stage.removeCandidate != nil },
                set: { if !$0 { stage.removeCandidate = nil } })
    }
    /// The people sheet's words: on a link call a removed person may ask to join again.
    /// Controls audit 4-B6 (2026-10-23): "is this a link call" asked the way the sheet asks it.
    private var removeMessage: String {
        service.isLink ? "They can ask to join again." : "They won't be able to rejoin it."
    }
    /// The link's owner on a link call: the sheet's "Remove and Block" is offered here too (4-B6).
    /// The server checks the creator again.
    private var canBlock: Bool {
        service.isLink && service.currentLink != nil && (service.myRole == .owner || service.isLinkCreator)
    }
    @ViewBuilder
    private func removeButtons(_ t: CallTile) -> some View {
        Button("Remove", role: .destructive) { remove(t) }
        if canBlock {
            Button("Remove and Block", role: .destructive) { block(t) }
        }
        Button("Cancel", role: .cancel) {}
    }
    /// Out of the call and refused by this link for good (`callAdmin` block, as the sheet does).
    private func block(_ t: CallTile) {
        stage.removeCandidate = nil
        let uid = t.uid
        let name = t.name
        guard !uid.isEmpty else { return }
        Task { @MainActor in
            if !(await service.block(uid)) { service.showToast("Couldn't block \(name). Try again.") }
        }
    }
    /// The same server call the people sheet makes (`callAdmin` remove); the server checks my role.
    private func remove(_ t: CallTile) {
        stage.removeCandidate = nil
        let uid = t.uid
        let name = t.name
        guard !uid.isEmpty else { return }
        Task { @MainActor in
            do { try await service.admin(.remove, target: uid) }
            catch { service.showToast("Couldn't remove \(name). Try again.") }
        }
    }

    /// Names, photos and the host mark on the tiles come from the service.
    private var synced: some View {
        presented
            .onAppear { syncPeople() }
            .onChange(of: service.members) { _, members in stage.refreshProfiles(members) }
            .onChange(of: service.rolesVersion) { _, _ in syncHosts() }
            .onChange(of: stage.tiles.count) { _, _ in syncHosts() }
            .onChange(of: service.myRole) { _, _ in syncHosts() }   // set once the room is up
            .onChange(of: service.isLinkCreator) { _, _ in syncHosts() }
    }

    private func syncPeople() {
        stage.refreshProfiles(service.members)
        syncHosts()
    }

    /// The tiles' host mark: whoever the server signed in as owner (LiveKit attribute `role`, group
    /// call permissions 2026-10-06). It used to be a flag of ours that only knew a link's creator.
    private func syncHosts() {
        let room = service.room
        let everyone: [Participant] = [room.localParticipant as Participant]
            + room.remoteParticipants.values.map { $0 as Participant }
        var hosts: Set<String> = []
        for p in everyone {
            guard let uid = p.identity?.stringValue, !uid.isEmpty else { continue }
            // Audit M-072, 2026-10-07 (with fix/F4): a group call's live role first; the attribute
            // was frozen at join.
            let role = service.groupRole(of: uid) ?? CallRole(attribute: p.attributes["role"])
            if role == .owner { hosts.insert(uid) }
        }
        // A server without roles yet: the link's creator (server-written `creatorUid`) as before.
        let me = service.myUid
        if service.isLinkCreator && !me.isEmpty { hosts.insert(me) }
        stage.hostUids = hosts
    }

    // MARK: - The stage (three or more people, and before the call is joined)

    /// Between header and controls: the stage's pages (the grid, and the big-speaker page a swipe
    /// away), or one person large with the strip (pinned or presenting). The self pip floats over
    /// it, so it never moves a tile. A tap on a tile is the tile's own (it pins, owner spec); a tap
    /// that lands on no tile reaches this view and shows or hides the chrome.
    private var stageArea: some View {
        // Reduce Motion: no matched-geometry flight, the focus view fades in.
        GroupCallStagePager(stage: stage, namespace: reduceMotion ? nil : ns, onFocusTap: { toggleChrome() },
                            iAmSharing: service.screenSharing, onStopSharing: { service.toggleScreenShare() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The stage's size, for the enlarged pip's cap. A background reader adds no layout of its own.
            .background(stageSizeReader)
            // The strip's trailing gap clears the pip as it is really drawn (small or enlarged).
            .environment(\.groupCallSelfPipWidth, selfPipWidth)
            // Audit M-101, 2026-10-07: what the tiles' top marks must clear (see `topClearance`).
            .environment(\.groupCallTopClearance, topClearance)
            .environment(\.groupCallIAmSharing, service.screenSharing)
            .overlay(alignment: .bottomTrailing) { if showsSelfPip { selfPip } }
            .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: stage.mode)
            .contentShape(Rectangle())
            .onTapGesture { toggleChrome() }
            // Chrome away: the first tap anywhere on the stage only brings it back. It must not
            // also pin whoever was under the finger, so it outranks the tiles' own taps; scrolling
            // is untouched. Chrome up: this gesture is off and the tiles get their taps.
            .highPriorityGesture(TapGesture().onEnded { showChrome() },
                                 including: chromeVisible ? .subviews : .all)
    }

    private var stageSizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { stageSize = geo.size }
                .onChange(of: geo.size) { _, size in stageSize = size }
        }
    }

    /// Bottom edge in line with the strip's tiles (strip inset), as in the reference app.
    private var selfPip: some View {
        GroupCallSelfView(stage: stage, expanded: $selfExpanded, stageSize: stageSize, inStrip: pipInStrip)
            .padding(.bottom, GroupCallMetrics.stripInset)
    }

    /// Between header and controls: the group stage, or (alone / two people) an empty, see-through
    /// area over the 1:1 look. The notes under the header and the reactions sit on this one view in
    /// every layout, so a person joining is still announced across the switch (the banner keeps who
    /// it has seen).
    /// Owner, 2026-10-07 (plan #1, "feeling like flat design"): the stage is no longer boxed between
    /// two black bands. It reaches up behind the header to the top of the screen, under a soft dark
    /// fade that keeps the header readable, the way the two-person screen already fills it. Its
    /// bottom stays on the controls' top edge: the strip, the self pip and the tile names must not
    /// sit under the button bar, which is unchanged (owner: keep it exactly as it is).
    private var middle: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .background(alignment: .bottom) {
                ZStack {
                    if front == nil, !groupWaiting {
                        // ⛔ THE STAGE STARTS UNDER THE HEADER — owner 2026-10-28, two screenshots
                        // with a red line where the call's name and buttons end: the tiles ran up
                        // under the clock and the battery (the 2026-10-07 full-screen stage, lifted
                        // behind the header). Reversed: the stage starts below the header whether
                        // the controls show or not, so no tile ever sits under the status bar.
                        stageArea
                            // Owner 2026-10-28: with the controls away, the stage takes their room
                            // too (it stopped at their top edge and left a black band).
                            .padding(.bottom, chromeVisible ? 0 : -(controlsHeight + 16))
                            .animation(GroupCallMotion.fade, value: chromeVisible)
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .top) { notes }
            .overlay(alignment: .bottomLeading) { reactions }
    }

    /// The fade behind the header, the two-person screen's own (GroupCallDuoView `topScrim`). It
    /// goes with the header when the controls hide.
    private var stageScrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: stageLift + 40)
            .opacity(chromeVisible ? 1 : 0)
            .animation(GroupCallMotion.fade, value: chromeVisible)
            .allowsHitTesting(false)
    }

    /// Stacked under the header: who joined or left and the connection notes, the short notes that
    /// do not close the screen ("Alice muted you"; they were a capsule at the bottom), and the
    /// raised hands. Only the hands pill takes touches; its tap opens the people list.
    private var notes: some View {
        VStack(spacing: 6) {
            GroupCallStatusBanner(stage: stage).allowsHitTesting(false)
            GroupCallTopToast().allowsHitTesting(false)
            GroupCallRaisedHandsPill(onTap: { showParticipants = true })
        }
    }

    /// Emoji reactions rise from the bottom-leading corner, just above the controls.
    private var reactions: some View {
        GroupCallReactionsOverlay()
            .padding(.leading, 14)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
    }

    // MARK: - Alone and two people (the 1:1 look)

    private struct Front {
        let local: CallTile
        let remote: CallTile?   // nil = I am alone
    }

    /// Me alone, or me and exactly one other person, in a call I have JOINED, nobody presenting a
    /// screen (a shared screen needs the group stage's fitted view). nil = the group stage. A pure
    /// reading of the room, so people joining and leaving quickly can never leave it stale.
    private var front: Front? {
        guard service.joinState == .joined else { return nil }
        var local: CallTile?
        var remote: CallTile?
        var remotes = 0
        for t in stage.tiles {
            if t.isLocal { local = t } else { remotes += 1; remote = t }
        }
        // Sharing my screen: always the group stage, which shows the sharing card (owner 2026-10-28).
        guard remotes <= 1, let local, !local.isScreenShare, !service.screenSharing else { return nil }
        if let remote, remote.isScreenShare { return nil }
        return Front(local: local, remote: remote)
    }
    /// 0 = the group stage, 1 = alone, 2 = two people.
    private var frontKind: Int {
        guard let f = front else { return 0 }
        return f.remote == nil ? 1 : 2
    }
    private var duoPair: (local: CallTile, remote: CallTile)? {
        guard let f = front, let remote = f.remote else { return nil }
        return (f.local, remote)
    }
    private var duoHasVideo: Bool {
        guard let p = duoPair else { return false }
        return p.local.hasVideo || p.remote.hasVideo
    }
    @State private var duoSwapped = false
    @State private var winInsets = EdgeInsets()
    @State private var headerHeight: CGFloat = 44
    @State private var controlsHeight: CGFloat = 0

    private var remoteCount: Int { stage.tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 } }
    private var isAlone: Bool { service.joinState == .joined && remoteCount == 0 }
    // Audit M-026, 2026-10-07: the quick reconnect too (it never leaves `.connected`).
    // Controls 7, 2026-10-23: and the service's one automatic rejoin after a lost connection.
    private var isReconnecting: Bool { stage.isReconnecting || service.rejoining }

    // MARK: - The chrome's hide rule

    // The chrome (header + controls) hides the way a 1:1 call's does: tap to toggle, gone after 5s.
    // Owner, 2026-10-06 (decision in the build plan, the reference app's rule): on ANY joined call
    // with at least one other person, not only the two-person video call. Never when alone, never
    // under VoiceOver, never on a two-person call with no camera on (the 1:1 voice rule, CallView
    // `autoHideEnabled`).
    @State private var chromeVisible = true
    @State private var hideTask: DispatchWorkItem?
    private static let autoHideAfter: TimeInterval = 5

    private var autoHideEnabled: Bool {
        guard service.joinState == .joined, remoteCount >= 1 else { return false }
        if UIAccessibility.isVoiceOverRunning { return false }
        if duoPair != nil && !duoHasVideo { return false }
        return true
    }

    /// A join-request card is on screen (link creator only): someone is waiting for an answer.
    private var requestCardShowing: Bool { service.isLinkCreator && !service.pendingRequests.isEmpty }

    /// Something is up that the chrome must not vanish under: the people sheet, the "…" panel, a
    /// join-request card, the remove question. No clock runs while one is; it starts again when the
    /// last one goes (`watched`). The 1:1 screen's lesson, owner audit 2026-10-06 #40: the clock ran
    /// on under a sheet and its dismissal landed on a screen whose buttons had already gone.
    private var chromeHeld: Bool {
        if showParticipants || showMore { return true }
        return requestCardShowing || stage.removeCandidate != nil
    }

    private func armAutoHide() {
        hideTask?.cancel()
        guard autoHideEnabled, !chromeHeld else {
            if !chromeVisible { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true } }
            return
        }
        let work = DispatchWorkItem { hideChromeIfDue() }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideAfter, execute: work)
    }

    /// The clock ran out. The rule is asked again here: five seconds is long enough for the last
    /// other person to leave, or for something to open, without passing through `armAutoHide`.
    private func hideChromeIfDue() {
        guard autoHideEnabled, !chromeHeld else { return }
        withAnimation(.easeInOut(duration: 0.28)) { chromeVisible = false }
    }

    private func showChrome() {
        if !chromeVisible { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true } }
        armAutoHide()
    }

    private func toggleChrome() {
        guard autoHideEnabled, !chromeHeld else { return }
        if chromeVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.28)) { chromeVisible = false }
        } else {
            showChrome()
        }
    }
    /// The self pip's enlarged state, here so the strip can follow it (see selfPipWidth).
    @State private var selfExpanded = false
    @State private var stageSize: CGSize = .zero

    private var selfPipWidth: CGFloat {
        guard showsSelfPip else { return 0 }
        return GroupCallSelfView.size(remoteCount: remoteCount, expanded: selfExpanded, stageSize: stageSize,
                                      inStrip: pipInStrip).width
    }
    /// One person large with others in the strip under them: my card sits in that row, strip-sized.
    private var pipInStrip: Bool {
        if case .focus = stage.mode { return remoteCount >= 2 }
        return false
    }
    /// Owner 2026-10-27: with 2+ others on the grid I am a tile of my own, first in the grid
    /// (GroupCallGridView), as in the reference app; the corner card was too easy to lose. The card
    /// stays for one person shown large (pinned or presenting) and for one other person presenting.
    private var showsSelfPip: Bool {
        if service.screenSharing { return false }   // the sharing card is my tile then
        if case .focus = stage.mode { return true }
        return remoteCount <= 1
    }
    @State private var settled = false
    @State private var showParticipants = false
    @State private var showMore = false

    // MARK: - Header

    /// Ad-hoc: the other people's names, live as people are added. Otherwise the call's own title.
    private var title: String {
        // Two people: the other person's name, as a 1:1 call's header.
        if let pair = duoPair, !pair.remote.name.isEmpty { return pair.remote.name }
        if service.isAdhoc {
            let me = service.myUid
            let t = GroupCallService.title(for: service.members.filter { $0.uid != me }.map(\.name))
            if !t.isEmpty { return t }
        }
        return service.callTitle
    }

    /// The line that outranks everything else: reconnecting, waiting to be let in, connecting.
    /// 2026-09-24 audit: `connecting` was published and never read, so a join still in flight
    /// showed "1 in call", identical to a live call nobody else is in. 2026-09-24 fix-all #105: a
    /// joined call that loses its connection said "N in call" over frozen tiles; the room's own
    /// state drives it, in the 1:1 screen's word.
    private var statusWords: String? {
        GroupCallWords.status(joinState: service.joinState, connecting: service.connecting,
                              reconnecting: isReconnecting)
    }

    /// The header's second line, in the reference app's order (owner, 2026-10-06): Reconnecting >
    /// Waiting to be let in > Connecting > alone: who is being rung, else "No one else is here" >
    /// two people: the clock (a 1:1 call's) > "N in call".
    @ViewBuilder
    private var subtitleView: some View {
        if service.isGroupChatCall, service.dialing, !isReconnecting, service.joinState != .pending {
            // A group chat's call I started (owner 2026-10-28): one line, "Calling…", from the tap
            // until somebody comes; then the usual lines.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if service.callingNow(at: ctx.date) { Text("Calling…") } else { joinedSubtitle }
            }
        } else if service.isGroupChatCall, !service.dialing, statusWords == "Connecting…",
                  let since = service.joinStartedAt {
            // Answering a group call (owner 2026-10-28): no "Connecting…" for the first two seconds;
            // with the pass fetched while it rang, the call is usually there before that.
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(ctx.date.timeIntervalSince(since) < 2 ? " " : "Connecting…")
            }
        } else {
            joinedSubtitle
        }
    }

    @ViewBuilder
    private var joinedSubtitle: some View {
        if let words = statusWords {
            Text(words)
        } else if isAlone {
            aloneLine
        } else if duoPair != nil, let since = service.joinedAt {
            clock(since)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(countLine + Self.ringingTail(service.stillRinging(at: ctx.date).count))
            }
        }
    }

    /// Owner 2026-10-27 (from the reference app's "2 participants, 3 invited"): once somebody came,
    /// the people still being rung were no longer mentioned anywhere. ", 2 ringing" while they are.
    static func ringingTail(_ n: Int) -> String { n > 0 ? ", \(n) ringing" : "" }

    /// Alone: "Ringing Alice…" while the people I called are still inside the ring window, then
    /// "No one else is here". On a clock, because the ring window ends by time alone.
    private var aloneLine: some View {
        // The names now sit under the big photo in the middle (`GroupCallRingingView`), so the
        // header says just "Ringing…" while anyone is rung (2026-10-07).
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let rung = service.ringingNames(at: ctx.date)
            Text(rung.isEmpty ? GroupCallWords.alone(ringing: []) : "Ringing…")
        }
    }

    private func clock(_ since: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(CallDuration.clock(Int(ctx.date.timeIntervalSince(since)))
                 + Self.ringingTail(service.stillRinging(at: ctx.date).count))
                .monospacedDigit()
        }
    }

    /// A call that is over or never started has nobody "in" it: a blank line, not "1 in call".
    private var countLine: String {
        service.joinState == .joined ? "\(stage.inCallCount) in call" : " "
    }

    private var header: some View {
        HStack {
            Button {
                // NOT ending the call: the floating card takes over. Owner, 2026-10-06: the screen
                // slid down to the bottom; it now shrinks into the card like a 1:1 call
                // (`CallPipMorph`), so the cover itself leaves with no animation of its own.
                CallPipMorph.minimize {
                    service.minimized = true
                    InstantCover.run { dismiss() }
                }
            } label: {
                Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)   // owner, 2026-10-06: Liquid Glass
            }
            .accessibilityLabel("Minimize")
            // Balances the two buttons on the right, so the title stays centred.
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                subtitleView.font(.caption).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)   // owner, 2026-10-07: the ringing line wrapped onto two
            }
            Spacer()
            HStack(spacing: 8) {
                moreButton
                participantsButton
            }
        }
    }

    private var participantsButton: some View {
        Button { showParticipants = true } label: {
            Image(systemName: "person.2.fill").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)   // owner, 2026-10-06: Liquid Glass
        }
        .accessibilityLabel("Participants")
    }

    // MARK: - Controls

    // Owner, 2026-10-06: five buttons now, so the spacing is 12 (20 would overflow a 393pt screen:
    // 5 x 54 + 4 x 20 + 36 = 386 inside 365). Nothing else about the capsule changed.
    private var controls: some View {
        // Fits a 375 pt phone inside its 14 pt gutters: 5 x 54 + 4 x 10 + 2 x 14 = 338 (audit
        // 2026-10-20: 12 and 18 made 354, past the gutters).
        // ⛔ SHARE, VIDEO, SPEAKER, MUTE, END in one capsule — Kasim 2026-10-22, as the 1:1 call
        // (`CallView.controlBar`): big circles, no names, Share Screen where the "..." was. The "..."
        // (raise hand, flip camera) moved up into the header. On a 375 pt phone:
        // 5 x 56 + 4 x 10 + 2 x 12 = 344, inside the 14 pt gutters (347).
        HStack(spacing: 10) {
            shareButton
            cameraButton
            speakerButton
            micButton
            endButton
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // A voice call link: the camera button is there, greyed and inert (owner, 2026-10-06).
    // VoiceOver labels name what a tap does (no visual change).
    private var cameraButton: some View {
        // Camera off = the solid white circle, as the 1:1 call's camera and this bar's Mute (owner
        // 2026-10-23: "camera still not white like the other buttons").
        ctrl(service.cameraOn ? "video.fill" : "video.slash.fill",
             active: !service.cameraOn && !service.cameraLocked) { cameraTapped() }
            .disabled(service.cameraLocked)
            .opacity(service.cameraLocked ? 0.35 : 1)
            .accessibilityLabel(cameraLabel)
    }

    private var micButton: some View {
        // Muted = the solid white circle, as the 1:1 call's Mute (owner 2026-10-23).
        ctrl(service.micOn ? "mic.fill" : "mic.slash.fill", active: !service.micOn) { micTapped() }
            .accessibilityLabel(service.micOn ? "Mute" : "Unmute")
    }

    // Speaker on / off (owner, 2026-10-04): a real switch with its state, not the route picker.
    // Kasim 2026-10-22: the icon always wears its sound waves, and ON is the whole circle turning
    // solid white with a dark glyph, as the 1:1 call's Speaker does (`CallView.callCircle`). The
    // waves appearing and a fade were too faint to read as on or off.
    private var speakerButton: some View {
        ctrl("speaker.wave.2.fill", active: service.speakerOn) { service.toggleSpeaker() }
            .accessibilityLabel(service.speakerOn ? "Turn speaker off" : "Turn speaker on")
    }

    // Share Screen, moved out of the "..." panel into the bar (Kasim 2026-10-22). Same rule as
    // that row had: once the room is up, never on a voice call link. Solid white while sharing.
    // Controls audit 4-B5 (2026-10-23): from the tap until the broadcast starts (the system sheet is
    // up) the button said "Share Screen", and a second tap quietly ended the pending share. Now it
    // shows the pending state, half lit, and says that a tap cancels.
    private var shareButton: some View {
        let can = service.isActive && !service.cameraLocked
        let pending = service.sharePending && !service.screenSharing
        let on = service.screenSharing || pending
        return ctrl(on ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                    active: on) { service.toggleScreenShare() }
            .disabled(!can && !on)
            .opacity(pending ? 0.6 : (can || on ? 1 : 0.35))
            .accessibilityLabel(service.screenSharing ? "Stop Sharing" : pending ? "Cancel Sharing" : "Share Screen")
    }

    // Owner, 2026-10-06: raise hand and flip camera live in its panel (`GroupCallMoreMenu`). They
    // need the room, so it waits for the call to be joined. Kasim 2026-10-22: a header button now,
    // beside Participants; its panel hangs under the header.
    private var moreButton: some View {
        Button { showMore.toggle(); armAutoHide() } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
        }
        .disabled(!moreEnabled)
        .opacity(moreEnabled ? 1 : 0.35)
        .accessibilityLabel("More")
    }
    private var moreEnabled: Bool { service.joinState == .joined }

    // owner audit 2026-10-06 #4: before the room is up `activeCid` never changes, so the
    // onChange that closes this screen never fired and End looked dead. Close it here.
    private var endButton: some View {
        ctrl("phone.down.fill", tint: Color(.systemRed)) { endCall() }
            .accessibilityLabel("End call")
    }

    private func endCall() {
        let wasUp = service.isActive
        service.end()
        if !wasUp { dismiss() }
    }

    private var cameraLabel: String {
        if service.cameraLocked { return "Camera unavailable on a voice call" }
        return service.cameraOn ? "Turn camera off" : "Turn camera on"
    }

    /// Every press restarts the hide clock (the 1:1 screen's rule): hitting mute must not leave you
    /// two seconds from losing the rest of the buttons.
    /// `active`: the solid white "on" circle with a dark glyph (the 1:1 call's look), glass otherwise.
    /// `active`: the solid white "on" circle with a dark glyph (the 1:1 call's look), glass otherwise.
    private func ctrl(_ icon: String, tint: Color? = nil, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button {
            action()
            armAutoHide()
        } label: {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(active ? .black : .white)
                .frame(width: 56, height: 56)
                .background(active ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: Circle())
                // Real Liquid Glass circles (was a flat white-20% fill); end button = red glass.
                .liquidGlass(Circle(), interactive: true, tint: tint, enabled: !active)
                .contentShape(Circle())
        }
    }
}

/// The call's own words for its state, in one place so the header and the minimized card
/// (`GroupFloatingCallWindow`) can never say different things about the same call.
enum GroupCallWords {
    /// The line that outranks everything else, nil when the call is simply running (or over).
    static func status(joinState: GroupJoinState, connecting: Bool, reconnecting: Bool) -> String? {
        if reconnecting { return "Reconnecting…" }
        switch joinState {
        case .pending: return "Waiting to be let in"
        case .joining: return "Connecting…"
        case .notJoined: return connecting ? "Connecting…" : nil
        case .joined: return nil
        }
    }

    /// Alone in a joined call: who is being rung (`GroupCallService.ringingNames(at:)`), or that
    /// nobody else is here. "Ringing Alice…" / "Ringing Alice and Bob…" / "Ringing Alice, Bob and 3
    /// others…", the reference app's three forms.
    static func alone(ringing names: [String]) -> String {
        switch names.count {
        case 0: return "No one else is here"
        case 1: return "Ringing \(names[0])…"
        case 2: return "Ringing \(names[0]) and \(names[1])…"
        default:
            let rest = names.count - 2
            let others = rest == 1 ? "other" : "others"
            return "Ringing \(names[0]), \(names[1]) and \(rest) \(others)…"
        }
    }
}
