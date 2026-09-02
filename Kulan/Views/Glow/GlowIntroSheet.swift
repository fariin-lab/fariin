import SwiftUI

/// ⛔ THE SHEET THAT EXPLAINS A GLOW BEFORE YOU GIVE ONE — owner, 2026-09-02, with a reference of
/// the shape he wants: a picture panel, a title, two lines of explanation, and one wide button.
/// "Only when the user wants to GIVE a glow, not when they want to remove one."
///
/// ⚠️ THE ASYMMETRY IS THE POINT AND IT IS NOT AN OVERSIGHT. Giving a Glow hands somebody a standing
/// view of your stories, which is the act that needs saying out loud; taking it back needs no
/// explanation because nothing new reaches anybody. So this stands between the tap and the give, and
/// never between the tap and the remove.
///
/// ⚠️ MONOCHROME, DELIBERATELY. His reference is a purple gradient because that is the app it came
/// from. His own standing rule — 2026-09-02, on the notifications page — is that this app is black
/// and white and I am not to invent a hue for Glow. The panel is a soft radial light instead, which
/// is both his palette and, for once, literally the thing the feature is named after.
struct GlowIntroSheet: View {
    /// Whose stories this is about. Named rather than "them", because a sentence with the person's
    /// name in it is the difference between a policy and an answer to what you just tapped.
    let name: String
    let onGlow: () -> Void

    init(name: String, onGlow: @escaping () -> Void) {
        self.name = name
        self.onGlow = onGlow
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 10) {
                Text("What a Glow does")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                // Three facts and no more: what it gets you, what it gives them, and that it is not
                // permanent. The third is what makes the first two safe to agree to.
                Text("A Glow lets you see \(displayName)'s stories without being in each other's chats. "
                     + "They can see yours when you post to your Glowers. "
                     + "Either of you can take it back at any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Spacer(minLength: 16)

            // ⛔ THE BUTTON SAYS "Glow" — his instruction: "change Learn more to Glow". It is the
            // action, not a link to a longer page: pressing it is what gives the glow, which is why
            // the sheet can be the whole confirmation rather than a step before one.
            Button {
                onGlow()
                dismiss()
            } label: {
                Text("Glow")
                    .font(.headline)
                    .foregroundStyle(GlowStyle.onAccent(scheme == .dark))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GlowStyle.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
        // The button is edge-attached chrome and the system rests it — the rule he has sent four
        // times now, and the same treatment the wallpaper sheet's Apply buttons take.
        .safeAreaPadding(.bottom)
        .presentationDetents([.height(430)])
    }

    private var displayName: String {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "their" : t + "'s"
    }

    /// The picture panel. His reference fills it with the product's own icons; ours is the Glow mark
    /// lit from behind, which is the only "image" this feature has and the one he supplied.
    private var hero: some View {
        ZStack {
            RadialGradient(colors: [Color.primary.opacity(0.20), Color.primary.opacity(0)],
                           center: .center, startRadius: 2, endRadius: 160)
            GlowStyle.mark(76, filled: true)
                .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .overlay(alignment: .topTrailing) {
            // ⚠️ AN ✕ AND NO DRAG INDICATOR. His reference has the ✕ and the two together are two
            // ways to say the same thing in the same corner of the eye — the attach sheet went
            // through this exact argument on 2026-09-02.
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }
}
