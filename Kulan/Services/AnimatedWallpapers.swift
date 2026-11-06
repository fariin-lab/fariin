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
        AnimatedWallpaper(id: "snow", name: "Snow", look: .particles(kind: 0), period: 160),
        AnimatedWallpaper(id: "rain", name: "Rain", look: .particles(kind: 1), period: 20),
        AnimatedWallpaper(id: "glow-dots", name: "Glowing Dots", look: .particles(kind: 2), period: 480),
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

/// One animated wallpaper on screen. It MOVES only when all of these hold: Reduce Motion is off,
/// the app is active, and this view is on screen. Otherwise it
/// shows one still frame of the same look. At most 30 frames a second, drawn at a third of the
/// screen's resolution and scaled up (the looks are soft, the difference does not show).
struct AnimatedWallpaperView: View {
    let wallpaper: AnimatedWallpaper
    let dark: Bool
    /// Tiles in the picker run slower and smaller; the chat runs the full look.
    var preview = false
    /// A picker tile that is not the chosen one shows a still frame (5-angle check: fourteen tiles
    /// all moving at once was heavy for a row nobody is watching).
    var animates = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// ⛔ NO ON/OFF SWITCH AND NO PARTICLES SETTING (owner 2026-11-06: the big messengers have
    /// neither; a moving wallpaper moves, and whoever wants it still picks another wallpaper). Medium
    /// particles for everyone. Old saved values of those two settings are simply not read.
    private let intensity = 1
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The loop's own clock. Time only counts while moving: `elapsed` holds what ran before the last
    /// pause and `resumedAt` is when it last started, so a pause stops the picture where it is and
    /// it carries on from there (5-angle check: it used to jump on by however long it was paused).
    @State private var elapsed: TimeInterval = 0
    @State private var resumedAt = Date()

    private var moving: Bool {
        // Low Power Mode does NOT stop it (owner 2026-11-06, as the reference app does). Reduce
        // Motion still does: that is the phone's accessibility setting, not a battery choice.
        animates && !reduceMotion && scenePhase == .active && onScreen
    }

    private func seconds(at date: Date) -> TimeInterval {
        elapsed + (moving ? max(0, date.timeIntervalSince(resumedAt)) : 0)
    }

    var body: some View {
        Group {
            if case .doodles(let theme) = wallpaper.look {
                doodles(theme)
            } else {
                shaderBody
            }
        }
        // Both looks (doodles too: 5-angle check) follow Low Power Mode while on screen.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: moving) { _, now in
            if now { resumedAt = Date() } else { elapsed += max(0, Date().timeIntervalSince(resumedAt)) }
        }
    }

    /// Doodles: the theme's ground, and the doodle sheet (a little larger than the screen, so no edge
    /// shows) drifting on a small loop with a soft light passing over it. Only transforms of one
    /// picture: the cheapest look of all.
    @ViewBuilder private func doodles(_ theme: Int) -> some View {
        let themes = ChatWallpapers.all.filter { $0.pattern }
        if theme < themes.count, let sheet = ChatPattern.sheet {
            let g = themes[theme]
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !moving)) { ctx in   // a slow drift: 12 is plenty
                let phase = (seconds(at: ctx.date) / wallpaper.period).truncatingRemainder(dividingBy: 1) * 2 * .pi
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
                                // From fully off the left to fully off the right, so the jump back at
                                // the loop's end is never seen (5-angle check).
                                .offset(x: geo.size.width * (bandAt(phase) * 3.0 - 1.4),
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

    /// ⛔ BATTERY FIRST (owner 2026-11-06: "the big messengers never eat battery, make it like that").
    /// These looks change slowly (loops of 40 to 480 seconds), so most of them need far fewer frames
    /// than a game: 15 a second reads as smooth motion for a slow drift and is half of the old 30.
    /// Only Rain falls fast enough to need 24. The GPU work per frame shrinks too: the soft liquid
    /// and aurora looks draw at HALF the screen's resolution, as do the particles; the stars at full
    /// (owner 2026-11-06: "low quality, especially in light mode": a quarter showed as soft steps
    /// on the light grounds). Half the frames at twice the pixels costs about what 1108 did.
    private var framesPerSecond: Double {
        if case .particles(let kind) = wallpaper.look, kind == 1 { return 24 }
        return 15
    }

    private var renderScale: CGFloat {
        switch wallpaper.look {
        case .stars: return 1
        default: return 2
        }
    }

    /// Where the doodle light band is, 0 to 1 over a loop (a plain CGFloat for the type checker).
    private func bandAt(_ phase: Double) -> CGFloat { CGFloat(phase / (2 * Double.pi)) }

    private var shaderBody: some View {
        GeometryReader { geo in
            let full = geo.size
            // A third of the resolution for the soft looks; Stars keeps more, or its smallest stars
            // would vanish between pixels.
            let k: CGFloat = preview ? 2 : renderScale
            let small = CGSize(width: max(1, full.width / k), height: max(1, full.height / k))
            TimelineView(.animation(minimumInterval: 1.0 / (preview ? 12.0 : framesPerSecond), paused: !moving)) { ctx in
                let phase = Float((seconds(at: ctx.date) / wallpaper.period).truncatingRemainder(dividingBy: 1) * 2 * .pi)
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
