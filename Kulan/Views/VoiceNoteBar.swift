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
    /// The capsule's width, for turning a drag position into a point in the note.
    @State private var barWidth: CGFloat = 0

    static let height: CGFloat = 44
    /// The whole slot the bar takes under a header: the capsule plus its 6 above and 4 below
    /// (`body`'s paddings). The chat list reserves exactly this (`ChatListTable.voiceBar`).
    static let slotHeight: CGFloat = height + 6 + 4

    // The bar is a top inset; the chat list keeps itself at its top when the inset changes (see
    // `ChatListSelfSizingTable.adjustedContentInsetDidChange`), so nothing here signals it.
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
                    // ⛔ MINIMAL, AS IN THE REFERENCE — owner, 2026-09-29: "redesign the play icon,
                    // the text and the speed, don't touch the X". A smaller glyph in the accent, the
                    // only colour on the strip, so it reads as the control and nothing else does.
                    Image(systemName: engine.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // One answer for who this is from, shared with the lock screen — see
                // `VoiceNotePlayer.noteTitle`. Tight pair: a medium 13 name over a 11 caption, the
                // reference's strip weights, instead of two full-size lines filling the capsule.
                VStack(spacing: 0) {
                    Text(engine.noteTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Voice message")
                        .font(.system(size: 11))
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
            // Interactive, so a touch lights and stretches the glass the way the header's own
            // buttons do (owner, 2026-09-30).
            .liquidGlass(Capsule(), interactive: true)
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
            // ⛔ SLIDE TO SCRUB — owner, 2026-09-29: "I need to slide the progress bar left and right".
            // A horizontal drag anywhere on the capsule moves the note to that point of its width,
            // on the engine's own seek (the same one the bubble's waveform uses). Eight points of
            // travel before it counts, so a tap still opens the chat and the buttons still tap.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard barWidth > 0 else { return }
                        engine.setScrubbing(true)
                        engine.seek(Self.fraction(v.location.x, in: barWidth), id: engine.messageId)
                    }
                    .onEnded { v in
                        guard barWidth > 0 else { return }
                        engine.seek(Self.fraction(v.location.x, in: barWidth), id: engine.messageId)
                        engine.setScrubbing(false)
                    }
            )
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

    /// A drag's x across the bar's slot → a point in the note. The slot carries the capsule's 16pt
    /// side margins (`body`), so they come off both ends: the capsule's own edges are 0 and 1.
    static func fraction(_ x: CGFloat, in slotWidth: CGFloat) -> Double {
        let inset: CGFloat = 16
        let w = slotWidth - inset * 2
        guard w > 0 else { return 0 }
        return Double(max(0, min(1, (x - inset) / w)))
    }

    /// "1×", "1.5×", "2×", "0.5×".
    static func rateText(_ r: Float) -> String {
        let s = r == r.rounded() ? String(Int(r)) : String(format: "%g", Double(r))
        return "\(s)×"
    }
}

/// The speed, the reference's way: the number in a thin rounded outline. Replaces the dashed rules
/// above and below it (owner, 2026-09-29, "make it minimalist").
private struct SpeedMark: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: 26, minHeight: 17)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.secondary, lineWidth: 1.2))
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
