//
// The story viewer's own front door — a screen we present, not a sheet we argue with.
//
// WHY THIS EXISTS, and the crash that ordered it. The stories-row viewer used to be a SwiftUI
// `fullScreenCover`, and the custom open/close flew the card by transforming UIPageViewController's
// INTERNAL `_UIQueuingScrollView`. Build 481 died with that class asserting from
// `queuingScrollView:didEndManualScroll:toRevealView:` while UIKit cleaned up a transition we had a
// transform on. The owner's spec (2026-08-07) draws the line the crash proved: the viewer must be a
// screen OUR code owns end to end — our presentation, our gesture, our animation — with no native
// sheet underneath, no private view touched, and no competing dismissal anywhere.
//
// WHAT THIS IS. A `.overFullScreen` presentation with `animated: false` on both ends: UIKit is
// asked to add and remove the screen and NOTHING else — every visible open and close is drawn by
// us, on views we created:
//
//   window ▸ containerVC.view      ← THE WALL: opaque black at rest; the flight's dim writes here,
//            └ flightView          ← the ONE view the flight transforms (StoryCardMorph.flightCard)
//               └ UIHostingController(StoryViewer…)
//
// The flight shrinks `flightView` — the whole presented screen — and masks it down to the story
// card, so the chat list behind shows through exactly as far as the dim allows. Everything inside
// (pager blacks, footers, reply bar) is cropped by the same mask, which is why none of it has to be
// asked to step aside any more, and why the video keeps playing untouched: the AVPlayerLayer rides
// inside the transformed container and is never reparented, snapshotted or restarted.
//
// The drive itself (thresholds, springs, the drag state machine) is unchanged in StoriesViews —
// only its target moved off Apple's view onto ours. See StoryCardMorph.flightCard for that half.
//
// SCOPE (owner's spec §9): the stories-row door ONLY. Chat-ring, archive, profile and reply-quote
// doors keep Apple's zoom until this one is proven on a real phone.
//

import SwiftUI
import UIKit
import StoryUI

@MainActor
enum StoryZoomPresenter {
    private static var container: StoryZoomContainerVC?

    /// One viewer at a time; the row's onOpen guards on this too.
    static var isActive: Bool { container != nil }

    /// `coverFrom`: the tapped row card's live view. It is photographed HERE, at tap time while it
    /// is definitely on screen, and the snapshot rides the flight as the cover the open wears —
    /// the shared-element look he named from Snapchat: the thumbnail itself expands, opaque from
    /// the first pixel, and dissolves into the live story mid-flight. Nil (card scrolled away, or
    /// capture failed) degrades to the open without a cover, which is the pre-cover behaviour.
    /// - Parameter coverRadius: the radius `source` is drawn with. The shot is cut to it, so the
    ///   corners of the crop — which are the chat list, not the card — never ride the flight. See
    ///   `StoryCardShot.crop`, which is where his white corners are actually removed.
    static func present<Content: View>(_ content: Content, coverFrom source: UIView? = nil,
                                       coverRadius: CGFloat = 0) {
        guard container == nil else { return }
        guard let top = topController() else { return }
        let vc = StoryZoomContainerVC()
        // ⚠️ THE WINDOW IS PHOTOGRAPHED AND CROPPED, NOT THE REGISTERED VIEW, and the difference is
        // the whole cover. `MediaOpenRects` registers an ANCHOR: a `.background` view whose frame is
        // the card's frame and which draws NOTHING — the SwiftUI card is its sibling, not its
        // subtree. `drawHierarchy` renders the receiver's own hierarchy, so photographing the anchor
        // returned a fully transparent image, and the shared element has been an invisible cover
        // ever since it was written. That is his B-pops-to-A report arriving from the direction
        // nobody looked: the seat and the landing had nothing to wear, so the row card's picture was
        // swapped for the live story in one frame at both ends. Cropping the window at the card's
        // rectangle takes the pixels that are actually on screen — the photo AND the avatar ring
        // drawn over it — which is what the row card is.
        // ONE copy of that crop, in `StoryCardShot` — the row's long-press lift needs exactly the
        // same picture of exactly the same card, and two functions that have to agree pixel for
        // pixel is the mistake this area keeps writing down.
        if let source, let shot = StoryCardShot.crop(source, cornerRadius: coverRadius) {
            vc.setCoverImage(shot)
        }
        vc.setContent(AnyView(content))
        container = vc
        // animated:false is the whole design: the card flying out of the row IS the open animation
        // (`stageHeroOpen`), and a system presentation under it would be a second one nobody asked
        // for — the exact note the cover carried.
        top.present(vc, animated: false)
    }

    /// Delete-refeed: swap the viewer for one fed the remaining stories, in place, no re-present.
    /// `.id(UUID())` forces a fresh identity so the new viewer starts with fresh @State instead of
    /// inheriting the deleted story's — the same reason the old cover did its nil→fresh dance.
    static func replaceContent<Content: View>(_ content: Content) {
        container?.setContent(AnyView(content.id(UUID())))
    }

    /// The flight has landed (or the viewer must leave NOW): take the screen away with no animation
    /// of its own. Anything else would play a second close over the one the finger just drew.
    static func finish() {
        let vc = container
        container = nil
        vc?.tearDown()
    }

    /// The close that has nowhere to fly (the row card scrolled away, or geometry never came good):
    /// a short drift down and fade, drawn by us, then the instant removal. Gentler than the old
    /// "instant exit is the honest answer", and still honest — it never pretends to land anywhere.
    static func closeWithDrift() {
        guard let vc = container else { return }
        container = nil
        vc.driftAwayThenTearDown()
    }

    /// BELT, from the container's `viewDidDisappear`: if the screen left the stage by ANY path —
    /// including one we did not drive — the presenter must not go on believing a viewer is up.
    /// `isActive` stuck true would leave every story card dead until relaunch.
    static func noteDismissed(_ vc: StoryZoomContainerVC) {
        if container === vc { container = nil }
        // ⚠️ AND GIVE THE SOURCE BACK. The open HIDES whatever it flew out of, so the row shows a
        // waiting hole while the story is up, and every exit we drive reveals it again through
        // `storyPresenterClosed`. This belt did not: it cleared the flag and left the hole.
        //
        // That was survivable while the only door was the stories row, where a missing card reads as
        // a gap in a strip. It is not survivable now the CHAT LIST's ringed avatars use this: an
        // exit we did not drive would leave a permanent blank circle in the main screen of the app,
        // with no way back short of a relaunch. Idempotent, so calling it on every path is free.
        MediaSourceVisibility.shared.reveal()
        // Same belt for the fold flag, which `tearDown` clears on the driven paths: left raised by
        // an exit we did not drive, it would keep the NEXT story's cube flat for the whole visit.
        StoryCardMorph.heroDismissActive = false
    }

    private static func topController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// The presented screen. Deliberately dumb: it owns the wall, the flight container and the hosted
/// SwiftUI content, and nothing about the transition itself — the drive lives with the viewer.
final class StoryZoomContainerVC: UIViewController {
    let flightView = UIView()
    private var hosting: UIHostingController<AnyView>?
    private var pendingRoot: AnyView?
    /// The snapshot of the tapped row card, worn by the open and by the close's landing. Lives
    /// INSIDE flightView (top-most), so it rides the flight's transform and mask for free; framed
    /// to the card strip by `StoryCardMorph.applyCore`; alpha driven only by the flight's ticks.
    /// Born invisible: before the flight has geometry its frame falls back to the whole screen,
    /// and a full-screen cover flash is exactly the kind of frame this system exists to kill.
    private var coverView: UIImageView?

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        // The story is black; the clock over it must be white whatever theme the app is in.
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        // THE WALL. Opaque black AT REST — a friend's full-bleed story has no black of its own
        // (that was the cover's `.presentationBackground`), so without it the chat list would show
        // through the letterbox. But BORN TRANSPARENT: the screen goes up with no animation, and an
        // opaque wall on frame one would snap the whole display to black before the flight has even
        // found its geometry — the tap must keep showing the chat list until the card lifts off the
        // row. Who paints it after that: `applyFlight`'s dim writes this alpha every frame of a
        // flight (up to 0.45, Snapchat-judged, letting go before the landing), and `resetFlight`
        // makes it opaque at every arrival at rest — the open landing, a cancelled drag springing
        // home, and the no-flight fallback alike.
        view.backgroundColor = UIColor.black.withAlphaComponent(0)
        flightView.backgroundColor = .clear
        flightView.frame = view.bounds
        flightView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(flightView)
        StoryCardMorph.shared.attachFlight(flightView)
        if let root = pendingRoot {
            pendingRoot = nil
            mount(root)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Fully off the presentation stack (not covered by a sheet): tell the presenter, in case
        // this exit was not one of ours. See `StoryZoomPresenter.noteDismissed`.
        if presentingViewController == nil { StoryZoomPresenter.noteDismissed(self) }
    }

    func setContent(_ root: AnyView) {
        if let hosting {
            hosting.rootView = root
        } else if isViewLoaded {
            mount(root)
        } else {
            pendingRoot = root
        }
    }

    func setCoverImage(_ image: UIImage) {
        let iv = UIImageView(image: image)
        // Framed by `applyCore` to the flight's CROP, whose aspect is the row card's exactly, so at
        // the row end this fills it with nothing spare. Aspect-fill (never stretch) for the frames
        // in between, where the crop opens towards 9:16 while the cover is already dissolving out.
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.alpha = 0
        coverView = iv
    }

    private func mount(_ root: AnyView) {
        let hc = UIHostingController(rootView: root)
        hc.view.backgroundColor = .clear   // the wall behind answers for what shows through
        addChild(hc)
        hc.view.frame = flightView.bounds
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        flightView.addSubview(hc.view)
        hc.didMove(toParent: self)
        hosting = hc
        // The cover sits ABOVE the content, inside the transformed container: it rides the flight's
        // transform and mask untouched, and only its alpha is ever driven.
        if let coverView {
            flightView.addSubview(coverView)
            StoryCardMorph.shared.flightCover = coverView
        }
    }

    func tearDown() {
        // Dismiss FIRST, detach second. `detachFlight` runs `resetFlight`, which puts the container
        // back to identity — done before the dismissal that would be one frame of full-screen story
        // painted between the landing and the removal. Off-window, the reset touches nobody.
        dismiss(animated: false)
        // THE CUBE STAYS FLAT UNTIL THE SCREEN IS GONE. The landing used to clear this, but the
        // landing is 0.03s before the removal on this door — and an unflagged card that is still
        // parked on the row card computes a large fold angle from its global minX. See the note in
        // `land`, and StoryDetailView's own for what that fold looks like.
        StoryCardMorph.heroDismissActive = false
        if StoryCardMorph.shared.flightCover === coverView { StoryCardMorph.shared.flightCover = nil }
        // Identity-checked detach, same contract as the pagers': a successor presented before this
        // teardown finishes must not lose its registration.
        StoryCardMorph.shared.detachFlight(flightView)
    }

    func driftAwayThenTearDown() {
        // All ours: one short ease-in drift while the wall lets go, then the instant removal. The
        // numbers are the chat media viewer's no-destination fallback, halved — this path is rare
        // and should feel like a door closing, not an animation performing.
        let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeIn) { [self] in
            flightView.transform = CGAffineTransform(translationX: 0, y: 90).scaledBy(x: 0.96, y: 0.96)
            flightView.alpha = 0
            view.backgroundColor = UIColor.black.withAlphaComponent(0)
        }
        animator.addCompletion { [weak self] _ in self?.tearDown() }
        animator.startAnimation()
    }
}
