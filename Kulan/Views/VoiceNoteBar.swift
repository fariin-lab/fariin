import SwiftUI

/// THE BAR THAT SAYS SOMETHING IS STILL PLAYING, once you have walked away from the chat it is in.
///
/// The engine (`VoiceNotePlayer`) is what keeps a voice note alive after you leave a conversation.
/// Without this, that work is invisible and unusable: the audio carries on with nothing on screen to
/// say what it is, no way to stop it, and no way back to it. The reference app shows exactly this, and it is
/// the half of the feature a person actually touches.
///
/// It appears ONLY when a note is OPEN — started, not yet finished or closed — and its chat is not the
/// one on screen; see `VoiceNotePlayer.barVisible`. Inside that chat the bubble already says everything
/// this would. Open rather than playing, because a paused note still needs its controls.
struct VoiceNoteBar: View {
    @ObservedObject private var engine = VoiceNotePlayer.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if engine.barVisible {
            HStack(spacing: 12) {
                // Play AND pause, not pause alone. The bar now outlives a pause — it has to, because
                // pulling out headphones and taking a phone call both pause the note, and a bar that
                // vanished on those would strand it: stopped, in a chat the person has walked away
                // from, with the only control gone. So this toggles.
                Button {
                    engine.playing ? engine.pause() : engine.resume()
                } label: {
                    Image(systemName: engine.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent(scheme == .dark))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent(scheme == .dark).opacity(0.16), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    // One answer for who this is from, shared with the lock screen — see
                    // `VoiceNotePlayer.noteTitle`. It used to be computed here, which meant the bar and
                    // the lock screen could have disagreed about what was playing.
                    Text(engine.noteTitle)
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
            //
            // ⚠️ THE MESSAGE ID GOES WITH IT, AND IT HAS TO BE SET FIRST. That route only ever carried
            // a chat, so this dropped you at the bottom of the conversation to go looking for the one
            // bubble that was moving. `pendingChatId` is what MainShell watches, so writing it last
            // guarantees the message is already parked when the chat is pushed.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                AppRouter.shared.pendingMessageId = engine.messageId
                AppRouter.shared.pendingChatId = engine.cid
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: engine.barVisible)
        }
    }
}
