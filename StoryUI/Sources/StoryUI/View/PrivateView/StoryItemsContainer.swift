//
//  StoryItemsContainer.swift
//  StoryUI
//
//  ONE UIKit CONTAINER PER STORY — their `itemsContainerView` and its per-item
//  `contentContainerView`, and the reason this exists rather than a SwiftUI `ZStack`.
//
//  ⚠️ THE POINT IS THE TRANSFORM, AND SWIFTUI CANNOT BE TRUSTED WITH IT.
//
//  The next step gives every story its own position and scale so A can move centre → side while B
//  moves side → centre. In SwiftUI the only render-time scale is `.scaleEffect`, and this repo has
//  paid for that twice: `c938ad8` scaled the live story with it and `da0bc72` tore it out again,
//  because a SwiftUI scale re-lays-out the hosted representable and re-insets it against the safe
//  area — the "top break-out". A `CGAffineTransform` on a UIView changes no bounds and runs no layout
//  pass, which is exactly why `StoryCardMorph` has always used one.
//
//  Setting a transform on a view SwiftUI owns is not an option either: SwiftUI writes `frame` on
//  every layout pass, and writing `frame` while a transform is non-identity is undefined. So each
//  story gets a container this file owns, and SwiftUI's content lives INSIDE it.
//
//  This step installs the containers and lays them out exactly as the `ZStack` did — every item
//  filling the card. Nothing is transformed yet. If the build looks any different, this file is
//  wrong.
//

import SwiftUI
import UIKit

/// The card's own rectangle clip, present only while the card owns the geometry.
///
/// ⚠️ A `clipShape` AT RADIUS ZERO STILL CLIPS. It had to become a modifier that is absent rather
/// than a radius that is zero, because the edge itself is the problem: once each story carries its
/// own placement they travel out of the card's rectangle, and a clip there cuts them off as they
/// leave. Each item carries its own corner radius instead, which is the right owner anyway — the
/// cards in the row have never all shared one.
struct CardClip: ViewModifier {
    let on: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if on {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

/// The host controller: one child per story id, each holding that story's media.
final class StoryItemsHostVC: UIViewController {
    /// Keyed by story id, because identity is the STORY. A slot-keyed cache would hand one view a
    /// different story as the window moves, which is the single-view architecture being removed.
    private var hosts: [String: UIHostingController<AnyView>] = [:]
    /// Insertion order, so the container's subview order is stable rather than dictionary order.
    private var order: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // The card's own clip lives outside this; a container that clipped would cut the items off
        // the moment they are laid out side by side.
        view.clipsToBounds = false
    }

    func sync(ids: [String], content: (String) -> AnyView) {
        for id in ids {
            if let existing = hosts[id] {
                existing.rootView = content(id)
                continue
            }
            let hc = UIHostingController(rootView: content(id))
            hc.view.backgroundColor = .clear
            // ⚠️ NO AUTORESIZING. This view's frame is written by `viewDidLayoutSubviews` below and,
            // from the next step, its transform. An autoresizing mask would fight both the moment
            // the container's bounds move.
            hc.view.autoresizingMask = []
            addChild(hc)
            view.addSubview(hc.view)
            hc.didMove(toParent: self)
            hosts[id] = hc
            order.append(id)
        }
        // Anything no longer in the window goes, views and all. Their removal is deferred to the end
        // of an animation when one is running; ours has nothing mid-flight to protect yet, because
        // nothing is laid out anywhere but the card.
        let live = Set(ids)
        for id in order where !live.contains(id) {
            guard let hc = hosts.removeValue(forKey: id) else { continue }
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
        }
        order.removeAll { !live.contains($0) }
        // The row blanks its own card for every story held here. Published by the container because
        // it is the thing that knows, rather than guessed at a second time on the host side.
        StoryVideoHost.setHeldItemIds(live)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutItems()
    }

    /// ⚠️ TWO LAYOUTS, AND THE FLAG DECIDES WHICH — because they cannot both be right at once.
    ///
    /// While the host is NOT placing items, the story page owns its own geometry exactly as it
    /// always has: the card container is what `StoryCardMorph` transforms for the pull, and every
    /// item simply fills it. Applying a per-item placement in that state would apply the shrink
    /// TWICE — once as the container's transform and once as the item's — which is why this is a
    /// switch and not an addition.
    ///
    /// While the host IS placing items, the container is left alone and each item takes its own
    /// position and scale, in the container's own space. That is the state where a story can travel:
    /// A moves centre → side and B moves side → centre because each has a view of its own to move.
    ///
    /// The placements arrive in WINDOW coordinates, which is the one space the host computes in and
    /// the same space `StoryRowPlacement` has always used. Converting per item rather than asking
    /// the host for local coordinates keeps the host free of any knowledge of this hierarchy.
    func layoutItems() {
        let layout = StoryItemLayout.shared
        guard layout.hostOwnsItems, !layout.placements.isEmpty else {
            for id in order {
                guard let v = hosts[id]?.view else { continue }
                if v.transform != .identity { v.transform = .identity }
                v.frame = view.bounds
            }
            return
        }
        for id in order {
            guard let v = hosts[id]?.view else { continue }
            guard let p = layout.placements[id] else {
                // A story the host is not placing this pass has nowhere to be. Hidden rather than
                // left at its last seat, which would be a stale card sitting in the row.
                v.isHidden = true
                continue
            }
            v.isHidden = false
            // ⚠️ BOUNDS STAY THE CARD'S AND THE TRANSFORM DOES THE SIZING, WHICH IS THE WHOLE REASON
            // THIS IS UIKit. A bounds change re-lays-out the SwiftUI content inside — the media, its
            // aspect fill, its corner — and that is a layout pass per frame of a drag. A transform
            // changes nothing and runs nothing.
            if v.transform != .identity { v.transform = .identity }
            v.frame = view.bounds
            let scale = view.bounds.width > 1 ? p.size.width / view.bounds.width : 1
            let centre = view.convert(p.center, from: nil)
            v.transform = CGAffineTransform(scaleX: max(scale, 0.0001), y: max(scale, 0.0001))
            v.center = centre
            // The card's clip is gone while we own the geometry, so each item wears its own corner —
            // which is correct rather than merely necessary: the row's cards have never all shared
            // one radius. Pre-divided by the scale it is about to be multiplied by, their
            // `12.0 * (1.0 / itemScale)`, so it reads on screen as the number the host asked for.
            v.layer.cornerCurve = .continuous
            v.layer.cornerRadius = p.cornerRadius / max(scale, 0.0001)
            v.layer.masksToBounds = p.cornerRadius > 0
        }
    }
}

/// The SwiftUI face of it. `ids` is the window; `content` builds one story's media.
struct StoryItemsContainer: UIViewControllerRepresentable {
    let ids: [String]
    let content: (String) -> AnyView

    func makeUIViewController(context: Context) -> StoryItemsHostVC {
        let vc = StoryItemsHostVC()
        vc.sync(ids: ids, content: content)
        return vc
    }

    func updateUIViewController(_ vc: StoryItemsHostVC, context: Context) {
        vc.sync(ids: ids, content: content)
        // ⚠️ LAID OUT NOW, NOT ON THE NEXT PASS. `setNeedsLayout` alone defers to the next runloop
        // turn, which is a frame of lag against a finger — the exact shape of the lag the row was
        // just repaired for. The placements for this pass are already published when SwiftUI runs
        // this, so they are spent here.
        vc.layoutItems()
    }
}
