import SwiftUI
import LiveKit

// Group call screen — voice = avatar grid, video = live tile grid. Frosted-capsule controls to
// match the 1:1 call UI. Observes the LiveKit Room directly for live participant updates.
struct GroupCallView: View {
    @ObservedObject private var service = GroupCallService.shared
    @ObservedObject private var room = GroupCallService.shared.room
    @Environment(\.dismiss) private var dismiss

    private var participants: [Participant] {
        [room.localParticipant as Participant] + room.remoteParticipants.values.map { $0 as Participant }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                header
                if service.isLinkCreator && !service.pendingRequests.isEmpty { waitingBanner }
                if service.isVideo {
                    ScrollView { videoGrid }
                } else {
                    Spacer(); voiceGrid; Spacer()
                }
                controls
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        // Always dark, for the same reason the 1:1 call is — see `CallView`. A call is drawn for a
        // dark ground whatever the phone is set to.
        .environment(\.colorScheme, .dark)
        .onChange(of: service.activeCid) { _, cid in if cid == nil { dismiss() } }
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
        .sheet(isPresented: $showParticipants) { GroupCallParticipantsSheet() }
        .sheet(isPresented: $showRequests) { CallLinkRequestsSheet() }
        // The last person waiting was answered: nothing left to show.
        .onChange(of: service.pendingRequests.isEmpty) { _, empty in if empty { showRequests = false } }
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
        if room.connectionState == .reconnecting { return "Reconnecting…" }
        if service.isActive && room.remoteParticipants.isEmpty { return "Waiting for others…" }
        return "\(participants.count) in call"
    }

    /// LiveKit's participant identity is the uid (the token's `sub`), so the invite list's photo
    /// and name can be matched to a tile.
    private func member(_ p: Participant) -> CallMember? {
        guard let uid = p.identity?.stringValue else { return nil }
        return service.members.first { $0.uid == uid }
    }
    private func displayName(_ p: Participant) -> String {
        if let n = p.name, !n.isEmpty { return n }
        return member(p)?.name ?? "Member"
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
                service.minimized = true   // NOT ending the call: the green return bar takes over
                dismiss()
            } label: {
                Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(.white.opacity(0.15), in: Circle())
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
                    .frame(width: 38, height: 38).background(.white.opacity(0.15), in: Circle())
            }
        }
    }

    private var voiceGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 22) {
            ForEach(participants, id: \.sid) { p in   // stable id: index-keyed tiles reused the wrong track on join/leave
                VStack(spacing: 6) {
                    AvatarView(name: displayName(p), photoUrl: member(p)?.photoUrl, size: 76)
                        .overlay(Circle().stroke(Color.green, lineWidth: p.isSpeaking ? 3 : 0))
                    Text(displayName(p)).font(.caption).foregroundStyle(.white).lineLimit(1)
                }
            }
        }
    }

    private var videoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(participants, id: \.sid) { p in   // stable id (see voiceGrid)
                ZStack(alignment: .bottomLeading) {
                    if let track = p.firstCameraVideoTrack {
                        SwiftUIVideoView(track, layoutMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.12)
                            AvatarView(name: displayName(p), photoUrl: member(p)?.photoUrl, size: 56)
                        }
                    }
                    HStack(spacing: 4) {
                        if !p.isMicrophoneEnabled() { Image(systemName: "mic.slash.fill").font(.caption2) }
                        Text(displayName(p)).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(.white).padding(6)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            ctrl(service.cameraOn ? "video.fill" : "video.slash.fill") { service.toggleCamera() }
            ctrl(service.micOn ? "mic.fill" : "mic.slash.fill") { service.toggleMic() }
            // Speaker on / off (owner, 2026-10-04): a real switch with its state, not the route picker.
            ctrl(service.speakerOn ? "speaker.wave.2.fill" : "speaker.fill") { service.toggleSpeaker() }
                .opacity(service.speakerOn ? 1 : 0.7)
            ctrl("phone.down.fill", tint: Color(.systemRed)) { service.end() }
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
