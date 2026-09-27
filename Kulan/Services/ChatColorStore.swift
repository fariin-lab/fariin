import SwiftUI

// A per-chat bubble colour the user picks for THEMSELVES (local, never synced) — the standard per-chat
// colour. One colour = solid; two = a gradient. Stored per-cid in UserDefaults as a compact hex string.
struct ChatColorSpec: Equatable, Identifiable {
    var colors: [UInt]        // 1 = solid, 2 = gradient (RGB hex)
    var id: String { stored }

    var isGradient: Bool { colors.count >= 2 }
    var solid: Color { Color(hex: colors.first ?? 0x3A76F0) }
    var gradient: LinearGradient {
        // Top to bottom, the first colour on top — the reference app's gradients all run this way
        // (their angles are 180°, or within 12° of it). Was corner to corner.
        LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
    }
    // The fill used behind a bubble — solid Color or the gradient, type-erased for one `.background(_:)`.
    var fill: AnyShapeStyle { isGradient ? AnyShapeStyle(gradient) : AnyShapeStyle(solid) }
    // A representative swatch colour (for the picker circle / button tint).
    var swatch: Color { solid }

    var stored: String { (isGradient ? "g:" : "s:") + colors.map { String(format: "%06X", $0) }.joined(separator: ",") }

    init(colors: [UInt]) { self.colors = colors }
    init?(stored: String?) {
        guard let s = stored, s.count > 2 else { return nil }
        let hexes = s.dropFirst(2).split(separator: ",").compactMap { UInt($0, radix: 16) }
        guard !hexes.isEmpty else { return nil }
        self.colors = hexes
    }

    // Build from HSB (used by the Custom Color editor). Brightness is fixed high so white bubble text
    // stays readable while the hue/saturation vary.
    static func solid(hue: Double, saturation: Double) -> ChatColorSpec {
        ChatColorSpec(colors: [rgbHex(hue: hue, saturation: saturation, brightness: 0.86)])
    }
    static func gradient(_ a: (h: Double, s: Double), _ b: (h: Double, s: Double)) -> ChatColorSpec {
        ChatColorSpec(colors: [rgbHex(hue: a.h, saturation: a.s, brightness: 0.86),
                               rgbHex(hue: b.h, saturation: b.s, brightness: 0.86)])
    }

    static func rgbHex(hue: Double, saturation: Double, brightness: Double) -> UInt {
        let ui = UIColor(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: CGFloat(brightness), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt(r * 255) << 16) | (UInt(g * 255) << 8) | UInt(b * 255)
    }
}

enum ChatColors {
    // Preset swatches shown in the picker (a mix of gradients + solids, the standard style).
    // ⛔ THE REFERENCE APP'S WHOLE PALETTE — owner, 2026-09-27, with its Chat Color page: "my chat
    // colours look ugly; copy theirs, all of them". Read from its source
    // (`PaletteChatColor+Constants.swift`): Ultramarine (its default), twelve solids, nine
    // gradients, in its order and with its exact values. Our five old presets are gone; a chat that
    // stored one still shows it (a stored colour is the colour itself, not a reference to this list).
    static let presets: [ChatColorSpec] = [
        .init(colors: [0x0552F0, 0x2C6BED]),   // Ultramarine
        .init(colors: [0xCF163E]),   // Crimson
        .init(colors: [0xC73F0A]),   // Vermilion
        .init(colors: [0x6F6A58]),   // Burlap
        .init(colors: [0x3B7845]),   // Forest
        .init(colors: [0x1D8663]),   // Wintergreen
        .init(colors: [0x077D92]),   // Teal
        .init(colors: [0x336BA3]),   // Blue
        .init(colors: [0x6058CA]),   // Indigo
        .init(colors: [0x9932C8]),   // Violet
        .init(colors: [0xAA377A]),   // Plum
        .init(colors: [0x8F616A]),   // Taupe
        .init(colors: [0x71717F]),   // Steel
        .init(colors: [0xE57C00, 0x5E0000]),   // Ember
        .init(colors: [0x2C2C3A, 0x787891]),   // Midnight
        .init(colors: [0xF65560, 0x442CED]),   // Infrared
        .init(colors: [0x004066, 0x32867D]),   // Lagoon
        .init(colors: [0xEC13DD, 0x1B36C6]),   // Fluorescent
        .init(colors: [0x2F9373, 0x077343]),   // Basil
        .init(colors: [0x6281D5, 0x974460]),   // Sublime
        .init(colors: [0x498FD4, 0x2C66A0]),   // Sea
        .init(colors: [0xDB7133, 0x911231]),   // Tangerine
    ]
}

// Observable so setting a colour re-renders the open chat instantly (live preview), same pattern as
// WallpaperStore: caches are observation-ignored; the `version` counter drives re-renders.
@Observable final class ChatColorStore {
    static let shared = ChatColorStore()
    private(set) var version = 0
    /// Stored picks by UserDefaults key (a chat's, or the default's). Resolution is not cached: it
    /// depends on the wallpaper store too, and is a few dictionary reads.
    @ObservationIgnored private var cache: [String: ChatColorSpec?] = [:]

    // CUSTOM COLOR LIBRARY (same idea as the wallpaper library): every colour the user builds in the
    // Custom Color editor is saved here permanently and shown as a reusable swatch in the picker —
    // newest first, deduped, presets never enter it. Observed so the picker updates live.
    private(set) var customColors: [ChatColorSpec]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: "chatColor.customLibrary.v1") ?? []
        customColors = stored.compactMap { ChatColorSpec(stored: $0) }
    }

    func addCustom(_ spec: ChatColorSpec) {
        guard !ChatColors.presets.contains(spec),                    // presets aren't "custom"
              !customColors.contains(spec) else { return }           // no duplicates
        customColors.insert(spec, at: 0)
        persistCustoms()
    }

    func removeCustom(_ spec: ChatColorSpec) {
        customColors.removeAll { $0 == spec }
        persistCustoms()
    }

    /// SIGN-OUT (audit 2026-09-24). Same problem as `WallpaperStore.reset`: per-chat colours, the
    /// all-chats default and the custom swatches are device-wide keys, so the next account inherited
    /// them. Called from `SessionWipe`.
    func reset() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("chatColor.") {
            d.removeObject(forKey: k)
        }
        cache = [:]
        customColors = []
        version &+= 1
    }

    private func persistCustoms() {
        UserDefaults.standard.set(customColors.map(\.stored), forKey: "chatColor.customLibrary.v1")
    }

    // MARK: - Auto colour, the reference app's rule
    //
    // ⛔ OWNER, 2026-09-27: "do it exactly like the reference app: the same Auto colour system". From its
    // source (`ChatColorSettingStore.resolvedChatColor` / `autoChatColor`, `Wallpaper.defaultChatColor`):
    //
    //   1. this chat's own chosen colour, if it has one — it always wins;
    //   2. otherwise AUTO, which asks, in order:
    //      a. this chat's OWN wallpaper (not the inherited one): its paired colour;
    //      b. the colour chosen in Settings;
    //      c. the Settings wallpaper: its paired colour;
    //      d. the app's default blue (nil here).
    //
    // A wallpaper has a paired colour only if it is one of the built-in themes (`bubbleHex`); a photo
    // or a plain-colour wallpaper has none and falls through, exactly as a photo does there.
    //
    // ⚠️ AUTO IS STORED AS NOTHING. No key for a chat = that chat is on Auto; no default key = the
    // Settings colour is Auto. Setting a wallpaper never writes a colour, so a colour somebody chose
    // stays until they pick Auto or reset it, and a chat on Auto follows every wallpaper change.

    /// What the bubbles draw. nil = the app's default blue.
    func color(for cid: String) -> ChatColorSpec? {
        chosenColor(for: cid) ?? autoColor(for: cid)
    }

    /// This chat's own pick; nil = Auto.
    func chosenColor(for cid: String) -> ChatColorSpec? { stored(Self.key(cid)) }

    /// The colour chosen in Settings; nil = Auto.
    var globalChosenColor: ChatColorSpec? { stored(Self.defaultKey) }

    /// What Auto gives this chat right now (the sheet's Auto circle shows it). nil = default blue.
    /// The sheet previews a wallpaper by writing it as the chat's own, so a previewed wallpaper's
    /// pairing is what this answers while it is being tried — their `previewWallpaper`.
    func autoColor(for cid: String) -> ChatColorSpec? {
        let walls = WallpaperStore.shared
        if walls.hasOverride(for: cid), let c = walls.wallpaper(for: cid).pairedColor { return c }
        return globalColor
    }

    /// What a chat with no wallpaper or colour of its own draws: the Settings colour, else the
    /// Settings wallpaper's pairing, else nil (default blue). Steps b–d above.
    var globalColor: ChatColorSpec? {
        globalChosenColor ?? WallpaperStore.shared.defaultWallpaper.pairedColor
    }

    /// Auto for the Settings colour itself: the Settings wallpaper's pairing, else default blue.
    var globalAutoColor: ChatColorSpec? { WallpaperStore.shared.defaultWallpaper.pairedColor }

    private func stored(_ key: String) -> ChatColorSpec? {
        if let hit = cache[key] { return hit }
        let raw = UserDefaults.standard.string(forKey: key)
        // `noneMarker` was the old per-chat Reset ("app blue, whatever the default says"). Reset now
        // means Auto, as it does there, so an old marker reads as Auto.
        let spec = raw == Self.noneMarker ? nil : ChatColorSpec(stored: raw)
        cache[key] = spec
        return spec
    }

    /// nil = Auto.
    func set(_ spec: ChatColorSpec?, for cid: String) {
        cache[Self.key(cid)] = nil
        if let spec { UserDefaults.standard.set(spec.stored, forKey: Self.key(cid)) }
        else { UserDefaults.standard.removeObject(forKey: Self.key(cid)) }
        version &+= 1
    }

    static let noneMarker = "__none__"

    /// "Reset Chat Color" for one chat: back to Auto.
    func resetChatColor(for cid: String) { set(nil, for: cid) }

    /// "Reset All Chat Colors": every chat and the Settings colour back to Auto (their
    /// `resetAllSettings`). The custom colour library is kept.
    func resetAllColors() { applyToAllChats(nil, clearingChatPicks: true) }

    /// "Apply For All Chats": the default bubble colour (nil = app default). Same rule as
    /// `WallpaperStore.applyToAllChats` (owner, 2026-09-27): a chat's own colour beats the default,
    /// because the chat wallpaper sheet saves a colour with the wallpaper, and a Settings theme
    /// replacing only the colour would leave that chat half its own and half the default.
    func applyToAllChats(_ spec: ChatColorSpec?, alsoFor cid: String? = nil, clearingChatPicks: Bool = false) {
        let d = UserDefaults.standard
        if clearingChatPicks {
            for k in d.dictionaryRepresentation().keys
                where k.hasPrefix("chatColor.") && k != "chatColor.customLibrary.v1" && k != Self.defaultKey {
                d.removeObject(forKey: k)
            }
        } else if let cid {
            d.removeObject(forKey: Self.key(cid))
        }
        cache = [:]
        if let spec { d.set(spec.stored, forKey: Self.defaultKey) } else { d.removeObject(forKey: Self.defaultKey) }
        version &+= 1
    }

    private static func key(_ cid: String) -> String { "chatColor.\(cid)" }
    static let defaultKey = "chatColor.__default__"   // the all-chats fallback
}
