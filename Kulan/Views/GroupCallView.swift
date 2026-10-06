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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                header.padding(.horizontal, 14)
                if service.isLinkCreator && !service.pendingRequests.isEmpty {
                    waitingBanner.padding(.horizontal, 14)
                }
                // Edge to edge: the stage keeps its own 6pt inset (the reference app's grid).
                stageArea
                controls.padding(.horizontal, 14)
            }
            .padding(.vertical, 10)
        }
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
        .onChange(of: service.isLinkCreator) { _, _ in syncHosts() }
    }

    /// Hosts the service can name: the link creator, when that is me. The service does not keep the
    /// ad-hoc starter or group admins for a running call, so nobody else is marked.
    private func syncHosts() {
        let me = service.myUid
        stage.hostUids = service.isLinkCreator && !me.isEmpty ? [me] : []
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
        .overlay(alignment: .bottomTrailing) {
            // Bottom edge in line with the strip's tiles (strip inset), as in the reference app.
            GroupCallSelfView(stage: stage)
                .padding(.bottom, GroupCallMetrics.stripInset)
        }
        .overlay(alignment: .top) { GroupCallStatusBanner(stage: stage) }
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: stage.mode)
    }
    @State private var settled = false
    @State private var showParticipants = false
    @State private var showRequests = false

    /// Ad-hoc: the other people's names, live as people are added. Otherwise the call's own title.
    private var title: String {
        if service.isAdhoc {
            let me = service.myUid
            let t = GroupCallService.title(for: service.members.filter { $0.uid != me }.map(\.name))
            if !t.isEmpty { return t }
        }
        return service.callTitle
    }

    private var subtitle: String {
        if service.waitingForApproval { return "Waiting to be let in…" }
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

    private var waitingBanner: some View {
        Button { showRequests = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.clock.fill").font(.system(size: 14, weight: .semibold))
                Text("\(service.pendingRequests.count) waiting").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Button {
                service.minimized = true   // NOT ending the call: the floating card takes over
                dismiss()
            } label: {
                Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)   // owner, 2026-10-06: Liquid Glass
            }
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { showParticipants = true } label: {
                Image(systemName: "person.2.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)   // owner, 2026-10-06: Liquid Glass
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            // A voice call link: the camera button is there, greyed and inert (owner, 2026-10-06).
            ctrl(service.cameraOn ? "video.fill" : "video.slash.fill") { service.toggleCamera() }
                .disabled(service.cameraLocked)
                .opacity(service.cameraLocked ? 0.35 : 1)
            ctrl(service.micOn ? "mic.fill" : "mic.slash.fill") { service.toggleMic() }
            // Speaker on / off (owner, 2026-10-04): a real switch with its state, not the route picker.
            ctrl(service.speakerOn ? "speaker.wave.2.fill" : "speaker.fill") { service.toggleSpeaker() }
                .opacity(service.speakerOn ? 1 : 0.7)
            // owner audit 2026-10-06 #4: before the room is up `activeCid` never changes, so the
            // onChange that closes this screen never fired and End looked dead. Close it here.
            ctrl("phone.down.fill", tint: Color(.systemRed)) {
                let wasUp = service.isActive
                service.end()
                if !wasUp { dismiss() }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
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
                    answer("checkmark", tint: Color(.systemGreen)) {
                        Task { await service.answerRequest(uid: person.uid, approve: true) }
                    }
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
