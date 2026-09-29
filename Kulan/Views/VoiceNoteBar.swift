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
///
/// ⛔ OWNER'S DESIGN, 2026-09-29, from his reference screenshot: one Liquid Glass capsule the width of
/// the search bar, UNDER the header (see `voiceNoteBarSlot`). A bare pause/play glyph on the left, the
/// name over "Voice Message" in the middle, the speed and a close mark on the right, and the progress
/// as a line along the capsule's bottom edge.
struct VoiceNoteBar: View {
    @ObservedObject private var engine = VoiceNotePlayer.shared

    static let height: CGFloat = 44

    var body: some View {
        if engine.barVisible {
            HStack(spacing: 0) {
                // Play AND pause, not pause alone. The bar now outlives a pause — it has to, because
                // pulling out headphones and taking a phone call both pause the note, and a bar that
                // vanished on those would strand it: stopped, in a chat the person has walked away
                // from, with the only control gone. So this toggles.
                Button {
                    engine.playing ? engine.pause() : engine.resume()
                } label: {
                    Image(systemName: engine.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // One answer for who this is from, shared with the lock screen — see
                // `VoiceNotePlayer.noteTitle`.
                VStack(spacing: 1) {
                    Text(engine.noteTitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Voice Message")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                // The same per-chat speed the bubble's pill cycles (1 → 1.5 → 2 → 0.5).
                Button {
                    engine.cycleRate(cid: engine.cid)
                } label: {
                    SpeedMark(text: Self.rateText(engine.rate(for: engine.cid)))
                        .frame(width: 44, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Close: stop and put the bar away. Distinct from pause on purpose — pause keeps your
                // place so you can carry on, this ends it.
                Button {
                    engine.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
            .frame(height: Self.height)
            // A thin line rather than a full waveform: this is a status strip, not a player. Along the
            // bottom edge, clipped by the capsule, the way his reference draws it.
            .overlay(alignment: .bottom) { progressLine }
            .clipShape(Capsule())
            .liquidGlass(Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
            // TAP THE BODY TO GO BACK TO IT. Through `AppRouter.pendingChatId`, which is the route
            // every other "open this chat" already uses (push taps, the in-app banner, forwarding), so
            // the tab foregrounding and the push are somebody else's solved problem.
            //
            // ⚠️ THE MESSAGE ID GOES WITH IT, AND IT HAS TO BE SET FIRST. That route only ever carried
            // a chat, so this dropped you at the bottom of the conversation to go looking for the one
            // bubble that was moving. `pendingChatId` is what MainShell watches, so writing it last
            // guarantees the message is already parked when the chat is pushed.
            .contentShape(Capsule())
            .onTapGesture {
                AppRouter.shared.pendingMessageId = engine.messageId
                AppRouter.shared.pendingChatId = engine.cid
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: engine.barVisible)
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.primary)
                .frame(width: max(0, geo.size.width * engine.progress), height: 2.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    /// "1X", "1.5X", "2X", "0.5X".
    static func rateText(_ r: Float) -> String {
        let s = r == r.rounded() ? String(Int(r)) : String(format: "%g", Double(r))
        return "\(s)X"
    }
}

/// The speed label from his reference: the number with a short dashed rule above and below it.
private struct SpeedMark: View {
    let text: String

    var body: some View {
        VStack(spacing: 3) {
            dashes
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            dashes
        }
    }

    private var dashes: some View {
        Line()
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
            .frame(width: 24, height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

extension View {
    /// Where the playing-note bar lives: UNDER a tab's header (below its search field, when it has
    /// one), owner 2026-09-29. Applied to each tab's root INSIDE its NavigationStack, because only
    /// there does the top safe area start below the navigation bar. An inset rather than an overlay,
    /// so the list underneath makes room instead of being covered.
    /// `showing: false` keeps the slot empty (Settings while its full-screen photo is open, where
    /// nothing may float over the picture).
    func voiceNoteBarSlot(showing: Bool = true) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if showing { VoiceNoteBar() }
        }
    }
}
