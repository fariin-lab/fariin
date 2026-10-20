import SwiftUI
import UIKit

/// The first-time story guide (owner, 2026-10-20: "copy the reference app's story onboarding",
/// his screenshot of it as the model).
///
/// The reference's logic, kept:
/// - Shown over the viewer until the person taps Got it on this phone. ONLY Got it marks it seen;
///   the X leaves the whole story viewer without marking it, so the guide is back next time.
/// - The story is paused underneath and takes no tap, hold or swipe: a touch on the guide that is
///   not one of its two buttons does nothing.
/// - Blur and content fade in together over 0.35s; 0.3s after that the three animations play one
///   after another, each once, then the round starts again. Got it fades everything out in 0.2s.
/// - X top right, three rows centred (icon 54pt, label 12pt under it, 42pt between rows), Got it
///   at the bottom.
/// The rows are OUR gestures: tap to go on, swipe left for the next person, swipe down to close
/// (swipe up opens viewers and reply here, so it is not taught as "skip"). The hand animations are
/// drawn here in SwiftUI, nothing is taken from the reference's assets.
enum StoryGuide {
    private static let key = "storyGuide.seen.v1"

    static var isSeen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}

/// Sits as the top layer of the story viewer. Draws nothing once the guide has been seen.
struct StoryGuideHost: View {
    /// Closes the whole story viewer (the guide's X).
    let onExit: () -> Void
    @State private var shown = !StoryGuide.isSeen

    var body: some View {
        if shown {
            StoryGuideOverlay(
                onGotIt: { shown = false },
                onExit: {
                    NotificationCenter.default.post(name: .init("resumeStory"), object: "guide")
                    onExit()
                })
                .transition(.identity)
        }
    }
}

private struct StoryGuideOverlay: View {
    let onGotIt: () -> Void
    let onExit: () -> Void

    @State private var visible = false
    @State private var leaving = false
    @State private var playing = -1
    @State private var round: Task<Void, Never>?

    private let rows: [(GuideMotion, String)] = [
        (.tap, "Tap to advance"),
        (.swipeLeft, "Swipe left to skip"),
        (.swipeDown, "Swipe down to exit"),
    ]

    var body: some View {
        ZStack {
            BlurBackdrop(on: visible && !leaving)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color(white: 0.11)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)

                Spacer(minLength: 12)
                VStack(spacing: 42) {
                    ForEach(rows.indices, id: \.self) { i in
                        VStack(spacing: 12) {
                            GuideAnimation(motion: rows[i].0, playToken: playing == i ? i : -1)
                                .frame(width: 54, height: 54)
                            Text(rows[i].1)
                                .font(.system(size: 17))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal, 20)
                Spacer(minLength: 42)

                Button(action: gotIt) {
                    Text("Got it")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(170, UIScreen.main.bounds.width * 0.44), height: 52)
                        .background(Capsule().fill(Color(white: 0.11)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 32)
            }
            .opacity(visible && !leaving ? 1 : 0)
        }
        // Every touch stops here and does nothing (the reference's own rule): the story under it
        // takes no tap, hold or swipe while the guide is up.
        .contentShape(Rectangle())
        .onTapGesture {}
        .gesture(DragGesture(minimumDistance: 0))
        .onAppear {
            NotificationCenter.default.post(name: .init("pauseStory"), object: "guide")
            // Again a beat later: on the very first open the player may not be listening yet, and a
            // story left running under the guide would move on by itself. The pause is a set of
            // reasons, so asking twice is harmless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !leaving else { return }
                NotificationCenter.default.post(name: .init("pauseStory"), object: "guide")
            }
            withAnimation(.easeInOut(duration: 0.35)) { visible = true }
            round = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)   // 0.35 fade in + 0.3
                while !Task.isCancelled {
                    for i in rows.indices {
                        guard !Task.isCancelled else { return }
                        playing = i
                        try? await Task.sleep(nanoseconds: UInt64(GuideMotion.length * 1_000_000_000))
                    }
                    playing = -1
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        .onDisappear { round?.cancel() }
    }

    private func gotIt() {
        guard !leaving else { return }
        StoryGuide.markSeen()
        round?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { leaving = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            NotificationCenter.default.post(name: .init("resumeStory"), object: "guide")
            onGotIt()
        }
    }
}

/// The story stage is always dark, so the guide blurs it with the dark style.
private struct BlurBackdrop: UIViewRepresentable {
    let on: Bool
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: nil) }
    func updateUIView(_ v: UIVisualEffectView, context: Context) {
        let effect: UIVisualEffect? = on ? UIBlurEffect(style: .dark) : nil
        UIView.animate(withDuration: on ? 0.35 : 0.2) { v.effect = effect }
    }
}

enum GuideMotion {
    case tap, swipeLeft, swipeDown
    /// How long one animation plays before the next one starts.
    static let length: Double = 1.5
}

/// Thin white line drawings: a hand that taps; a phone with a hand swiping across it; a hand
/// pulling an arrow down out of a phone. Each plays once when `playToken` turns to its row.
private struct GuideAnimation: View {
    let motion: GuideMotion
    let playToken: Int

    @State private var t: CGFloat = 0
    @State private var pressed = false

    private let line = Color.white

    var body: some View {
        ZStack {
            switch motion {
            case .tap:
                Circle()
                    .stroke(line.opacity(pressed ? 0.7 : 0), lineWidth: 1.5)
                    .frame(width: pressed ? 26 : 6, height: pressed ? 26 : 6)
                    .offset(x: -2, y: -18)
                hand
                    .scaleEffect(pressed ? 0.9 : 1)
                    .offset(y: pressed ? 2 : 0)
            case .swipeLeft:
                phone
                hand
                    .scaleEffect(0.78)
                    .offset(x: 10 - 18 * t, y: 6)
            case .swipeDown:
                phone.offset(x: 8)
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(line.opacity(0.4 + 0.6 * t))
                    .offset(x: 8, y: -6 + 10 * t)
                hand
                    .scaleEffect(0.78)
                    .offset(x: -12, y: -6 + 14 * t)
            }
        }
        .onChange(of: playToken) { _, token in if token >= 0 { play() } }
    }

    private var hand: some View {
        Image(systemName: "hand.point.up.left")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(line)
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(line, lineWidth: 1.6)
            .frame(width: 26, height: 42)
    }

    private func play() {
        t = 0
        pressed = false
        switch motion {
        case .tap:
            withAnimation(.easeOut(duration: 0.15).delay(0.1)) { pressed = true }
            withAnimation(.easeOut(duration: 0.25).delay(0.3)) { pressed = false }
            withAnimation(.easeOut(duration: 0.15).delay(0.7)) { pressed = true }
            withAnimation(.easeOut(duration: 0.25).delay(0.9)) { pressed = false }
        case .swipeLeft, .swipeDown:
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) { t = 1 }
            withAnimation(.easeInOut(duration: 0.4).delay(0.95)) { t = 0 }
        }
    }
}
