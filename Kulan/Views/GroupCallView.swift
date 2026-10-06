import SwiftUI
import LiveKit

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
//   three or more       GroupCallStagePager (grid page + speaker page)
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
            frontLayer
            chromeStack
            hiddenChromeCatcher
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
                .transition(.opacity)
        }
    }

    private var chromeStack: some View {
        VStack(spacing: 16) {
            headerBar
            // Edge to edge: the stage keeps its own 6pt inset (the reference app's grid).
            middle
            bottomBar
        }
        .padding(.vertical, 10)
    }

    private var headerBar: some View {
        header.padding(.horizontal, 14)
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
            controls.padding(.horizontal, 14)
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .accessibilityHidden(!chromeVisible)
        }
    }

    /// Group stage with the chrome away: the first tap anywhere only brings it back (it must not
    /// also pin whoever was under the finger). It exists ONLY while the chrome is hidden, so it can
    /// never sit over a tile the user is trying to pin. Alone / two people, GroupCallDuoView has
    /// the 1:1 screen's own tap surface and this is not drawn.
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
            ZStack(alignment: .bottom) {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { showMore = false }
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                GroupCallMoreMenu(onClose: { showMore = false })
                    .padding(.bottom, Self.moreMenuLift)
            }
            .transition(.opacity)
        }
    }
    /// The capsule's top edge above the safe bottom (10 screen padding + 54 buttons + 2x12 capsule
    /// padding) and a 12pt gap.
    private static let moreMenuLift: CGFloat = 100

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
            .onChange(of: duoHasVideo) { _, _ in showChrome() }
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
            .onDisappear { service.screenClosed() }
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
            .sheet(isPresented: $showParticipants) { GroupCallParticipantsSheet(stage: stage) }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        settled = true
    }

    private var noticeTitle: String { service.notice?.title ?? "" }
    private var noticeShown: Binding<Bool> {
        Binding(get: { settled && service.notice != nil },
                set: { if !$0 { service.notice = nil; dismiss() } })
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
    private var removeMessage: String {
        service.currentLink != nil ? "They can ask to join again." : "They won't be able to rejoin it."
    }
    @ViewBuilder
    private func removeButtons(_ t: CallTile) -> some View {
        Button("Remove", role: .destructive) { remove(t) }
        Button("Cancel", role: .cancel) {}
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
        for p in everyone where CallRole(attribute: p.attributes["role"]) == .owner {
            if let uid = p.identity?.stringValue, !uid.isEmpty { hosts.insert(uid) }
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
        GroupCallStagePager(stage: stage, namespace: reduceMotion ? nil : ns)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The stage's size, for the enlarged pip's cap. A background reader adds no layout of its own.
            .background(stageSizeReader)
            // The strip's trailing gap clears the pip as it is really drawn (small or enlarged).
            .environment(\.groupCallSelfPipWidth, selfPipWidth)
            .overlay(alignment: .bottomTrailing) { selfPip }
            .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: stage.mode)
            .contentShape(Rectangle())
            .onTapGesture { toggleChrome() }
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
        GroupCallSelfView(stage: stage, expanded: $selfExpanded, stageSize: stageSize)
            .padding(.bottom, GroupCallMetrics.stripInset)
    }

    /// Between header and controls: the group stage, or (alone / two people) an empty, see-through
    /// area over the 1:1 look. The notes under the header and the reactions sit on this one view in
    /// every layout, so a person joining is still announced across the switch (the banner keeps who
    /// it has seen).
    private var middle: some View {
        ZStack {
            if front == nil {
                stageArea.transition(.opacity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { notes }
        .overlay(alignment: .bottomLeading) { reactions }
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
        guard remotes <= 1, let local, !local.isScreenShare else { return nil }
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

    private var remoteCount: Int { stage.tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 } }
    private var isAlone: Bool { service.joinState == .joined && remoteCount == 0 }
    private var isReconnecting: Bool { stage.connectionState == .reconnecting }

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
        GroupCallSelfView.size(remoteCount: remoteCount, expanded: selfExpanded, stageSize: stageSize).width
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
        if let words = statusWords {
            Text(words)
        } else if isAlone {
            aloneLine
        } else if duoPair != nil, let since = service.joinedAt {
            clock(since)
        } else {
            Text(countLine)
        }
    }

    /// Alone: "Ringing Alice…" while the people I called are still inside the ring window, then
    /// "No one else is here". On a clock, because the ring window ends by time alone.
    private var aloneLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(GroupCallWords.alone(ringing: service.ringingNames(at: ctx.date)))
        }
    }

    private func clock(_ since: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(CallDuration.clock(Int(ctx.date.timeIntervalSince(since))))
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
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                subtitleView.font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { showParticipants = true } label: {
                Image(systemName: "person.2.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)   // owner, 2026-10-06: Liquid Glass
            }
            .accessibilityLabel("Participants")
        }
    }

    // MARK: - Controls

    // Owner, 2026-10-06: five buttons now, so the spacing is 12 (20 would overflow a 393pt screen:
    // 5 x 54 + 4 x 20 + 36 = 386 inside 365). Nothing else about the capsule changed.
    private var controls: some View {
        HStack(spacing: 12) {
            cameraButton
            micButton
            speakerButton
            moreButton
            endButton
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // A voice call link: the camera button is there, greyed and inert (owner, 2026-10-06).
    // VoiceOver labels name what a tap does (no visual change).
    private var cameraButton: some View {
        ctrl(service.cameraOn ? "video.fill" : "video.slash.fill") { service.toggleCamera() }
            .disabled(service.cameraLocked)
            .opacity(service.cameraLocked ? 0.35 : 1)
            .accessibilityLabel(cameraLabel)
    }

    private var micButton: some View {
        ctrl(service.micOn ? "mic.fill" : "mic.slash.fill") { service.toggleMic() }
            .accessibilityLabel(service.micOn ? "Mute" : "Unmute")
    }

    // Speaker on / off (owner, 2026-10-04): a real switch with its state, not the route picker.
    private var speakerButton: some View {
        ctrl(service.speakerOn ? "speaker.wave.2.fill" : "speaker.fill") { service.toggleSpeaker() }
            .opacity(service.speakerOn ? 1 : 0.7)
            .accessibilityLabel(service.speakerOn ? "Turn speaker off" : "Turn speaker on")
    }

    // Owner, 2026-10-06: the one new button, same glass circle as its neighbours, between speaker
    // and end. Reactions, raise hand and flip camera live in its panel (`GroupCallMoreMenu`). They
    // all need the room, so it waits for the call to be joined.
    private var moreButton: some View {
        ctrl("ellipsis") { showMore.toggle() }
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
    private func ctrl(_ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            armAutoHide()
        } label: {
            Image(systemName: icon).font(.title3).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                // Real Liquid Glass circles (was a flat white-20% fill); end button = red glass.
                .liquidGlass(Circle(), interactive: true, tint: tint)
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
