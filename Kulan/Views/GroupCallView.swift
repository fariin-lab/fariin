import SwiftUI
import LiveKit

// Group call screen: header, the stage (Views/GroupCall/, owner spec §8-16), frosted-capsule
// controls to match the 1:1 call UI. ⛔ Owner, 2026-10-06: the header and the controls capsule stay
// exactly as they are; only the stage between them was rebuilt. The stage object walks the LiveKit
// room once for the tiles, the subtitle and the people sheet, so they all agree.
struct GroupCallView: View {
    @ObservedObject private var service = GroupCallService.shared
    // One stage for the life of this screen; the people sheet shares it (same speaker, same pin).
    @StateObject private var stage = GroupCallStage(room: GroupCallService.shared.room)
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// The screen and its two-person behaviour, apart from `body` so neither is too long for the
    /// type checker (it gave up on a long body here once, 2026-10-06).
    private var screen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Two people: the 1:1 call's look, edge to edge under the chrome (GroupCallDuoView).
            if let pair = duoPair {
                GroupCallDuoView(stage: stage, local: pair.local, remote: pair.remote,
                                 swapped: $duoSwapped, chromeVisible: chromeVisible, insets: winInsets,
                                 onBackgroundTap: toggleChrome,
                                 onTileTouch: { hideTask?.cancel() },
                                 onTileRelease: armAutoHide,
                                 onShowChrome: showChrome)
                    .transition(.opacity)
            }
            VStack(spacing: 16) {
                header.padding(.horizontal, 14)
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                    .accessibilityHidden(!chromeVisible)
                if service.isLinkCreator && !service.pendingRequests.isEmpty {
                    waitingBanner.padding(.horizontal, 14)
                }
                // Edge to edge: the stage keeps its own 6pt inset (the reference app's grid).
                middle
                controls.padding(.horizontal, 14)
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                    .accessibilityHidden(!chromeVisible)
            }
            .padding(.vertical, 10)
        }
        // 2 <-> 3 people: one cross-fade between the 1:1 look and the group stage.
        .animation(.easeInOut(duration: 0.3), value: duoPair != nil)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { winInsets = geo.safeAreaInsets }
                .onChange(of: geo.safeAreaInsets) { _, v in winInsets = v }
        })
        .onChange(of: duoPair != nil) { _, duo in
            if !duo { duoSwapped = false }
            showChrome()
        }
        .onChange(of: duoHasVideo) { _, _ in showChrome() }
        .onChange(of: service.isActive) { _, _ in showChrome() }
        .onChange(of: showParticipants) { _, up in
            if up { hideTask?.cancel() } else { showChrome() }
        }
        .onDisappear { hideTask?.cancel() }
    }

    var body: some View {
        screen
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
        .task { try? await Task.sleep(nanoseconds: 500_000_000); settled = true }
        .alert(service.notice?.title ?? "",
               isPresented: Binding(get: { settled && service.notice != nil },
                                    set: { if !$0 { service.notice = nil; dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let m = service.notice?.message { Text(m) }
        }
        .sheet(isPresented: $showParticipants) { GroupCallParticipantsSheet(stage: stage) }
        .sheet(isPresented: $showRequests) { CallLinkRequestsSheet() }
        // The last person waiting was answered: nothing left to show.
        .onChange(of: service.pendingRequests.isEmpty) { _, empty in if empty { showRequests = false } }
        // Names, photos and the host mark on the tiles come from the service.
        .onAppear {
            stage.refreshProfiles(service.members)
            syncHosts()
        }
        .onChange(of: service.members) { _, members in stage.refreshProfiles(members) }
        .onChange(of: service.rolesVersion) { _, _ in syncHosts() }
        .onChange(of: stage.tiles.count) { _, _ in syncHosts() }
        .onChange(of: service.myRole) { _, _ in syncHosts() }   // set once the room is up
        .onChange(of: service.isLinkCreator) { _, _ in syncHosts() }
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

    /// Between header and controls: the grid, or one person large with the strip (pinned or
    /// presenting). The self pip and the status capsule float over it, so neither moves a tile.
    private var stageArea: some View {
        ZStack {
            if case .focus(let id) = stage.mode {
                // Reduce Motion: no matched-geometry flight, the focus view fades in.
                GroupCallFocusView(stage: stage, focusId: id, namespace: reduceMotion ? nil : ns)
                    .transition(.opacity)
            } else {
                GroupCallGridView(stage: stage)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The stage's size, for the enlarged pip's cap. A background reader adds no layout of its own.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { stageSize = geo.size }
                .onChange(of: geo.size) { _, size in stageSize = size }
        })
        // The strip's trailing gap clears the pip as it is really drawn (small or enlarged).
        .environment(\.groupCallSelfPipWidth, selfPipWidth)
        .overlay(alignment: .bottomTrailing) {
            // Bottom edge in line with the strip's tiles (strip inset), as in the reference app.
            GroupCallSelfView(stage: stage, expanded: $selfExpanded, stageSize: stageSize)
                .padding(.bottom, GroupCallMetrics.stripInset)
        }
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: stage.mode)
    }

    /// Between header and controls: the group stage, or (two people) an empty, see-through area
    /// over the 1:1 look. The join/leave notes and the toasts sit on this one view in both layouts,
    /// so a person joining is still announced across the switch (the banner keeps who it has seen).
    private var middle: some View {
        ZStack {
            if duoPair == nil {
                stageArea.transition(.opacity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { GroupCallStatusBanner(stage: stage).allowsHitTesting(duoPair == nil) }
        // Group call permissions, 2026-10-06: "You were muted" and other short notes that do not
        // close the screen. VoiceOver hears it as an announcement from the service.
        .overlay(alignment: .bottom) {
            if let toast = service.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(GroupCallMotion.fade, value: service.toast)
    }

    // MARK: - Two people (the 1:1 look)

    /// Me and exactly one other person, nobody presenting a screen (a shared screen needs the
    /// group stage's fitted view). nil = the group stage.
    private var duoPair: (local: CallTile, remote: CallTile)? {
        guard service.isActive else { return nil }
        var local: CallTile?
        var remote: CallTile?
        var remotes = 0
        for t in stage.tiles {
            if t.isLocal { local = t } else { remotes += 1; remote = t }
        }
        guard remotes == 1, let local, let remote, !remote.isScreenShare, !local.isScreenShare else { return nil }
        return (local, remote)
    }
    private var duoHasVideo: Bool {
        guard let p = duoPair else { return false }
        return p.local.hasVideo || p.remote.hasVideo
    }
    @State private var duoSwapped = false
    @State private var winInsets = EdgeInsets()

    // The chrome (header + controls) hides on a two-person VIDEO call the way a 1:1 call's does:
    // tap to toggle, gone after 5s. Never under VoiceOver, never on a voice call, never on the group
    // stage (CallView `autoHideEnabled`).
    @State private var chromeVisible = true
    @State private var hideTask: DispatchWorkItem?
    private var autoHideEnabled: Bool { duoHasVideo && !UIAccessibility.isVoiceOverRunning }

    private func armAutoHide() {
        hideTask?.cancel()
        guard autoHideEnabled, !showParticipants else {
            if !chromeVisible { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true } }
            return
        }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.28)) { chromeVisible = false }
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func showChrome() {
        if !chromeVisible { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true } }
        armAutoHide()
    }

    private func toggleChrome() {
        guard autoHideEnabled else { return }
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
        let remotes = stage.tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 }
        return GroupCallSelfView.size(remoteCount: remotes, expanded: selfExpanded, stageSize: stageSize).width
    }
    @State private var settled = false
    @State private var showParticipants = false
    @State private var showRequests = false

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

    private var subtitle: String {
        // Group call permissions, 2026-10-06: also true while the host is away; they keep waiting.
        if service.waitingForApproval { return "Waiting for the host to let you in" }
        // 2026-09-24 audit: `connecting` was published and never read, so a join still in flight
        // showed "1 in call", identical to a live call nobody else is in. Same word the 1:1 call
        // screen uses.
        if service.connecting { return "Connecting…" }
        // 2026-09-24 fix-all #105: a joined call that loses its connection said "N in call" over
        // frozen tiles. The room's own state drives it now, in the 1:1 screen's word.
        if stage.connectionState == .reconnecting { return "Reconnecting…" }
        if service.isActive && !stage.tiles.contains(where: { !$0.isLocal }) { return "Waiting for others…" }
        return "\(stage.inCallCount) in call"
    }

    /// The two-person header's clock (a 1:1 call's), else the subtitle above.
    @ViewBuilder private var subtitleView: some View {
        if duoPair != nil, let since = service.joinedAt, !service.waitingForApproval, !service.connecting,
           stage.connectionState != .reconnecting {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(CallDuration.clock(Int(ctx.date.timeIntervalSince(since))))
                    .monospacedDigit()
            }
        } else {
            Text(subtitle)
        }
    }

    private var waitingBanner: some View {
        Button { showRequests = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.clock.fill").font(.system(size: 14, weight: .semibold))
                Text("\(service.pendingRequests.count) waiting").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(minHeight: 40)   // grows with Dynamic Type, 40 at default
            .background(.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
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

    private var controls: some View {
        HStack(spacing: 20) {
            // A voice call link: the camera button is there, greyed and inert (owner, 2026-10-06).
            // VoiceOver labels name what a tap does (no visual change).
            ctrl(service.cameraOn ? "video.fill" : "video.slash.fill") { service.toggleCamera() }
                .disabled(service.cameraLocked)
                .opacity(service.cameraLocked ? 0.35 : 1)
                .accessibilityLabel(cameraLabel)
            ctrl(service.micOn ? "mic.fill" : "mic.slash.fill") { service.toggleMic() }
                .accessibilityLabel(service.micOn ? "Mute" : "Unmute")
            // Speaker on / off (owner, 2026-10-04): a real switch with its state, not the route picker.
            ctrl(service.speakerOn ? "speaker.wave.2.fill" : "speaker.fill") { service.toggleSpeaker() }
                .opacity(service.speakerOn ? 1 : 0.7)
                .accessibilityLabel(service.speakerOn ? "Turn speaker off" : "Turn speaker on")
            // owner audit 2026-10-06 #4: before the room is up `activeCid` never changes, so the
            // onChange that closes this screen never fired and End looked dead. Close it here.
            ctrl("phone.down.fill", tint: Color(.systemRed)) {
                let wasUp = service.isActive
                service.end()
                if !wasUp { dismiss() }
            }
            .accessibilityLabel("End call")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }


    private var cameraLabel: String {
        if service.cameraLocked { return "Camera unavailable on a voice call" }
        return service.cameraOn ? "Turn camera off" : "Turn camera on"
    }

    private func ctrl(_ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                // Real Liquid Glass circles (was a flat white-20% fill); end button = red glass.
                .liquidGlass(Circle(), interactive: true, tint: tint)
        }
    }
}

/// Creator of a link call with approval on: the people knocking, each let in or turned away.
struct CallLinkRequestsSheet: View {
    @ObservedObject private var service = GroupCallService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(service.pendingRequests) { person in
                HStack(spacing: 12) {
                    AvatarView(name: person.name, photoUrl: person.photoUrl, size: 40)
                    Text(person.name).lineLimit(1)
                    Spacer()
                    answer("xmark", tint: Color(.systemRed)) {
                        Task { await service.answerRequest(uid: person.uid, approve: false) }
                    }
                    .accessibilityLabel("Decline \(person.name)")
                    answer("checkmark", tint: Color(.systemGreen)) {
                        Task { await service.answerRequest(uid: person.uid, approve: true) }
                    }
                    .accessibilityLabel("Let in \(person.name)")
                }
            }
            .navigationTitle("\(service.pendingRequests.count) waiting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func answer(_ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(tint, in: Circle())
        }
        .buttonStyle(.borderless)   // two buttons in one List row: each keeps its own tap
    }
}
