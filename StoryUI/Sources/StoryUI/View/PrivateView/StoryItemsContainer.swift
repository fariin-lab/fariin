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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Every item fills the card, which is what the `ZStack` did. Positions and scales arrive in
        // the next step; until then this must be indistinguishable from what shipped.
        for id in order {
            hosts[id]?.view.frame = view.bounds
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
        vc.view.setNeedsLayout()
    }
}
