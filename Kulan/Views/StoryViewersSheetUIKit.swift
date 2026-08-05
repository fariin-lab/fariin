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
final class StoryViewersSheetView: UIView {

    // MARK: Public surface

    /// 0 shut, 1 fully open. The host reads this to drive the live story's morph, so it is the same
    /// number the card is scaled by — the sheet and the story cannot disagree about how far open it is.
    var onProgress: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    var onSendMessage: ((StoryViewerInfo) -> Void)?
    /// Finger lifted: (progress now, progress when the drag began, velocity in progress-units/sec,
    /// + = opening). The host decides open/close (Telegram's thresholds) and runs the one spring.
    var onRelease: ((CGFloat, CGFloat, CGFloat) -> Void)?
    /// A finger owns progress right now (any of our pans is live). The host cancels its spring on
    /// true and holds its parked-sheet watchdog while it is true.
    var onDragActive: ((Bool) -> Void)?
    /// Tap on the dark area above the panel → collapse (NOT dismiss the viewer).
    var onCollapseTap: (() -> Void)?
    /// Where the my-stories carousel row sits (screen coords). Touches here pass through to SwiftUI
    /// while the sheet is fully open, so the cover-flow swipe and card taps keep working.
    var carouselBand: CGRect = .zero

    /// Height as a fraction of the screen. Matches `StoryViewersBottomSheet.heightFraction`, which the
    /// carousel still derives its slot from.
    static let heightFraction: CGFloat = 0.60

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

    private var sheetHeight: CGFloat { bounds.height * Self.heightFraction }
    private var panelTop: CGFloat { bounds.height - sheetHeight * progress }

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        buildHierarchy()
        pan.delegate = self
        addGestureRecognizer(pan)
        tapAbove.delegate = self
        addGestureRecognizer(tapAbove)
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

        configureTab(allTab, "All Viewers", selected: true)
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
        panel.frame = CGRect(x: 0, y: bounds.height - h * progress, width: bounds.width, height: h)
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
            onDragActive?(true)   // finger beats spring: the host cancels any in-flight settle
            suspendForeignPans()  // catch any lazily-created system pan before it can ride along
            dragStart = progress
            panBaselineY = translation
            dragOwnsSheet = shouldSheetTakeDrag(velocity: velocity)
        case .changed:
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
        configureTab(allTab, "All Viewers", selected: i == 0)
        configureTab(friendsTab, "Friends", selected: i == 1)
        applyFilter()
        UIView.animate(withDuration: 0.18) { self.setNeedsLayout(); self.layoutIfNeeded() }
    }

    @objc private func searchChanged() { applyFilter() }

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
            StoryViewerRowContent(viewer: v, onSendMessage: { [weak self] in self?.onSendMessage?(v) })
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
                    if let r = viewer.reaction, !r.isEmpty {
                        Text(r).font(.system(size: 11))
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(Color(.systemRed)))
                            .overlay(Circle().stroke(Color(white: 0.10), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewer.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 5) { doubleCheck; Text(dateFmt(viewer.viewedAt)) }
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Menu {
                Button(action: onSendMessage) { Label("Send message", systemImage: "message") }
            } label: {
                Image(systemName: "ellipsis").font(.body).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }
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
    @Binding var progress: CGFloat
    var carouselBand: CGRect = .zero
    var onClose: () -> Void
    var onCollapseTap: () -> Void = {}
    var onRelease: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }
    var onDragActive: (Bool) -> Void = { _ in }

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
        v.carouselBand = carouselBand
        v.onSendMessage = { viewer in
            AppRouter.shared.pendingChatName = viewer.name
            AppRouter.shared.pendingChatPhoto = viewer.photoUrl
            AppRouter.shared.pendingChatId = ChatService.convId(AuthService.shared.uid ?? "", viewer.id)
            onClose()
            NotificationCenter.default.post(name: .init("storyForceClose"), object: nil)
        }
        context.coordinator.view = v
        context.coordinator.load(activeStoryId)
        return v
    }

    func updateUIView(_ v: StoryViewersSheetView, context: Context) {
        if !context.coordinator.applying { v.setProgress(progress) }
        v.carouselBand = carouselBand
        context.coordinator.load(activeStoryId)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: StoryViewersSheetView?
        var applying = false
        private var loadedId = ""
        private var task: Task<Void, Never>?

        /// Debounced by story id: scrubbing the carousel changes this on every card, and a fetch per
        /// card would be a request storm for a list nobody has stopped to read yet.
        func load(_ id: String) {
            guard !id.isEmpty, id != loadedId else { return }
            loadedId = id
            task?.cancel()
            view?.isLoading = true
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let people = await StoriesService.shared.fetchViewers(storyId: id)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.view?.viewers = people
                    self?.view?.isLoading = false
                }
            }
        }
    }
}
