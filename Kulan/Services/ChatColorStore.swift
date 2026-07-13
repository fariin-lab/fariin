import SwiftUI

// A per-chat bubble colour the user picks for THEMSELVES (local, never synced) — the standard per-chat
// colour. One colour = solid; two = a gradient. Stored per-cid in UserDefaults as a compact hex string.
struct ChatColorSpec: Equatable, Identifiable {
    var colors: [UInt]        // 1 = solid, 2 = gradient (RGB hex)
    var id: String { stored }

    var isGradient: Bool { colors.count >= 2 }
    var solid: Color { Color(hex: colors.first ?? 0x3A76F0) }
    var gradient: LinearGradient {
        LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
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
    static let presets: [ChatColorSpec] = [
        .init(colors: [0xE9459B, 0xF06CC9]),   // pink gradient
        .init(colors: [0x5B6CF0, 0x8A4BF0]),   // blue → purple
        .init(colors: [0xC0243A]),             // red
        .init(colors: [0x14245B]),             // navy
        .init(colors: [0x101827]),             // near-black
    ]
}

// Observable so setting a colour re-renders the open chat instantly (live preview), same pattern as
// WallpaperStore: caches are observation-ignored; the `version` counter drives re-renders.
@Observable final class ChatColorStore {
    static let shared = ChatColorStore()
    private(set) var version = 0
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

    private func persistCustoms() {
        UserDefaults.standard.set(customColors.map(\.stored), forKey: "chatColor.customLibrary.v1")
    }

    func color(for cid: String) -> ChatColorSpec? {
        if let c = cache[cid] { return c }
        let spec = ChatColorSpec(stored: UserDefaults.standard.string(forKey: Self.key(cid)))
        cache[cid] = spec
        return spec
    }

    func set(_ spec: ChatColorSpec?, for cid: String) {
        cache[cid] = spec
        if let spec { UserDefaults.standard.set(spec.stored, forKey: Self.key(cid)) }
        else { UserDefaults.standard.removeObject(forKey: Self.key(cid)) }
        version &+= 1
    }

    private static func key(_ cid: String) -> String { "chatColor.\(cid)" }
}
