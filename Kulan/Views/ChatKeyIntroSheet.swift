import SwiftUI

/// ⛔ THE SHEET THAT SAYS WHAT A CHAT KEY IS — owner, 2026-09-11, with two mock-ups: "when I click
/// Set a Chat Key, show a sheet like this explaining what a Chat Key is. Also when the user selects
/// 'People who know my key', show that sheet."
///
/// Both of his doors are the same moment: somebody is about to make a decision about a feature this
/// app invented, and nothing on either screen has told them what it is. The Settings row's footer
/// has one sentence and the privacy row has none.
///
/// ⚠️ IT STANDS BEFORE THE ACT, NOT AFTER IT. "Got it" continues into whatever was tapped — the
/// keypad, or the privacy change — so this is a step in the flow rather than a detour out of it, and
/// closing it with the ✕ leaves everything exactly as it was.
///
/// ⚠️ AND IT IS NOT A "SHOW ONCE" SHEET, because it cannot become one by accident. The Settings door
/// is "Set a Chat Key", which is only on screen for an account that has NO key; the privacy door is
/// the first time that mode is chosen without one. Both are rare by construction, so neither needs a
/// seen-flag, and a flag would be a thing to get wrong for no gain.
struct ChatKeyIntroSheet: View {
    /// Called by "Got it" to RECORD that the flow should continue — see the button. It must
    /// not present anything itself. The ✕ does not call it at all.
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    /// ⛔ THE APP'S OWN BLUE, NOT A NEW ONE. The standing rule is that this app is black and white
    /// and I do not invent a hue — but his mock-up is blue, and he has asked for blue buttons on
    /// three other screens today. `Theme.defaultBubble` is the blue this app already uses for an
    /// outgoing bubble, and it is a different value in light and dark so it stays legible in both.
    private var accent: Color { Theme.defaultBubble(dark) }

    var body: some View {
        ScrollView {
                VStack(spacing: 0) {
                    // ⛔ THE REFERENCE SHEET'S SHAPE — owner, 2026-09-27: "this sheet looks like AI
                    // slop; make it smooth and clear like the other app's", with its Disable Sharing
                    // sheet beside it. What that sheet is: one big emoji, a bold title with nothing
                    // under it, three rows each a thin blue outline icon beside a semibold line and
                    // a grey sentence, one blue button. The glowing disc, the eight rays, the
                    // paragraph and the tinted icon tiles are gone.
                    Text("🔑")
                        .font(.system(size: 96))
                        .padding(.top, 36)
                    Text("What is a Chat Key?")
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)

                    VStack(alignment: .leading, spacing: 26) {
                        // ⛔ THIS LINE IS NOT THE ONE HE WROTE, AND THE CHANGE IS DELIBERATE. His
                        // mock-up says "Your Chat Key is end-to-end encrypted", and that is not what
                        // this feature does: the key is hashed with scrypt and only the hash is
                        // stored, which is how a server can check a key it cannot read. That is a
                        // GOOD property and it is worth saying — but "end-to-end encrypted" means
                        // something specific in this app, it is printed on the chat screen itself,
                        // and using it for something else would make the real claim worth less.
                        // What is written here is true and is the same reassurance.
                        point("lock", "Private and secure",
                              "Your key is never stored as you typed it. We keep a scrambled copy "
                              + "that cannot be turned back into your key.")
                        point("person.2", "Direct communication",
                              "People with your Chat Key can message and call you straight away, "
                              + "whatever your Messages and Calls settings say.")
                        point("checkmark.shield", "You are in control",
                              "Share it only with people you want to hear from, and change or "
                              + "remove it whenever you like.")
                    }
                    .padding(.top, 34)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // ⛔ "GOT IT" IS EDGE-ATTACHED, NOT THE LAST ROW OF A STACK — owner, 2026-09-16, quoting the
        // distinction back at me: content inside the safe area is app content; system chrome and
        // edge-attached UI is system-positioned. It was the second child of a `VStack`, so it took
        // its place from the content above it and the three points scrolled UNDERNEATH nothing —
        // the button simply sat wherever the stack ended, over the text at the `.medium` detent.
        //
        // A `safeAreaInset` is the system-positioned place for a sheet's one action: pinned to the
        // bottom edge, clear of the home indicator on its own, and the scroll view above it insets
        // itself so the last point can always be scrolled clear of it. Same decision, same reason, as
        // Save on `ChatPinSetSheet`.
        .safeAreaInset(edge: .bottom) {
            Button {
                // ⚠️ THE FLAG IS RAISED HERE AND ACTED ON IN `onDismiss`, NOT HERE — the trap this
                // codebase has been caught by twice. Setting the presenter's other sheet flag while
                // THIS sheet is still animating away asks SwiftUI to present and dismiss in one
                // frame, and what it does with that is drop one of them. So `onContinue` only
                // records the intent; every caller reads it back once this sheet is really gone.
                onContinue()
                dismiss()
            } label: {
                Text("Got it")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            // ⚠️ 8, NOT A FULL GUTTER. A `safeAreaInset` already rests above the home indicator, so a
            // larger number here stacks on top of that band and lifts the button off the edge — the
            // same arithmetic mistake the Save button on the other sheet records.
            .padding(.bottom, 8)
        }
        .overlay(alignment: .topLeading) {
            // His mock-up's ✕, in the corner it is drawn in. The drag indicator stays off for the
            // reason the Glow sheet records: two ways to say "close" in the same corner of the eye.
            // The reference's ✕: a 44pt glass circle, the same close every other sheet here has.
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        // ⚠️ `.safeAreaPadding(.bottom)` IS GONE FROM HERE. It was resting the button when the button
        // was a child of the stack; the `safeAreaInset` above rests itself, and leaving both in would
        // count the home-indicator band twice.
        //
        // ⛔ ONE TALL DETENT — owner, 2026-09-16: "I can see text very well plz open sheet very well
        // to see text, open up to like image 2", with the half-height sheet and the full one side by
        // side. `.medium` is what he photographed: three points and a paragraph do not fit in half a
        // phone, so the sheet opened already clipped and the reassurance the screen exists to give was
        // the part cut off. It opens at the height his second shot shows, and still scrolls.
        //
        // ⛔ AS TALL AS ITS WORDS, NOT THE WHOLE PHONE — owner, 2026-09-27, with a band of empty dark
        // ringed between the last point and Got it: "open like 70% or fix the empty space, like image
        // 2" (the reference's Disable Sharing sheet, which ends right under its button). `.large`
        // fixed the clipping above and left this gap on every tall phone. The sheet is now the
        // measured content plus the button's band (52 + 12 + 8), so nothing is clipped and nothing is
        // empty; with very large text the system caps it at full height and it scrolls as before.
        .presentationDetents([.height(contentHeight + 72)])
        .presentationDragIndicator(.hidden)
    }

    /// Measured from the content; the first value is a close estimate so the sheet does not open
    /// at one height and move to another.
    @State private var contentHeight: CGFloat = 540

    /// One row, the reference's: a thin outline glyph in the app's blue, no tile behind it, and
    /// the title over its sentence.
    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(body)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
