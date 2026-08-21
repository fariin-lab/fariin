import UIKit
import SwiftUI

// THE ARCHIVE'S STORY STRIP, ON A SCROLL VIEW WE OWN.
//
// ⛔ WHY THIS EXISTS, AND IT IS THE FOURTH ATTEMPT AT ONE BUG. The archive strip's long press has
// been reported dead four times and three source-reasoned fixes have shipped and died. Every one of
// them was a patch on the same mechanism: `StoryRowLongPress` as a SwiftUI `.background`, which has
// to FIND the strip's scroll view by climbing superviews and installing a recogniser on whatever it
// finds. That file now carries a retry, a second retry a runloop later, a liveness check, a
// re-anchor when its host dies, and a gated window fallback for when the climb finds nothing — five
// pieces of machinery, all of them there because the climb is not reliable.
//
// The stories row on the chat list has none of that and has never failed. Its own note says why, in
// one line: it "hands the coordinator its own scroll view directly instead of being found by walking
// up from a SwiftUI representable". This is the archive being given the same thing.
//
// ⚠️ THE CARDS ARE NOT PORTED AND DELIBERATELY SO. Only the SCROLLER changes hands. The cards stay
// the SwiftUI they already are — same drawing, same rings, same rect registration for the story
// flight, same menu — because none of that was ever the broken part, and re-drawing seven working
// things in UIKit to fix a recogniser is how a fix becomes a regression.
//
// `install(from:)` climbs from `view.superview`, so the anchor below only has to be INSIDE the
// scroll view for the very first step to find it. No walk, no timing, nothing to retry.
struct ArchiveStripScroller<Content: View>: UIViewRepresentable {
    /// Which card is under this window point, and what its menu says. Asked at press time.
    let target: (CGPoint) -> StoryMenuTarget?
    /// ⚠️ GIVEN, NOT MEASURED. A `UIScrollView` reports no intrinsic size, so a representable
    /// wrapping one has nothing to tell SwiftUI and the strip would lay out at zero. The archive
    /// already computes its card height exactly — it is the same expression the card's own frame
    /// uses — so it is passed in rather than discovered. One number, from the place that owns it.
    let height: CGFloat
    let content: Content

    init(target: @escaping (CGPoint) -> StoryMenuTarget?,
         height: CGFloat,
         @ViewBuilder content: () -> Content) {
        self.target = target
        self.height = height
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.alwaysBounceHorizontal = true
        sv.backgroundColor = .clear
        // The strip is inside a vertically scrolling List. Without this, a slightly-off-horizontal
        // drag is claimed by the outer list and the strip feels sticky — the SwiftUI ScrollView this
        // replaces got that behaviour for free.
        sv.contentInsetAdjustmentBehavior = .never

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            // Full height, natural width: the content decides how far the strip scrolls and the
            // frame decides how tall it is.
            host.view.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor),
        ])

        // ⛔ THE PRESS, ON A VIEW INSIDE THE SCROLLER. `install` climbs from `view.superview`, so
        // this is found on the first step and can never be found late, never be found wrong, and
        // never fall through to the gated window anchor. It is the same one line the UIKit stories
        // row runs.
        //
        // Not user-interactive and zero-sized: it exists to be an address, not a target.
        let anchor = UIView(frame: .zero)
        anchor.isUserInteractionEnabled = false
        sv.addSubview(anchor)
        context.coordinator.press.install(from: anchor)
        context.coordinator.anchor = anchor
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.press.target = target
        context.coordinator.host.rootView = content
        // The strip's contents change when a story is unhidden or a new one arrives, and SwiftUI is
        // free to rebuild the hosting view under us. Re-asking is a no-op while the press is alive.
        if let a = context.coordinator.anchor { context.coordinator.press.install(from: a) }
    }

    /// Height comes from the caller; width is whatever it is offered.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? UIScreen.main.bounds.width, height: height)
    }

    static func dismantleUIView(_ sv: UIScrollView, coordinator: Coordinator) {
        coordinator.press.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(target: target, content: content) }

    @MainActor final class Coordinator {
        let press: StoryRowLongPress.Coordinator
        let host: UIHostingController<Content>
        weak var anchor: UIView?

        init(target: @escaping (CGPoint) -> StoryMenuTarget?, content: Content) {
            press = StoryRowLongPress.Coordinator(target: target)
            host = UIHostingController(rootView: content)
            // No safe-area inset from a hosting controller that is not in a view controller
            // hierarchy — the strip sets its own padding and a second one would push the cards down.
            host.safeAreaRegions = []
        }
    }
}
