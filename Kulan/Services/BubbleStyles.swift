import SwiftUI
import UIKit

/// ⛔ BUBBLE STYLES (owner 2026-11-06, "Cute & Aesthetic Message Bubble Styles"). A style is chosen
/// once in Settings > Appearance > Bubble Styles and goes with every text message I send after that
/// (`bs` on the message), so the other person sees my bubbles in it too; their own bubbles keep
/// theirs. Builds that do not know a style, or a style id they do not have, draw the normal bubble.
///
/// Every look carries its own TEXT colour: my bubbles were always white text on a strong colour,
/// and a pastel needs dark text to stay readable. Stage one is colour; stage two adds the small
/// decorations (hearts, bows, stars) at a bubble's corners.
struct BubbleStyle: Identifiable, Equatable {
    struct Look: Equatable {
        /// One colour is a solid bubble, two a gradient.
        let fill: [UInt]
        let text: UInt
        /// Soft Glass: the system's own glass material instead of a colour.
        var glass = false
    }
    let id: String
    let name: String
    /// A Fariin Plus style (owner: "selected styles as Fariin Plus features"). Until Plus is sold,
    /// only the Fariin team may pick one (`BubbleStyles.mayUse`).
    let plus: Bool
    let light: Look
    let dark: Look
    /// A picture style (owner 2026-11-07, `PictureStyles`); nil for a colour style. Its look is the
    /// picture's own colour and text colour, the same in light and dark (SPEC section 1).
    var picture: PictureStyle? = nil

    func look(_ dark: Bool) -> Look { dark ? self.dark : light }

    init(id: String, name: String, plus: Bool, light: Look, dark: Look) {
        self.id = id; self.name = name; self.plus = plus; self.light = light; self.dark = dark
    }

    /// ⛔ EVERY PICTURE STYLE IS FREE (owner 2026-11-07). The colour styles keep their own flags.
    init(_ p: PictureStyle) {
        let look = Look(fill: [p.fill], text: p.textHex)
        self.init(id: p.id, name: p.name, plus: false, light: look, dark: look)
        picture = p
    }
}

enum BubbleStyles {
    /// What the pickers list: `all` minus the ones the admin panel hid (redraws live). A message
    /// already sent with a hidden style still draws it.
    static var shown: [BubbleStyle] {
        let hidden = LiveFeatures.shared.bubblesHidden
        return all.filter { !hidden.contains($0.id) }
    }
    /// Colour styles first, then the pictures in their groups.
    static let all: [BubbleStyle] = colours + PictureStyles.all.map(BubbleStyle.init)

    /// ⚠️ "pink" WAS "strawberry" until 2026-11-07: the picture set owns that id now (its file
    /// name, shared with Android). A message sent with the old colour id draws the strawberry
    /// picture, which is the same pink.
    static let colours: [BubbleStyle] = [
        BubbleStyle(id: "pink", name: "Strawberry Pink", plus: false,
                    light: .init(fill: [0xFFC9D6], text: 0x4A1020),
                    dark: .init(fill: [0x7E2F49], text: 0xFFE3EA)),
        BubbleStyle(id: "lavender", name: "Dreamy Lavender", plus: false,
                    light: .init(fill: [0xE6D8FF, 0xCDB6FF], text: 0x2E1A55),
                    dark: .init(fill: [0x4B3577, 0x6A4BA3], text: 0xF1E9FF)),
        BubbleStyle(id: "peach", name: "Peach Blossom", plus: false,
                    light: .init(fill: [0xFFDCC8], text: 0x4A2414),
                    dark: .init(fill: [0x7A4632], text: 0xFFE8DC)),
        BubbleStyle(id: "mint", name: "Mint Cutie", plus: false,
                    light: .init(fill: [0xCBF2DF], text: 0x123D2C),
                    dark: .init(fill: [0x2F6B54], text: 0xE2FFF3)),
        BubbleStyle(id: "cotton", name: "Cotton Candy", plus: true,
                    light: .init(fill: [0xFFC6E3, 0xBFE3FF], text: 0x2A2440),
                    dark: .init(fill: [0x7A3B66, 0x2F5D86], text: 0xF5EEFF)),
        BubbleStyle(id: "heart", name: "Heart Love", plus: true,
                    light: .init(fill: [0xFF9DBB], text: 0x4A0A22),
                    dark: .init(fill: [0xA8325C], text: 0xFFE6EF)),
        BubbleStyle(id: "kawaii", name: "Kawaii", plus: true,
                    light: .init(fill: [0xFFEBA8], text: 0x4A3A05),
                    dark: .init(fill: [0x76611E], text: 0xFFF6D6)),
        BubbleStyle(id: "glass", name: "Soft Glass", plus: true,
                    light: .init(fill: [0xFFFFFF], text: 0x1C1C1E, glass: true),
                    dark: .init(fill: [0x2C2C2E], text: 0xF2F2F7, glass: true)),
    ]

    /// ⛔ SHOWN AGAIN (owner 2026-11-07, "build and show in app", with the picture styles). It was
    /// hidden on 2026-11-06 ("I will do this feature next year, completely hide it"). Off: no
    /// Settings row, no search entry, nothing sent with a style, and every style draws as the
    /// normal bubble.
    static let shown = true

    private static let byId: [String: BubbleStyle] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// A colour style or a picture style; nil for an unknown id (an older build, a removed style).
    static func find(_ id: String?) -> BubbleStyle? {
        guard shown, let id, !id.isEmpty else { return nil }
        return byId[id]
    }

    /// The style I send with: UserDefaults, nil = the normal bubble.
    static let key = "bubbleStyle.v1"
    static var current: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Send my style's decorations too (owner: "optional decorative elements"). On by default.
    static let decorKey = "bubbleStyle.decor.v1"
    static var decorations: Bool {
        get { UserDefaults.standard.object(forKey: decorKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: decorKey) }
    }

    /// May I use this style now? A Plus style: the Fariin team only, until Plus is on sale.
    /// The admin record loads a moment after launch; until it does a team member is remembered from
    /// the last time it said so (5-angle check: a Plus style was silently dropped right after launch).
    private static let teamKey = "bubbleStyle.team.v1"
    @MainActor static func mayUse(_ s: BubbleStyle) -> Bool {
        guard s.plus else { return true }
        if AdminStore.shared.isAdmin { UserDefaults.standard.set(true, forKey: teamKey); return true }
        return UserDefaults.standard.bool(forKey: teamKey)
    }

    /// What goes on a message I send: my style, if I may still use it (a Plus style picked while
    /// on the team is not sent after leaving it).
    @MainActor static func forSending() -> String? {
        guard let s = find(current), mayUse(s) else { return nil }
        return s.id
    }

    /// My style as it was when a message was written: taken ONCE, so the bubble on my screen and
    /// the message that lands (or a retry later) wear the same style even if I change it meanwhile.
    struct Snapshot: Codable, Equatable {
        var id: String?
        var decor: Bool
    }

    @MainActor static func snapshotForSending() -> Snapshot {
        let id = forSending()
        return Snapshot(id: id, decor: id != nil && decorations)
    }

    /// The bubble fill for a styled message.
    static func fill(_ look: BubbleStyle.Look) -> BubbleFill {
        if look.glass { return .material }
        return look.fill.count > 1 ? .gradient(look.fill) : .solid(look.fill.first ?? 0x007AFF)
    }
}
