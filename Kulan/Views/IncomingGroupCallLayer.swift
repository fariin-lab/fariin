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
            if let invite = service.incomingInvite, !GroupCallRinging.shared.isDeclined(invite.roomId) {
                IncomingGroupCallScreen(invite: invite)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.incomingInvite?.roomId)
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
        // The ring window is 90s from the start; past it the invitation goes away by itself.
        .task(id: service.incomingInvite?.roomId) {
            guard let invite = service.incomingInvite else { return }
            let left = 90 - Date().timeIntervalSince(invite.startedAt)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            service.reevaluateInvites()
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

/// The invitation itself: who is calling, and Decline / Join.
private struct IncomingGroupCallScreen: View {
    let invite: AdhocInvite
    @ObservedObject private var service = GroupCallService.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer()
                avatars
                Text(invite.title).font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .padding(.horizontal, 24)
                Text(invite.video ? "Kulan video call" : "Kulan voice call")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                Spacer()
                HStack {
                    // owner, 2026-10-06: both go through GroupCallRinging, so the system ring for the
                    // same call stops with them and a decline reaches the caller.
                    button("Decline", icon: "phone.down.fill", tint: Color(.systemRed)) {
                        GroupCallRinging.shared.declineFromScreen(invite)
                    }
                    Spacer()
                    button("Join", icon: invite.video ? "video.fill" : "phone.fill",
                           tint: Color(.systemGreen)) { GroupCallRinging.shared.acceptFromScreen(invite) }
                }
                .padding(.horizontal, 48).padding(.bottom, 40)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Up to three faces, overlapping, the starter in front.
    private var avatars: some View {
        let shown = Array(invite.others.prefix(3))
        return HStack(spacing: -28) {
            ForEach(Array(shown.enumerated()), id: \.element.uid) { i, m in
                AvatarView(name: m.name, photoUrl: m.photoUrl, size: 96)
                    .overlay(Circle().stroke(Color.black, lineWidth: 3))
                    .zIndex(Double(shown.count - i))
            }
        }
    }

    private func button(_ label: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 72, height: 72).background(tint, in: Circle())
            }
            Text(label).font(.footnote).foregroundStyle(.white)
        }
    }
}
