import SwiftUI
import UIKit

// EXPERIMENTAL reference-style media open/close (Settings > Privacy > "the reference app Media Open").
// the reference app never uses a system transition for its gallery: the tapped image itself is animated from
// the bubble's exact rect to the fullscreen fitted rect with a spring, over a black backdrop that
// fades in — and flies back into the bubble on close. This file provides the shared pieces; the
// viewers opt in when ThreadView hands them a source rect (toggle ON), otherwise nothing changes.

// Where each media bubble currently sits on screen, keyed by message id. Written by a cheap reporter
// on the bubble's media view (a static dict — never SwiftUI state, so writes can't re-render anything).
@MainActor enum MediaOpenRects {
    private static var rects: [String: CGRect] = [:]
    private static var radii: [String: CGFloat] = [:]

    /// THE KEY IS SCOPED BY SCREEN, and that is the whole bug fix (2026-07-29). The registry used to be
    /// keyed by message id ALONE — but the SAME message id is registered by the chat bubble, the All
    /// Media tile, and the profile strip thumb. Whichever screen laid out last overwrote the others, so
    /// opening a photo in All Media flew from (and landed on) the CHAT's coordinates: the user's
    /// "opening wrong area / closing wrong area". And when the stale entry belonged to a screen that had
    /// scrolled, the lookup could miss entirely, which dropped the open to a plain presentation and the
    /// close to the drift-down fallback — his "sometimes it uses the old animation / the image goes
    /// down". One id, three screens, one dictionary. Now every screen owns its own namespace.
    enum Scope: String { case chat, gallery, profile, album }
    static func key(_ scope: Scope, _ id: String) -> String { "\(scope.rawValue)|\(id)" }

    static func capture(_ key: String, _ rect: CGRect, cornerRadius: CGFloat) {
        rects[key] = rect
        radii[key] = cornerRadius
    }
    static func rect(_ key: String) -> CGRect? { rects[key] }
    /// The bubble's own corner radius, so a transition interpolates from the REAL shape instead of a
    /// hardcoded guess. The close used a flat 14 and the open had no radius at all, so media with a
    /// different bubble radius visibly changed shape at the moment the copy took over.
    static func cornerRadius(_ key: String) -> CGFloat { radii[key] ?? 14 }

    /// The visible message viewport in window coordinates — the reference app's `clippingAreaInsets`, as a rect.
    /// Published by the message list controller on every layout pass. The transition's flying copy is
    /// clipped to this region at the bubble end of BOTH directions, so a bubble half-scrolled under the
    /// header is revealed from behind the bar instead of flying over it. Written only by the chat list;
    /// read only through the closures the chat wires up, so other screens (gallery, profile) are
    /// unaffected by a stale value.
    static var clipRect: CGRect?
}

/// Whether a media bubble should render itself, so a transition can HIDE the tile it is flying to or
/// from. Without this the copy converges onto an already-visible thumbnail: for one moment the same
/// photo is on screen twice, and there is no cross-fade at the landing. the reference app hides the source view for
/// exactly the duration of the transition and restores it before removing the copy.
///
/// Alpha, never `isHidden`: a hidden view stops reporting its frame, which would erase the very rect the
/// transition is animating towards.
@MainActor final class MediaSourceVisibility: ObservableObject {
    static let shared = MediaSourceVisibility()
    @Published private(set) var hiddenId: String?
    func hide(_ id: String?) { if hiddenId != id { hiddenId = id } }
    func reveal() { if hiddenId != nil { hiddenId = nil } }
}

// Continuously reports a bubble media view's global frame (one dict write per layout pass — no state),
// and hides itself while a transition is flying to or from it.
struct MediaRectReporter: ViewModifier {
    let id: String
    var scope: MediaOpenRects.Scope = .chat
    var cornerRadius: CGFloat = 14
    @ObservedObject private var visibility = MediaSourceVisibility.shared
    private var key: String { MediaOpenRects.key(scope, id) }
    func body(content: Content) -> some View {
        content
            // Hiding is keyed the same scoped way, so hiding the gallery tile can never blank the
            // chat bubble behind it (they share an id but not a key).
            .opacity(visibility.hiddenId == key ? 0 : 1)
            .background(
                GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                        MediaOpenRects.capture(key, f, cornerRadius: cornerRadius)
                    }
                }
            )
    }
}

/// Re-opening media IMMEDIATELY after closing it did nothing — the user had to wait a second. SwiftUI
/// ignores a `fullScreenCover` presentation requested while the previous one is still dismissing, so the
/// tap was silently swallowed. This gate does not block anything: it runs the presentation NOW when the
/// coast is clear, and otherwise DEFERS it just past the dismissal, so a fast tap always opens.
/// WAITS FOR THE EVENT, NOT FOR A CLOCK (2026-07-29). This used to hold a re-open for a fixed 0.42s
/// after any dismissal — a guess at how long SwiftUI's cover takes to leave. The guess was the delay
/// the user felt: the photo had landed back in its bubble and looked ready, but tapping it did nothing
/// for the rest of that window (user: "I have to wait a short time before it becomes tappable again").
///
/// the reference app has no such window because its viewer is a UIKit custom transition: the interactive dismiss
/// calls `completeTransition`, and the presenting controller is ready in that same instant. We can't
/// borrow the mechanism through a `fullScreenCover`, but we can borrow the principle — gate on the
/// cover ACTUALLY being gone, which the viewer reports from `onDisappear`. Combined with dismissing
/// without an animation (see `instantDismiss`), the wait collapses to a frame or two.
@MainActor enum MediaPresentGate {
    private static var closing = false
    private static var queued: (() -> Void)?
    private static var safety: DispatchWorkItem?

    /// A viewer started leaving. SwiftUI silently DROPS a presentation requested before the previous
    /// cover has finished, so a tap that arrives now must be held rather than fired into the void.
    static func noteDismissed() {
        closing = true
        safety?.cancel()
        // Belt: a viewer torn down without ever reporting (killed by a parent pop, say) must not
        // strand a queued tap forever.
        let w = DispatchWorkItem { MediaPresentGate.noteClosed() }
        safety = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// The cover is really gone. Releases the tap that came in while it was leaving.
    static func noteClosed() {
        safety?.cancel(); safety = nil
        closing = false
        guard let q = queued else { return }
        queued = nil
        // One hop: `noteClosed` is called from onDisappear, and presenting from inside a view update
        // is a state write mid-update.
        DispatchQueue.main.async(execute: q)
    }

    static func present(_ block: @escaping () -> Void) {
        guard closing else { block(); return }
        queued = block   // newest tap wins; an older queued open is stale by definition
    }
}

// DELETED HERE: `TGMediaZoomLayer` and `TGOpenState` — a complete second open/close animation, in
// SwiftUI, that ran alongside the UIKit pair in SignalMediaDismiss.swift. Every call site passed nil so
// it never fired, but it disagreed with the real pipeline on every number that matters: spring response
// 0.38 with 0.86 damping against the reference app's 0.25 critically damped, a hardcoded 16pt corner radius against
// the bubble's real one, `UIScreen.main.bounds` against the transition container's geometry, and
// `aspectRatio(.fill)` on a view with no clipping view around it.
//
// Keeping a dormant second animator "in case" is how an area ends up with two sources of truth, and this
// one had already outlived the toggle that used to switch it on.

// Present/dismiss without the system animation (the flying copy IS the animation).
@MainActor func withoutPresentationAnimation(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}

// DELETED HERE: `ConditionalZoomTransition` — the switch that used to choose between the system
// `.zoom` transition and the fly pipeline. Every chat-media call site had it hard-coded to
// `enabled: false`, and the namespaces and matchedTransitionSource anchors that fed it are gone with
// it. Stories still use the system zoom, via their own namespaces, applied directly.
