import SwiftUI

/// Mounted once at the root (inside CallContainer). Two jobs, both for multi-person and link calls:
/// the full-screen invitation when someone adds me to a call, and the call screen itself, which has
/// no chat or group page of its own to be presented from.
struct IncomingGroupCallLayer: View {
    @ObservedObject private var service = GroupCallService.shared
    @State private var showRoom = false

    var body: some View {
        ZStack {
            // A real, zero-sized anchor so the cover and listeners below always have a view to
            // hang on, and nothing takes space or touches while no invitation is up.
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if let invite = service.incomingInvite {
                IncomingGroupCallScreen(invite: invite)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.incomingInvite?.roomId)
        .onAppear { service.startInviteListener() }
        // Held a beat: the start usually comes from a sheet or the 1:1 screen closing on the same
        // tap, and a cover asked for mid-dismissal is dropped by UIKit.
        .onChange(of: service.presentsRoomScreen) { _, want in
            guard want else { showRoom = false; return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                // Hard cut, no slide-up: the reference app swaps to its call window instantly.
                if service.presentsRoomScreen {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { showRoom = true }
                }
            }
        }
        // Nothing rings during a 1:1. Once it is over, look again, after the handover to a
        // multi-person call has had its moment to join (so its own invite never flashes up).
        .onChange(of: CallService.shared.state) { _, state in
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
                    button("Decline", icon: "phone.down.fill", tint: Color(.systemRed)) { service.declineInvite() }
                    Spacer()
                    button("Join", icon: invite.video ? "video.fill" : "phone.fill",
                           tint: Color(.systemGreen)) { service.acceptInvite() }
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
