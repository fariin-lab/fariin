import SwiftUI
import UIKit

// EXPERIMENTAL Telegram-style media open/close (Settings > Privacy > "Telegram Media Open").
// Telegram never uses a system transition for its gallery: the tapped image itself is animated from
// the bubble's exact rect to the fullscreen fitted rect with a spring, over a black backdrop that
// fades in — and flies back into the bubble on close. This file provides the shared pieces; the
// viewers opt in when ThreadView hands them a source rect (toggle ON), otherwise nothing changes.

// Where each media bubble currently sits on screen, keyed by message id. Written by a cheap reporter
// on the bubble's media view (a static dict — never SwiftUI state, so writes can't re-render anything).
@MainActor enum MediaOpenRects {
    private static var rects: [String: CGRect] = [:]
    static func capture(_ id: String, _ rect: CGRect) { rects[id] = rect }
    static func rect(_ id: String) -> CGRect? { rects[id] }
}

// Continuously reports a bubble media view's global frame (one dict write per layout pass — no state).
struct MediaRectReporter: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                    MediaOpenRects.capture(id, f)
                }
            }
        )
    }
}

// The animating copy: at `expanded == false` the image sits exactly in the bubble rect (rounded like a
// bubble); at `true` it fills the screen's fitted rect. Drive `expanded` inside withAnimation(spring)
// and SwiftUI interpolates frame + corner radius — the Telegram open/close in one view.
struct TGMediaZoomLayer: View {
    let image: UIImage
    let source: CGRect
    let expanded: Bool

    var body: some View {
        let screen = UIScreen.main.bounds
        let fit = mediaFitRect(image.size, in: screen)
        let r = expanded ? fit : source
        ZStack {
            Color.black.opacity(expanded ? 1 : 0)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: r.width, height: r.height)
                .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 16, style: .continuous))
                .position(x: r.midX, y: r.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// Shared open/close driver so the photo viewer and the video player behave identically.
@MainActor final class TGOpenState: ObservableObject {
    @Published var expanded = false   // copy at bubble (false) / fullscreen (true)
    @Published var live = false       // animation finished → real content shown, copy gone
    private static let springDuration = 0.42

    func open() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { expanded = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDuration) { [weak self] in
            self?.live = true
        }
    }

    // Fly back into the bubble, then run `then` (an instant, non-animated dismiss).
    func close(then: @escaping () -> Void) {
        live = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDuration, execute: then)
    }
}

// Present/dismiss without the system animation (the copy IS the animation in Telegram mode).
@MainActor func withoutPresentationAnimation(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}

// Apply the native zoom transition only when the Telegram-open test is OFF (a transition modifier
// can't be conditionally chained inline without splitting the view tree — this keeps identity stable).
struct ConditionalZoomTransition: ViewModifier {
    let enabled: Bool
    let sourceID: String
    let ns: Namespace.ID
    func body(content: Content) -> some View {
        if enabled {
            content.navigationTransition(.zoom(sourceID: sourceID, in: ns))
        } else {
            content
        }
    }
}
