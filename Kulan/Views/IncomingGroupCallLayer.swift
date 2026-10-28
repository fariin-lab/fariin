import SwiftUI

/// Mounted once at the root (inside CallContainer). Two jobs, both for multi-person and link calls:
/// the full-screen invitation when someone adds me to a call, and the call screen itself, which has
/// no chat or group page of its own to be presented from.
struct IncomingGroupCallLayer: View {
    @ObservedObject private var service = GroupCallService.shared
    @State private var showRoom = false
    /// The pre-join screen for a link (`CallLobbyView`), following `service.lobby` after the same
    /// wait for a closing sheet as the call screen.
    @State private var shownLobby: GroupCallService.Lobby?

    /// Waits only while a sheet or the 1:1 screen is still up or on its way out (checked every
    /// 50ms, at most 0.8s); goes at once when nothing is. A cover asked for mid-dismissal is
    /// dropped by UIKit.
    private func waitForClearTop() async {
        for _ in 0..<16 {
            guard let top = WebLink.topViewController() else { break }
            let leaving = top.isBeingDismissed || top.presentingViewController?.isBeingDismissed == true
                || top.transitionCoordinator != nil
            let onTop = top.presentingViewController != nil   // a sheet or cover still up
            if !leaving && !onTop { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    var body: some View {
        ZStack {
            // A real, zero-sized anchor so the cover and listeners below always have a view to
            // hang on, and nothing takes space or touches while no invitation is up.
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            // owner, 2026-10-06: not for a room already declined on the lock screen (the list of
            // invitations can load after that decline).
            // 2026-10-23 (owner): a group chat's ring shows here too (`groupRingScreen`).
            // A nudge's invitation (owner 2026-10-23) is for someone who declined: it shows anyway.
            // Owner 2026-10-27: not while the system call screen rings for the same room (two ring
            // screens for one call). Shown when the system could not ring (Focus, refused).
            if CallFeatures.groupCalls, let invite = service.incomingInvite ?? service.groupRingScreen,
               invite.fromNudge || !GroupCallRinging.shared.isDeclined(invite.roomId),
               invite.fromNudge || invite.roomId != service.systemRingRoom {
                IncomingGroupCallScreen(invite: invite)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.incomingInvite?.roomId ?? service.groupRingScreen?.roomId)
        .onAppear { service.startInviteListener() }
        // owner, 2026-10-06: and the service forgets that invitation too, so nothing waits behind.
        .onChange(of: service.incomingInvite?.roomId) { _, roomId in
            if let roomId, GroupCallRinging.shared.isDeclined(roomId) { service.declineInvite() }
        }
        // Held a beat: the start usually comes from a sheet or the 1:1 screen closing on the same
        // tap, and a cover asked for mid-dismissal is dropped by UIKit.
        .onChange(of: service.presentsRoomScreen) { _, want in
            guard want else { showRoom = false; return }
            Task { @MainActor in
                // Owner, 2026-10-06: tapping a link row "has more lags". The fixed 0.6s beat was
                // paid on every join, even from the plain list with nothing to wait for.
                await waitForClearTop()
                // Hard cut, no slide-up: the reference app swaps to its call window instantly.
                if service.presentsRoomScreen {
                    InstantCover.run { showRoom = true }   // a cut, not a slide (see InstantCover)
                }
            }
        }
        // Nothing rings during a 1:1. Once it is over, look again, after the handover to a
        // multi-person call has had its moment to join (so its own invite never flashes up).
        .onChange(of: CallService.shared.state) { _, state in
            // owner, 2026-10-06: one ring at a time; the system ring for a group call stops too.
            if state != .idle { GroupCallRinging.shared.oneToOneTookOver() }
            // Audit M-064, 2026-10-07: a 1:1 call answered (or placed) while a link's pre-join
            // screen is up: the lobby covered the 1:1 screen and its camera kept running. The lobby
            // goes; its didSet ends a join or a knock still running from it. A ring alone leaves it
            // up (it may be declined). Not once the call itself fills that cover.
            if state == .active || state == .outgoing, service.lobby != nil, !service.roomInLobbyCover {
                service.lobby = nil
            }
            guard state == .idle else { service.reevaluateInvites(); return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                service.reevaluateInvites()
            }
        }
        // Past the service's ring window the invitation goes away by itself. Asked again every few
        // seconds while it stays (audit 2026-10-20): the card waited 90s against a 60s ring, and a
        // person added late, whose own ring started after the call's, was asked once and never again.
        .task(id: service.incomingInvite?.roomId) {
            guard let invite = service.incomingInvite else { return }
            while !Task.isCancelled, service.incomingInvite?.roomId == invite.roomId {
                let left = GroupCallService.ringWindow + 0.5 - Date().timeIntervalSince(invite.startedAt)
                try? await Task.sleep(nanoseconds: UInt64(max(left, 5) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                service.reevaluateInvites()
            }
        }
        .fullScreenCover(isPresented: $showRoom, onDismiss: {
            service.presentsRoomScreen = false
            if service.isActive {
                service.minimized = true   // swiped away, not ended: the floating card takes over
            } else if service.waitingForApproval {
                service.end()              // nobody let me in yet; closing the screen is leaving
            }
        }) { GroupCallView() }
        .onChange(of: service.lobby) { _, lobby in
            guard let lobby else { InstantCover.run { shownLobby = nil }; return }
            Task { @MainActor in
                await waitForClearTop()
                if service.lobby == lobby { InstantCover.run { shownLobby = lobby } }
            }
        }
        // On a child, so it never shares a view with the call screen's cover above.
        .background {
            Color.clear
                .fullScreenCover(item: $shownLobby, onDismiss: {
                    service.lobbyCoverClosed()   // swiped away = Leave; with the room inside = minimize
                }) { LobbyCoverContent(lobby: $0) }
        }
    }
}

/// One cover, two contents: the pre-join screen, then the call screen in its place once the join is
/// through (`GroupCallService.roomInLobbyCover`). The lobby used to go down and the room come up as
/// a second cover, and the screen underneath showed in between (owner, 2026-10-07: "after the
/// loading it shows the Calls list, then enters the call"). The reference app's lobby IS its call
/// screen in another state; with two screens, swapping them inside one cover is the nearest thing.
private struct LobbyCoverContent: View {
    let lobby: GroupCallService.Lobby
    @ObservedObject private var service = GroupCallService.shared
    /// Audit M-063, 2026-10-07: the call has filled this cover at least once.
    @State private var roomShown = false
    var body: some View {
        ZStack {
            if service.roomInLobbyCover {
                GroupCallView().transition(.opacity)
            } else if roomShown || service.lobby == nil {
                // Audit M-063, 2026-10-07: the cover is on its way down (the call inside it was
                // minimized or ended, or the lobby was closed). It used to build the lobby again for
                // that moment: a second camera session and a fresh join-token request. Black instead.
                // The swap from the lobby to the call (audit 11-1, `aac312e8`) is untouched.
                Color.black.ignoresSafeArea()
            } else {
                CallLobbyView(lobby: lobby).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.roomInLobbyCover)
        .onAppear { if service.roomInLobbyCover { roomShown = true } }
        .onChange(of: service.roomInLobbyCover) { _, on in if on { roomShown = true } }
    }
}

/// The invitation itself — owner 2026-10-23, with the reference (whatsapp) group-call ring screen:
/// the call's name and "Group call" at the top, the faces in one round cluster in the middle, a Mute
/// pill (join with the mic off), and at the foot one card: "<starter> is ringing you" with the faces
/// small beside it, then Ignore and a green Join.
private struct IncomingGroupCallScreen: View {
    let invite: AdhocInvite
    @State private var muted = false

    private var starter: CallMember? { invite.others.first }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text(invite.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(2)
                        .padding(.horizontal, 24)
                    Label(invite.video ? "Group video call" : "Group call",
                          systemImage: invite.video ? "video" : "phone")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 24)
                Spacer()
                FaceCluster(members: Array(invite.others.prefix(4)))
                Spacer()
                Button {
                    muted.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Mute", systemImage: muted ? "mic.slash.fill" : "mic.slash")
                        .font(.headline).foregroundStyle(muted ? .black : .white)
                        .padding(.horizontal, 20).frame(height: 48)
                        .background(Capsule().fill(muted ? Color.white : Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
                ringingCard
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var ringingCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Color(.systemGreen)).frame(width: 8, height: 8)
                Text("\(starter?.name ?? "Someone") is ringing you")
                    .font(.body).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: -10) {
                    ForEach(Array(invite.others.prefix(3).enumerated()), id: \.element.uid) { i, m in
                        AvatarView(name: m.name, photoUrl: m.photoUrl, size: 30)
                            .overlay(Circle().stroke(Color(white: 0.11), lineWidth: 2))
                            .zIndex(Double(3 - i))
                    }
                }
            }
            .padding(.horizontal, 20).frame(height: 64)
            Divider().overlay(Color.white.opacity(0.12))
            HStack(spacing: 12) {
                // owner, 2026-10-06: both go through GroupCallRinging, so the system ring for the
                // same call stops with them and a decline reaches the caller.
                Button { GroupCallRinging.shared.declineFromScreen(invite) } label: {
                    Text("Ignore").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Capsule().fill(Color.black))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                Button { GroupCallRinging.shared.acceptFromScreen(invite, muted: muted) } label: {
                    Text("Join").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Capsule().fill(Color(.systemGreen)))
                }
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.11)))
    }
}

/// Up to four faces packed in one round plate, the reference's layout: the starter large at the
/// upper left, the rest smaller around it. One face alone fills the middle.
private struct FaceCluster: View {
    let members: [CallMember]
    private let plate: CGFloat = 270

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08)).frame(width: plate, height: plate)
            ForEach(Array(members.enumerated()), id: \.element.uid) { i, m in
                let spot = Self.spots(members.count)[i]
                AvatarView(name: m.name, photoUrl: m.photoUrl, size: spot.size)
                    .offset(x: spot.x, y: spot.y)
            }
        }
        .frame(width: plate, height: plate)
    }

    /// Centre offsets and sizes, inside a 270pt plate.
    private static func spots(_ n: Int) -> [(x: CGFloat, y: CGFloat, size: CGFloat)] {
        switch n {
        case 1: return [(0, 0, 150)]
        case 2: return [(-38, -20, 124), (62, 52, 92)]
        case 3: return [(-38, -38, 124), (74, 0, 84), (-6, 82, 76)]
        default: return [(-40, -40, 120), (66, -66, 52), (76, 22, 84), (-8, 86, 72)]
        }
    }
}
