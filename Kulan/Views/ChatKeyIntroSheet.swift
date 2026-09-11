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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    Text("What is a Chat Key?")
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                    Text("A Chat Key is a private code that lets people message and call you "
                         + "directly, without your phone number and whatever your usual privacy "
                         + "settings say.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)

                    VStack(spacing: 18) {
                        // ⛔ THIS LINE IS NOT THE ONE HE WROTE, AND THE CHANGE IS DELIBERATE. His
                        // mock-up says "Your Chat Key is end-to-end encrypted", and that is not what
                        // this feature does: the key is hashed with scrypt and only the hash is
                        // stored, which is how a server can check a key it cannot read. That is a
                        // GOOD property and it is worth saying — but "end-to-end encrypted" means
                        // something specific in this app, it is printed on the chat screen itself,
                        // and using it for something else would make the real claim worth less.
                        // What is written here is true and is the same reassurance.
                        point("lock.fill", "Private and secure",
                              "Your key is never stored as you typed it. We keep a scrambled copy "
                              + "that cannot be turned back into your key.")
                        point("person.2.fill", "Direct communication",
                              "People with your Chat Key can message and call you straight away, "
                              + "whatever your Messages and Calls settings say.")
                        point("checkmark.shield.fill", "You are in control",
                              "Share it only with people you want to hear from, and change or "
                              + "remove it whenever you like.")
                    }
                    .padding(.top, 26)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

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
        }
        .overlay(alignment: .topLeading) {
            // His mock-up's ✕, in the corner it is drawn in. The drag indicator stays off for the
            // reason the Glow sheet records: two ways to say "close" in the same corner of the eye.
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        // Edge-attached chrome is rested by the system — the rule he has sent four times.
        .safeAreaPadding(.bottom)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    /// The illustration. His fuller mock-up draws a phone ringed by four faces on dashed lines;
    /// this is the simpler of his two — the key on a lit disc — because that one is artwork and this
    /// one is geometry. If he wants the four faces it needs a real drawing, not more SwiftUI.
    private var hero: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.22), accent.opacity(0)],
                                     center: .center, startRadius: 20, endRadius: 92))
                .frame(width: 184, height: 184)
            Circle()
                .fill(accent.opacity(0.14))
                .frame(width: 116, height: 116)
            Circle()
                .fill(accent)
                .frame(width: 84, height: 84)
            Image(systemName: "key.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
                // The mock-up's key lies along the diagonal rather than upright.
                .rotationEffect(.degrees(-45))
            // The little rays his first mock-up draws either side of the disc.
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(accent.opacity(0.55))
                    .frame(width: 12, height: 3)
                    .offset(x: 74)
                    .rotationEffect(.degrees(Double(i) * 45 + 22.5))
            }
        }
        .frame(height: 200)
        .padding(.top, 28)
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(accent.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
