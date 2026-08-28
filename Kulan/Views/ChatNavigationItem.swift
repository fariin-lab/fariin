import SwiftUI
import UIKit

// ⛔ THE WHOLE `navigationItem` IS UIKIT-MANAGED, THE WAY THE REFERENCE APP MANAGES ITS — owner,
// 2026-08-25: "anything [it] manages with UIKit, my app should also manage with UIKit. I don't want
// a mixed SwiftUI/UIKit implementation for the header."
//
// Their `ConversationViewController` sets, from UIKit, on its own `navigationItem`:
//   · `titleView`             = the header view                     (`createHeaderViews`)
//   · `rightBarButtonItems`   = [audio, video] as `UIBarButtonItem(image:primaryAction:)`,
//                               each `isEnabled = currentCall == nil` (`updateBarButtonItems`)
//   · `leftBarButtonItem`     = nil normally; "Delete All" (plain) in selection mode
//   · `rightBarButtonItems`   = [system Cancel] in selection mode
//   · `hidesBackButton`       = false normally, true in selection mode
//   · `titleView`             = nil in selection mode (`uiModeDidChange`)
// This bridge does exactly that list, and nothing else.
//
// What was SwiftUI until today, and is gone: the call items as `ToolbarItem`s, the selection bar
// as `ToolbarItem`s with a `.principal` title, `.navigationBarBackButtonHidden`, and the whole
// suspend/resume dance that handed the title area back and forth between the two owners. There is
// one owner now.
//
// ⚠️ WHY A BRIDGE AT ALL. Their header is set from a `UIViewController` that owns its
// `navigationItem`. A SwiftUI screen has no such handle, so a hidden marker view is planted to find
// the owning controller. And because SwiftUI's `NavigationStack` re-manages the same navigationItem
// on its own update cycles, everything set here is observed and re-asserted when SwiftUI clears it,
// ASYNC and COALESCED. The synchronous version of that re-assert once ping-ponged with SwiftUI's
// redisplay, burned 10s of CPU in nav-bar layout and tripped the 0x8BADF00D watchdog (a device
// crash). One deferred re-assert per runloop tick is the rule for every property below.
struct ChatNavigationItem: UIViewRepresentable {
    var model: ChatHeaderModel
    var bar: Bar
    var onTap: () -> Void
    var onTapAvatar: (() -> Void)? = nil

    /// What sits either side of the header. Mirrors their `uiMode` switch.
    enum Bar {
        /// Normal: audio and video on the right, nothing on the left, system back button.
        case conversation(audio: (() -> Void)?, video: (() -> Void)?, callsEnabled: Bool)
        /// Their selection mode: "Delete All" on the left, system Cancel on the right, no back button.
        case selection(deleteAll: () -> Void, deleteEnabled: Bool, cancel: () -> Void)
        /// A screen with its own single right item (the official channel's bell).
        case custom([BarButton])

        /// Everything the bar's SHAPE depends on. Closures are looked up at tap time, so a body
        /// re-evaluation that only produced new closure instances rebuilds nothing.
        var signature: String {
            switch self {
            case let .conversation(audio, video, enabled):
                return "conv:\(audio != nil):\(video != nil):\(enabled)"
            case let .selection(_, enabled, _):
                return "sel:\(enabled)"
            case let .custom(buttons):
                return "custom:" + buttons.map { "\($0.id)=\($0.image)" }.joined(separator: ",")
            }
        }
    }

    struct BarButton {
        var id: String
        var image: String            // asset name, rendered as a template at its natural size
        var accessibilityLabel: String
        var action: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let marker = NavItemMarkerView()
        marker.isUserInteractionEnabled = false
        marker.isHidden = true
        // THE MARKER REPORTS ITS OWN ARRIVAL. On a push, both attempts in updateUIView can run before
        // the view is in the hierarchy, and install() returns at its owningViewController guard. A
        // busy screen re-evaluates within a frame and self-heals; a QUIET one (the official chat,
        // whose name and avatar are constants) did not, and showed an empty header until a Firestore
        // echo seconds later. didMoveToWindow is the native signal that the owner is resolvable.
        marker.onAttach = { [weak coordinator = context.coordinator, weak marker] in
            guard let coordinator, let marker else { return }
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
        c.setBar(bar)
        c.install(from: marker)                                  // synchronous — as early as possible
        DispatchQueue.main.async { c.install(from: marker) }     // and once laid out
    }

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: NSObject {
        let header = ChatHeaderView()
        var lastModel: ChatHeaderModel?

        private var bar: Bar = .conversation(audio: nil, video: nil, callsEnabled: true)
        private var barSignature = ""
        private var rightItems: [UIBarButtonItem] = []
        private var leftItem: UIBarButtonItem?
        private var hidesBack = false
        /// Does the title area belong to the header right now. False in selection mode, where theirs
        /// nils the `titleView` outright — the avatar and name give way to Delete All and Cancel.
        private var showsTitle = true

        private weak var target: UIViewController?
        private var observations: [NSKeyValueObservation] = []
        private var reassertScheduled = false
        private var relayoutScheduled = false

        // MARK: Bar

        func setBar(_ new: Bar) {
            bar = new                                   // closures always current
            let sig = new.signature
            guard sig != barSignature else { return }   // shape unchanged → nothing to rebuild
            barSignature = sig
            rebuildItems()
            scheduleAssert()
        }

        /// Their `updateBarButtonItems`, as data rather than as assignments — the assignments happen
        /// in `assertAll`, which is the one place that writes to the navigationItem.
        private func rebuildItems() {
            switch bar {
            case let .conversation(audio, video, enabled):
                var items: [UIBarButtonItem] = []
                if audio != nil {
                    let item = UIBarButtonItem(image: UIImage(named: "ic_call_voice"),
                                               primaryAction: UIAction { [weak self] _ in self?.tapAudio() })
                    item.isEnabled = enabled
                    item.accessibilityLabel = "Voice call"
                    items.append(item)
                }
                if video != nil {
                    let item = UIBarButtonItem(image: UIImage(named: "ic_call_video"),
                                               primaryAction: UIAction { [weak self] _ in self?.tapVideo() })
                    item.isEnabled = enabled
                    item.accessibilityLabel = "Video call"
                    items.append(item)
                }
                rightItems = items
                leftItem = nil
                hidesBack = false
                showsTitle = true
            case let .selection(_, enabled, _):
                // Theirs: `.cancelButton { uiMode = .normal }` on the right, a plain-style "Delete
                // All" on the left, back button hidden, and the TITLE AREA CLEARED — their
                // `uiModeDidChange` runs `navigationItem.titleView = nil` for `.selection`. This file
                // used to claim the opposite in a comment; it was read from an older source.
                rightItems = [UIBarButtonItem(systemItem: .cancel,
                                              primaryAction: UIAction { [weak self] _ in self?.tapCancel() })]
                let delete = UIBarButtonItem(title: "Delete All", style: .plain,
                                             target: nil, action: nil)
                delete.primaryAction = UIAction(title: "Delete All") { [weak self] _ in self?.tapDeleteAll() }
                delete.isEnabled = enabled
                delete.tintColor = .systemRed
                leftItem = delete
                hidesBack = true
                showsTitle = false
            case let .custom(buttons):
                rightItems = buttons.map { b in
                    let item = UIBarButtonItem(image: UIImage(named: b.image)?.withRenderingMode(.alwaysTemplate),
                                               primaryAction: UIAction { [weak self] _ in self?.tapCustom(b.id) })
                    item.accessibilityLabel = b.accessibilityLabel
                    return item
                }
                leftItem = nil
                hidesBack = false
                showsTitle = true
            }
        }

        private func tapAudio()  { if case let .conversation(a, _, _) = bar { a?() } }
        private func tapVideo()  { if case let .conversation(_, v, _) = bar { v?() } }
        private func tapCancel() { if case let .selection(_, _, c) = bar { c() } }
        private func tapDeleteAll() { if case let .selection(d, _, _) = bar { d() } }
        private func tapCustom(_ id: String) {
            if case let .custom(buttons) = bar { buttons.first { $0.id == id }?.action() }
        }

        // MARK: Install

        func install(from marker: UIView) {
            // The OWNING (pushed) controller, not navigationController.topViewController — during a
            // push that is still the previous screen, and the title would land after the transition.
            guard let vc = marker.owningViewController else { return }
            if target !== vc {
                observations.forEach { $0.invalidate() }
                observations = []
                target = vc
            }
            assertAll()
            clearBarAppearance(on: vc)
            guard observations.isEmpty else { return }
            let item = vc.navigationItem
            // Every property this bridge owns is watched. SwiftUI clears them on its own update
            // cycles; the re-assert is deferred and coalesced — see the file comment for the crash
            // that a synchronous one caused.
            observations = [
                item.observe(\.titleView, options: [.new]) { [weak self] _, _ in self?.scheduleAssert() },
                item.observe(\.rightBarButtonItems, options: [.new]) { [weak self] _, _ in self?.scheduleAssert() },
                item.observe(\.leftBarButtonItem, options: [.new]) { [weak self] _, _ in self?.scheduleAssert() },
                // The back button is the title area's left edge: when its visibility changes the
                // header has to be re-seated, or it keeps the frame computed while the leading area
                // was empty and sits under the chevron (the selection-exit bug, twice reported).
                item.observe(\.hidesBackButton, options: [.new]) { [weak self] _, _ in
                    self?.scheduleAssert(); self?.scheduleTitleRelayout()
                },
            ]
        }

        /// The one place that writes. Each property is set only when it differs, so a re-assert that
        /// finds everything in place touches nothing and triggers no further KVO.
        private func assertAll() {
            guard let item = target?.navigationItem else { return }
            var changed = false
            // The header owns the title area except in selection mode, where theirs hands it back
            // to the bar so Delete All and Cancel sit alone.
            let wantedTitle: UIView? = showsTitle ? header : nil
            if item.titleView !== wantedTitle { item.titleView = wantedTitle; changed = true }
            if !(item.rightBarButtonItems ?? []).elementsEqual(rightItems, by: ===) {
                item.rightBarButtonItems = rightItems; changed = true
            }
            if item.leftBarButtonItem !== leftItem { item.leftBarButtonItem = leftItem; changed = true }
            if item.hidesBackButton != hidesBack { item.hidesBackButton = hidesBack; changed = true }
            // Only a flag, never a synchronous layout: this can be reached from the KVO path.
            if changed { target?.navigationController?.navigationBar.setNeedsLayout() }
        }

        private func scheduleAssert() {
            guard !reassertScheduled else { return }
            reassertScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.reassertScheduled = false
                self?.assertAll()
            }
        }

        // A REAL nil→header re-assignment: releasing and re-setting the titleView is what provably
        // makes the bar recompute the title frame; a setNeedsLayout alone left the stale frame on
        // device. Both assignments land in one runloop tick, so nothing flickers.
        private func scheduleTitleRelayout() {
            guard !relayoutScheduled else { return }
            relayoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relayoutScheduled = false
                guard let item = self.target?.navigationItem, item.titleView === self.header else { return }
                item.titleView = nil
                item.titleView = self.header
                self.target?.navigationController?.navigationBar.setNeedsLayout()
            }
        }

        // Be IDENTICAL to the Chats-list header: no per-item appearance, so the bar inherits the
        // system default. Any override here — even a "transparent" one — drew the band/border the
        // owner kept seeing (build 282, "use 282"). The reference app does not restyle its bar either.
        private func clearBarAppearance(on vc: UIViewController) {
            if vc.navigationItem.standardAppearance != nil { vc.navigationItem.standardAppearance = nil }
            if vc.navigationItem.scrollEdgeAppearance != nil { vc.navigationItem.scrollEdgeAppearance = nil }
            if vc.navigationItem.compactAppearance != nil { vc.navigationItem.compactAppearance = nil }
        }

        func remove() {
            observations.forEach { $0.invalidate() }
            observations = []
            guard let item = target?.navigationItem else { return }
            if item.titleView === header { item.titleView = nil }
            if (item.rightBarButtonItems ?? []).elementsEqual(rightItems, by: ===) { item.rightBarButtonItems = nil }
            if item.leftBarButtonItem === leftItem { item.leftBarButtonItem = nil }
        }
    }
}

/// The marker that knows when it lands: `didMoveToWindow` fires at the exact moment
/// `owningViewController` becomes answerable.
final class NavItemMarkerView: UIView {
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
