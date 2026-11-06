import SwiftUI
import UIKit
import Combine

/// ⛔ ANIMATED CHAT WALLPAPERS (owner 2026-11-06, his three reference videos: liquid metal, water,
/// aurora; then liquid glow and liquid edge). Each is drawn live by a shader in `AnimatedWallpapers.metal`: no pictures, no video, so
/// nothing to license and nothing to download. Stage one: Liquid Metal, Water, Aurora ×3. Stars,
/// Particles and Doodles come next.
struct AnimatedWallpaper: Identifiable, Equatable {
    enum Look: Equatable { case liquidMetal, water, liquidGlow, liquidEdge, aurora(palette: Int) }
    let id: String
    let name: String
    let look: Look
    /// Seconds for one full loop of the motion (the shader's phase goes once round in this time).
    let period: Double

    /// Is the top of the screen dark in this mode? Decides the chat header's text colour, since a
    /// moving ground has no still picture to measure (`WallpaperBlur.headerBackdrop`).
    func topIsDark(_ dark: Bool) -> Bool {
        switch look {
        case .liquidMetal, .water, .liquidGlow, .liquidEdge: return dark
        case .aurora: return true
        }
    }
}

enum AnimatedWallpapers {
    static let all: [AnimatedWallpaper] = [
        AnimatedWallpaper(id: "liquid-metal", name: "Liquid Metal", look: .liquidMetal, period: 90),
        AnimatedWallpaper(id: "water", name: "Water", look: .water, period: 60),
        AnimatedWallpaper(id: "liquid-glow", name: "Liquid Glow", look: .liquidGlow, period: 40),
        AnimatedWallpaper(id: "liquid-edge", name: "Liquid Edge", look: .liquidEdge, period: 50),
        AnimatedWallpaper(id: "aurora-green", name: "Aurora Green", look: .aurora(palette: 0), period: 75),
        AnimatedWallpaper(id: "aurora-purple", name: "Aurora Purple", look: .aurora(palette: 1), period: 75),
        AnimatedWallpaper(id: "aurora-pink", name: "Aurora Pink", look: .aurora(palette: 2), period: 75),
    ]

    static func find(_ id: String) -> AnimatedWallpaper? { all.first { $0.id == id } }

    /// Settings > Appearance > Animated Wallpapers. Off: every animated wallpaper is a still frame.
    static let enabledKey = "animatedWallpapers"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
}

/// One animated wallpaper on screen. It MOVES only when all of these hold: the setting is on, Reduce
/// Motion is off, Low Power Mode is off, the app is active, and this view is on screen. Otherwise it
/// shows one still frame of the same look. At most 30 frames a second, drawn at a third of the
/// screen's resolution and scaled up (the looks are soft, the difference does not show).
struct AnimatedWallpaperView: View {
    let wallpaper: AnimatedWallpaper
    let dark: Bool
    /// Tiles in the picker run slower and smaller; the chat runs the full look.
    var preview = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AnimatedWallpapers.enabledKey) private var enabledSetting = true
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The loop's own clock: phase is measured from here, so it starts at 0 and never grows large.
    @State private var start = Date()

    private var moving: Bool {
        enabledSetting && !reduceMotion && !lowPower && scenePhase == .active && onScreen
    }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size
            let k: CGFloat = preview ? 2 : 3
            let small = CGSize(width: max(1, full.width / k), height: max(1, full.height / k))
            TimelineView(.animation(minimumInterval: 1.0 / (preview ? 20.0 : 30.0), paused: !moving)) { ctx in
                // The timeline's own date: paused, it stays on the last frame shown, so stopping and
                // starting again carries on from there instead of jumping back to the beginning.
                let seconds = max(0, ctx.date.timeIntervalSince(start))
                let phase = Float((seconds / wallpaper.period).truncatingRemainder(dividingBy: 1) * 2 * .pi)
                Rectangle()
                    .frame(width: small.width, height: small.height)
                    .colorEffect(shader(size: small, phase: phase))
                    .drawingGroup()
                    .scaleEffect(k, anchor: .topLeading)
                    .frame(width: full.width, height: full.height, alignment: .topLeading)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func shader(size: CGSize, phase: Float) -> Shader {
        let s = Shader.Argument.float2(Float(size.width), Float(size.height))
        let d = Shader.Argument.float(dark ? 1 : 0)
        switch wallpaper.look {
        case .liquidMetal: return ShaderLibrary.default.fariinLiquidMetal(s, .float(phase), d)
        case .water: return ShaderLibrary.default.fariinWater(s, .float(phase), d)
        case .liquidGlow: return ShaderLibrary.default.fariinLiquidGlow(s, .float(phase), d)
        case .liquidEdge: return ShaderLibrary.default.fariinLiquidEdge(s, .float(phase), d)
        case .aurora(let p): return ShaderLibrary.default.fariinAurora(s, .float(phase), d, .float(Float(p)))
        }
    }
}
