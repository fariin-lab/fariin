import SwiftUI
import UIKit

// Bridges a SwiftUI view into the navigation bar as the native `UINavigationItem.titleView` — the
// standard approach. A titleView is a subview of the UINavigationBar, so it renders ON TOP
// of the bar's native blur (never covered), left-aligns after the back button, slides with the
// native swipe-back, and its tap is a native gesture — no custom overlay/blur.
//
// Usage: `.background(NavTitleView(onTap: { ... }) { avatarNameView })` in the pushed view.
struct NavTitleView<Content: View>: UIViewRepresentable {
    /// False while some other owner should have the title area — selection mode, which puts its own
    /// centred `.principal` item there. We then hand the title back instead of fighting for it; see
    /// `suspend()` for why that matters beyond tidiness.
    var isActive: Bool = true
    var onTap: () -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

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
        context.coordinator.onTap = onTap
        context.coordinator.host.rootView = AnyView(content())
        context.coordinator.isActive = isActive
        guard isActive else { context.coordinator.suspend(); return }
        context.coordinator.install(from: marker)          // synchronous — install as early as possible
        DispatchQueue.main.async { context.coordinator.install(from: marker) }   // retry once laid out
    }

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.remove()   // clear our title view so nothing dangles when the chat is popped
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        /// Mirrors the representable's `isActive`, so the marker's attach callback cannot install
        /// over selection mode's principal item while we are suspended.
        var isActive = true
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        private let container = TitleContainerView()
        private weak var target: UIViewController?
        private var observation: NSKeyValueObservation?
        private var backObservation: NSKeyValueObservation?   // back-button visibility — the title area's left edge
        private var reassertScheduled = false   // coalesces KVO re-asserts so they can't storm the bar
        private var relayoutScheduled = false   // coalesces back-button re-seats the same way
        private var needsReseatOnResume = false // set by suspend(): the next install re-seats once

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
            super.init()
            host.view.backgroundColor = .clear
            host.sizingOptions = [.intrinsicContentSize]
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                // Left-align the avatar+name; top/bottom pinned so the container gets a real height.
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }

        @objc private func tapped() { onTap() }

        func install(from marker: UIView) {
            // The nav bar reads the navigation controller's TOP view controller's navigationItem —
            // target that one, not whatever intermediate host controller owns the marker.
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
            applyBlurAppearance(to: vc)
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

        // A REAL nil→container re-assignment, not just a layout flag: releasing and re-setting the
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
                if item.titleView === self.container {
                    item.titleView = nil
                    item.titleView = self.container
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

        // ALWAYS-ON native blur (the secret): a nav bar has two backgrounds — standardAppearance (once
        // scrolled) and scrollEdgeAppearance (at the top). The scroll-edge one defaults to TRANSPARENT,
        // so the blur only showed after scrolling ("sometimes works"). Set BOTH to the system
        // default-background blur so the native iOS 26 liquid-glass blur is present in every state.
        // Re-apply only when it's been cleared (SwiftUI resets it), to avoid flicker.
        // Be IDENTICAL to the Chats-list header: the list sets no per-item appearance, so the bar uses
        // the system default (transparent at the top, blur when scrolled, no visible border). Any
        // per-navigationItem override we set here — even a "transparent" one — diverges from that and
        // showed the band/border the user kept seeing. So clear every override and inherit the native
        // default, exactly like the list. We only install the titleView (the native way to put an
        // avatar+name in the real nav bar); we never restyle the bar itself.
        private func applyBlurAppearance(to vc: UIViewController) {
            // BUILD 282's borderless header (user: "use 282"): set NO custom nav appearance — clear every
            // override so the bar inherits the system default, exactly like the Chats list. A custom
            // appearance (configureWithDefaultBackground / any blur material) draws the grey band; the
            // default does not. Header only — nothing here touches sending or scroll.
            if vc.navigationItem.standardAppearance != nil { vc.navigationItem.standardAppearance = nil }
            if vc.navigationItem.scrollEdgeAppearance != nil { vc.navigationItem.scrollEdgeAppearance = nil }
            if vc.navigationItem.compactAppearance != nil { vc.navigationItem.compactAppearance = nil }
        }

        private func assertTitleView() {
            guard let item = target?.navigationItem, item.titleView !== container else { return }
            item.titleView = container
            // Ask for a fresh bar layout with the CURRENT leading items. The container declares a
            // 10,000pt intrinsic width so the bar hands it the whole title area and the avatar can
            // left-align in it — which means its frame depends entirely on where that area starts, and
            // that moves when the back button appears or disappears. Selection mode hides the back
            // button; on the way out the bar restored it but kept the title frame it had computed while
            // the leading area was empty, so the avatar and name sat UNDERNEATH the back chevron (user
            // report, screenshot). Only a flag is set here, never a synchronous layout — this can be
            // reached from the KVO path, and a synchronous re-layout there is what once span the bar
            // into a watchdog kill.
            target?.navigationController?.navigationBar.setNeedsLayout()
        }

        /// Hand the title area back to whoever else wants it (selection mode's `.principal` item).
        /// Without this the KVO below simply re-asserted our container over SwiftUI's centred title, so
        /// the two took turns owning `titleView` for the whole of selection mode. Releasing it also means
        /// the re-install on the way out is a REAL assignment rather than an early return, which is what
        /// forces the bar to recompute the title frame now that the back button is back.
        func suspend() {
            observation?.invalidate(); observation = nil
            backObservation?.invalidate(); backObservation = nil
            needsReseatOnResume = true
            guard let item = target?.navigationItem, item.titleView === container else { return }
            item.titleView = nil
            target?.navigationController?.navigationBar.setNeedsLayout()
        }

        func remove() {
            observation?.invalidate(); observation = nil
            backObservation?.invalidate(); backObservation = nil
            if target?.navigationItem.titleView === container { target?.navigationItem.titleView = nil }
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

// Full-width title container (the standard trick): a large finite intrinsic width so the nav bar hands
// the title view the whole title area, letting its content left-align. A finite value (not
// .greatestFiniteMagnitude) avoids Auto Layout blowing up.
final class TitleContainerView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: 10_000, height: UIView.noIntrinsicMetric)
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
