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
// TOUCH ROUTING (the 2026-08-05 rebuild — Telegram's model, read from their source):
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
//      the sheet exactly like Telegram's; only the band's horizontal drags are refused, so the
//      cover-flow keeps them).
//
// WHY THE WINDOW PANS EXIST AT ALL: Apple's zoom transition installs its own interactive-dismiss pan
// up the presentation chain, and it sees every touch in the cover no matter who hit-tests it. That
// pan tracking a sheet drag is why dragging the sheet down used to close the WHOLE story viewer.
// `require(toFail:)` on it was tried and DID NOT HOLD on the device (build 466) — so while the
// sheet is in a window the foreign pans up the chain are DISABLED outright and restored on unmount:
// see `suspendForeignPans`. Telegram does the same thing by policy: their outer gestures are
// refused entirely while the view list is open (`allowsInteractiveGestures() == false` in
// StoryItemSetContainerComponent).
//
// RELEASE: no internal animator any more. Every finger-up reports (progress, where the drag started,
// velocity) to the host, which owns the ONE spring that settles sheet + story morph + carousel on the
// same per-frame value. The old `UIViewPropertyAnimator` settle animated the panel beautifully and
// reported progress ONCE — the story snapped to its end state while the sheet glided, which is
// exactly the disconnection the owner reported.
//
// WHAT IS STILL SWIFTUI, DELIBERATELY: the row's contents, through `UIHostingConfiguration`.
// The search field's keyboard and clear button. Return = keyboard down, query and tall sheet stay
// (Telegram). The X is HIS exit: "when i click x button go back to small sheet" — and it is the
// only path that collapses, so backspacing a query to nothing never yanks the keyboard mid-thought
// (`textFieldShouldClear` fires for the clear BUTTON alone, never for typing).
extension StoryViewersSheetView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        textField.text = ""
        applyFilter()
        textField.resignFirstResponder()
        setSearchExpanded(false)
        return false   // the clearing is done above; returning true would double-clear
    }
}

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
    /// + = opening). The host decides open/close (Telegram's thresholds) and runs the one spring.
    var onRelease: ((CGFloat, CGFloat, CGFloat) -> Void)?
    /// A finger owns progress right now (any of our pans is live). The host cancels its spring on
    /// true and holds its parked-sheet watchdog while it is true.
    var onDragActive: ((Bool) -> Void)?
    /// Tap on the dark area above the panel → collapse (NOT dismiss the viewer).
    var onCollapseTap: (() -> Void)?
    /// Swipe the sheet sideways → the NEIGHBOUR story's sheet (+1 next, -1 previous), Telegram's
    /// viewListPanGesture: their sheet at .half slides horizontally into the next item's own list.
    /// The host switches `sheetStoryId`; everything else (list reload, carousel recentre, the
    /// frozen story jumping underneath) already follows that one value.
    var onPage: ((Int) -> Void)?
    /// Put the neighbour's list in the panel WITHOUT committing to it: +1 next, -1 previous, 0 back
    /// to the story we are still on. Fired the instant a page drag picks a side, so what slides in
    /// under the finger is the neighbour's real sheet rather than a stand-in. See `beginPagePreview`.
    var onPagePreview: ((Int) -> Void)?
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

    var viewers: [StoryViewerInfo] = [] {
        didSet { applyFilter() }
    }
    var isLoading = false {
        didSet { loadingView.isHidden = !isLoading; updateEmptyState() }
    }

    // MARK: Views

    private let grabber = UIView()
    private let allTab = UIButton(type: .system)
    private let friendsTab = UIButton(type: .system)

    /// WHAT THIS STORY'S AUDIENCE WAS, AND WHETHER A SECOND TAB SAYS ANYTHING.
    ///
    /// His 2026-08-08 rule, in his words: Everyone shows Everyone plus Friends; My Friends shows only
    /// the friends tab; a custom list shows only that list's name; View Once shows only View Once.
    /// So the row never disappears — it always names the audience — and it only ever offers a CHOICE
    /// for a story that went to Everyone, because that is the only audience whose viewers can be a
    /// mix of friends and strangers. The words come from `storyAudienceTitle`, the same function the
    /// pill on the story itself reads.
    var audience: (title: String, bothTabs: Bool) = ("All Viewers", true) {
        didSet {
            // Field by field rather than as a tuple: `updateUIView` writes this on every pass, so
            // the no-change case has to be cheap and certain, and tuple `!=` on a LABELLED tuple is
            // the kind of thing that resolves differently than it reads.
            guard audience.title != oldValue.title || audience.bothTabs != oldValue.bothTabs
            else { return }
            applyAudienceTabs()
        }
    }

    /// THE FIRST TAB IS ALWAYS THE AUDIENCE'S OWN NAME, which makes the whole rule one sentence: the
    /// first tab names who this story went to, and the second exists only when that was Everyone.
    /// It used to read "All Viewers" in every case, which said nothing about the story. His words for
    /// the Everyone case were "show Everyone + Friends", so that is what it says.
    private var allTabTitle: String { audience.title }

    private func applyAudienceTabs() {
        // A HIDDEN FRIENDS TAB MUST NOT LEAVE ITS FILTER ON. Paging the sheet from an Everyone story
        // you were reading on Friends across to a My Friends story would otherwise show that story's
        // list still narrowed, under a tab that is no longer on screen to say so.
        if !audience.bothTabs, tab != 0 {
            tab = 0
            applyFilter()
        }
        friendsTab.isHidden = !audience.bothTabs
        // Nothing to switch to, so it stops behaving like a button: no highlight, no touch feedback
        // on a tap that cannot change anything. It is a label with an underline at that point.
        allTab.isUserInteractionEnabled = audience.bothTabs
        configureTab(allTab, allTabTitle, selected: tab == 0)
        configureTab(friendsTab, "Friends", selected: tab == 1)
        setNeedsLayout()
    }
    private let underline = UIView()
    private let search = UISearchTextField()
    private let table = UITableView(frame: .zero, style: .plain)
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let emptyLabel = UILabel()

    private var filtered: [StoryViewerInfo] = []
    private var tab = 0
    /// The uids of my 1:1 chats, for the Friends tab. Read once per filter rather than per row.
    private var friendUids: Set<String> = []

    // MARK: Gestures

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tapAbove = UITapGestureRecognizer(target: self, action: #selector(handleTapAbove(_:)))
    /// The drag on the story card / dark area, attached to the WINDOW so it also sees the carousel
    /// band (which hit-tests through to SwiftUI). NOT direction-locked: every drag above the panel
    /// must be OURS (a horizontal one just moves nothing), because any drag we fail is a drag
    /// Apple's interactive dismiss is free to take — the whole-viewer-closes bug through a side
    /// door. The one exception is horizontal drags in the carousel band, refused in shouldBegin so
    /// the cover-flow keeps them (bandGuard blocks the system pans there instead).
    private lazy var outsidePan = UIPanGestureRecognizer(target: self, action: #selector(handleOutsidePan(_:)))
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
    private var outsideDragStart: CGFloat = 0
    private var outsideBaselineY: CGFloat = 0
    /// True once a drag has decided the SHEET owns it rather than the list.
    private var dragOwnsSheet = false
    /// TRUE FOR THE REST OF A GESTURE THAT WAS SPENT COLLAPSING THE SEARCH. One touch does one
    /// thing: the drag that steps the sheet back from full to half is finished the moment it has
    /// done that, and cannot go on to take the sheet and dismiss it. See `handlePan`.
    private var dragSpentOnSearch = false

    /// SEARCH GROWS THE SHEET TO (almost) THE WHOLE SCREEN — Telegram's rule, read from their
    /// source on his order (2026-08-09: "there is not enough space when the keyboard appears…
    /// first go read telegram"). Their viewers panel has two resting states, half and full, and
    /// focusing search jumps it to full = screen height minus 60 on a 0.5s spring; leaving search
    /// steps it back to half. Ours maps their "half" to the resting `heightFraction` sheet and their "full"
    /// to this flag — same layout path, one number changes, so every child lays out through the
    /// code that already positions it.
    private var searchExpanded = false

    private var sheetHeight: CGFloat {
        searchExpanded ? bounds.height - max(60, safeAreaInsets.top + 8)
                       : bounds.height * Self.heightFraction
    }
    private var panelTop: CGFloat { bounds.height - sheetHeight * progress }

    // MARK: Init

    /// The horizontal sheet-to-sheet pan (see `onPage`). On SELF like the vertical pan; the two are
    /// axis-partitioned — the vertical pan's shouldBegin demands |vy| ≥ |vx| and this one is
    /// direction-locked horizontal, so exactly one of them takes any given drag.
    private lazy var pagePan = DirectionalSheetPan(axis: .horizontal, target: self, action: #selector(handlePagePan(_:)))
    private var pageBaselineX: CGFloat = 0
    /// A frozen picture of the sheet being left behind, live only while a page drag is.
    ///
    /// THE REAL PANEL BECOMES THE ARRIVING ONE. Snapshotting the sheet we are leaving, rather than
    /// building a second panel, is what makes that possible: there is one table and one set of
    /// chrome, so the thing sliding in under the finger is genuinely the neighbour's sheet with the
    /// neighbour's viewers in it. A second panel would have been a drawing of a sheet.
    private var pageGhost: UIView?
    /// Which way the live page drag is going: 1 = the next story is arriving, -1 = the previous one,
    /// 0 = no preview installed.
    private var pageDir = 0
    /// TRUE while a committed page is still settling. Read by the next `.began`, so an interrupting
    /// swipe lands the previous one the way it was already going to land instead of reversing it.
    private var pageCommitted = false
    /// How far past the edge a departing panel is parked, so its shadow and corners clear the screen.
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
        buildHierarchy()
        pan.delegate = self
        addGestureRecognizer(pan)
        tapAbove.delegate = self
        addGestureRecognizer(tapAbove)
        pagePan.delegate = self
        addGestureRecognizer(pagePan)
        // Selector-based observers, so they are dropped with this view and there is no token to
        // keep. See `keyboardWillChange` for what they are for.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
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
    /// natural collapse gesture there is (it is how Telegram closes theirs).
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

    private func buildHierarchy() {
        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.10, alpha: 1)
        panel.layer.cornerRadius = 24
        panel.layer.cornerCurve = .continuous
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        panel.tag = 1
        addSubview(panel)

        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        grabber.layer.cornerRadius = 2.5
        panel.addSubview(grabber)

        // Placeholder titles only: `audience` is set by the representable the moment this view is
        // built and `applyAudienceTabs` writes the real ones.
        configureTab(allTab, allTabTitle, selected: true)
        configureTab(friendsTab, "Friends", selected: false)
        allTab.addTarget(self, action: #selector(pickAll), for: .touchUpInside)
        friendsTab.addTarget(self, action: #selector(pickFriends), for: .touchUpInside)
        underline.backgroundColor = .white
        underline.layer.cornerRadius = 1
        panel.addSubview(allTab); panel.addSubview(friendsTab); panel.addSubview(underline)

        search.placeholder = "Search"
        search.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        search.textColor = .white
        search.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        // The keyboard says SEARCH (his ask — the default return key said nothing useful), and
        // return only lowers the keyboard: the query and the expanded sheet stay, Telegram's shape.
        search.returnKeyType = .search
        search.delegate = self
        // Focus grows the sheet, leaving with an empty query shrinks it — see `searchExpanded`.
        search.addTarget(self, action: #selector(searchBegan), for: .editingDidBegin)
        search.addTarget(self, action: #selector(searchEnded), for: .editingDidEnd)
        panel.addSubview(search)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 64
        table.contentInsetAdjustmentBehavior = .never
        // The bounce is what fought the collapse drag in the SwiftUI version and had to be switched
        // off there. It can stay on here: `handlePan` only takes the movement when the list is
        // genuinely at its top, so the two never claim the same pixels.
        table.alwaysBounceVertical = true
        table.register(UITableViewCell.self, forCellReuseIdentifier: "viewer")
        panel.addSubview(table)

        loadingView.color = .white
        loadingView.hidesWhenStopped = false
        loadingView.startAnimating()
        loadingView.isHidden = true
        panel.addSubview(loadingView)

        emptyLabel.text = "No views yet"
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        panel.addSubview(emptyLabel)
    }

    private func configureTab(_ b: UIButton, _ title: String, selected: Bool) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
        b.setTitleColor(selected ? .white : UIColor.white.withAlphaComponent(0.5), for: .normal)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let panel = viewWithTag(1) else { return }
        let h = sheetHeight
        // Setting `frame` on a transformed view is undefined — while the page-slide has the panel
        // translated, its identity geometry is already correct, so leave it alone.
        if panel.transform == .identity {
            panel.frame = CGRect(x: 0, y: bounds.height - h * progress, width: bounds.width, height: h)
        }
        grabber.frame = CGRect(x: (bounds.width - 38) / 2, y: 8, width: 38, height: 5)

        let tabY: CGFloat = 25
        allTab.sizeToFit()
        friendsTab.sizeToFit()
        allTab.frame = CGRect(x: 18, y: tabY, width: allTab.bounds.width, height: 26)
        friendsTab.frame = CGRect(x: allTab.frame.maxX + 24, y: tabY, width: friendsTab.bounds.width, height: 26)
        let active = tab == 0 ? allTab : friendsTab
        underline.frame = CGRect(x: active.frame.minX, y: allTab.frame.maxY + 4,
                                 width: active.bounds.width, height: 2)

        search.frame = CGRect(x: 16, y: underline.frame.maxY + 12, width: bounds.width - 32, height: 38)
        let top = search.frame.maxY + 10
        table.frame = CGRect(x: 0, y: top, width: bounds.width, height: h - top)
        loadingView.center = CGPoint(x: bounds.width / 2, y: top + 44)
        emptyLabel.frame = CGRect(x: 24, y: top + 40, width: bounds.width - 48, height: 22)
    }

    // MARK: Keyboard

    /// THE LIST MUST NOT RUN ON UNDER THE KEYBOARD.
    ///
    /// The table is laid out all the way down to the bottom of the screen and its
    /// `contentInsetAdjustmentBehavior` is `.never`, so nothing moves it out of the way by itself:
    /// with search focused the keyboard simply covered the last rows, which could then be neither
    /// read nor tapped. The one thing that changes here is the table's own bottom inset, which is
    /// what a scroll view is supposed to answer a keyboard with. The SHEET's height is left alone on
    /// purpose: its two resting heights are Telegram's and the host's settle maths is written
    /// against them, so making the keyboard a third one would put two height models on one drag.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        // A hide notification still carries a frame, and on some paths it is still the on-screen
        // one, so the hide case is answered with a flat zero rather than by measuring anything.
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        // `from: nil` means the window, which is the space the keyboard frame is published in.
        let keyboardTop = hiding ? bounds.maxY : convert(end, from: nil).minY
        let listBottom = convert(table.bounds, from: table).maxY
        let overlap = max(0, listBottom - keyboardTop)
        guard abs(table.contentInset.bottom - overlap) > 0.5 else { return }

        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        // The keyboard rides a curve that has no `UIView.AnimationCurve` case of its own (it reports
        // 7). Shifting the raw value into the options field is how you ride the same timing, and it
        // is the difference between the list settling WITH the keyboard and a beat behind it.
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
        let timing = UIView.AnimationOptions(rawValue: UInt(curve) << 16)
        UIView.animate(withDuration: duration, delay: 0,
                       options: [timing, .beginFromCurrentState]) {
            self.table.contentInset.bottom = overlap
            self.table.verticalScrollIndicatorInsets.bottom = overlap
        }
    }

    // MARK: Progress

    /// Move the sheet, without animation. The host's spring drives this frame by frame during a
    /// release, exactly as the finger does during a drag, so there is one path and one feel.
    func setProgress(_ p: CGFloat) {
        let clamped = max(0, min(1, p))
        guard abs(clamped - progress) > 0.0001 else { return }
        progress = clamped
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
            // A DRAG ON THE EXPANDED SHEET STEPS BACK ONE LEVEL, Telegram's rule: full+search →
            // half, and only the NEXT drag can dismiss. The host's settle math is written against
            // the half height, so letting a drag run while expanded would fight two height models.
            if searchExpanded {
                search.resignFirstResponder()
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
                    g.setTranslation(.zero, in: self)
                    panBaselineY = 0
                }
                return
            }
            table.contentOffset.y = 0          // pin it while the sheet owns the movement
            setProgress(dragStart - (translation - panBaselineY) / sheetHeight)
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
            onRelease?(progress, dragStart, -velocity / sheetHeight)
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

    /// The sheet slides sideways under the finger and commits to the neighbour's sheet — Telegram's
    /// thresholds (30% of the width, or 5% with 200pt/s behind it).
    ///
    /// BOTH SHEETS MOVE TOGETHER, WHICH IS THE WHOLE OF HIS REPORT. It used to be a relay: the one
    /// panel slid out over 0.16s, the host flipped the story, and only THEN did the panel come back
    /// from the far edge as the new sheet. So for the entire drag there was nothing behind the panel
    /// but black, and the sheet he was swiping to did not exist until after he let go — "the next
    /// sheet is coming late". Telegram's does not: the neighbour is on screen, moving, from the
    /// first millimetre.
    ///
    /// The trick that makes it cheap is `beginPagePreview`: the departing sheet becomes a snapshot
    /// and the REAL panel becomes the arriving one, loaded with the neighbour's viewers. So the
    /// sheet under the finger is the real sheet, there is still only one table, and the commit is
    /// just the host's id catching up with what is already on screen.
    ///
    /// No neighbour → no preview, a quarter-strength rubber-band and a spring home, as before.
    @objc private func handlePagePan(_ g: UIPanGestureRecognizer) {
        guard let panel = viewWithTag(1) else { return }
        let rawX = g.translation(in: self).x
        switch g.state {
        case .began:
            onDragActive?(true)
            suspendForeignPans()
            // A transition from the last swipe still settling: land it NOW. Otherwise the first
            // .changed snapshots a panel that is halfway across the screen and the photograph
            // arrives crooked.
            //
            // ⚠️ AND IT MUST BE LANDED THE WAY IT WAS GOING TO LAND. The comment here used to say
            // "restoring is right either way"; it is not. A COMMITTED page ends with
            // `endPagePreview(restore: false)` from the animation's completion — the preview IS the
            // story now — and interrupting it with `restore: true` runs the opposite teardown and
            // posts `onPagePreview?(0)`, putting the departing story's list back over the one the
            // host has already switched to. So the same state got torn down two different ways
            // depending only on whether a finger arrived within the 0.28s.
            //
            // That window is exactly what "fast fast" swiping lives in, which is his 2026-08-07
            // report. `pageCommitted` remembers which way the last cycle went so an interruption
            // finishes it the same way it would have finished itself.
            if pageDir != 0 {
                panel.layer.removeAllAnimations()
                pageGhost?.layer.removeAllAnimations()
                endPagePreview(restore: !pageCommitted)
                panel.transform = .identity
            }
            pageCommitted = false
            pageBaselineX = rawX
        case .changed:
            let tx = rawX - pageBaselineX
            // Under half a point is not a direction. Without this the first frame (which is ~0 by
            // construction, see pageBaselineX) would install a preview of whichever side the sign
            // of zero happened to name.
            guard abs(tx) >= 0.5 else {
                if pageDir != 0 { endPagePreview(restore: true) }
                panel.transform = .identity
                onPageDrag?(0)
                return
            }
            let dir = tx < 0 ? 1 : -1          // finger left → the NEXT story arrives
            let allowed = dir == 1 ? hasNext : hasPrev
            guard allowed else {
                if pageDir != 0 { endPagePreview(restore: true) }
                panel.transform = CGAffineTransform(translationX: tx * 0.25, y: 0)
                onPageDrag?(tx * 0.25 / max(bounds.width, 1))   // the rubber-band, same units
                return
            }
            if pageDir != dir { beginPagePreview(dir) }
            // The departing sheet rides the finger; the arriving one rides it exactly one screen
            // behind. One number, two views, no gap between them at any moment of the drag.
            pageGhost?.transform = CGAffineTransform(translationX: tx, y: 0)
            panel.transform = CGAffineTransform(translationX: tx + CGFloat(dir) * pageTravel, y: 0)
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
            onPageDrag?(tx / max(bounds.width, 1))
        case .ended, .cancelled:
            onDragActive?(false)
            let tx = rawX - pageBaselineX
            let vx = g.velocity(in: self).x
            let w = max(bounds.width, 1)
            let commit = g.state == .ended && pageDir != 0
                && (abs(tx) > w * 0.30 || (abs(tx) > w * 0.05 && abs(vx) > 200))
            if commit {
                let dir = pageDir
                // THE ID FLIPS NOW, not when the animation lands. The host zeroes the row's drag in
                // the same transaction, so the carousel glides its remaining distance while these
                // two panels finish theirs — one motion. Nothing reloads: the preview already put
                // this story's viewers in the panel, so the coordinator's load() is a no-op.
                onPage?(dir)
                pageCommitted = true
                // `.allowUserInteraction`, OR THE INTERRUPTION PATH ABOVE CAN NEVER RUN. Without
                // it, UIKit turns off touch delivery to the animating panel's whole subtree for
                // the length of the settle — so a finger arriving inside the 0.28s (his 2026-08-09
                // "swipe back does not work until the first swipe completes") was dropped before
                // the pan ever heard it, and the `.began` that lands a mid-flight cycle sat
                // unreachable. The flag is what every interruptible-gesture settle carries.
                UIView.animate(withDuration: 0.28, delay: 0,
                               options: [.curveEaseOut, .allowUserInteraction]) {
                    self.pageGhost?.transform =
                        CGAffineTransform(translationX: -CGFloat(dir) * self.pageTravel, y: 0)
                    panel.transform = .identity
                } completion: { _ in
                    self.pageCommitted = false
                    self.endPagePreview(restore: false)   // the preview IS the story now
                }
            } else {
                onPageDrag?(0)
                // Home for the arriving panel is back off the edge it came from; with no preview
                // installed (no neighbour that way) it is the rubber-band springing back.
                let parked: CGAffineTransform = pageDir == 0
                    ? .identity
                    : CGAffineTransform(translationX: CGFloat(pageDir) * pageTravel, y: 0)
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                               initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) {   // same rule as the commit settle
                    self.pageGhost?.transform = .identity
                    panel.transform = parked
                } completion: { _ in
                    // Put the panel back where it belongs BEFORE it is visible again: the ghost is
                    // covering it until the moment it goes away, and the restore inside
                    // endPagePreview is what puts this story's own viewers back in it.
                    self.endPagePreview(restore: true)
                    panel.transform = .identity
                }
            }
        default: break
        }
    }

    /// Hand the panel to the neighbour and leave a photograph of the sheet we are on in its place.
    private func beginPagePreview(_ dir: Int) {
        guard let panel = viewWithTag(1) else { return }
        if pageDir != 0 { endPagePreview(restore: true) }   // he changed his mind mid-drag
        // `afterScreenUpdates: false` deliberately: the panel is exactly as the last frame drew it,
        // and waiting for a commit here would snapshot the panel AFTER the preview had already
        // swapped the list into it — a picture of the sheet we are moving to, left behind as the
        // sheet we came from.
        guard let shot = panel.snapshotView(afterScreenUpdates: false) else { return }
        shot.frame = panel.frame
        shot.transform = panel.transform
        shot.isUserInteractionEnabled = false   // a photograph must never answer a touch
        insertSubview(shot, aboveSubview: panel)
        pageGhost = shot
        pageDir = dir
        onPagePreview?(dir)
    }

    /// Drop the photograph. `restore` puts the story we are still on back in the panel — true when
    /// the swipe came to nothing, false when it committed and the panel's contents ARE the story now.
    private func endPagePreview(restore: Bool) {
        pageGhost?.removeFromSuperview()
        pageGhost = nil
        if restore, pageDir != 0 { onPagePreview?(0) }
        pageDir = 0
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
            let loc = outsidePan.location(in: self)
            guard loc.y < panelTop else { return false }
            // In the carousel band, horizontal drags belong to the cover-flow: refuse them and let
            // bandGuard ride along with SwiftUI. Everywhere else, every direction is ours.
            if progress > 0.95, carouselBand.contains(loc) {
                let v = outsidePan.velocity(in: self)
                return abs(v.y) >= abs(v.x)
            }
            return true
        }
        if gestureRecognizer === bandGuard {
            guard window != nil, progress > 0.95 else { return false }
            return carouselBand.contains(bandGuard.location(in: self))
        }
        if gestureRecognizer === tapAbove {
            return tapAbove.location(in: self).y < panelTop
        }
        if gestureRecognizer === pagePan {
            // Only a settled-open sheet pages (Telegram gates theirs to the .half state too), and
            // only from the panel — the carousel band above has its own horizontal owner.
            guard progress > 0.95 else { return false }
            return pagePan.location(in: self).y >= panelTop
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// The one question the list hand-off turns on.
    private func shouldSheetTakeDrag(velocity: CGFloat) -> Bool {
        if progress < 0.999 { return true }               // not fully open → the sheet is the thing moving
        if table.contentOffset.y > 0.5 { return false }   // list has somewhere to go → let it scroll
        return velocity > 0                               // at the top and pulling down → collapse
    }

    // MARK: Filtering

    @objc private func pickAll() { setTab(0) }
    @objc private func pickFriends() { setTab(1) }

    private func setTab(_ i: Int) {
        guard tab != i else { return }
        tab = i
        configureTab(allTab, allTabTitle, selected: i == 0)
        configureTab(friendsTab, "Friends", selected: i == 1)
        applyFilter()
        UIView.animate(withDuration: 0.18) { self.setNeedsLayout(); self.layoutIfNeeded() }
    }

    @objc private func searchChanged() { applyFilter() }

    // MARK: Search expansion (Telegram's two resting heights — see `searchExpanded`)

    @objc private func searchBegan() { setSearchExpanded(true) }
    @objc private func searchEnded() {
        // Keyboard down with a live query keeps the tall sheet (results need the room);
        // down with an empty one has nothing to show and steps back to half.
        if (search.text ?? "").isEmpty { setSearchExpanded(false) }
    }

    private func setSearchExpanded(_ on: Bool) {
        guard searchExpanded != on else { return }
        searchExpanded = on
        // Telegram's 0.5s spring for exactly this jump. `.allowUserInteraction` for the same
        // reason the page settles carry it: a finger must be able to interrupt.
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// THE SHEET IS BEING POINTED AT A DIFFERENT STORY, so everything that was narrowing the LAST
    /// story's list goes with it.
    ///
    /// A query typed for one story means nothing for the next one's audience, and it was surviving
    /// the swap: `viewers.didSet` re-ran the old text against the new people, so paging sideways
    /// showed "No views yet" for a story that has viewers, with the words that hid them sitting in a
    /// search field that had already collapsed out of sight. There was no way to see what was wrong,
    /// let alone undo it.
    ///
    /// The friends set is emptied here for a different reason with the same shape: it is read once
    /// and then kept for ever, so the Friends tab was answering with whatever the conversation list
    /// said the first time that tab was opened in this sheet. Emptying it makes the next filter go
    /// and read it again.
    func prepareForStorySwap() {
        friendUids = []
        guard !(search.text ?? "").isEmpty || searchExpanded else { return }
        search.text = ""
        search.resignFirstResponder()
        setSearchExpanded(false)
        applyFilter()
    }

    private func applyFilter() {
        let me = AuthService.shared.uid ?? ""
        if tab == 1 && friendUids.isEmpty {
            friendUids = Set(ConversationsRepository.shared.conversations
                .filter { !$0.isGroup }.map { $0.otherUid(me) }.filter { !$0.isEmpty })
        }
        var v = viewers
        if tab == 1 { v = v.filter { friendUids.contains($0.id) } }
        let q = (search.text ?? "").trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { v = v.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        // Reactions first, then most recent — the same order the SwiftUI sheet used, kept so the list
        // does not reorder itself the day this replaces it.
        filtered = v.sorted { a, b in
            let ar = !(a.reaction ?? "").isEmpty, br = !(b.reaction ?? "").isEmpty
            if ar != br { return ar }
            return a.viewedAt > b.viewedAt
        }
        table.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = isLoading || !filtered.isEmpty
    }
}

/// Axis-locked pan for the sheet's window-level gestures. Judges the CUMULATIVE movement since
/// touch-down and fails fast on the wrong axis, so a horizontal cover-flow swipe never loses its
/// first frames to a vertical recognizer and vice versa. (Telegram's InteractiveTransitionGesture-
/// Recognizer decides the same way: 2:1 dominance wins immediately, a distance deadline settles
/// ambiguous diagonals.)
final class DirectionalSheetPan: UIPanGestureRecognizer {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    private var startPoint: CGPoint?

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
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let touch = touches.first {
            let loc = touch.location(in: view)
            let start = startPoint ?? loc
            let ax = abs(loc.x - start.x), ay = abs(loc.y - start.y)
            if max(ax, ay) >= 8 {
                if ay > ax * 1.2, axis == .horizontal { state = .failed; return }
                if ax > ay * 1.2, axis == .vertical { state = .failed; return }
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

// MARK: - Table

extension StoryViewersSheetView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "viewer", for: indexPath)
        let v = filtered[indexPath.row]
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        // SwiftUI for the row's CONTENTS only. The avatar, its hashed letter fallback and the reaction
        // badge already exist and already look right; rebuilding them in UIKit would only be a chance
        // for the two to drift apart.
        cell.contentConfiguration = UIHostingConfiguration {
            StoryViewerRowContent(
                viewer: v,
                onSendMessage: { [weak self] in self?.onSendMessage?(v) },
                onOpenProfile: { [weak self] in self?.onOpenProfile?(v) },
                onToggleHidden: { [weak self] in
                    let store = StoryAudienceStore.shared
                    store.setHidden(v.id, !store.isHidden(v.id))
                    // Redraw: the menu's label is the state, so a stale row would offer to hide
                    // somebody it just hid.
                    //
                    // FOUND BY WHO IS IN IT, not by the index this cell happened to be built with. A
                    // tab switch or a keystroke in the search between the build and the tap re-runs
                    // the filter and moves everybody, and the captured index then names whoever has
                    // since taken that slot: the wrong row redrew, and the tapped one kept the label
                    // it had just contradicted.
                    guard let self, let row = self.filtered.firstIndex(where: { $0.id == v.id })
                    else { return }
                    self.table.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
                },
                onBlock: { [weak self] in self?.onBlock?(v) },
                isHidden: StoryAudienceStore.shared.isHidden(v.id))
        }
        .margins(.horizontal, 16)
        .margins(.vertical, 9)
        return cell
    }

    /// The table's own scrolling is untouched while the list owns the drag; this only stops it
    /// rubber-banding UPWARD past its top while the sheet is the thing that should be moving.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if dragOwnsSheet { scrollView.contentOffset.y = 0 }
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
    /// This story's audience, in words, and whether it earns a second tab. See `audience` on the
    /// view and `storyAudienceTitle` in StoriesViews, which is where both of these come from.
    var audienceTitle: String = "All Viewers"
    var audienceHasBothTabs: Bool = true
    @Binding var progress: CGFloat
    var carouselBand: CGRect = .zero
    var hasPrev: Bool = false
    var hasNext: Bool = false
    /// The stories either side of `activeStoryId`. The sheet needs the IDS, not just whether they
    /// exist, because it loads the neighbour's viewers the moment a sideways drag picks a side —
    /// see `Coordinator.preview`. Empty string = no neighbour that way.
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
        v.onPagePreview = { [weak c = context.coordinator] d in c?.preview(d) }
        context.coordinator.view = v
        v.audience = (audienceTitle, audienceHasBothTabs)
        context.coordinator.setNeighbours(prev: prevStoryId, next: nextStoryId)
        context.coordinator.load(activeStoryId)
        return v
    }

    func updateUIView(_ v: StoryViewersSheetView, context: Context) {
        if !context.coordinator.applying { v.setProgress(progress) }
        // The sheet pages sideways between the author's stories, and each one may have gone to a
        // different audience, so the tab follows the story on screen rather than the one it opened on.
        v.audience = (audienceTitle, audienceHasBothTabs)
        v.carouselBand = carouselBand
        v.hasPrev = hasPrev
        v.hasNext = hasNext
        context.coordinator.setNeighbours(prev: prevStoryId, next: nextStoryId)
        context.coordinator.load(activeStoryId)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: StoryViewersSheetView?
        var applying = false
        private var loadedId = ""
        private var activeId = ""
        private var prevId = ""
        private var nextId = ""
        private var task: Task<Void, Never>?
        /// A page drag owns the panel: the list in it belongs to the neighbour the finger is
        /// bringing in, not to the story the host still thinks we are on.
        private var previewing = false
        /// Viewers by story id. Small (a story's whole audience) and short-lived (this sheet), and
        /// it is what lets the arriving sheet arrive with its people already in it.
        private var cache: [String: [StoryViewerInfo]] = [:]

        func setNeighbours(prev: String, next: String) {
            guard prev != prevId || next != nextId else { return }
            prevId = prev
            nextId = next
            warmNeighbours()   // paging changed who the neighbours are; go and get them
        }

        /// The host's story changed.
        ///
        /// While a preview is up this must NOT pull the host's story back into the panel — the
        /// finger has already moved on. The one thing it does is notice when the host has caught up
        /// with what the finger brought in (a commit), and hand ownership back.
        func load(_ id: String) {
            activeId = id
            if previewing {
                if id == loadedId { previewing = false }
                return
            }
            show(id)
        }

        /// Put a neighbour in the panel without the host committing to it: +1 next, -1 previous,
        /// 0 back to the story we are on. Called from the page drag's first millimetre.
        func preview(_ dir: Int) {
            previewing = dir != 0
            let target = dir == 1 ? nextId : (dir == -1 ? prevId : activeId)
            guard !target.isEmpty else { previewing = false; return }
            show(target)
        }

        /// Debounced by story id: scrubbing the carousel changes this on every card, and a fetch per
        /// card would be a request storm for a list nobody has stopped to read yet. A cache hit
        /// skips the wait entirely, which is what makes a previewed neighbour land already filled.
        private func show(_ id: String) {
            guard !id.isEmpty, id != loadedId else { return }
            loadedId = id
            // A NEW STORY IS A NEW AUDIENCE. Drop the last one's search text and its friends set
            // BEFORE the new people are handed over, because assigning `viewers` filters them on the
            // way in: do it after and the first thing drawn is the new list seen through the old
            // story's query.
            view?.prepareForStorySwap()
            task?.cancel()
            if let hit = cache[id] {
                view?.viewers = hit
                view?.isLoading = false
                warmNeighbours()
                return
            }
            view?.viewers = []
            view?.isLoading = true
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let people = await StoriesService.shared.fetchViewers(storyId: id)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.cache[id] = people
                    self.view?.viewers = people
                    self.view?.isLoading = false
                    self.warmNeighbours()
                }
            }
        }

        /// Fetch both neighbours' lists in the background so a sideways swipe has something to slide
        /// in. Without this the arriving sheet would be a spinner every time, which is the shape of
        /// the bug rather than a fix for it. Two small reads, only ever while this sheet is open.
        private func warmNeighbours() {
            for id in [prevId, nextId] where !id.isEmpty && cache[id] == nil {
                Task { [weak self] in
                    let people = await StoriesService.shared.fetchViewers(storyId: id)
                    await MainActor.run { self?.cache[id] = people }
                }
            }
        }
    }
}
