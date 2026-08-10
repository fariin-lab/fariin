import SwiftUI

/// THE BAR THAT SAYS SOMETHING IS STILL PLAYING, once you have walked away from the chat it is in.
///
/// The engine (`VoiceNotePlayer`) is what keeps a voice note alive after you leave a conversation.
/// Without this, that work is invisible and unusable: the audio carries on with nothing on screen to
/// say what it is, no way to stop it, and no way back to it. WhatsApp shows exactly this, and it is
/// the half of the feature a person actually touches.
///
/// It appears ONLY when a note is playing and its chat is not the one on screen — see
/// `VoiceNotePlayer.barVisible`. Inside that chat the bubble already says everything this would.
struct VoiceNoteBar: View {
    @ObservedObject private var engine = VoiceNotePlayer.shared
    @Environment(\.colorScheme) private var scheme

    private var name: String {
        // `displayName` is the app's own answer, and the only correct one: `title` is the GROUP name
        // and is empty for a one-to-one chat, where the name lives in the `names` map instead. Reading
        // `title` directly would have left every private chat saying "Voice message".
        let me = AuthService.shared.uid ?? ""
        let conv = ConversationsRepository.shared.conversations.first { $0.id == engine.cid }
        let title = conv?.displayName(me) ?? ""
        if engine.isMine { return title.isEmpty ? "You" : "You · \(title)" }
        return title.isEmpty ? "Voice message" : title
    }

    var body: some View {
        if engine.barVisible {
            HStack(spacing: 12) {
                // Pause. The one control that has to be reachable without going anywhere, because the
                // reason a person looks for this bar is usually to stop it.
                Button {
                    engine.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent(scheme == .dark))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent(scheme == .dark).opacity(0.16), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    // A thin line rather than a full waveform: this is a status strip, not a player.
                    // Redrawing forty bars behind every screen in the app for a 100pt widget is cost
                    // with nothing bought.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.15))
                            Capsule().fill(Theme.accent(scheme == .dark))
                                .frame(width: max(2, geo.size.width * engine.progress))
                        }
                    }
                    .frame(height: 3)
                }

                // Close: stop and put the bar away. Distinct from pause on purpose — pause keeps your
                // place so you can carry on, this ends it.
                Button {
                    engine.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.horizontal, 12)
            // TAP THE BODY TO GO BACK TO IT. Through `AppRouter.pendingChatId`, which is the route
            // every other "open this chat" already uses (push taps, the in-app banner, forwarding), so
            // the tab foregrounding and the push are somebody else's solved problem.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { AppRouter.shared.pendingChatId = engine.cid }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: engine.barVisible)
        }
    }
}
