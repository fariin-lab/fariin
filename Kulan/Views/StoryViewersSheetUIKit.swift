import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass   // DirectionalSheetPan sets `state = .failed`

// The story viewers sheet, in UIKit.
//
// WHY IT MOVED. The SwiftUI version worked, but it had to be argued into working: THREE
// `DragGesture`s (the handle, the list, the backdrop) all writing one `progress`, a `SheetDragArbiter`
// class to stop them writing on alternate frames, `scrollDisabled(progress < 1 || dragStart != nil)`
// to keep the list from fighting the sheet, `scrollBounceBehavior(.basedOnSize)` to kill a rubber-band
// that fought the collapse, and a watchdog to un-park a sheet left mid-air by a cancelled drag. Every
// one of those is a patch over the same missing thing: SwiftUI gives no way to say "this pan and that
// scroll view are one interaction".
//
// UIKit does, and it is one method. `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` lets the
// sheet's pan and the table's own pan run together, and the handler decides which of them owns the
// movement on each event by asking one question: is the list at its top and is the finger going down.
//
// TOUCH ROUTING (the 2026-08-05 rebuild — the reference app's model, read from its source):
//
// This view is full-screen, and `hitTest` partitions the screen into exactly three territories so
// every touch has ONE owner:
//   1. THE PANEL — the sheet machinery: its own pan (drag the sheet, hand off to the list), the
//      tabs, the search, the table.
//   2. THE CAROUSEL BAND (a rect the host publishes), only while the sheet is fully open — passed
//      through to SwiftUI, where the carousel's own horizontal drag and card taps live.
//   3. EVERYTHING ELSE ABOVE THE PANEL — ours: a tap collapses the sheet, and a pan on the WINDOW
//      drags the story card + sheet as one connected surface (on the window because the carousel
//      band hit-tests through this view, and a vertical drag on the shrunken card must collapse
//      the sheet exactly like the reference app's; only the band's horizontal drags are refused, so the
//      cover-flow keeps them).
//
// WHY THE WINDOW PANS EXIST AT ALL: Apple's zoom transition installs its own interactive-dismiss pan
// up the presentation chain, and it sees every touch in the cover no matter who hit-tests it. That
// pan tracking a sheet drag is why dragging the sheet down used to close the WHOLE story viewer.
// `require(toFail:)` on it was tried and DID NOT HOLD on the device (build 466) — so while the
// sheet is in a window the foreign pans up the chain are DISABLED outright and restored on unmount:
// see `suspendForeignPans`. The reference app does the same thing by policy: its outer gestures are
// refused entirely while the view list is open (its own interactive-gestures flag going false in
// its list container).
//
// RELEASE: no internal animator any more. Every finger-up reports (progress, where the drag started,
// velocity) to the host, which owns the ONE spring that settles sheet + story morph + carousel on the
// same per-frame value. The old `UIViewPropertyAnimator` settle animated the panel beautifully and
// reported progress ONCE — the story snapped to its end state while the sheet glided, which is
// exactly the disconnection the owner reported.
//
// WHAT IS STILL SWIFTUI, DELIBERATELY: the row's contents, through `UIHostingConfiguration`.
//
// WHAT THIS VIEW IS NOT ANY MORE: the viewers list. Everything a list is made of — the table, the
// search field, the tabs, the filter, the people — moved to `StoryViewersPanelView`, one instance
// per story id, because a sheet that can slide sideways has to be able to hold two of them at once.
// See that file's header for why, and `handlePagePan` below for the geometry that moves them.
final class StoryViewersSheetView: UIView {

    // MARK: Public surface

    /// 0 shut, 1 fully open. The host reads this to drive the live story's morph, so it is the same
    /// number the card is scaled by — the sheet and the story cannot disagree about how far open it is.
    var onProgress: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    var onSendMessage: ((StoryViewerInfo) -> Void)?
    /// Tap the row → that person's profile. Blocking is the host's job too: it writes the
    /// conversation and revokes my live stories from them (see `ChatService.setBlocked`), neither of
    /// which belongs to a sheet that only knows how to draw a list.
    var onOpenProfile: ((StoryViewerInfo) -> Void)?
    var onBlock: ((StoryViewerInfo) -> Void)?
    /// Finger lifted: (progress now, progress when the drag began, velocity in progress-units/sec,
    /// + = opening). The host decides open/close (the reference app's thresholds) and runs the one spring.
    var onRelease: ((CGFloat, CGFloat, CGFloat) -> Void)?
    /// A finger owns progress right now (any of our pans is live). The host cancels its spring on
    /// true and holds its parked-sheet watchdog while it is true.
    var onDragActive: ((Bool) -> Void)?
    /// Tap on the dark area above the panel → collapse (NOT dismiss the viewer).
    var onCollapseTap: (() -> Void)?
    /// Swipe the sheet sideways → the NEIGHBOUR story's sheet (+1 next, -1 previous), the reference app's
    /// own page-swipe gesture: its sheet at .half slides horizontally into the next item's own list.
    /// The host switches `sheetStoryId`; everything else (list reload, carousel recentre, the
    /// frozen story jumping underneath) already follows that one value.
    var onPage: ((Int) -> Void)?
    /// LIVE sideways page drag as a FRACTION OF ONE PANEL WIDTH, signed, rubber-banded past the ends.
    /// The host spends it as card units, so one full width of travel is exactly one card.
    ///
    /// ⚠️ THIS HAS BEEN BOTH WAYS IN ONE DAY AND THIS IS THE ONE HE WANTS. It shipped in 470 as raw
    /// POINTS, divided by the row's own points-per-card, because he said the row "is not working
    /// like when I'm using my finger" — and 1:1 points does make the two gestures move the row at
    /// the same rate. But it cannot also keep them in step, because the two gestures have different
    /// journeys: the row brings a card home in `fullDist`, about half a screen, while the panel
    /// needs a whole width. 1:1 points therefore ran the row about two cards for one sheet.
    ///
    /// His newer spec is synchronisation, in his words: "if I swipe 10% in the sheet viewer, the top
    /// image should also move 10%… when the sheet viewer reaches the next image, the corresponding
    /// top image should also be centered". That is proportional, so proportional it is. The cost is
    /// the one he reported this morning — dragging the SHEET moves the row at about half the rate
    /// dragging the ROW does — and it is unavoidable while the two have different lengths to cover.
    var onPageDrag: ((CGFloat) -> Void)?
    /// Whether a neighbour exists on each side — no neighbour means the drag rubber-bands.
    var hasPrev = false
    var hasNext = false
    /// Where the my-stories carousel row sits (screen coords). Touches here pass through to SwiftUI
    /// while the sheet is fully open, so the cover-flow swipe and card taps keep working.
    var carouselBand: CGRect = .zero

    /// Height as a fraction of the screen. Matches `StoryViewersBottomSheet.heightFraction`, which the
    /// carousel still derives its slot from.
    ///
    /// ⚠️ THIS ONE NUMBER IS BOTH HALVES OF HIS 2026-08-09 ASK — "make the sheet slightly taller,
    /// not too tall" AND "make the thumbnail cards slightly smaller to give the sheet space". They
    /// are the same number because `cardSlot` lays the cards out in what is LEFT: its `avail` is
    /// `screen − sheetH − topInset`, so the sheet growing is the cards shrinking, and nothing has
    /// to be kept in step by hand.
    ///
    /// 0.60 → 0.64. On an 852pt screen that is ~34pt more sheet (the empty band he drew a line
    /// through, between the count row and the sheet's top edge) and a card that goes 200pt → 172pt.
    /// Deliberately small: 0.66 was tried on paper and takes a fifth off the card, which is a
    /// resize rather than the nudge he asked for. If he wants more, move THIS and nothing else.
    static let heightFraction: CGFloat = 0.64

    private(set) var progress: CGFloat = 0

    // MARK: The panels

    /// EVERY LIVE PANEL, BY STORY ID — the reference app's `viewLists: [StoryId: ViewList]`.
    ///
    /// Normally three: the story on screen and its two neighbours. A page that is still settling can
    /// leave a fourth behind for the length of the settle (see `pageActive`), which is deliberate —
    /// nothing is torn down while it is moving.
    private var panels: [String: StoryViewersPanelView] = [:]
    private var centerId = ""
    private var prevId = ""
    private var nextId = ""

    /// The panel the sheet's own gestures talk to: the one at slot 0.
    private var centerPanel: StoryViewersPanelView? { panels[centerId] }

    /// Where the story-viewers panels live and what the sheet knows about their order. The host
    /// calls this whenever the story on screen or either neighbour changes; slots are re-asserted
    /// from it, so the host always has the last word about which story is which.
    func setStories(center: String, prev: String, next: String) {
        guard center != centerId || prev != prevId || next != nextId else { return }
        centerId = center
        prevId = prev
        nextId = next
        ensurePanel(center, slot: 0)
        ensurePanel(prev, slot: -1)
        ensurePanel(next, slot: 1)
        // ⚠️ NEVER MID-MOTION. A panel removed while it is sliding is the bug the whole snapshot
        // approach was working around; the reference app has the same fence
        // (`viewListPanState != nil || isCompletingViewListPan` keeps every built list valid).
        if !pageActive { dropStalePanels() }
        setNeedsLayout()
    }

    func setViewers(_ v: [StoryViewerInfo], for id: String) { panels[id]?.viewers = v }
    func setLoading(_ l: Bool, for id: String) { panels[id]?.isLoading = l }
    func setAudience(title: String, bothTabs: Bool, for id: String) {
        panels[id]?.audience = (title, bothTabs)
    }

    /// Build the panel for a story if it is not up yet, and wire it to the sheet. Empty id = no
    /// neighbour that way, which is not an error and not a panel.
    ///
    /// ⚠️ THE SLOT GOES IN BEFORE THE FIRST LAYOUT, NOT AFTER. Every panel starts at slot 0, so a
    /// neighbour laid out first and slotted second is laid out ON TOP OF THE ONE ON SCREEN for
    /// however long it takes the next layout pass to come round.
    @discardableResult
    private func ensurePanel(_ id: String, slot: CGFloat) -> StoryViewersPanelView? {
        guard !id.isEmpty else { return nil }
        if let existing = panels[id] {
            existing.slot = slot
            return existing
        }
        let p = StoryViewersPanelView(storyId: id)
        p.slot = slot
        p.onSendMessage = { [weak self] v in self?.onSendMessage?(v) }
        p.onOpenProfile = { [weak self] v in self?.onOpenProfile?(v) }
        p.onBlock = { [weak self] v in self?.onBlock?(v) }
        p.onSearchActive = { [weak self] on in self?.setSearchExpanded(on) }
        p.shouldPinScroll = { [weak self] in self?.dragOwnsSheet ?? false }
        panels[id] = p
        addSubview(p)
        // Laid out before it is ever seen: a panel built for a neighbour is created off the edge,
        // and a first layout inside an animation block would fly it in from wherever zero is. It
        // also joins the strip where the strip currently is — a panel the host hands us mid-page
        // must not sit one displacement away from its siblings.
        layoutPanel(p)
        if pageOffset != 0 { p.transform = CGAffineTransform(translationX: pageOffset, y: 0) }
        return p
    }

    private func dropStalePanels() {
        for (id, p) in panels where id != centerId && id != prevId && id != nextId {
            p.removeFromSuperview()
            panels.removeValue(forKey: id)
        }
    }

    // MARK: Gestures

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tapAbove = UITapGestureRecognizer(target: self, action: #selector(handleTapAbove(_:)))
    /// The drag on the story card / dark area, attached to the WINDOW so it also sees the carousel
    /// band (which hit-tests through to SwiftUI). NOT direction-locked: every drag above the panel
    /// must be OURS (a horizontal one just moves nothing), because any drag we fail is a drag
    /// Apple's interactive dismiss is free to take — the whole-viewer-closes bug through a side
    /// door. The one exception is horizontal drags in the carousel band, refused in shouldBegin so
    /// the cover-flow keeps them (bandGuard blocks the system pans there instead).
    ///
    /// ⚠️ AXIS-LOCKED NOW, AND THAT IS A BUG FIX RATHER THAN A TIDY-UP. It was a plain
    /// `UIPanGestureRecognizer` whose direction was decided in `shouldBegin` from the INSTANTANEOUS
    /// velocity at the ~10pt mark, and it won every tie. A thumb swiping the thumbnails along a
    /// slight arc reported `|vy| >= |vx|` at that one instant, so this took the gesture, cancelled
    /// the row's touches underneath it, and collapsed the sheet instead. It is a
    /// `DirectionalSheetPan` on the vertical axis now, which fails itself after 2pt of dominant
    /// horizontal travel — the reference app's own rule, and far earlier than either could begin.
    private lazy var outsidePan = DirectionalSheetPan(axis: .vertical, target: self, action: #selector(handleOutsidePan(_:)))
    /// Begins on horizontal drags in the carousel band and does NOTHING except exist: the system
    /// dismiss pans are subordinated to it, so a cover-flow swipe can never feed Apple's
    /// interactive dismiss. `cancelsTouchesInView = false` keeps the SwiftUI carousel tracking.
    private lazy var bandGuard = DirectionalSheetPan(axis: .horizontal, target: self, action: #selector(handleBandGuard(_:)))
    private weak var installedWindow: UIWindow?
    /// Foreign pans switched OFF while the sheet exists — see `suspendForeignPans`.
    private var suspendedPans: [UIPanGestureRecognizer] = []

    /// Progress when the current drag began, so the finger maps 1:1 from wherever it grabbed.
    private var dragStart: CGFloat = 0
    /// Translation already accumulated when the pan engaged (the recognizer begins ~10pt in);
    /// subtracted so the first frame moves nothing — the engagement snap the owner once measured.
    private var panBaselineY: CGFloat = 0
    /// The sheet's height in points when the current drag began — their `viewListHeight` at the start
    /// of a pan, and the thing a finger's travel is added to.
    private var dragStartHeight: CGFloat = 0
    /// Whether that drag began above the half stop, so a release that has come back down to exactly
    /// the stop still knows it belongs to the expand rule rather than to the close rule.
    private var dragStartExpand: CGFloat = 0
    private var outsideDragStart: CGFloat = 0
    private var outsideBaselineY: CGFloat = 0
    /// True once a drag has decided the SHEET owns it rather than the list.
    private var dragOwnsSheet = false
    /// TRUE FOR THE REST OF A GESTURE THAT WAS SPENT COLLAPSING THE SEARCH. One touch does one
    /// thing: the drag that steps the sheet back from full to half is finished the moment it has
    /// done that, and cannot go on to take the sheet and dismiss it. See `handlePan`.
    private var dragSpentOnSearch = false

    /// SEARCH GROWS THE SHEET TO (almost) THE WHOLE SCREEN — the reference app's rule, read from its
    /// source on his order (2026-08-09: "there is not enough space when the keyboard appears…
    /// first go read the reference app"). Its viewers panel has two resting states, half and full, and
    /// focusing search jumps it to full = screen height minus 60 on a 0.5s spring; leaving search
    /// steps it back to half. Ours maps their "half" to the resting `heightFraction` sheet and their "full"
    /// to this flag — same layout path, one number changes, so every child lays out through the
    /// code that already positions it.
    /// HOW FAR PAST THE HALF STOP THE SHEET IS: 0 = half, 1 = full screen.
    ///
    /// ⚠️ THE REFERENCE APP HAS THREE RESTING STATES AND WE ONLY EVER HAD TWO. Theirs are hidden,
    /// half and full, and the way to full is to DRAG THE LIST UP — the whole of
    /// `viewListDismissPanGesture`'s upward half exists for it. Ours could only reach full by
    /// focusing the search field, so a long viewers list had no way to be made bigger.
    ///
    /// Theirs is not a third flag either. It is ONE height, clamped between two stops:
    ///
    ///     viewListHeight += -verticalPanState.accumulatedOffset
    ///     viewListHeight = max(minViewListHeight, min(maxViewListHeight, viewListHeight))
    ///     self.targetViewListDisplayStateIsFull = viewListHeight > midViewListHeight
    ///
    /// so the drag past the half stop is continuous and the state is a description of where the
    /// height ended up rather than something the gesture has to decide as it goes. `progress` and
    /// this are the two halves of that one height: `progress` covers hidden → half, this covers
    /// half → full, and `dragHeight` below is the single number the finger actually writes.
    private var expand: CGFloat = 0

    private var halfHeight: CGFloat { bounds.height * Self.heightFraction }
    /// Their `maxViewListHeight = availableSize.height - 60.0`, with our safe-area floor.
    private var fullHeight: CGFloat { bounds.height - max(60, safeAreaInsets.top + 8) }
    private var sheetHeight: CGFloat { halfHeight + (fullHeight - halfHeight) * expand }
    private var panelTop: CGFloat { bounds.height - sheetHeight * progress }

    /// THE ONE NUMBER A VERTICAL DRAG WRITES — their `viewListHeight`. Reading it turns the two
    /// stored fractions back into points; writing it splits the points back into the two, which is
    /// what keeps a single finger travelling smoothly across the half stop instead of stalling at it.
    private var dragHeight: CGFloat {
        get { halfHeight * progress + (fullHeight - halfHeight) * expand }
        set {
            let h = max(0, min(fullHeight, newValue))
            setProgress(min(1, h / max(1, halfHeight)))
            setExpand(max(0, h - halfHeight) / max(1, fullHeight - halfHeight))
        }
    }

    private func setExpand(_ v: CGFloat) {
        let clamped = max(0, min(1, v))
        guard abs(clamped - expand) > 0.0001 else { return }
        expand = clamped
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: Init

    /// The horizontal sheet-to-sheet pan (see `onPage`). On SELF like the vertical pan; the two are
    /// axis-partitioned — the vertical pan's shouldBegin demands |vy| ≥ |vx| and this one is
    /// direction-locked horizontal, so exactly one of them takes any given drag.
    private lazy var pagePan = DirectionalSheetPan(axis: .horizontal, target: self, action: #selector(handlePagePan(_:)))
    private var pageBaselineX: CGFloat = 0
    /// HOW FAR THE WHOLE STRIP OF PANELS IS DISPLACED, IN POINTS. Applied as a translation transform
    /// to every panel, so the strip moves as one and each panel's own resting place (its `slot`)
    /// stays a plain frame the sheet's height animations can keep writing. Zero at rest.
    private var pageOffset: CGFloat = 0
    /// TRUE from the first millimetre of a page drag until its settle has landed. While it is true
    /// no panel is ever removed — see `setStories`.
    private var pageActive = false
    /// Bumped on every `.began`, captured by each settle's completion, so a settle that a new finger
    /// interrupted cannot clear `pageActive` out from under the drag that replaced it.
    private var pageCycle = 0
    /// One panel width plus the gap the reference app leaves between two lists, so a departing
    /// panel's shadow and rounded corners clear the screen edge before the next one arrives.
    private var pageTravel: CGFloat { bounds.width + 20 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // ALWAYS DARK (owner 2026-08-05: "search in viewer plz make it dark mode always"). The
        // panel's own colours are hard-coded dark, but the SYSTEM pieces inside it — the search
        // field's text, placeholder, loupe and cursor, the table's scroll indicator — resolve from
        // the interface style, and on a light-mode phone they came out light-on-light. One override
        // here and every system control inside the sheet resolves dark, matching the story area's
        // standing rule.
        overrideUserInterfaceStyle = .dark
        pan.delegate = self
        addGestureRecognizer(pan)
        tapAbove.delegate = self
        addGestureRecognizer(tapAbove)
        pagePan.delegate = self
        addGestureRecognizer(pagePan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Touch routing

    /// The three territories. See the header note.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        if point.y >= panelTop { return super.hitTest(point, with: event) }
        // The carousel is only interactive once the sheet has settled open (it fades in over the
        // last tenth of the pull) — mid-drag its band belongs to us like everything else.
        if progress > 0.95, carouselBand.contains(point) { return nil }
        return self
    }

    /// The window pans install when the sheet enters a window and leave with it. They live on the
    /// window because the carousel band hit-tests through this view: a pan attached HERE would never
    /// see a vertical drag that starts on the shrunken story card, and that drag is the single most
    /// natural collapse gesture there is (it is how the reference app closes theirs).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let old = installedWindow, old !== window {
            old.removeGestureRecognizer(outsidePan)
            old.removeGestureRecognizer(bandGuard)
            installedWindow = nil
            restoreForeignPans()
        }
        guard let window else { return }
        if installedWindow !== window {
            outsidePan.delegate = self
            bandGuard.delegate = self
            bandGuard.cancelsTouchesInView = false
            window.addGestureRecognizer(outsidePan)
            window.addGestureRecognizer(bandGuard)
            installedWindow = window
        }
        subordinateSystemPans()
        suspendForeignPans()
    }

    /// THE OWNER'S RULE, VERBATIM: "when sheet is open disable scroll down to close story."
    ///
    /// `require(toFail:)` was tried first and DID NOT HOLD on the device (build 466: dragging the
    /// open sheet rode the whole cover down into Apple's zoom dismissal — his screenshot). Whatever
    /// recognizer drives that dismissal either never matched the "_UI" name test or never honoured
    /// the requirement, and there is no way to know which from here. So no more asking it to wait:
    /// while this sheet is IN A WINDOW, every foreign pan recognizer up the chain is switched OFF
    /// and remembered, and switched back on the moment the sheet leaves.
    ///
    /// Why this is safe where the requirement was not: a pan that is DISABLED when a touch begins
    /// never receives that touch at all, and enabling it later does not deliver the touch
    /// retroactively — so it cannot take over mid-gesture the way a merely-waiting recognizer can
    /// the instant its requirement dies. SwiftUI's own recognizers ("SwiftUI…") are left strictly
    /// alone: the carousel's swipe and every other content gesture multiplex through them.
    ///
    /// Re-run on every drag start as well as on mount, because system recognizers can be created
    /// lazily — a pan that did not exist when the sheet mounted must still be caught.
    private func suspendForeignPans() {
        var node: UIView? = superview
        while let cur = node {
            for g in cur.gestureRecognizers ?? [] {
                guard let p = g as? UIPanGestureRecognizer,
                      p !== pan, p !== outsidePan, p !== bandGuard,
                      !suspendedPans.contains(where: { $0 === p }) else { continue }
                guard !NSStringFromClass(type(of: p)).hasPrefix("SwiftUI") else { continue }
                if p.isEnabled {
                    p.isEnabled = false
                    suspendedPans.append(p)
                }
            }
            node = cur.superview
        }
    }

    private func restoreForeignPans() {
        for p in suspendedPans { p.isEnabled = true }
        suspendedPans.removeAll()
    }

    /// Every system "_UI…" pan up the chain (Apple's zoom-transition interactive dismiss lives
    /// there) must wait for OUR pans to fail while the sheet exists. Ours begin on every vertical
    /// drag anywhere and on horizontal drags in the carousel band, so the system dismiss never
    /// engages under the sheet — dragging the sheet down can no longer close the whole viewer.
    /// Name is READ only, no private API is called; if iOS renames them this degrades to the old
    /// behaviour rather than breaking. Requirements on recognizers that are later removed from the
    /// window are inert (a detached recognizer is not analyzing any touch), so Apple's dismiss is
    /// back to normal the moment the sheet unmounts.
    private func subordinateSystemPans() {
        var node: UIView? = superview
        while let cur = node {
            for g in cur.gestureRecognizers ?? [] {
                guard g is UIPanGestureRecognizer, g !== outsidePan, g !== bandGuard else { continue }
                if NSStringFromClass(type(of: g)).hasPrefix("_UI") {
                    g.require(toFail: pan)
                    g.require(toFail: outsidePan)
                    g.require(toFail: bandGuard)
                }
            }
            node = cur.superview   // ends at (and includes) the UIWindow
        }
    }

    // MARK: Layout

    /// EVERY PANEL, PLACED BY ONE FORMULA — the reference app's, line for line:
    ///
    ///     var viewListFrame = CGRect(origin: CGPoint(x: viewListBaseOffsetX, ...
    ///     let indexDistance = CGFloat(max(-1, min(1, itemIndex - currentIndex)))
    ///     viewListFrame.origin.x += indexDistance * (availableSize.width + 20.0)
    ///
    /// `slot` is their `indexDistance` and `pageOffset` is their `viewListBaseOffsetX`. One number
    /// for the strip, one number per panel, and the neighbour is placed by the same arithmetic as
    /// the one on screen rather than by a second code path.
    ///
    /// ⚠️ CENTRE AND BOUNDS, NOT `frame`. Every panel carries the strip's translation as a transform
    /// (see `handlePagePan`), and setting `frame` on a transformed view is undefined. Their
    /// `setPosition`/`setBounds` pair is the same choice for the same reason. It is also what keeps
    /// the sheet's HEIGHT animations (`animateExpand`, the host's settle) independent of the
    /// sideways motion: one writes bounds and centre, the other writes the transform, and neither
    /// can cancel the other's animation.
    override func layoutSubviews() {
        super.layoutSubviews()
        for p in panels.values { layoutPanel(p) }
    }

    private func layoutPanel(_ p: StoryViewersPanelView) {
        let h = sheetHeight
        let size = CGSize(width: bounds.width, height: h)
        if p.bounds.size != size { p.bounds = CGRect(origin: .zero, size: size) }
        p.center = CGPoint(x: p.slot * pageTravel + bounds.width / 2,
                           y: bounds.height - h * progress + h / 2)
    }

    // MARK: Progress

    /// Move the sheet, without animation. The host's spring drives this frame by frame during a
    /// release, exactly as the finger does during a drag, so there is one path and one feel.
    func setProgress(_ p: CGFloat) {
        let clamped = max(0, min(1, p))
        guard abs(clamped - progress) > 0.0001 else { return }
        progress = clamped
        // A SHEET ON ITS WAY DOWN IS NOT AN EXPANDED SHEET.
        //
        // The host's release spring writes this directly, frame by frame, and knows nothing about the
        // half → full stop. Left standing, `expand` would keep `sheetHeight` at the FULL height for
        // the whole of a close, so the panel would slide out at full height and the story behind it
        // would be measured against a sheet that is no longer there. Zeroed without animation on
        // purpose: the sheet is already moving, and a spring on top of a spring is two curves.
        if clamped < 0.999, expand > 0 { expand = 0 }
        setNeedsLayout()
        layoutIfNeeded()
        onProgress?(clamped)
    }

    // MARK: Gesture handlers

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let translation = g.translation(in: self).y
        let velocity = g.velocity(in: self).y

        switch g.state {
        case .began:
            dragSpentOnSearch = false
            // A DRAG WHILE THE KEYBOARD IS UP STEPS BACK ONE LEVEL, the reference app's rule: search →
            // half, and only the NEXT drag can dismiss.
            //
            // ⚠️ IT ASKS THE SEARCH FIELD NOW, NOT THE HEIGHT. The test used to be `searchExpanded`,
            // which was the same thing while search was the only way to reach the full stop. A drag
            // can reach it now, and a sheet a finger opened must be closable by that finger's next
            // drag rather than spending a whole gesture doing nothing.
            if let c = centerPanel, c.isSearchFocused {
                c.endSearchEditing()
                setSearchExpanded(false)
                g.setTranslation(.zero, in: self)
                dragOwnsSheet = false
                // AND NOW SOMETHING ENFORCES THAT CLAIM. Returning here used to leave the same touch
                // live: the very next `.changed` asked `shouldSheetTakeDrag` again, got a yes (the
                // list is at its top and the finger is still coming down), took the sheet, and the
                // release dismissed it. So one flick collapsed the search AND closed the sheet, when
                // the rule above says the close belongs to a second, separate drag. The flag spends
                // this gesture on the collapse and on nothing else.
                dragSpentOnSearch = true
                return
            }
            onDragActive?(true)   // finger beats spring: the host cancels any in-flight settle
            suspendForeignPans()  // catch any lazily-created system pan before it can ride along
            dragStart = progress
            dragStartHeight = dragHeight
            dragStartExpand = expand
            panBaselineY = translation
            dragOwnsSheet = shouldSheetTakeDrag(velocity: velocity)
        case .changed:
            if dragSpentOnSearch { return }
            if !dragOwnsSheet {
                // The list is scrolling. Re-check on every event, because the moment it reaches its
                // top and the finger is still coming down, the sheet takes over mid-gesture — that
                // hand-off is the thing the SwiftUI version could not express.
                if shouldSheetTakeDrag(velocity: velocity) {
                    dragOwnsSheet = true
                    dragStart = progress
                    dragStartHeight = dragHeight
                    dragStartExpand = expand
                    g.setTranslation(.zero, in: self)
                    panBaselineY = 0
                }
                return
            }
            centerPanel?.pinScrollToTop()      // pin it while the sheet owns the movement
            // ⚠️ ONE HEIGHT, IN POINTS, ACROSS BOTH STOPS. This was `setProgress(dragStart - travel /
            // sheetHeight)`, which is only the hidden → half half of the journey and stalls dead at
            // the half stop. Writing the height instead lets one finger carry the sheet from closed,
            // through half, up to full without the gesture noticing there is a stop in the middle —
            // which is what theirs does with `viewListHeight`.
            dragHeight = dragStartHeight - (translation - panBaselineY)
        case .ended, .cancelled:
            // Balanced with `.began`. A gesture spent on the collapse never said a finger owns
            // progress, so it must not say one has let go either: it moved no sheet, there is no
            // settle for the host to cancel and nothing for its parked-sheet watchdog to hold.
            if dragSpentOnSearch {
                dragSpentOnSearch = false
                return
            }
            onDragActive?(false)
            guard dragOwnsSheet else { return }
            dragOwnsSheet = false
            // ⚠️ THE EXPAND ZONE HAS ITS OWN RELEASE RULE, AND IT IS NOT THE HOST'S.
            //
            // Theirs, for a release that happened above the half stop (`accumulatedOffset < 0`):
            //
            //     if verticalPanState.fraction <= -0.05 || velocity.y <= -80.0 {
            //         self.viewListDisplayState = .full
            //     } else {
            //         self.viewListDisplayState = .half
            //     }
            //
            // on a 0.4s spring. `fraction` is the drag as a share of the SCREEN height and negative is
            // upward, so it commits to full on a twentieth of the screen where the close asks for
            // three tenths. An expand is meant to be easy; a dismiss is not.
            if progress > 0.999, expand > 0.0001 || dragStartExpand > 0.0001 {
                let fraction = (translation - panBaselineY) / max(1, bounds.height)
                animateExpand(to: (fraction <= -0.05 || velocity <= -80) ? 1 : 0)
                return
            }
            // Dropped back below the half stop: the gesture is a collapse and the host owns that
            // decision, exactly as before. Anything left of the expansion goes home with it.
            if expand > 0.0001 { animateExpand(to: 0) }
            // ⚠️ `halfHeight`, NOT `sheetHeight`. The host's settle maths is written against the half
            // height (`StoryViewersSheetView.heightFraction`), so the velocity handed to it has to be
            // in those units. `sheetHeight` is bigger than that whenever the sheet is expanded, and
            // dividing by it would under-report the speed of exactly the drags that come down from
            // full — the ones most likely to be a deliberate close.
            onRelease?(progress, dragStart, -velocity / max(1, halfHeight))
        default:
            break
        }
    }

    /// The story-card / dark-area drag: the card and the sheet move as one connected surface, both
    /// directions, exactly as if the finger were on the panel.
    @objc private func handleOutsidePan(_ g: UIPanGestureRecognizer) {
        let ty = g.translation(in: self).y
        switch g.state {
        case .began:
            onDragActive?(true)
            suspendForeignPans()  // same lazily-created-pan guard as the sheet pan's
            outsideDragStart = progress
            outsideBaselineY = ty
        case .changed:
            setProgress(outsideDragStart - (ty - outsideBaselineY) / sheetHeight)
        case .ended, .cancelled:
            onDragActive?(false)
            onRelease?(progress, outsideDragStart, -g.velocity(in: self).y / sheetHeight)
        default: break
        }
    }

    /// Exists so the system dismiss pans have something to wait for over the carousel band. The
    /// SwiftUI carousel keeps the touches (`cancelsTouchesInView = false`).
    @objc private func handleBandGuard(_ g: UIPanGestureRecognizer) {}

    @objc private func handleTapAbove(_ g: UITapGestureRecognizer) {
        guard g.location(in: self).y < panelTop else { return }
        onCollapseTap?()
    }

    /// THE SIDEWAYS PAGE: TWO REAL PANELS, ONE NUMBER, NO PHOTOGRAPH.
    ///
    /// WHAT THIS USED TO DO AND WHY IT WAS WRONG. There was one panel, so showing two sheets at once
    /// meant `snapshotView`-ing the one being left behind and re-pointing the real panel at the
    /// neighbour's list mid-drag. Everything about that was a consequence of the panel not being a
    /// view you could have two of: the departing sheet was a picture (it could not scroll, could not
    /// answer a touch, and a fetch landing during the drag drew into the sheet under the finger
    /// rather than into the one it belonged to), and the arriving sheet was the same table being
    /// rewritten under the gesture. A cancelled drag then had to put the old story's list BACK into
    /// that one panel, which is why the teardown had two modes and why an interrupted settle could
    /// leave the wrong list on screen.
    ///
    /// WHAT IT DOES NOW, which is the reference app's `viewListPanGesture` and its layout pass:
    ///   · every story keeps its own real panel (`panels`, their `viewLists` keyed by story id);
    ///   · the drag writes ONE displacement in points, carried by every panel as a transform, so the
    ///     strip moves together and the neighbour follows the finger from the first millimetre;
    ///   · the release commits on their thresholds and REBASES — the arriving panel becomes slot 0
    ///     and the displacement is shifted by exactly one travel, so the picture does not move at
    ///     the instant the story id changes — then the strip springs home from wherever it is;
    ///   · nothing is created, destroyed or re-pointed during the gesture.
    ///
    /// Their commit is `fraction <= -0.3` / `>= 0.3`, or `0.05` with 200pt/s behind it, and ours are
    /// the same numbers on the same fraction. No neighbour that way → a quarter-strength rubber-band
    /// and a spring home, as before.
    @objc private func handlePagePan(_ g: UIPanGestureRecognizer) {
        let rawX = g.translation(in: self).x
        let w = max(bounds.width, 1)
        switch g.state {
        case .began:
            onDragActive?(true)
            suspendForeignPans()
            // A SETTLE STILL IN FLIGHT IS LANDED, NOT REVERSED. Theirs does exactly this — the
            // `.began` clears `isCompletingViewListPan` and starts from the current translation, so
            // the strip snaps to its resting layout and follows the new finger from there. It is
            // coherent because the id already changed at the previous release: the resting layout IS
            // the committed one. This is what the old `pageCommitted` flag was hand-rolling around
            // the snapshot, and it is why "fast fast" swiping used to land the wrong list.
            //
            // ⚠️ ONLY WHEN A PAGE IS ACTUALLY IN FLIGHT. Clearing the panels' animations
            // unconditionally would also kill an `animateExpand` in progress and snap the sheet's
            // height — the two motions are deliberately on different properties (transform vs
            // bounds/centre) so that neither has to cancel the other.
            if pageActive {
                for p in panels.values { p.layer.removeAllAnimations() }
            }
            pageCycle &+= 1
            pageActive = true
            pageOffset = 0
            applyPageOffset()
            // ⚠️ AND THE ROW IS TOLD, WHICH IT WAS NOT. Zeroing `pageOffset` here moves OUR panels
            // back to their slots but said nothing to the row, and the row subtracts this number
            // from its own position (`rowPosition`: `scroll·f + centralIndex·(1-f) - pageDrag`).
            //
            // So a page pan that begins and never reaches `.ended` or `.cancelled` — a gesture the
            // system takes over, a drag that turns into a scroll — left the LAST fraction standing
            // in the row for the rest of the sitting, with our own panels already back at zero. The
            // row is then permanently off by whatever the abandoned drag had reached, and because
            // nothing else writes it, it survives into the next tap and biases that too. That is
            // the owner's "when I swipe the sheet sideways the row misbehaves", and it is why it
            // then misbehaves on a tap he makes afterwards.
            //
            // Both numbers describe one thing, so they are written in one place.
            onPageDrag?(0)
            pageBaselineX = rawX
        case .changed:
            let tx = rawX - pageBaselineX
            // Under half a point is not a direction. Without this the first frame (which is ~0 by
            // construction, see pageBaselineX) would pick whichever side the sign of zero named.
            guard abs(tx) >= 0.5 else {
                pageOffset = 0
                applyPageOffset()
                onPageDrag?(0)
                return
            }
            let dir = tx < 0 ? 1 : -1          // finger left → the NEXT story arrives
            // The FLAG AND THE ID BOTH. The flag is the host's answer and the id is what a panel can
            // actually be built from; a side with no id has nothing real to slide in and must
            // rubber-band even if the flag says otherwise.
            let allowed = dir == 1 ? (hasNext && !nextId.isEmpty) : (hasPrev && !prevId.isEmpty)
            guard allowed else {
                pageOffset = tx * 0.25
                applyPageOffset()
                onPageDrag?(pageOffset / pageTravel)   // the rubber-band, same units as below
                return
            }
            // Clamped at one panel width, theirs: `fraction = max(-1, min(1, translation.x / width))`.
            // Clamped to the panel's own travel, which is what the fraction below is measured
            // against — clamping to `w` capped the row a hair short of a whole card.
            pageOffset = max(-pageTravel, min(pageTravel, tx))
            applyPageOffset()
            // ⚠️ A FRACTION OF THE PANEL'S OWN JOURNEY, AND IT MUST STAY ONE. Twice now I have
            // "corrected" this into a distance and both times it was wrong, so the reasoning is
            // written down here rather than in a commit nobody re-reads.
            //
            // The sheet commits exactly ONE story per full panel travel, and at that commit the row
            // snaps to exactly one card. So the row has to cross exactly one card over that same
            // full travel, or the snap is a jump. A fraction spent as card units does that by
            // construction: 1 screen of panel = 1.0 card.
            //
            // Measured on a 14 Pro, where fullDist is about 90pt: dividing this by fullDist (build
            // 493, mine) moves the row 0.01 of a card and it looks frozen; sending raw points and
            // dividing (my next attempt) moves it 4.4 cards and it overshoots by four to one. Only
            // the fraction lands where the commit lands.
            //
            // It does mean the row travels slower than a finger ON the row, where one card is 90pt.
            // That is not a bug: these two gestures are pacing different things. The row's own pan
            // paces CARDS; this one paces PANELS, and the row is following the panel.
            //
            // ⚠️ AND THE DIVISOR IS `pageTravel`, NOT `w`. The note above says it in as many words —
            // "the row has to cross exactly one card over that same full travel" — and the travel is
            // `bounds.width + 20`, because of the gap left between two lists. Divided by `w` the row
            // reached a whole card while the panel still had 20pt to go, so through every drag the
            // two were about 4.7% out of step and only agreed at the ends. One number, both readers.
            onPageDrag?(pageOffset / pageTravel)
        case .ended, .cancelled:
            onDragActive?(false)
            let tx = rawX - pageBaselineX
            let vx = g.velocity(in: self).x
            let dir = tx < 0 ? 1 : -1
            let allowed = dir == 1 ? (hasNext && !nextId.isEmpty) : (hasPrev && !prevId.isEmpty)
            let commit = g.state == .ended && allowed && abs(tx) >= 0.5
                && (abs(tx) > w * 0.30 || (abs(tx) > w * 0.05 && abs(vx) > 200))
            let cycle = pageCycle
            if commit {
                // THE REBASE, WHICH IS THE WHOLE OF THE COMMIT. The arriving panel is at
                // `slot * travel + pageOffset`; shifting every slot by -dir and the displacement by
                // +dir * travel leaves every panel exactly where it already is on screen while
                // making the arriving one slot 0. Theirs is the same move on fractions:
                //
                //     if case .previous = direction { fraction = 1.0 + fraction }
                //     else { fraction = fraction - 1.0 }
                //
                // In points rather than fractions because our panels are one travel apart (a width
                // PLUS the 20pt gap), and rebasing by a bare width would leave a 20pt jump.
                for p in panels.values { p.slot -= CGFloat(dir) }
                pageOffset += CGFloat(dir) * pageTravel
                // What the sheet knows about the new order until the host confirms it: the story we
                // came from is now the neighbour behind us, and the far side is unknown until the
                // host's next pass (which arrives on the same runloop turn — `onPage` writes the
                // host's state directly).
                let arriving = dir == 1 ? nextId : prevId
                if dir == 1 { prevId = centerId; nextId = "" } else { nextId = centerId; prevId = "" }
                centerId = arriving
                setNeedsLayout()
                layoutIfNeeded()               // slots are frames; land them before the spring
                applyPageOffset()              // and hold the picture still across the rebase
                // THE ID FLIPS NOW, not when the animation lands. The host zeroes the row's drag in
                // the same transaction, so the carousel glides its remaining distance while these
                // panels finish theirs — one motion. Nothing reloads: the arriving panel has had
                // this story's viewers in it since the sheet learned it was a neighbour.
                onPage?(dir)
                // `.allowUserInteraction`, OR THE INTERRUPTION PATH ABOVE CAN NEVER RUN. Without
                // it, UIKit turns off touch delivery to the animating panels for the length of the
                // settle — so a finger arriving inside the 0.28s (his 2026-08-09 "swipe back does
                // not work until the first swipe completes") was dropped before the pan ever heard
                // it. The flag is what every interruptible-gesture settle carries.
                //
                // ⚠️ AND THE CURVE IS THE ROW'S OWN, NOT A FOURTH ONE. This was 0.28 ease-out while
                // the cards it belongs to settled over a 0.3s spring, and the abandon below was a
                // third number again — so the viewers list and the row arrived at different times on
                // different curves for one gesture. Theirs runs both off ONE transition; both read
                // `StoryRowSettle` now, which is where their 0.3 and 0.4 live.
                UIView.animate(withDuration: StoryRowSettle.commit.duration, delay: 0,
                               usingSpringWithDamping: StoryRowSettle.commit.damping,
                               initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) {
                    self.pageOffset = 0
                    self.applyPageOffset()
                } completion: { [weak self] _ in
                    self?.endPageCycle(cycle)
                }
            } else {
                onPageDrag?(0)
                // Their abandon is deliberately SLOWER than their commit — 0.4s against 0.3s — so a
                // drag that undoes itself does not read as decisive as one that meant something.
                // Ours was 0.3 at a different damping, i.e. neither their number nor our own commit's.
                UIView.animate(withDuration: StoryRowSettle.abandon.duration, delay: 0,
                               usingSpringWithDamping: StoryRowSettle.abandon.damping,
                               initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) {   // same rule as the commit settle
                    self.pageOffset = 0
                    self.applyPageOffset()
                } completion: { [weak self] _ in
                    self?.endPageCycle(cycle)
                }
            }
        default: break
        }
    }

    /// The strip's displacement, on every panel. A transform rather than a frame so it composes with
    /// the sheet's height rather than fighting it — see `layoutPanel`.
    private func applyPageOffset() {
        let t: CGAffineTransform = pageOffset == 0
            ? .identity
            : CGAffineTransform(translationX: pageOffset, y: 0)
        for p in panels.values where p.transform != t { p.transform = t }
    }

    /// The settle landed (or was abandoned by a finger that started a new one). Only the cycle that
    /// is still current may release the fence and clear away the panels the page left behind.
    private func endPageCycle(_ cycle: Int) {
        guard cycle == pageCycle else { return }
        pageActive = false
        dropStalePanels()
    }

    /// Gates for all four recognizers. IN THE CLASS BODY WITH `override`, not in the delegate
    /// extension: `UIView` already declares `gestureRecognizerShouldBegin(_:)` itself, so putting it
    /// in an extension is an override — and Swift does not allow overriding in an extension. The
    /// same method also serves as the DELEGATE gate for the two window pans (same selector).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan {
            // The sheet's own pan starts only in the panel; vertical drags only.
            guard pan.location(in: self).y >= panelTop else { return false }
            let v = pan.velocity(in: self)
            return abs(v.y) >= abs(v.x)
        }
        if gestureRecognizer === outsidePan {
            // Only while mounted with the sheet actually up, and only above the panel — the panel
            // belongs to `pan`.
            guard window != nil, progress > 0.02 else { return false }
            // ⚠️ NO DIRECTION TEST HERE ANY MORE, AND ITS ABSENCE IS THE POINT. This used to compare
            // `|vy|` against `|vx|` inside the carousel band, which is an arbitration made from one
            // velocity sample at the moment UIKit happened to ask. The recogniser itself decides now,
            // from accumulated translation, and it has already failed on 2pt of dominant horizontal
            // travel by the time this is called — so a row swipe can no longer reach here at all,
            // anywhere on the screen, rather than only inside a rectangle we had to keep in step.
            return outsidePan.location(in: self).y < panelTop
        }
        if gestureRecognizer === bandGuard {
            guard window != nil, progress > 0.95 else { return false }
            return carouselBand.contains(bandGuard.location(in: self))
        }
        if gestureRecognizer === tapAbove {
            return tapAbove.location(in: self).y < panelTop
        }
        if gestureRecognizer === pagePan {
            // ⚠️ THE .half STATE AND NOTHING ELSE, WHICH IS THEIR RULE AND NOT AN APPROXIMATION OF IT.
            // Their allowed-directions closure opens with exactly this and returns nothing at all
            // otherwise:
            //
            //     if self.viewListDisplayState != .half { return [] }
            //
            // Their three states are hidden, half and full. `progress > 0.95` is "not hidden"; the
            // line below is "not full", and it was missing — so a sheet dragged up to full, or grown
            // by focusing search, still paged sideways. Theirs cannot: a tall list is a list you are
            // reading, and a horizontal drag inside it belongs to nothing.
            guard progress > 0.95, expand <= 0.0001 else { return false }
            // ⚠️ EVERYWHERE EXCEPT THE THUMBNAIL ROW, WHICH IS THEIR RULE VERBATIM. Theirs allows
            // left/right when the point is inside the screen and NOT inside the items container:
            //
            //     if self.bounds.contains(point), !self.itemsContainerView.frame.contains(point) {
            //         return [.left, .right]
            //     }
            //
            // Ours was gated to the panel alone, so a sideways swipe on the dark area beside the
            // shrunken story did nothing at all — and worse, it was a horizontal drag that none of
            // our recognisers claimed, which is precisely the kind of drag Apple's interactive
            // dismiss is free to pick up. The row keeps its own band because the row's scroller is
            // the thing that owns it, exactly as their items container owns theirs.
            return !carouselBand.contains(pagePan.location(in: self))
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// The one question the list hand-off turns on.
    private func shouldSheetTakeDrag(velocity: CGFloat) -> Bool {
        if progress < 0.999 { return true }               // not fully open → the sheet is the thing moving
        // The list on screen — a neighbour's scroll position is nothing to do with this drag.
        if (centerPanel?.scrollOffsetY ?? 0) > 0.5 { return false }   // let it scroll
        if velocity > 0 { return true }                   // at the top and pulling down → collapse
        // ⚠️ AT THE TOP AND PUSHING UP: THE SHEET GROWS UNTIL IT IS FULL, and only then does the list
        // scroll. This line is the half → full gesture.
        //
        // Theirs is the same rule, written from the other side: while the list is in `.half` an
        // upward drag is accumulated into the sheet's height rather than into the scroll view —
        //
        //     if self.viewListDisplayState == .half && verticalPanState.didLockScrolling {
        //         verticalPanState.accumulatedOffset += -overflowY
        //
        // — and `didLockScrolling` is set the moment the scroll view is at its top. So the list is
        // only scrollable once there is no more sheet to open.
        return expand < 0.999
    }

    // MARK: Sheet height stops

    private func setSearchExpanded(_ on: Bool) {
        // The reference app's 0.5s spring for the search jump specifically; a drag-driven expand uses
        // their 0.4s, which is the number on that transition in their source.
        animateExpand(to: on ? 1 : 0, duration: 0.5, damping: 0.85)
    }

    /// Take the sheet to a stop, half (0) or full (1), on a spring.
    ///
    /// `expand` is a plain stored property and nothing animates it directly. What animates is the
    /// LAYOUT it produces: setting it inside the block and laying out there is the shape the search
    /// expansion has always used, and the frames that change are what carry the curve.
    /// `.allowUserInteraction` for the same reason every settle in this file has it — a finger has to
    /// be able to interrupt one.
    private func animateExpand(to target: CGFloat, duration: Double = 0.4, damping: CGFloat = 0.85) {
        guard abs(expand - target) > 0.0001 else { return }
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: damping,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.expand = target
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

}

/// Axis-locked pan for the sheet's window-level gestures. Judges the CUMULATIVE movement since
/// touch-down and fails fast on the wrong axis, so a horizontal cover-flow swipe never loses its
/// first frames to a vertical recognizer and vice versa. (The reference app's own directional gesture
/// recognizer decides the same way: 2:1 dominance wins immediately, a distance deadline settles
/// ambiguous diagonals.)
/// AXIS-LOCKED PAN, USING THE REFERENCE APP'S OWN VALIDATION RULE.
///
/// ⚠️ THIS CLASS DECIDES WHICH GESTURE OWNS A TOUCH, AND THE OLD RULE WAS THE REASON A SWIPE ON THE
/// THUMBNAILS SOMETIMES MOVED THE SHEET INSTEAD OF THE ROW.
///
/// What it used to do: wait for 8pt of travel and then compare the two axes at a 1.2 ratio. What the
/// sheet's own outside pan did was worse — it was a plain `UIPanGestureRecognizer` and arbitrated in
/// `shouldBegin` on INSTANTANEOUS VELOCITY at the ~10pt mark. Velocity is a sample, not a summary: a
/// thumb that has already travelled 20pt sideways but happens to be drifting down at the instant the
/// recogniser asks reports `|vy| >= |vx|`, so the sheet took the whole gesture and cancelled the
/// row's touches under it.
///
/// Their rule, read from `InteractiveTransitionGestureRecognizer.touchesMoved` and reproduced here
/// exactly, arbitrates on ACCUMULATED TRANSLATION and decides far earlier:
///
///   · past 10pt of total travel, the larger axis simply wins (`>=`, so a perfect diagonal is
///     resolved rather than left hanging);
///   · below that, 2pt on the wrong axis with double the dominance FAILS the recogniser outright;
///   · below that, 2pt on the right axis with double the dominance VALIDATES it.
///
/// So a horizontal swipe kills the vertical recogniser after two points of movement — long before
/// either could have begun — and the row never has a competitor to lose to.
///
/// ⚠️ AND TOUCHES ARE WITHHELD FROM `super` UNTIL VALIDATION, WHICH IS THEIRS TOO. A pan that starts
/// accumulating translation before it knows it owns the gesture begins with a jump of however far
/// the finger travelled while it was deciding. Withheld, the translation starts at the moment of
/// validation, which is why `.began` can be forced at 2pt without the content leaping.
final class DirectionalSheetPan: UIPanGestureRecognizer {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    private var startPoint: CGPoint?
    /// The gesture has been proven to be on our axis. Until then nothing reaches `super`.
    private var validated = false

    init(axis: Axis, target: AnyObject, action: Selector) {
        self.axis = axis
        super.init(target: target, action: action)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        startPoint = touches.first?.location(in: view)
    }

    override func reset() {
        super.reset()
        startPoint = nil
        validated = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        var fireBegan = false
        if !validated, let touch = touches.first {
            let loc = touch.location(in: view)
            let start = startPoint ?? loc
            // ON our axis and ACROSS it, named for the axis rather than for x and y, so the two
            // branches below are one piece of arithmetic instead of two mirrored copies.
            let along = axis == .vertical ? abs(loc.y - start.y) : abs(loc.x - start.x)
            let across = axis == .vertical ? abs(loc.x - start.x) : abs(loc.y - start.y)
            let total = sqrt(along * along + across * across)
            if total > 10 {
                // Force the dominant direction after 10pt. `>=` on OUR axis, matching theirs.
                if along >= across { validated = true; fireBegan = true } else { state = .failed; return }
            } else if across > 2, across > along * 2 {
                state = .failed
                return
            } else if along > 2, across * 2 < along {
                validated = true
                fireBegan = true
            }
        }
        guard validated else { return }
        super.touchesMoved(touches, with: event)
        if fireBegan, state == .possible { state = .began }
    }
}

// MARK: - Simultaneous recognition

extension StoryViewersSheetView: UIGestureRecognizerDelegate {
    /// THE ONE LINE THE SWIFTUI VERSION COULD NOT WRITE. The sheet's pan and the table's pan run
    /// together, and `handlePan` decides which of them the movement belongs to on each event. Without
    /// this the two recognisers cancel one another and you get the dead drag the arbiter existed to
    /// paper over. (The window pans are location-partitioned from `pan` in shouldBegin, so "always
    /// yes" cannot put two of OUR writers on one touch.)
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

}

// MARK: - Row contents

/// One viewer, exactly as the SwiftUI sheet drew it. Extracted so the UIKit cell and any future
/// caller render the same row rather than two that look alike today.
struct StoryViewerRowContent: View {
    let viewer: StoryViewerInfo
    var onSendMessage: () -> Void
    /// Open this person's profile. The whole row is the target — his ask: "if I click profile, user
    /// or name or other area, one tap shows that person's profile".
    var onOpenProfile: () -> Void = {}
    /// "Hide my stories from X", and the way back. The label flips, so one row is both states and
    /// there is never a menu offering to hide somebody who is already hidden.
    var onToggleHidden: () -> Void = {}
    var onBlock: () -> Void = {}
    var isHidden: Bool = false

    private var doubleCheck: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark"); Image(systemName: "checkmark").offset(x: 4)
        }
        .font(.system(size: 9, weight: .bold))
    }

    private func dateFmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yy 'at' h:mm a"; return f.string(from: d)
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: viewer.name, photoUrl: viewer.photoUrl, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    // HIS REFERENCE DESIGN (2026-08-05 image): a soft rose disc riding the
                    // avatar's bottom-right corner with a WHITE heart glyph — bigger than the old
                    // 19pt emoji-in-red-ring, no border, just a soft shadow lifting it off the
                    // photo. A liked story draws the heart; any other reaction emoji sits on the
                    // same disc so the row reads as one design.
                    if let r = viewer.reaction, !r.isEmpty {
                        ZStack {
                            Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.47))
                            if r == "❤️" {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text(r).font(.system(size: 11))
                            }
                        }
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: 5, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewer.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 5) { doubleCheck; Text(dateFmt(viewer.viewedAt)) }
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Menu {
                rowActions
            } label: {
                Image(systemName: "ellipsis").font(.body).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }
        }
        // ONE TAP ANYWHERE ON THE ROW OPENS THE PROFILE, and the contentShape is what makes the gaps
        // count: without it the empty space between the name and the "…" is not part of the row and
        // a tap there does nothing.
        .contentShape(Rectangle())
        .onTapGesture { onOpenProfile() }
        // The same three actions on a long press as behind the "…", because people reach for both
        // and finding one of them empty is the kind of difference that reads as broken.
        .contextMenu { rowActions }
    }

    /// The one definition of what you can do to a viewer, used by the "…" menu and the long press.
    @ViewBuilder private var rowActions: some View {
        Button(action: onSendMessage) { Label("Send message", systemImage: "message") }
        Button(action: onToggleHidden) {
            // The label carries the state, so the menu never offers to hide somebody already hidden.
            Label(isHidden ? "Don't hide my stories from \(viewer.name)"
                           : "Hide my stories from \(viewer.name)",
                  systemImage: isHidden ? "eye" : "eye.slash")
        }
        // Destructive and last, where iOS puts the action you least want to hit by accident.
        Button(role: .destructive, action: onBlock) {
            Label("Block \(viewer.name)", systemImage: "hand.raised")
        }
    }
}

// MARK: - SwiftUI bridge

/// Hosts `StoryViewersSheetView` and keeps it in step with the host's `progress`.
///
/// The binding is TWO-WAY on purpose and that is the whole point of it: the finger writes progress
/// from inside UIKit, and the host's own opens and closes (the swipe-up on the story, the settle
/// spring, the parked-sheet self-heal) write it from outside. One number, either direction, and
/// the live story's morph reads the same one — so the sheet and the card behind it cannot disagree
/// about how far open the sheet is.
struct StoryViewersSheet: UIViewRepresentable {
    let activeStoryId: String
    /// A story's audience, in words, and whether it earns a second tab — BY ID, not just for the one
    /// on screen. The sheet holds a real panel per story now and each of them wears its own
    /// audience, so the neighbour arrives with the right tabs already on it instead of inheriting
    /// the tabs of the story you were reading. See `storyAudienceTitle` in StoriesViews.
    var audienceFor: (String) -> (title: String, bothTabs: Bool) = { _ in ("All Viewers", true) }
    @Binding var progress: CGFloat
    var carouselBand: CGRect = .zero
    var hasPrev: Bool = false
    var hasNext: Bool = false
    /// The stories either side of `activeStoryId`. The sheet needs the IDS, not just whether they
    /// exist, because each of them is a real panel it builds and fills in advance — see
    /// `Coordinator.sync`. Empty string = no neighbour that way.
    var prevStoryId: String = ""
    var nextStoryId: String = ""
    var onClose: () -> Void
    var onCollapseTap: () -> Void = {}
    var onRelease: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }
    var onDragActive: (Bool) -> Void = { _ in }
    var onPage: (Int) -> Void = { _ in }
    var onPageDrag: (CGFloat) -> Void = { _ in }
    /// Tap a viewer row → show that person's profile. The host owns the presentation.
    var onOpenProfile: (StoryViewerInfo) -> Void = { _ in }

    func makeUIView(context: Context) -> StoryViewersSheetView {
        let v = StoryViewersSheetView()
        v.onProgress = { p in
            // `applying` guards the loop: without it, writing the binding here would come straight
            // back through updateUIView and fight the finger.
            context.coordinator.applying = true
            progress = p
            context.coordinator.applying = false
        }
        v.onClose = onClose
        v.onCollapseTap = onCollapseTap
        v.onRelease = onRelease
        v.onDragActive = onDragActive
        v.onPage = onPage
        v.onPageDrag = onPageDrag
        v.carouselBand = carouselBand
        v.hasPrev = hasPrev
        v.hasNext = hasNext
        v.onSendMessage = { viewer in
            AppRouter.shared.pendingChatName = viewer.name
            AppRouter.shared.pendingChatPhoto = viewer.photoUrl
            AppRouter.shared.pendingChatId = ChatService.convId(AuthService.shared.uid ?? "", viewer.id)
            onClose()
            NotificationCenter.default.post(name: .init("storyForceClose"), object: nil)
        }
        // Tap a row → that person's profile. Handed to the host rather than routed from here: the
        // host already presents exactly this sheet for the story header, and two presentations of
        // one screen would be two things to keep in step.
        v.onOpenProfile = { viewer in onOpenProfile(viewer) }
        // Block: writes the conversation AND revokes my live stories from them, which
        // `ChatService.setBlocked` already does — the audience is frozen at post time, so without
        // that reach-back a blocked person keeps watching for up to 24 hours.
        v.onBlock = { viewer in
            let cid = ChatService.convId(AuthService.shared.uid ?? "", viewer.id)
            Task { await ChatService.setBlocked(cid, true) }
        }
        context.coordinator.view = v
        context.coordinator.audienceFor = audienceFor
        context.coordinator.sync(active: activeStoryId, prev: prevStoryId, next: nextStoryId)
        return v
    }

    func updateUIView(_ v: StoryViewersSheetView, context: Context) {
        if !context.coordinator.applying { v.setProgress(progress) }
        v.carouselBand = carouselBand
        v.hasPrev = hasPrev
        v.hasNext = hasNext
        // The closure is rebuilt on every render and closes over this pass's story array, so it is
        // replaced rather than kept — a stale one would answer for stories that have since moved.
        context.coordinator.audienceFor = audienceFor
        context.coordinator.sync(active: activeStoryId, prev: prevStoryId, next: nextStoryId)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// KEEPS THE THREE PANELS POINTED AT THE RIGHT THREE STORIES AND FED.
    ///
    /// There is no "preview" any more and no notion of the panel being borrowed. Each story has its
    /// own panel and its own fetch; this only decides which three stories are up and pushes each
    /// one's people into its own panel whenever they arrive. That is the reference app's shape too:
    /// it preloads the current item's list and both neighbours' (`preloadViewListIds`) so a sideways
    /// swipe never brings in a spinner.
    final class Coordinator {
        weak var view: StoryViewersSheetView?
        var applying = false
        var audienceFor: (String) -> (title: String, bothTabs: Bool) = { _ in ("All Viewers", true) }
        private var activeId = ""
        private var prevId = ""
        private var nextId = ""
        /// Viewers by story id. Small (a story's whole audience) and short-lived (this sheet), and it
        /// is what lets a panel that has never been on screen arrive with its people already in it.
        private var cache: [String: [StoryViewerInfo]] = [:]
        /// One fetch per story at a time. Scrubbing the carousel walks `activeId` across every card,
        /// and without this each pass would start the same three reads again.
        private var tasks: [String: Task<Void, Never>] = [:]

        func sync(active: String, prev: String, next: String) {
            let moved = active != activeId || prev != prevId || next != nextId
            activeId = active; prevId = prev; nextId = next
            if moved { view?.setStories(center: active, prev: prev, next: next) }
            // Audience every pass, not only on a move: a story's own audience can be re-read by the
            // host (it comes from the live repository) without the neighbours changing.
            for id in [active, prev, next] where !id.isEmpty {
                let a = audienceFor(id)
                view?.setAudience(title: a.title, bothTabs: a.bothTabs, for: id)
            }
            guard moved else { return }
            for id in [active, prev, next] where !id.isEmpty { fill(id) }
        }

        /// Put a story's people in that story's own panel, fetching them once if they are not held.
        private func fill(_ id: String) {
            if let hit = cache[id] {
                view?.setViewers(hit, for: id)
                view?.setLoading(false, for: id)
                return
            }
            guard tasks[id] == nil else { return }
            view?.setLoading(true, for: id)
            tasks[id] = Task { [weak self] in
                let people = await StoriesService.shared.fetchViewers(storyId: id)
                await MainActor.run {
                    guard let self else { return }
                    self.tasks[id] = nil
                    self.cache[id] = people
                    self.view?.setViewers(people, for: id)
                    self.view?.setLoading(false, for: id)
                }
            }
        }
    }
}
