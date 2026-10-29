import SwiftUI

/// Where the composer goes for someone who is not an admin of a channel (2026-10-28). Following:
/// one centred glass pill, Mute / Unmute (the reference app's channel footer). Not following (I
/// unfollowed, or opened it from a link I have not used): Follow, for a public channel.
struct ChannelFollowerBar: View {
    let conv: Conversation
    @State private var follows = ChannelFollows.shared
    @State private var busy = false
    @State private var problem: String?

    private var following: Bool { follows.follows(conv.id) }
    private var muted: Bool { follows.entry(conv.id)?.muted ?? false }

    var body: some View {
        VStack(spacing: 8) {
            if let problem {
                Text(problem).font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if following {
                pill(muted ? "Unmute" : "Mute", icon: muted ? "bell" : "bell.slash", tint: nil) {
                    Haptics.impact(.light)
                    ChannelService.setMuted(cid: conv.id, !muted)
                }
                .accessibilityLabel(muted ? "Unmute channel" : "Mute channel")
            } else if conv.isPublic {
                pill(busy ? "Following…" : "Follow", icon: nil, tint: Color(hex: 0x2392FE)) { follow() }
            } else {
                Text("This channel is private. Ask an admin for its invite link.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .systemBarChrome()
    }

    private func pill(_ title: String, icon: String?, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 16, weight: .medium)) }
                Text(title).font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 19)
            .frame(minWidth: 166)
            .frame(height: 44)
            .liquidGlass(Capsule(), interactive: true, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func follow() {
        guard !busy else { return }
        guard NetworkState.shared.isOnline else { problem = "No internet connection. Try again."; return }
        busy = true; problem = nil
        Task {
            do { try await ChannelService.follow(cid: conv.id) } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}
