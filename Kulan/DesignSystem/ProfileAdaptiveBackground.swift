import SwiftUI
import UIKit

// MARK: - The theme, handed down the page

/// The palette of the profile currently on screen, or nil for a page that has no photo to read.
///
/// An environment value rather than a parameter because the cards are built in six different places
/// on the page and `PosterActionIcon` is shared with two other screens; threading a colour through
/// every call site would put the decision in a dozen places instead of one.
private struct ProfilePaletteKey: EnvironmentKey {
    static let defaultValue: ProfilePalette? = nil
}

extension EnvironmentValues {
    var profilePalette: ProfilePalette? {
        get { self[ProfilePaletteKey.self] }
        set { self[ProfilePaletteKey.self] = newValue }
    }
}

// MARK: - The page

/// The adaptive profile page: ONE FLAT COLOUR, extracted from the person's photograph.
///
/// ⚠️ **NOT A BLURRED COPY OF THE PHOTO, AND NOT A GRADIENT.** This view used to draw the photo
/// itself, downscaled and blurred, across the whole screen — the ordinary way apps do this — and it
/// was rejected outright (owner, 2026-08-19: "Do not use blur to generate the background colour…
/// the extracted colour should be a clean, flat/solid adaptive colour"). The picture is read for a
/// colour and then it is put away: what the page paints is a solid fill, the same one at the top of
/// the screen as at the bottom.
///
/// The only blur left anywhere near this is inside the HEADER, where the photograph loses its detail
/// over its last stretch and arrives at exactly this colour. That is a transition between a picture
/// and a colour, which is the one place blur is allowed, and it is not what decides the colour.
struct ProfileAdaptiveBackdrop: View {
    let palette: ProfilePalette?
    /// Drawn when there is no photo to read — an ordinary system page, which is the stated fallback.
    let fallback: Color
    /// The palette this view has already drawn once. See `wash` — it is the whole reason the first
    /// colours of a session land instantly and every later change is animated.
    @State private var drawn: String?

    var body: some View {
        // ⚠️ ONE VIEW, WHATEVER THE STATE — never `if palette != nil { … } else { … }`. Two branches
        // are two view identities, and SwiftUI does not animate BETWEEN identities, it swaps them.
        // The colours land a beat after the page does (a photo has to be read first), so a swap here
        // is precisely the flash this has to avoid: the fill is one value that changes, and a
        // changing fill is something SwiftUI can carry.
        Rectangle()
            .fill(colour)
            .animation(wash, value: palette?.key)
            .onChange(of: palette?.key, initial: true) { _, key in drawn = key }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// ⚠️ THE FIRST COLOURS OF A VISIT LAND INSTANTLY; ONLY A CHANGE OF PERSON IS ANIMATED.
    ///
    /// The page is not the only thing that turns over when a reading lands — the cards, the hairlines
    /// and the header's fade all change with it, and not every one of them is a colour SwiftUI can
    /// carry. Washing one of them over 0.4s while the rest cut is worse than everything cutting
    /// together, so an arrival is a single frame where the whole page agrees. The animation is kept
    /// for going from one person's colour straight to another's, which is a change of subject rather
    /// than the page finishing loading.
    private var wash: Animation? {
        drawn == nil ? nil : .easeInOut(duration: 0.40)
    }

    private var colour: Color {
        guard let palette else { return fallback }
        return Color(uiColor: palette.page)
    }
}

// MARK: - The cards

/// THE SURFACE EVERY GROUPED CARD ON A PROFILE WEARS.
///
/// **This has been asked for four times now and the history is the whole reason it looks like this.**
/// It started as `.ultraThinMaterial`, from a written spec, and was rejected on sight. It went back
/// to the plain opaque grouped card and that was rejected too — white cards on a coloured page were
/// never the idea. It then became Liquid Glass, picked off two live toolbar buttons. That is what
/// this replaces, and the current instruction is explicit (owner, 2026-08-19): "The cards should not
/// become Liquid Glass… no heavy glass effect, no frosted/blurred card interior, no excessive
/// transparency… Apple-style flat adaptive cards + dynamic profile colour."
///
/// So: **a flat, opaque fill, made of the page's own colour, lifted.** Nothing here samples, blurs
/// or refracts anything behind it — there is no material in this file at all. The lift is brightness,
/// never saturation, which is what keeps a violet profile's cards a lighter violet rather than a
/// louder one. A hairline sits on top of that for the pages whose colour is light enough that the
/// step alone is quiet.
struct ProfileAdaptiveSurface: ViewModifier {
    /// Drawn instead of the tint on a profile with no photo — the ordinary card colour.
    let plain: Color
    let radius: CGFloat
    @Environment(\.profilePalette) private var palette
    /// Same rule as the page behind it: the first colours land in the frame the text flips, and only
    /// a change of person is washed. A card that animated while the page cut would be worse than
    /// either on its own.
    @State private var drawn: String?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// ONE PATH, tinted or not — same reason as the page above. A card that is rebuilt when the
    /// colours arrive pops; a card whose fill changes washes.
    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            // Hairline, not a shadow and not a border: this page has no shadows anywhere, and a
            // visible stroke on a card this subtle would be the loudest thing on the screen. It is
            // clear — drawn and invisible — on a profile with no colours, so the card is never
            // rebuilt just because a hairline came or went.
            .overlay(shape.strokeBorder(stroke, lineWidth: 0.5))
            .animation(drawn == nil ? nil : .easeInOut(duration: 0.40), value: palette?.key)
            .onChange(of: palette?.key, initial: true) { _, key in drawn = key }
    }

    private var fill: Color {
        guard let palette else { return plain }
        return Color(uiColor: palette.card)
    }

    private var stroke: Color {
        guard let palette else { return .clear }
        return Color(uiColor: palette.edge)
    }
}

extension View {
    /// The one place a profile card decides what it sits on. Reads the environment, so a card never
    /// has to be told twice.
    func profileSurface(plain: Color, radius: CGFloat = 24) -> some View {
        modifier(ProfileAdaptiveSurface(plain: plain, radius: radius))
    }
}
