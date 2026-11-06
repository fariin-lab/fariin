import SwiftUI
import UIKit
import Combine

/// ⛔ ANIMATED CHAT WALLPAPERS (owner 2026-11-06, his three reference videos: liquid metal, water,
/// aurora; then liquid glow and liquid edge). Each is drawn live by a shader in `AnimatedWallpapers.metal`: no pictures, no video, so
/// nothing to license and nothing to download. Stage one: Liquid Metal, Water, Aurora ×3. Stars,
/// Particles and Doodles come next.
struct AnimatedWallpaper: Identifiable, Equatable {
    enum Look: Equatable {
        case liquidMetal, water, liquidGlow, liquidEdge, aurora(palette: Int), stars
        /// 0 snow, 1 rain, 2 glowing dots.
        case particles(kind: Int)
        /// Fariin's own doodle sheet drifting over the nth patterned theme (`ChatWallpapers`).
        case doodles(theme: Int)
    }
    let id: String
    let name: String
    let look: Look
    /// Seconds for one full loop of the motion (the shader's phase goes once round in this time).
    let period: Double

    /// Is the top of the screen dark in this mode? Decides the chat header's text colour, since a
    /// moving ground has no still picture to measure (`WallpaperBlur.headerBackdrop`).
    func topIsDark(_ dark: Bool) -> Bool {
        switch look {
        case .liquidMetal, .water, .liquidGlow, .liquidEdge, .doodles, .particles: return dark
        case .aurora, .stars: return true
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
        // Stage two (owner 2026-11-06): space, particles, doodles.
        AnimatedWallpaper(id: "stars", name: "Stars", look: .stars, period: 60),
        AnimatedWallpaper(id: "snow", name: "Snow", look: .particles(kind: 0), period: 20),
        AnimatedWallpaper(id: "rain", name: "Rain", look: .particles(kind: 1), period: 6),
        AnimatedWallpaper(id: "glow-dots", name: "Glowing Dots", look: .particles(kind: 2), period: 30),
        AnimatedWallpaper(id: "doodles-1", name: "Doodles", look: .doodles(theme: 0), period: 40),
        AnimatedWallpaper(id: "doodles-2", name: "Doodles 2", look: .doodles(theme: 1), period: 40),
        AnimatedWallpaper(id: "doodles-3", name: "Doodles 3", look: .doodles(theme: 2), period: 40),
    ]

    static func find(_ id: String) -> AnimatedWallpaper? { all.first { $0.id == id } }

    /// Settings > Appearance > Animated Wallpapers. Off: every animated wallpaper is a still frame.
    static let enabledKey = "animatedWallpapers"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Snow, rain and glowing dots: 0 light, 1 medium (default), 2 heavy. Settings > Appearance.
    static let intensityKey = "animatedWallpapers.intensity"
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
    @AppStorage(AnimatedWallpapers.intensityKey) private var intensity = 1
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The loop's own clock: phase is measured from here, so it starts at 0 and never grows large.
    @State private var start = Date()

    private var moving: Bool {
        enabledSetting && !reduceMotion && !lowPower && scenePhase == .active && onScreen
    }

    var body: some View {
        if case .doodles(let theme) = wallpaper.look {
            doodles(theme)
        } else {
            shaderBody
        }
    }

    /// Doodles: the theme's ground, and the doodle sheet (a little larger than the screen, so no edge
    /// shows) drifting on a small loop with a soft light passing over it. Only transforms of one
    /// picture: the cheapest look of all.
    @ViewBuilder private func doodles(_ theme: Int) -> some View {
        let themes = ChatWallpapers.all.filter { $0.pattern }
        if theme < themes.count, let sheet = ChatPattern.sheet {
            let g = themes[theme]
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !moving)) { ctx in
                let seconds = max(0, ctx.date.timeIntervalSince(start))
                let phase = (seconds / wallpaper.period).truncatingRemainder(dividingBy: 1) * 2 * .pi
                let ground = MeshGradient(width: 3, height: 3, points: WallpaperGradient.meshPoints,
                                          colors: g.meshColors(dark))
                ground
                    .overlay {
                        ground
                            .overlay(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.16))
                            .mask {
                                Color.clear
                                    .overlay {
                                        Image(uiImage: sheet).resizable().scaledToFill()
                                            .scaleEffect(1.12)
                                            .offset(x: cos(phase) * 14, y: sin(phase) * 10)
                                    }
                                    .clipped()
                            }
                    }
                    .overlay {
                        // The light passing over: a soft diagonal band crossing once per loop.
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, .white.opacity(dark ? 0.06 : 0.10), .clear],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: geo.size.width * 0.8, height: geo.size.height * 1.6)
                                .rotationEffect(.degrees(20))
                                .offset(x: -geo.size.width + (geo.size.width * 2.2) * (phase / (2 * .pi)),
                                        y: -geo.size.height * 0.3)
                        }
                        .allowsHitTesting(false)
                    }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
        } else {
            Theme.bg(dark)
        }
    }

    private var shaderBody: some View {
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
        case .stars: return ShaderLibrary.default.fariinStars(s, .float(phase), d)
        case .particles(let k):
            return ShaderLibrary.default.fariinParticles(s, .float(phase), d, .float(Float(k)),
                                                         .float(Float(min(2, max(0, intensity)))))
        case .doodles: return ShaderLibrary.default.fariinLiquidGlow(s, .float(phase), d)   // unused: doodles draw without a shader
        }
    }
}
