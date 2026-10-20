import SwiftUI
import UIKit

/// The first-time story guide (owner, 2026-10-20: "show it only the first time someone opens a
/// story, same logic as the reference app").
///
/// The reference's logic, kept: shown over the viewer on the very first story open on this phone,
/// the flag is written the moment it shows (so a crash or a swipe away never shows it twice), the
/// story stays paused and takes no gestures underneath, each row plays its little hand animation in
/// turn with the playing row lifted and lit, and a tap anywhere (or Got it, or the X) closes it.
/// The rows are OUR gestures, not the reference's: tap forward, hold to pause, swipe sideways for the
/// next person, swipe down to close (swipe up opens viewers and reply here).
enum StoryGuide {
    private static let key = "storyGuide.shown.v1"

    /// True once per phone: the first caller gets true and the flag is written at once.
    static func takeFirstTime() -> Bool {
        let d = UserDefaults.standard
        guard !d.bool(forKey: key) else { return false }
        d.set(true, forKey: key)
        return true
    }
}

/// Sits as the top layer of the story viewer. Draws nothing unless this is the first story open.
struct StoryGuideHost: View {
    @State private var shown = StoryGuide.takeFirstTime()

    var body: some View {
        if shown {
            StoryGuideOverlay { shown = false }
                .transition(.identity)
        }
    }
}

private struct StoryGuideOverlay: View {
    let onDone: () -> Void

    @State private var blurOn = false
    @State private var contentIn = false
    @State private var leaving = false
    @State private var playing = 0
    @State private var cycle: Task<Void, Never>?

    private let rows: [(GuideMotion, String)] = [
        (.tap, "Tap to see the next one"),
        (.hold, "Hold to pause"),
        (.sideways, "Swipe sideways for the next person"),
        (.down, "Swipe down to close"),
    ]

    var body: some View {
        ZStack {
            BlurBackdrop(on: blurOn)
                .ignoresSafeArea()
            Color.black.opacity(blurOn ? 0.25 : 0).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    ForEach(rows.indices, id: \.self) { i in
                        GuideRow(motion: rows[i].0, text: rows[i].1, isPlaying: playing == i)
                    }
                }
                .padding(.horizontal, 28)
                Spacer()
                Button(action: close) {
                    Text("Got it")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 52)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 56)
            }
            .opacity(contentIn && !leaving ? 1 : 0)
            .scaleEffect(leaving ? 1.1 : (contentIn ? 1 : 0.85))

            VStack {
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.top, 58)
                .padding(.trailing, 16)
                Spacer()
            }
            .opacity(contentIn && !leaving ? 1 : 0)
        }
        .opacity(leaving ? 0 : 1)
        // Every touch stops here: the story underneath takes no tap, hold or swipe while the guide
        // is up, and a tap anywhere closes it (the reference's own behaviour).
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .onAppear {
            NotificationCenter.default.post(name: .init("pauseStory"), object: "guide")
            // Again a beat later: on the very first open the player may not be listening yet when
            // this appears, and a story left running under the guide would move on by itself.
            // The pause is a set of reasons, so asking twice is harmless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !leaving else { return }
                NotificationCenter.default.post(name: .init("pauseStory"), object: "guide")
            }
            withAnimation(.easeOut(duration: 0.2)) { blurOn = true }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { contentIn = true }
            cycle = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(GuideMotion.length * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { playing = (playing + 1) % rows.count }
                }
            }
        }
        .onDisappear { cycle?.cancel() }
    }

    private func close() {
        guard !leaving else { return }
        cycle?.cancel()
        withAnimation(.easeIn(duration: 0.25)) { leaving = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            NotificationCenter.default.post(name: .init("resumeStory"), object: "guide")
            onDone()
        }
    }
}

/// The story stage is always dark, so the guide blurs it with the dark style.
private struct BlurBackdrop: UIViewRepresentable {
    let on: Bool
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: nil) }
    func updateUIView(_ v: UIVisualEffectView, context: Context) {
        let effect: UIVisualEffect? = on ? UIBlurEffect(style: .dark) : nil
        UIView.animate(withDuration: 0.2) { v.effect = effect }
    }
}

private struct GuideRow: View {
    let motion: GuideMotion
    let text: String
    let isPlaying: Bool

    var body: some View {
        VStack(spacing: 10) {
            GuideAnimation(motion: motion, isPlaying: isPlaying)
                .frame(width: 64, height: 64)
            Text(text)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(isPlaying ? 1 : 0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(isPlaying ? 0.1 : 0))
        )
        .scaleEffect(isPlaying ? 1.06 : 1)
    }
}

enum GuideMotion {
    case tap, hold, sideways, down
    /// How long one row plays before the next one starts.
    static let length: Double = 1.8
}

/// A phone outline with a hand doing the gesture. Plays once each time its row becomes the playing
/// one, then rests, like the reference's one-shot animations.
private struct GuideAnimation: View {
    let motion: GuideMotion
    let isPlaying: Bool

    @State private var t: CGFloat = 0      // 0 = at rest, 1 = gesture done
    @State private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 30, height: 50)
            ripple
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2)
                .scaleEffect(pressed ? 0.86 : 1)
                .offset(handOffset)
        }
        .onChange(of: isPlaying) { _, now in if now { play() } }
        .onAppear { if isPlaying { play() } }
    }

    @ViewBuilder private var ripple: some View {
        switch motion {
        case .tap, .hold:
            Circle()
                .stroke(Color.white.opacity(pressed ? 0.8 : 0), lineWidth: 2)
                .frame(width: pressed ? (motion == .hold ? 30 : 22) : 8, height: pressed ? (motion == .hold ? 30 : 22) : 8)
                .offset(x: motion == .tap ? 6 : 0, y: -6)
        case .sideways:
            Image(systemName: "arrow.left")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(t > 0.3 ? 0.9 : 0))
                .offset(x: -22, y: -6)
        case .down:
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(t > 0.3 ? 0.9 : 0))
                .offset(x: 22, y: 6)
        }
    }

    private var handOffset: CGSize {
        switch motion {
        case .tap: return CGSize(width: 14, height: 10)
        case .hold: return CGSize(width: 8, height: 10)
        case .sideways: return CGSize(width: 18 - 28 * t, height: 10)
        case .down: return CGSize(width: 8, height: -2 + 22 * t)
        }
    }

    private func play() {
        t = 0
        pressed = false
        switch motion {
        case .tap:
            withAnimation(.easeOut(duration: 0.18).delay(0.15)) { pressed = true }
            withAnimation(.easeOut(duration: 0.25).delay(0.4)) { pressed = false }
            withAnimation(.easeOut(duration: 0.18).delay(0.85)) { pressed = true }
            withAnimation(.easeOut(duration: 0.25).delay(1.1)) { pressed = false }
        case .hold:
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) { pressed = true }
            withAnimation(.easeOut(duration: 0.3).delay(1.35)) { pressed = false }
        case .sideways, .down:
            withAnimation(.easeOut(duration: 0.15).delay(0.1)) { pressed = true }
            withAnimation(.easeInOut(duration: 0.7).delay(0.25)) { t = 1 }
            withAnimation(.easeOut(duration: 0.15).delay(1.0)) { pressed = false }
            withAnimation(.easeInOut(duration: 0.35).delay(1.3)) { t = 0 }
        }
    }
}
