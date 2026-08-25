import SwiftUI
import UIKit

// Installs the UIKit `ChatHeaderView` as the native `UINavigationItem.titleView` of the screen this
// sits in — the reference app's own approach (`navigationItem.titleView = headerView`), reached from
// inside a SwiftUI `NavigationStack`.
//
// ⛔ THE CONTENT IS UIKIT NOW; ONLY THE INSTALL IS BRIDGED — owner, 2026-08-25, "match [the reference]
// 100%… if [it] uses UIKit for its top header, use UIKit for my top header as well". This file used
// to host a SwiftUI view in a `UIHostingController` inside a width-forcing container and set THAT as
// the titleView. Both wrappers are gone: `ChatHeaderView` is a plain `UIView` that declares its own
// intrinsic size the way theirs does, and it is assigned directly.
//
// What has to remain bridged, and why: their header is set from a `UIViewController` that owns its
// own `navigationItem`. A SwiftUI screen has no such handle, so a hidden marker view is planted to
// find the owning controller, and the titleView is re-asserted when SwiftUI's own nav-item
// reconcile clears it. Every safeguard below exists because of a real crash or a real flicker, and
// each carries its history. None of it is about what the header looks like.
struct NavTitleView: UIViewRepresentable {
    /// False while some other owner should have the title area — selection mode, which puts its own
    /// centred `.principal` item there. We then hand the title back instead of fighting for it; see
    /// `suspend()` for why that matters beyond tidiness.
    var isActive: Bool = true
    var model: ChatHeaderModel
    var onTap: () -> Void
    var onTapAvatar: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let marker = NavTitleMarkerView()
        marker.isUserInteractionEnabled = false
        marker.isHidden = true
        // THE MARKER REPORTS ITS OWN ARRIVAL. The two attempts in updateUIView are both guesses
        // about WHEN the view lands in the hierarchy, and on a push both can run before it has —
        // install() then returns at its owningViewController guard, silently. A busy screen
        // (ThreadView) re-evaluates within a frame and self-heals; a QUIET one does not. The
        // official chat is exactly that: its name and avatar are compile-time constants and its
        // store is usually already loaded, so nothing re-ran updateUIView until a Firestore echo
        // seconds later — his "name and avatar coming late" with an empty header in between.
        // didMoveToWindow is the native signal that the owning VC is now resolvable.
        marker.onAttach = { [weak coordinator = context.coordinator, weak marker] in
            guard let coordinator, coordinator.isActive, let marker else { return }
            coordinator.install(from: marker)
        }
        return marker
    }

    func updateUIView(_ marker: UIView, context: Context) {
        let c = context.coordinator
        c.header.onTap = onTap
        c.header.onTapAvatar = onTapAvatar
        if c.lastModel != model {
            c.lastModel = model
            c.header.configure(model)
        }
        c.isActive = isActive
        guard isActive else { c.suspend(); return }
        c.install(from: marker)          // synchronous — install as early as possible
        DispatchQueue.main.async { c.install(from: marker) }   // retry once laid out
    }

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.remove()   // clear our title view so nothing dangles when the chat is popped
    }

    final class Coordinator: NSObject {
        /// Mirrors the representable's `isActive`, so the marker's attach callback cannot install
        /// over selection mode's principal item while we are suspended.
        var isActive = true
        /// The header itself — their `ConversationHeaderView`, ours. Assigned as the titleView directly.
        let header = ChatHeaderView()
        var lastModel: ChatHeaderModel?
        private weak var target: UIViewController?
        private var observation: NSKeyValueObservation?
        private var backObservation: NSKeyValueObservation?   // back-button visibility — the title area's left edge
        private var reassertScheduled = false   // coalesces KVO re-asserts so they can't storm the bar
        private var relayoutScheduled = false   // coalesces back-button re-seats the same way
        private var needsReseatOnResume = false // set by suspend(): the next install re-seats once

        func install(from marker: UIView) {
            // Target the OWNING (pushed) view controller — NOT navigationController.topViewController,
            // which during a push is still the PREVIOUS screen, so the title only landed after the
            // transition finished (it "came in late"). The owning VC's navigationItem is the one the
            // bar shows for this screen, so setting it here makes the title slide in WITH the page.
            guard let vc = marker.owningViewController else { return }
            if target !== vc {
                observation?.invalidate(); observation = nil
                backObservation?.invalidate(); backObservation = nil
                target = vc
            }
            assertTitleView()
            // Coming back from selection mode: UIKit property observation is best-effort, so the
            // guaranteed path is this one — the install that runs when `isActive` flips back on. The
            // deferred re-seat lands on the next runloop tick, by which time SwiftUI's same commit has
            // restored the back button, so the bar recomputes the title area with the chevron in place.
            if needsReseatOnResume {
                needsReseatOnResume = false
                scheduleTitleRelayout()
            }
            clearBarAppearance(on: vc)
            // SwiftUI re-manages the navigationItem on its own update cycles and clears titleView
            // (the "avatar+name sometimes gone" flicker). Observe it and put ours back — but ASYNC and
            // coalesced (never synchronously from inside the KVO). Re-asserting synchronously here set
            // titleView mid-redisplay, which re-triggered _redisplayItems while SwiftUI's own nav-item
            // reconcile was still clearing it → a synchronous ping-pong that burned 10s of CPU in nav-bar
            // layout during a push and tripped the 0x8BADF00D scene-update watchdog (device crash). One
            // deferred re-assert per runloop tick lets SwiftUI's redisplay finish first, so the war can't
            // form — at worst a one-frame flicker, never a hang.
            if observation == nil, let item = target?.navigationItem {
                observation = item.observe(\.titleView, options: [.new]) { [weak self] _, _ in
                    self?.scheduleAssertTitleView()
                }
            }
            // THE SECOND HALF OF THE SELECTION-EXIT FIX. Re-assigning the titleView on the way out
            // (assertTitleView) was not enough on device: our install runs synchronously when
            // `selecting` flips false, but SwiftUI restores the back button LATER in its own commit —
            // and when the chevron lands, nothing told the bar the title area's left edge had moved,
            // so the avatar and name stayed at the full-width frame computed while the leading area
            // was empty, underneath the chevron (user report, 12:08 screenshot, second occurrence).
            // The trigger to anchor to is the back button itself: when its visibility changes, re-seat
            // the title. Deferred and coalesced for the same storm reasons as the titleView observer.
            if backObservation == nil, let item = target?.navigationItem {
                backObservation = item.observe(\.hidesBackButton, options: [.new]) { [weak self] _, _ in
                    self?.scheduleTitleRelayout()
                }
            }
        }

        // A REAL nil→header re-assignment, not just a layout flag: releasing and re-setting the
        // titleView is what provably makes the bar recompute the title frame (see suspend()); a
        // setNeedsLayout alone left the stale frame on device. Both assignments land in one runloop
        // tick, so nothing flickers. Only when we currently own the title — during selection mode the
        // principal toolbar owns it, and stealing it back here would fight that owner.
        private func scheduleTitleRelayout() {
            guard !relayoutScheduled else { return }
            relayoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relayoutScheduled = false
                guard let item = self.target?.navigationItem else { return }
                if item.titleView === self.header {
                    item.titleView = nil
                    item.titleView = self.header
                }
                self.target?.navigationController?.navigationBar.setNeedsLayout()
            }
        }

        // Coalesced, asynchronous re-assert: many titleView clears within one SwiftUI update collapse to a
        // single deferred put-back on the next runloop tick, breaking the synchronous redisplay storm.
        private func scheduleAssertTitleView() {
            guard !reassertScheduled else { return }
            reassertScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.reassertScheduled = false
                self?.assertTitleView()
            }
        }

        // Be IDENTICAL to the Chats-list header: the list sets no per-item appearance, so the bar uses
        // the system default (transparent at the top, blur when scrolled, no visible border). Any
        // per-navigationItem override set here — even a "transparent" one — diverges from that and
        // showed the band/border the user kept seeing (build 282, "use 282"). So clear every override
        // and inherit the native default. The reference app does not restyle its bar either.
        private func clearBarAppearance(on vc: UIViewController) {
            if vc.navigationItem.standardAppearance != nil { vc.navigationItem.standardAppearance = nil }
            if vc.navigationItem.scrollEdgeAppearance != nil { vc.navigationItem.scrollEdgeAppearance = nil }
            if vc.navigationItem.compactAppearance != nil { vc.navigationItem.compactAppearance = nil }
        }

        private func assertTitleView() {
            guard let item = target?.navigationItem, item.titleView !== header else { return }
            item.titleView = header
            // Ask for a fresh bar layout with the CURRENT leading items. The header declares an
            // unbounded intrinsic width so the bar hands it the whole title area and the avatar can
            // left-align in it — which means its frame depends entirely on where that area starts, and
            // that moves when the back button appears or disappears. Only a flag is set here, never a
            // synchronous layout — this can be reached from the KVO path, and a synchronous re-layout
            // there is what once span the bar into a watchdog kill.
            target?.navigationController?.navigationBar.setNeedsLayout()
        }

        /// Hand the title area back to whoever else wants it (selection mode's `.principal` item).
        /// Without this the KVO simply re-asserted our header over SwiftUI's centred title, so the two
        /// took turns owning `titleView` for the whole of selection mode. Releasing it also means the
        /// re-install on the way out is a REAL assignment rather than an early return, which is what
        /// forces the bar to recompute the title frame now that the back button is back.
        func suspend() {
            observation?.invalidate(); observation = nil
            backObservation?.invalidate(); backObservation = nil
            needsReseatOnResume = true
            guard let item = target?.navigationItem, item.titleView === header else { return }
            item.titleView = nil
            target?.navigationController?.navigationBar.setNeedsLayout()
        }

        func remove() {
            observation?.invalidate(); observation = nil
            backObservation?.invalidate(); backObservation = nil
            if target?.navigationItem.titleView === header { target?.navigationItem.titleView = nil }
        }
    }
}

/// The marker that knows when it lands. `didMoveToWindow` fires at the exact moment
/// `owningViewController` becomes answerable — no guessing with async ticks. See makeUIView.
final class NavTitleMarkerView: UIView {
    var onAttach: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttach?() }
    }
}

extension UIView {
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}
