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
    private static var radii: [String: CGFloat] = [:]
    static func capture(_ id: String, _ rect: CGRect, cornerRadius: CGFloat) {
        rects[id] = rect
        radii[id] = cornerRadius
    }
    static func rect(_ id: String) -> CGRect? { rects[id] }
    /// The bubble's own corner radius, so a transition interpolates from the REAL shape instead of a
    /// hardcoded guess. The close used a flat 14 and the open had no radius at all, so media with a
    /// different bubble radius visibly changed shape at the moment the copy took over.
    static func cornerRadius(_ id: String) -> CGFloat { radii[id] ?? 14 }
}

/// Whether a media bubble should render itself, so a transition can HIDE the tile it is flying to or
/// from. Without this the copy converges onto an already-visible thumbnail: for one moment the same
/// photo is on screen twice, and there is no cross-fade at the landing. Signal hides the source view for
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
    var cornerRadius: CGFloat = 14
    @ObservedObject private var visibility = MediaSourceVisibility.shared
    func body(content: Content) -> some View {
        content
            .opacity(visibility.hiddenId == id ? 0 : 1)
            .background(
                GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                        MediaOpenRects.capture(id, f, cornerRadius: cornerRadius)
                    }
                }
            )
    }
}

// DELETED HERE: `TGMediaZoomLayer` and `TGOpenState` — a complete second open/close animation, in
// SwiftUI, that ran alongside the UIKit pair in SignalMediaDismiss.swift. Every call site passed nil so
// it never fired, but it disagreed with the real pipeline on every number that matters: spring response
// 0.38 with 0.86 damping against Signal's 0.25 critically damped, a hardcoded 16pt corner radius against
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
