import UIKit

// ⛔ THE STICKER PANEL — owner 2026-10-17 ("go build"). It takes the KEYBOARD'S PLACE: the composer
// sets it as the field's `inputView` and calls `reloadInputViews`, so the system animates the swap
// and the bar (pinned to keyboardLayoutGuide) rides it for free. Shape and numbers from the
// reference app: a "GIFs | Stickers" switch on top, a strip of pack icons, then one scrolling grid
// with a section per shelf (Recently Used, Favorites, each pack). Only tiles on screen animate.
// ⛔ GIF SEARCH GROWS THIS SHEET — owner 2026-10-18 (5775aae8 restored onto today's panel): every view
// lives in `cardView`. Tapping Search GIFs lifts the card out of the keyboard into an overlay on the
// app window and springs it to full screen; the search field there takes the system keyboard (an
// inputView cannot host its own text field's keys). X lifts the card into a window above the
// keyboard, gives the composer its panel back, and springs the card down onto it at the panel's
// own height before putting it home. See `expandForGifSearch` / `collapseGifSearch`.

/// The panel's height: the last real keyboard's, so the swap does not jump; a per-phone default
/// until a keyboard has been seen.
enum StickerPanelHeight {
    private static var lastKeyboard: CGFloat = 0
    private static var observer: NSObjectProtocol?

    /// Starts listening once; every later call is free.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                                          object: nil, queue: .main) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // A panel's own show also posts this; only a real keyboard (taller than a bar) counts,
            // and our panel reports the same height it was given, so it cannot drift.
            if f.height > 170 { lastKeyboard = f.height }
        }
    }

    static var current: CGFloat {
        if lastKeyboard > 170 { return lastKeyboard }
        let screen = UIScreen.main.bounds.size
        let longSide = max(screen.width, screen.height)
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let homeIndicator = (window?.safeAreaInsets.bottom ?? 0) > 0
        if !homeIndicator { return 260 }          // SE-size, Touch ID phones
        return longSide >= 926 ? 345 : 335        // Max / Plus, then every other notch phone
    }
}

final class StickerKeyboardView: UIInputView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSend: (Sticker) -> Void = { _ in }
    var onCreate: () -> Void = {}
    /// A GIF tapped in the panel's own GIFs tab.
    var onSendGif: (GiphyService.Gif) -> Void = { _ in }
    /// Host window and focus hand-offs for growing GIF search to full screen in place.
    var hostWindow: () -> UIWindow? = { nil }
    var onTouch: () -> Void = {}
    var onBeginGifSearch: () -> Void = {}
    var onWillCollapseGifSearch: () -> Void = {}
    var onRestorePanelFocus: () -> Void = {}
    var onDidCollapseGifSearch: () -> Void = {}

    /// Everything the panel draws. It sits in the panel at rest and leaves it only for GIF search.
    private let cardView = UIView()
    /// The card's own background while it is out of the keyboard (the panel's is the keyboard's).
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let gifGrid = PanelGifGrid()
    private(set) var searchingGifs = false
    private var transitionGen = 0
    private var searchOverlay: PassthroughOverlayView?
    private var collapseWindow: PassthroughWindow?
    /// The home-indicator inset seen while in the keyboard, for laying the card out while it is away.
    private var restSafeBottom: CGFloat = 0

    // ⛔ DRAG TO GROW / SHRINK — owner 2026-10-18 ("it cannot be enlarged or shrunk"). Read off the
    // reference app's source (its input panel container + chat layout): one vertical pan over the
    // panel; from the strip / tab band any time, from a grid only when that grid is at its top and
    // the drag is DOWN on the grown panel (up on a grid always scrolls it). The height follows the
    // finger 1:1 between the keyboard's height and "screen minus status bar minus 10 minus the
    // composer"; release past a quarter of the way commits, else it goes back; 0.4 s on their
    // spring-named cubic either way. The chat above dims to 0.2 black, the composer rides on top of
    // the panel, top corners round to 10. Sending a sticker or GIF shrinks it back, as theirs does.
    // While grown the card lives in a window above the keyboard (the GIF search machinery), since
    // an inputView cannot draw or take touches above the keyboard's own frame.
    /// The composer's bar moves up with the grown panel by this much (0 = at rest).
    var onExpansionLift: (CGFloat) -> Void = { _ in }
    /// The top of the composer's bar container in window space, at rest.
    var composerTopInWindow: () -> CGFloat? = { nil }
    /// The lowest point the grown panel must leave free at the top (the chat's navigation bar foot).
    var expansionCeilingInWindow: () -> CGFloat? = { nil }
    private let expandPan = UIPanGestureRecognizer()
    private let expandPanDelegate = ExpandPanDelegate()
    private let expandDim = UIView()
    private var expandAnimator: UIViewPropertyAnimator?
    /// The card is out in its window for the grow (dragging, grown, or settling).
    private var expansionLive = false
    /// The panel is leaving with the keys and the card is sliding down after it.
    private var slidingAway = false
    private var lift: CGFloat = 0
    /// A grow drag is under a finger (the card's pan or the bar's): the other may not start too.
    private var dragInFlight = false
    private var liftAtStart: CGFloat = 0
    private var liftRange: CGFloat = 0
    private var restCardFrame: CGRect = .zero
    /// The composer's band above the panel (its pad, the bar, the gap), measured when the grow starts.
    private var chromeH: CGFloat = 0

    private enum Shelf: Equatable {
        case recents, favorites, pack(StickerPack)
        var title: String {
            switch self {
            case .recents: return "Recently Used"
            case .favorites: return "Favorites"
            case .pack(let p): return p.title
            }
        }
        /// Only my own shelves can lose stickers; the packs are everyone's.
        var editable: Bool { self == .recents || self == .favorites }
        var key: String { self == .recents ? "r" : "f" }
    }
    private struct Section { let shelf: Shelf; let stickers: [Sticker] }

    private let height: CGFloat
    private var sections: [Section] = []
    // ⛔ ONE PEN, NOT AN EDIT PER SHELF — owner 2026-10-17: a small pen beside the tabs; tapping it
    // makes every sticker in Recently Used and Favorites selectable at once, then Delete.
    private var editing = false
    /// "<shelf key>|<sticker id>": the same sticker can sit in both shelves and is picked per shelf.
    private var picked: Set<String> = []
    private let editButton = UIButton(type: .system)
    /// The glass under Edit / Done: its own view, sized to the button's slot. The system glass button
    /// style keeps its own minimum height, so squeezed into this 32 pt slot it drew its title twice,
    /// the second copy sliding out to the right (owner 2026-10-18, build 969).
    private let editGlass: UIVisualEffectView = {
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = true
        let v = UIVisualEffectView(effect: g)
        v.isUserInteractionEnabled = false
        v.clipsToBounds = true
        return v
    }()
    private let tabGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))

    private let tabs = UISegmentedControl(items: ["GIFs", "Stickers"])
    /// The chosen tab's pill. Our own: clearing the control's track (for the glass under it) also
    /// takes away its selected thumb, so `selectedSegmentTintColor` alone draws nothing (owner 2026-10-18).
    private let tabThumb = UIView()
    private let strip = UIScrollView()
    private var stripButtons: [UIButton] = []
    private let grid: UICollectionView
    private let deleteBar = UIView()
    private let deleteButton = UIButton(type: .system)

    // Reference numbers (owner-approved report, 2026-10-17).
    private enum M {
        static let item: CGFloat = 70, spacing: CGFloat = 12, side: CGFloat = 10, row: CGFloat = 2
        static let header: CGFloat = 24, packGap: CGFloat = 18
        static let stripCell: CGFloat = 40, stripInset: CGFloat = 6, stripSpacing: CGFloat = 4
        static let top: CGFloat = 8, tabsH: CGFloat = 32, stripH: CGFloat = 44
    }

    init(height: CGFloat) {
        self.height = height
        let layout = UICollectionViewFlowLayout()
        layout.sectionHeadersPinToVisibleBounds = false
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        // The pack strip slides up out of the panel when the grid scrolls; it leaves at the panel's top
        // edge, as the reference app's does, instead of drawing over the composer (owner 2026-10-18).
        clipsToBounds = true
        autoresizingMask = [.flexibleWidth]

        // The card clips too, so the strip still leaves at its top edge while the card is away.
        // Square at rest (the panel's look); its top corners round only while it is out for search.
        cardView.layer.cornerCurve = .continuous
        cardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        cardView.clipsToBounds = true
        addSubview(cardView)
        backdrop.contentView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.65)
        backdrop.isHidden = true
        cardView.addSubview(backdrop)

        tabs.selectedSegmentIndex = 1
        let normal = UIFont.systemFont(ofSize: 14, weight: .regular)
        let bold = UIFont.systemFont(ofSize: 14, weight: .semibold)
        tabs.setTitleTextAttributes([.font: normal, .foregroundColor: UIColor.secondaryLabel], for: .normal)
        tabs.setTitleTextAttributes([.font: bold, .foregroundColor: UIColor.label], for: .selected)
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        // ⛔ LIQUID GLASS UNDER THE SWITCH — owner 2026-10-17: the flat grey track read as a web control.
        // The system glass capsule is the track; the control's own track is cleared on top of it.
        tabGlass.clipsToBounds = true
        cardView.addSubview(tabGlass)
        tabs.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
        tabs.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        tabs.selectedSegmentTintColor = .clear
        tabThumb.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        tabThumb.isUserInteractionEnabled = false
        cardView.addSubview(tabThumb)
        cardView.addSubview(tabs)
        // Stickers only while the GIF tab is off (`AppFeatures.stickerPanelGifs`): no switch at all,
        // and the hit test / grow band below skip a hidden one.
        if !AppFeatures.stickerPanelGifs {
            for v in [tabs, tabGlass, tabThumb] as [UIView] { v.isHidden = true }
        }

        setPen()
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        cardView.addSubview(editButton)

        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = true
        cardView.addSubview(strip)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.id)
        grid.register(ShelfHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: ShelfHeader.id)
        cardView.addSubview(grid)

        gifGrid.isHidden = true
        gifGrid.onSend = { [weak self] g in
            self?.onSendGif(g)
            self?.collapseExpansion()   // a send shrinks the grown panel, as the reference app's does
        }
        gifGrid.onSearch = { [weak self] in self?.expandForGifSearch() }
        gifGrid.onCancelSearch = { [weak self] in self?.collapseGifSearch() }
        gifGrid.onSearchFieldEnded = { [weak self] in
            guard let self, self.searchingGifs else { return }
            self.collapseGifSearch()
        }
        cardView.addSubview(gifGrid)
        // The switch floats over both grids (it sits at their foot now).
        cardView.bringSubviewToFront(tabGlass)
        cardView.bringSubviewToFront(tabThumb)
        cardView.bringSubviewToFront(tabs)

        deleteBar.backgroundColor = .secondarySystemBackground
        deleteBar.isHidden = true
        deleteButton.setTitleColor(.systemRed, for: .normal)
        deleteButton.setTitleColor(.tertiaryLabel, for: .disabled)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteBar.addSubview(deleteButton)
        cardView.addSubview(deleteBar)

        expandDim.backgroundColor = UIColor(white: 0, alpha: 0.2)   // their content dim
        expandDim.isUserInteractionEnabled = false
        expandPan.maximumNumberOfTouches = 1
        expandPan.addTarget(self, action: #selector(expandPanned(_:)))
        expandPanDelegate.owner = self
        expandPan.delegate = expandPanDelegate
        cardView.addGestureRecognizer(expandPan)

        reload()
        // Packs from the admin panel (2026-10-18): a changed catalog redraws the shelves; a server
        // sticker's file landing fills its tile in place (no full reload, so nothing flashes).
        NotificationCenter.default.addObserver(self, selector: #selector(catalogChanged),
                                               name: StickerStore.packsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(artArrived),
                                               name: StickerStore.artArrived, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        searchOverlay?.removeFromSuperview()
        collapseWindow?.isHidden = true
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }

    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil { restSafeBottom = safeAreaInsets.bottom }
        // Only while the card is home. Away, its own animation lays it out; a pass from here (the
        // panel re-entering the keyboard mid-shrink) would snap its insides to the end frame.
        guard cardView.superview === self else { return }
        cardView.frame = bounds
        layoutCardSubviews()
    }

    /// The home-indicator inset to lay out with: the panel's own at rest, the remembered one (or the
    /// app window's) while the card is out, where the panel may have no window to ask.
    private var safeBottom: CGFloat {
        if cardView.superview === self, window != nil { return safeAreaInsets.bottom }
        return restSafeBottom > 0 ? restSafeBottom : (hostWindow()?.safeAreaInsets.bottom ?? safeAreaInsets.bottom)
    }

    /// Every frame, in the card's own space, so the same code lays it out in the panel, in the full-
    /// screen overlay, and on the way between.
    private func layoutCardSubviews() {
        let cb = cardView.bounds
        let w = cb.width
        let h = cb.height
        backdrop.frame = cb
        // Frames are only valid on an untransformed view; the hide lift is put back on below.
        for v in [tabs, tabGlass, editButton, strip] as [UIView] { v.transform = .identity }
        // ⛔ THE SWITCH SITS AT THE BOTTOM — owner 2026-10-17, as the reference app has it: the pack
        // strip (with the pen at its end) on top, GIFs | Stickers floating over the grid at the foot.
        // Scrolling into the grid sends the strip up and the switch down; scrolling back brings both.
        let sb = safeBottom
        let bottomInset = max(sb, 8)
        // Inset by the side margin and clipped there (owner 2026-10-18: swiping the packs slid them past
        // the panel's rounded edge). The scroll view clips, so icons leave at the margin, not the corner.
        let editW: CGFloat = 64
        strip.frame = CGRect(x: M.side, y: M.top, width: w - editW - 12 - M.side, height: M.stripH)
        editButton.frame = CGRect(x: w - editW - 8, y: M.top + (M.stripH - M.tabsH) / 2, width: editW, height: M.tabsH)
        if editGlass.superview !== editButton { editButton.insertSubview(editGlass, at: 0) }
        editGlass.frame = editButton.bounds
        editGlass.layer.cornerRadius = editButton.bounds.height / 2
        layoutStrip()
        // 160 wide (owner 2026-10-18: "that bar is big"), was 220.
        // Its foot is where the composer's pill rests (owner 2026-10-18, "use the bottom space the
        // composer uses"): 5 pt into the home-indicator strip, or 8 pt on a phone without one.
        let footGap = sb > 0 ? sb - 5 : 8
        tabs.frame = CGRect(x: (w - 160) / 2, y: h - footGap - M.tabsH, width: 160, height: M.tabsH)
        tabGlass.frame = tabs.frame.insetBy(dx: -3, dy: -3)
        tabGlass.layer.cornerRadius = tabGlass.bounds.height / 2
        layoutTabThumb()
        // While GIF search has the card, the strip and the switch are out of the way like a scroll hide.
        let hideBars = headerHidden || searchingGifs
        let up = hideBars ? strip.frame.maxY : 0
        let down = hideBars ? h - tabGlass.frame.minY : 0
        for v in [editButton, strip] as [UIView] { v.transform = CGAffineTransform(translationX: 0, y: -up) }
        for v in [tabs, tabGlass, tabThumb] as [UIView] { v.transform = CGAffineTransform(translationX: 0, y: down) }
        for v in [tabs, tabGlass, tabThumb, editButton, strip] as [UIView] { v.alpha = hideBars ? 0 : 1 }
        if editing { tabs.alpha = 0; tabGlass.alpha = 0; tabThumb.alpha = 0 }   // the Delete bar takes the foot while editing
        let gridTop = headerHidden ? 0 : strip.frame.maxY
        grid.frame = CGRect(x: 0, y: gridTop, width: w, height: max(0, h - gridTop))
        gifGrid.frame = CGRect(x: 0, y: M.top, width: w, height: max(0, h - M.top))
        // Searching, the system keyboard covers the card's foot: room for it under the last row.
        gifGrid.bottomRoom = searchingGifs ? (StickerPanelHeight.current + 8) : (M.tabsH + 16)
        // Room under the last row for the floating switch (and the Delete bar while editing).
        grid.contentInset.bottom = bottomInset + (tabs.isHidden ? 8 : M.tabsH + 16) + (editing ? 44 : 0)
        let barH = 44 + sb
        deleteBar.frame = CGRect(x: 0, y: h - barH, width: w, height: barH)
        deleteButton.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        if lastGridWidth != w { lastGridWidth = w; grid.collectionViewLayout.invalidateLayout() }
    }
    private var lastGridWidth: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Back on screen: pick up what changed while away (a sticker just sent, one just made).
        if window != nil, !editing { reload() }
        if window != nil { gifGrid.refreshLocalShelf() }
    }

    // MARK: GIF search: grow to full screen in place, shrink back on X (owner 2026-10-18)

    private func expandForGifSearch() {
        guard !searchingGifs else {
            gifGrid.focusSearchField()
            return
        }
        guard let hostWin = hostWindow() ?? window else { return }
        // Search from the grown panel: the card leaves its grow window from where it is (the branch
        // below), the composer goes back down behind the search page.
        if expansionLive { endExpansionForSearch() }
        transitionGen += 1
        searchingGifs = true
        headerHidden = false

        // Where the card is on screen now, in the app window's space.
        let startFrame: CGRect
        if let cw = collapseWindow, cardView.superview === cw {
            // Tapped Search again while it was still shrinking: grow from where it is.
            startFrame = cardView.layer.presentation()?.frame ?? cardView.frame
            cw.isHidden = true
            collapseWindow = nil
        } else if cardView.window != nil {
            startFrame = hostWin.convert(cardView.bounds, from: cardView)
        } else {
            let panelH = bounds.height > 0 ? bounds.height : height
            startFrame = CGRect(x: 0, y: hostWin.bounds.height - panelH, width: hostWin.bounds.width, height: panelH)
        }

        let ov = PassthroughOverlayView(frame: hostWin.bounds)
        ov.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ov.targetView = cardView
        ov.onTouch = { [weak self] in self?.onTouch() }
        hostWin.addSubview(ov)
        searchOverlay?.removeFromSuperview()
        searchOverlay = ov

        backdrop.isHidden = false
        UIView.performWithoutAnimation {
            ov.addSubview(cardView)
            cardView.frame = startFrame
            layoutCardSubviews()
            cardView.layoutIfNeeded()
        }

        gifGrid.setSearching(true)
        // The composer arms its resign first, so the field can let go for the search field's keys.
        onBeginGifSearch()
        gifGrid.focusSearchField()

        let topInset = max(hostWin.safeAreaInsets.top, 12)
        let expandedFrame = CGRect(x: 0, y: topInset, width: hostWin.bounds.width, height: hostWin.bounds.height - topInset)
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cardView.frame = expandedFrame
            self.cardView.layer.cornerRadius = 28
            self.layoutCardSubviews()
            self.cardView.layoutIfNeeded()
        }
    }

    func collapseGifSearch() {
        guard searchingGifs else { return }
        transitionGen += 1
        let gen = transitionGen
        searchingGifs = false
        headerHidden = false

        let hostWin = hostWindow() ?? searchOverlay?.window ?? window
        let currentFrame = cardView.layer.presentation()?.frame ?? cardView.frame

        gifGrid.setSearching(false)
        onWillCollapseGifSearch()

        // The card goes into a window above the keyboard's, so the panel coming back under it never
        // shows through and nothing on the way down is cut by the keyboard.
        if let scene = hostWin?.windowScene {
            let maxLevel = scene.windows.map(\.windowLevel.rawValue).max() ?? 10_000_001
            let cw = PassthroughWindow(windowScene: scene)
            cw.frame = hostWin?.bounds ?? scene.screen.bounds
            cw.windowLevel = UIWindow.Level(rawValue: maxLevel + 1)
            cw.backgroundColor = .clear
            cw.overrideUserInterfaceStyle = hostWin?.overrideUserInterfaceStyle ?? .unspecified
            cw.targetView = cardView
            cw.onTouch = { [weak self] in self?.onTouch() }
            cw.isHidden = false
            collapseWindow?.isHidden = true
            collapseWindow = cw

            UIView.performWithoutAnimation {
                cw.addSubview(cardView)
                cardView.frame = currentFrame
                cardView.layoutIfNeeded()
                searchOverlay?.removeFromSuperview()
                searchOverlay = nil
            }
        }

        // The field takes the responder back with this panel as its keys: the panel is up again at
        // once, under the card, so the composer settles on the same height it left.
        onRestorePanelFocus()

        let winBounds = hostWin?.bounds ?? cardView.superview?.bounds ?? .zero
        let targetH = bounds.height > 0 ? bounds.height : height
        let collapsedFrame = CGRect(x: 0, y: winBounds.height - targetH, width: winBounds.width, height: targetH)

        UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cardView.frame = collapsedFrame
            self.cardView.layer.cornerRadius = 0
            self.layoutCardSubviews()
            self.cardView.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.transitionGen == gen, !self.searchingGifs else { return }
            self.homeWhenPanelLands(gen: gen, target: collapsedFrame, tries: 0)
        }
    }

    /// ⛔ THE CARD WAITS FOR THE PANEL (owner 2026-10-18, build 973: "it goes small, disappears, and
    /// another one comes up"). Taking the responder back makes iOS raise this panel with its own
    /// keyboard slide, which often outlasts the card's spring. Moving the card home while the panel
    /// was still low dropped it into a view mid-rise: the card vanished and a second panel came up.
    /// So the card stays on top, already where it belongs, until the panel's on-screen frame (read
    /// from the presentation layers, the frame as drawn) sits under it. Then the swap shows nothing.
    /// About a second at most, then home anyway, so nothing can be left floating.
    private func homeWhenPanelLands(gen: Int, target: CGRect, tries: Int) {
        guard transitionGen == gen, !searchingGifs else { return }
        var landed = false
        if let win = window, let pl = layer.presentation() {
            let wl = win.layer.presentation() ?? win.layer
            let f = pl.convert(pl.bounds, to: wl)
            landed = abs(f.minY - target.minY) < 1 && abs(f.height - target.height) < 1
        }
        if landed || tries >= 60 {
            putCardHome()
            onDidCollapseGifSearch()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.homeWhenPanelLands(gen: gen, target: target, tries: tries + 1)
        }
    }

    /// Back in the panel, square, keyboard background, no extra window or overlay left behind.
    private func putCardHome() {
        UIView.performWithoutAnimation {
            backdrop.isHidden = true
            cardView.layer.cornerRadius = 0
            if cardView.superview !== self { addSubview(cardView) }
            cardView.frame = bounds
            layoutCardSubviews()
            cardView.layoutIfNeeded()
        }
        searchOverlay?.removeFromSuperview()
        searchOverlay = nil
        collapseWindow?.isHidden = true
        collapseWindow = nil
    }

    /// No animation: the chat is leaving, the panel is going, or the field was resigned from outside.
    /// Also ends a grow at once (no animation).
    func tearDownSearchOverlay() {
        if slidingAway { return }   // the slide-down puts the card home itself when it lands
        transitionGen += 1
        let was = searchingGifs
        let wasGrown = expansionLive
        if wasGrown { dropExpansionState() }
        searchingGifs = false
        gifGrid.setSearching(false)
        if gifGrid.searchField.isFirstResponder {
            _ = gifGrid.searchField.resignFirstResponder()
        }
        guard was || wasGrown || cardView.superview !== self else { return }
        putCardHome()
    }

    // MARK: Drag to grow / shrink (owner 2026-10-18, see the note on `onExpansionLift`)

    /// The pan may start here: vertical, the panel at rest or grown (never mid GIF search or editing);
    /// on a grid only DOWN, only when that grid is at its top, only while grown; elsewhere (strip, tab
    /// band, the GIF search pill) up from rest or down from grown.
    fileprivate func expandShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard !searchingGifs, !editing, !slidingAway, !dragInFlight else { return false }
        if cardView.superview === self {
            guard window != nil, hostWindow() != nil else { return false }
        } else {
            guard expansionLive else { return false }
        }
        let v = pan.velocity(in: cardView)
        guard abs(v.y) > abs(v.x) else { return false }
        let grown = currentLift() > 0.5
        let p = pan.location(in: cardView)
        // The tab band at the foot is its own row (see `hitTest`), even where the grid runs under it.
        let inBand = !headerHidden && !tabs.isHidden && tabs.alpha > 0.01 && p.y >= tabGlass.frame.minY - 10
        var hit = inBand ? nil : cardView.hitTest(p, with: nil)
        while let h = hit, h !== cardView {
            if let s = h as? UIScrollView, s === grid || s === gifGrid.scrollView {
                let atTop = s.contentOffset.y <= -s.adjustedContentInset.top + 1
                return grown && atTop && v.y > 0
            }
            hit = h.superview
        }
        return grown ? v.y > 0 : v.y < 0
    }

    // ⛔ THE BAR DRAGS THE PANEL TOO — owner 2026-10-19 (build 979, "does not support resizing"). The
    // reference app's grow pan sits on the container holding BOTH its message bar and the panel, so a
    // drag on the bar (the field, when its text does not scroll) grows / shrinks it. Ours lived only on
    // the card, whose bands hide on scroll, so most drags never reached it. The composer owns a second
    // pan and hands it here: same rules as a drag from the band, same handler.
    /// May a drag on the composer's bar start a grow (up from rest) or a shrink (down from grown)?
    func barPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard !searchingGifs, !editing, !slidingAway, !dragInFlight else { return false }
        if cardView.superview === self {
            guard window != nil, hostWindow() != nil else { return false }
        } else {
            guard expansionLive else { return false }
        }
        let v = pan.velocity(in: nil)
        guard abs(v.y) > abs(v.x) else { return false }
        return currentLift() > 0.5 ? v.y > 0 : v.y < 0
    }

    /// The composer's bar pan, driven exactly like the card's own.
    func barPanned(_ pan: UIPanGestureRecognizer) { expandPanned(pan) }

    /// The grids and the strip wait for this pan to fail, the way theirs makes every pan inside wait.
    fileprivate func expandShouldWait(for other: UIGestureRecognizer) -> Bool {
        guard other is UIPanGestureRecognizer, let sv = other.view as? UIScrollView else { return false }
        return sv.isDescendant(of: cardView)
    }

    /// The lift as drawn: a settle stopped half way leaves the card's frame where it was.
    private func currentLift() -> CGFloat {
        guard expansionLive, restCardFrame.height > 0 else { return 0 }
        return max(0, cardView.frame.height - restCardFrame.height)
    }

    @objc private func expandPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            dragInFlight = true
            if let a = expandAnimator {
                // Caught mid-settle: stop where it is drawn and carry on from there.
                expandAnimator = nil
                a.stopAnimation(true)
            }
            if cardView.superview === self {
                guard liftCardForExpansion() else { return }
            }
            lift = currentLift()
            liftAtStart = lift
        case .changed:
            guard expansionLive else { return }
            // Screen space: the card changes window on the way out, both windows fill the screen.
            let ty = pan.translation(in: nil).y
            applyLift(min(liftRange, max(0, liftAtStart - ty)))
        case .ended, .cancelled, .failed:
            dragInFlight = false
            guard expansionLive else { return }
            // Their rule: a quarter of the way from where the drag began decides; short of that the
            // panel goes back. Theirs reads a velocity that is always zero; a real flick (600 pt/s)
            // counts here, so a short fast swipe is not lost.
            let moved = lift - liftAtStart
            let vy = pan.velocity(in: nil).y
            let open: Bool
            if abs(moved) > liftRange * 0.25 { open = moved > 0 }
            else if abs(vy) > 600 { open = vy < 0 }
            else { open = liftAtStart >= liftRange * 0.5 }
            settleExpansion(open: open)
        default:
            break
        }
    }

    /// Takes the card out of the keyboard into a window above it, exactly over the panel.
    private func liftCardForExpansion() -> Bool {
        guard let hostWin = hostWindow() ?? window, let scene = hostWin.windowScene else { return false }
        let restH = bounds.height > 0 ? bounds.height : height
        let winB = hostWin.bounds
        restCardFrame = CGRect(x: 0, y: winB.height - restH, width: winB.width, height: restH)
        let composerTop = composerTopInWindow() ?? (restCardFrame.minY - 56)
        chromeH = max(0, restCardFrame.minY - composerTop)
        // Theirs: screen minus max(status bar, safe top) minus 10 minus the composer. Here the chat's
        // navigation bar stays visible (theirs pushes the whole chat back as a sheet), so the bar
        // stops 10 pt under whichever is lower.
        let statusH = scene.statusBarManager?.statusBarFrame.height ?? 0
        let ceiling = max(hostWin.safeAreaInsets.top, statusH, expansionCeilingInWindow() ?? 0)
        liftRange = max(0, composerTop - (ceiling + 10))
        guard liftRange > 40 else { return false }

        let maxLevel = scene.windows.map(\.windowLevel.rawValue).max() ?? 10_000_001
        let cw = PassthroughWindow(windowScene: scene)
        cw.frame = winB
        cw.windowLevel = UIWindow.Level(rawValue: maxLevel + 1)
        cw.backgroundColor = .clear
        cw.overrideUserInterfaceStyle = hostWin.overrideUserInterfaceStyle
        cw.targetView = cardView
        cw.onTouch = { [weak self] in self?.onTouch() }
        expandDim.alpha = 0
        expandDim.frame = CGRect(x: 0, y: 0, width: winB.width, height: max(0, composerTop))
        cw.addSubview(expandDim)
        cw.isHidden = false
        collapseWindow?.isHidden = true
        collapseWindow = cw

        transitionGen += 1
        expansionLive = true
        lift = 0
        backdrop.isHidden = false
        UIView.performWithoutAnimation {
            cw.addSubview(cardView)
            cardView.frame = restCardFrame
            layoutCardSubviews()
            cardView.layoutIfNeeded()
        }
        return true
    }

    /// One height for everything that follows it: the card, its corners, the dim, the composer.
    private func applyLift(_ l: CGFloat) {
        lift = l
        let f = restCardFrame
        let frac = liftRange > 0 ? min(1, l / liftRange) : 0
        cardView.frame = CGRect(x: f.minX, y: f.minY - l, width: f.width, height: f.height + l)
        cardView.layer.cornerRadius = 10 * frac
        expandDim.alpha = frac
        expandDim.frame.size.height = max(0, f.minY - chromeH - l)
        layoutCardSubviews()
        onExpansionLift(l)
    }

    private func settleExpansion(open: Bool) {
        let target = open ? liftRange : 0
        let a = UIViewPropertyAnimator(duration: MediaOpen.storyEditorDuration, timingParameters: MediaOpen.storyEditorCurve)
        a.addAnimations {
            self.applyLift(target)
            self.cardView.layoutIfNeeded()
        }
        a.addCompletion { [weak self, weak a] pos in
            guard let self, let a, self.expandAnimator === a else { return }
            self.expandAnimator = nil
            if pos == .end, target == 0 { self.finishExpansionHome() }
        }
        expandAnimator?.stopAnimation(true)
        expandAnimator = a
        a.startAnimation()
    }

    /// Back at the keyboard's height: the card goes home into the panel, which never moved.
    private func finishExpansionHome() {
        guard expansionLive else { return }
        dropExpansionState()
        putCardHome()
    }

    /// The grow's own state, nothing moved: the caller puts the card where it belongs.
    private func dropExpansionState() {
        if let a = expandAnimator {
            expandAnimator = nil
            a.stopAnimation(true)
        }
        expansionLive = false
        lift = 0
        expandDim.removeFromSuperview()
        onExpansionLift(0)
    }

    /// A sticker or GIF was sent from the grown panel: back to the keyboard's height (theirs calls
    /// `collapseInput` in the send's own update).
    func collapseExpansion() {
        guard expansionLive, !slidingAway else { return }
        settleExpansion(open: false)
    }

    /// GIF search starts from the grown panel. The search page covers the composer, which goes
    /// back down behind it; the card itself is moved on by `expandForGifSearch`.
    private func endExpansionForSearch() {
        if let a = expandAnimator {
            expandAnimator = nil
            a.stopAnimation(true)
        }
        expansionLive = false
        lift = 0
        expandDim.removeFromSuperview()
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.onExpansionLift(0)
        }
    }

    /// The keys are going (a tap on the chat, the keyboard button) while grown: the card slides down
    /// off the screen with them and the composer comes down with it, instead of snapping. The panel
    /// may already be out of the keyboard by then; the card goes home once it is out of sight.
    func slideExpansionAway() {
        guard expansionLive, !slidingAway else { return }
        if let a = expandAnimator {
            expandAnimator = nil
            a.stopAnimation(true)
        }
        expansionLive = false
        slidingAway = true
        let f = cardView.frame
        let bottom = cardView.superview?.bounds.height ?? (f.maxY + f.height)
        let a = UIViewPropertyAnimator(duration: MediaOpen.storyEditorDuration, timingParameters: MediaOpen.storyEditorCurve)
        a.addAnimations {
            self.cardView.frame = CGRect(x: f.minX, y: bottom, width: f.width, height: f.height)
            self.expandDim.alpha = 0
            self.onExpansionLift(0)
        }
        a.addCompletion { [weak self] _ in
            guard let self else { return }
            self.slidingAway = false
            self.lift = 0
            self.expandDim.removeFromSuperview()
            // Never left floating: home (and the grow window hidden) whatever happened meanwhile.
            guard !self.searchingGifs else { return }
            self.putCardHome()
        }
        a.startAnimation()
    }

    // MARK: Data

    @objc private func catalogChanged() {
        guard !editing else { return }   // the Delete bar's ticks would lose their rows
        reload()
    }

    @objc private func artArrived() {
        for ip in grid.indexPathsForVisibleItems {
            guard !isCreate(ip), let st = sticker(at: ip), let c = grid.cellForItem(at: ip) as? StickerCell else { continue }
            let px = Int(itemSide * min(UIScreen.main.scale, 2))
            c.show(url: StickerStore.shared.fileURL(for: st), pixelSize: px)
        }
        buildStrip()
    }

    @MainActor func reload() {
        let store = StickerStore.shared
        var s: [Section] = [Section(shelf: .recents, stickers: store.recents)]
        if !store.favorites.isEmpty { s.append(Section(shelf: .favorites, stickers: store.favorites)) }
        for p in store.packs { s.append(Section(shelf: .pack(p), stickers: p.stickers)) }
        sections = s
        let anyMine = !store.recents.isEmpty || !store.favorites.isEmpty
        editButton.isHidden = !anyMine || tabs.selectedSegmentIndex == 0 || !AppFeatures.stickerEdit
        if editing && !anyMine { endEditing() }
        grid.reloadData()
        buildStrip()
    }

    private func isCreate(_ ip: IndexPath) -> Bool { sections[ip.section].shelf == .recents && ip.item == 0 }

    private func sticker(at ip: IndexPath) -> Sticker? {
        let sec = sections[ip.section]
        let i = sec.shelf == .recents ? ip.item - 1 : ip.item
        return sec.stickers.indices.contains(i) ? sec.stickers[i] : nil
    }

    // MARK: Pack strip

    private func buildStrip() {
        stripButtons.forEach { $0.removeFromSuperview() }
        stripButtons = []
        for (i, sec) in sections.enumerated() {
            let b = UIButton(type: .system)
            b.tag = i
            b.tintColor = .secondaryLabel
            switch sec.shelf {
            case .recents:
                b.setImage(UIImage(named: "ic_clock_outline")?.withRenderingMode(.alwaysTemplate), for: .normal)   // his icon (owner 2026-10-18)
                b.accessibilityLabel = "Recently Used"
            case .favorites:
                // His icon (owner 2026-10-18), not the system star.
                b.setImage(UIImage(named: "ic_star_outline")?.withRenderingMode(.alwaysTemplate), for: .normal)
                b.accessibilityLabel = "Favorites"
            case .pack(let p):
                let player = StickerPlayerView()
                player.frame = CGRect(x: M.stripInset, y: M.stripInset,
                                      width: M.stripCell - 2 * M.stripInset, height: M.stripCell - 2 * M.stripInset)
                let px = Int((M.stripCell - 2 * M.stripInset) * min(UIScreen.main.scale, 2))
                player.setSticker(url: p.stickers.first.flatMap { StickerStore.shared.fileURL(for: $0) }, pixelSize: px)
                b.addSubview(player)   // still: the strip never animates
                b.accessibilityLabel = p.title
            }
            b.layer.cornerRadius = 10
            b.addTarget(self, action: #selector(stripTapped(_:)), for: .touchUpInside)
            strip.addSubview(b)
            stripButtons.append(b)
        }
        layoutStrip()
        markedStrip = -1
        markStrip(0)
    }

    private func layoutStrip() {
        var x: CGFloat = 0
        let y = (M.stripH - M.stripCell) / 2
        for b in stripButtons {
            b.frame = CGRect(x: x, y: y, width: M.stripCell, height: M.stripCell)
            x += M.stripCell + M.stripSpacing
        }
        if stripButtons.indices.contains(markedStrip) {
            stripHighlight.frame = stripButtons[markedStrip].frame.insetBy(dx: 4, dy: 4)
        }
        strip.contentSize = CGSize(width: x - M.stripSpacing, height: M.stripH)
    }

    private var markedStrip = -1
    /// One small highlight that slides between packs (owner 2026-10-17: the full-cell one looked big).
    private let stripHighlight: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        v.layer.cornerRadius = 9
        v.layer.cornerCurve = .continuous
        v.isUserInteractionEnabled = false
        return v
    }()
    private func markStrip(_ i: Int) {
        guard i != markedStrip else { return }
        let first = markedStrip < 0
        markedStrip = i
        if stripHighlight.superview !== strip { strip.insertSubview(stripHighlight, at: 0) }
        if stripButtons.indices.contains(i) {
            let to = stripButtons[i].frame.insetBy(dx: 4, dy: 4)
            if first { stripHighlight.frame = to }
            else { UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.stripHighlight.frame = to } }
        }
        if stripButtons.indices.contains(i) {
            strip.scrollRectToVisible(stripButtons[i].frame.insetBy(dx: -M.side, dy: 0), animated: true)
        }
    }

    @objc private func stripTapped(_ b: UIButton) {
        let sec = b.tag
        guard sections.indices.contains(sec) else { return }
        let ip = IndexPath(item: 0, section: sec)
        if let a = grid.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: ip),
           a.frame.height > 0 {
            let maxY = max(0, grid.contentSize.height - grid.bounds.height + grid.contentInset.bottom)
            grid.setContentOffset(CGPoint(x: 0, y: min(a.frame.minY, maxY)), animated: false)
        } else if grid.numberOfItems(inSection: sec) > 0 {
            grid.scrollToItem(at: ip, at: .top, animated: false)
        }
        markStrip(sec)
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv === grid else { return }
        let top = grid.indexPathsForVisibleItems.min()
        if let s = top?.section { markStrip(s) }
        // ⛔ THE TABS AND THE PACK STRIP GET OUT OF THE WAY — owner 2026-10-17: scrolling into the
        // stickers hides them, scrolling back shows them. Only a drag moves them, so a layout pass or
        // the strip's own jump never flickers them.
        guard sv.isTracking || sv.isDecelerating else { lastY = sv.contentOffset.y; return }
        let y = sv.contentOffset.y, dy = y - lastY
        lastY = y
        if y <= 0 { setHeaderHidden(false) }
        else if dy > 6 { setHeaderHidden(true) }
        else if dy < -6 { setHeaderHidden(false) }
    }

    private var lastY: CGFloat = 0
    private var headerHidden = false

    private func setHeaderHidden(_ hide: Bool) {
        guard hide != headerHidden else { return }
        headerHidden = hide
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutCardSubviews()
        }
    }

    // MARK: Tabs

    /// GIFs show in the panel itself now (owner 2026-10-17), search included (2026-10-18).
    /// ⛔ THE SWITCH'S WHOLE ROW IS ITS OWN — owner 2026-10-18: reaching for GIFs / Stickers sent the
    /// sticker under his finger. The reference app's panel keeps its bottom tab band out of the grid:
    /// a touch anywhere across that band, edge to edge, belongs to the band. Here the band is the
    /// switch's glass grown 10 pt on top and down to the foot; inside it a touch goes to the switch
    /// (with some room around it) or nowhere, never through to a sticker.
    /// Only while the card is home: its frames are then the panel's own coordinates. While it is out
    /// for GIF search the panel is empty and the card's window takes the touches.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if cardView.superview === self, !searchingGifs,
           !headerHidden, !editing, !tabs.isHidden, tabs.alpha > 0.01, point.y >= tabGlass.frame.minY - 10 {
            if tabs.frame.insetBy(dx: -12, dy: -10).contains(point) {
                // Land on the control at the nearest point, so a touch just beside it still switches.
                let p = CGPoint(x: min(max(point.x, tabs.frame.minX + 1), tabs.frame.maxX - 1), y: tabs.frame.midY)
                return tabs.hitTest(convert(p, to: tabs), with: event) ?? tabs
            }
            // The card, not the panel: still no sticker, but the drag-to-grow pan (on the card) sees
            // a drag that starts in the band, as theirs does across its whole panel (2026-10-18).
            return cardView
        }
        return super.hitTest(point, with: event)
    }

    /// The pill on the chosen half of the switch, set while the transform is identity (bounds-based).
    private func layoutTabThumb() {
        let half = tabs.bounds.width / 2
        let x = tabs.center.x - half + (tabs.selectedSegmentIndex == 0 ? 0 : half)
        tabThumb.bounds = CGRect(x: 0, y: 0, width: half, height: tabs.bounds.height).insetBy(dx: 1, dy: 1)
        tabThumb.center = CGPoint(x: x + half / 2, y: tabs.center.y)
        tabThumb.layer.cornerRadius = tabThumb.bounds.height / 2
    }

    @objc private func tabChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.layoutTabThumb() }
        let gifsOn = tabs.selectedSegmentIndex == 0
        if gifsOn { if editing { endEditing() }; gifGrid.loadIfNeeded() }
        UIView.transition(with: cardView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.gifGrid.isHidden = !gifsOn
            self.grid.isHidden = gifsOn
            self.strip.isHidden = gifsOn
            self.editButton.isHidden = gifsOn || (StickerStore.shared.recents.isEmpty && StickerStore.shared.favorites.isEmpty)
                || !AppFeatures.stickerEdit
        }
        setNeedsLayout()
    }

    // MARK: Editing

    @objc private func editTapped() {
        if editing { endEditing() } else { beginEditing() }
    }

    /// "Edit" / "Done" in a small Liquid Glass capsule (owner 2026-10-18: words, not the pen).
    private func setPen() {
        var c = UIButton.Configuration.plain()
        c.title = editing ? "Done" : "Edit"
        c.baseForegroundColor = editing ? .systemBlue : .label
        c.contentInsets = .zero
        c.titleLineBreakMode = .byClipping
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = .systemFont(ofSize: 15, weight: .semibold); return a
        }
        // No cross-fade between the two words: one title, swapped in place.
        UIView.performWithoutAnimation {
            editButton.configuration = c
            editButton.layoutIfNeeded()
        }
        editButton.accessibilityLabel = editing ? "Done" : "Edit stickers"
        if editGlass.superview !== editButton { editButton.insertSubview(editGlass, at: 0) }
    }

    private func beginEditing() {
        editing = true
        picked = []
        deleteBar.isHidden = false
        setPen()
        updateDeleteButton()
        setNeedsLayout()
        refreshChecks()
    }

    private func endEditing() {
        editing = false
        picked = []
        deleteBar.isHidden = true
        setPen()
        setNeedsLayout()
        refreshChecks()
    }

    /// The pen only turns the tick circles on or off. A full reload re-decoded every sticker on screen,
    /// which read as a flash (owner 2026-10-18); cells scrolled in later get the state in cellForItemAt.
    private func refreshChecks() {
        for ip in grid.indexPathsForVisibleItems {
            guard !isCreate(ip), let s = sticker(at: ip), let c = grid.cellForItem(at: ip) as? StickerCell else { continue }
            let shelf = sections[ip.section].shelf
            c.setChecking(editing && shelf.editable, on: picked.contains("\(shelf.key)|\(s.id)"))
        }
    }

    private func updateDeleteButton() {
        deleteButton.setTitle(picked.isEmpty ? "Delete" : "Delete (\(picked.count))", for: .normal)
        deleteButton.isEnabled = !picked.isEmpty
    }

    /// Recents lose the sticker from Recents only; Favorites lose it (and its file, for one I made).
    @objc @MainActor private func deleteTapped() {
        guard editing, !picked.isEmpty else { return }
        let ids = { (k: String) in Set(self.picked.filter { $0.hasPrefix(k + "|") }.map { String($0.dropFirst(2)) }) }
        let recents = ids(Shelf.recents.key), favorites = ids(Shelf.favorites.key)
        if !recents.isEmpty { StickerStore.shared.removeFromRecents(recents) }
        if !favorites.isEmpty { StickerStore.shared.removeFavorites(favorites) }
        endEditing()
        reload()
    }

    // MARK: Grid

    func numberOfSections(in cv: UICollectionView) -> Int { sections.count }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        sections[s].stickers.count + (sections[s].shelf == .recents ? 1 : 0)
    }

    private var itemSide: CGFloat {
        let w = grid.bounds.width > 0 ? grid.bounds.width : bounds.width
        let cols = max(5, Int((w + M.spacing) / (M.item + M.spacing)))
        let side = (w - 2 * M.side - CGFloat(cols - 1) * M.spacing) / CGFloat(cols)
        return floor(min(M.item, max(1, side)))
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        CGSize(width: itemSide, height: itemSide)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        minimumInteritemSpacingForSectionAt s: Int) -> CGFloat { M.spacing }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt s: Int) -> CGFloat { M.row }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        insetForSectionAt s: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: 0, left: M.side, bottom: s == sections.count - 1 ? 8 : M.packGap, right: M.side)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection s: Int) -> CGSize {
        // Recently Used with nothing in it keeps only its Create tile, no title.
        if sections[s].shelf == .recents && sections[s].stickers.isEmpty { return .zero }
        return CGSize(width: cv.bounds.width, height: M.header)
    }

    func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at ip: IndexPath) -> UICollectionReusableView {
        let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ShelfHeader.id, for: ip) as! ShelfHeader
        let shelf = sections[ip.section].shelf
        h.title.text = shelf.title
        h.edit.isHidden = true   // the one pen beside the tabs edits every shelf (2026-10-17)
        return h
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: StickerCell.id, for: ip) as! StickerCell
        if isCreate(ip) {
            c.showCreate()
            return c
        }
        guard let s = sticker(at: ip) else { return c }
        let px = Int(itemSide * min(UIScreen.main.scale, 2))
        c.show(url: StickerStore.shared.fileURL(for: s), pixelSize: px)
        let shelf = sections[ip.section].shelf
        c.setChecking(editing && shelf.editable, on: picked.contains("\(shelf.key)|\(s.id)"))
        c.accessibilityLabel = "Sticker \(s.emoji)"
        return c
    }

    /// Long press (owner 2026-10-17): Add to / Remove from Favorites on every sticker; Delete only on one
    /// I made — the packs are everyone's and cannot be deleted.
    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !editing, let ip = ips.first, !isCreate(ip), let s = sticker(at: ip) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            MainActor.assumeIsolated {
                let store = StickerStore.shared
                var items: [UIMenuElement] = []
                if store.isFavorite(s) {
                    items.append(UIAction(title: "Remove from Favorites", image: UIImage(systemName: "star.slash")) { [weak self] _ in
                        store.removeFavorites([s.id]); self?.reload()
                    })
                } else {
                    items.append(UIAction(title: "Add to Favorites", image: UIImage(systemName: "star")) { [weak self] _ in
                        store.addFavorite(s); self?.reload()
                    })
                }
                if s.source == .mine {
                    items.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        store.removeFavorites([s.id]); store.removeFromRecents([s.id]); self?.reload()
                    })
                }
                return UIMenu(children: items)
            }
        }
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        (cell as? StickerCell)?.player.play()
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        (cell as? StickerCell)?.player.stop()
    }

    @MainActor func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: false)
        if isCreate(ip) {
            if !editing { onCreate() }
            return
        }
        guard let s = sticker(at: ip) else { return }
        if editing {
            let shelf = sections[ip.section].shelf
            guard shelf.editable else { return }
            let k = "\(shelf.key)|\(s.id)"
            if picked.contains(k) { picked.remove(k) } else { picked.insert(k) }
            (cv.cellForItem(at: ip) as? StickerCell)?.setChecking(true, on: picked.contains(k))
            updateDeleteButton()
            return
        }
        // Recents move on the next showing, not under the finger.
        StickerStore.shared.noteUsed(s)
        onSend(s)
        collapseExpansion()   // a send from the grown panel shrinks it back (theirs: `collapseInput`)
    }
}

// MARK: - Cells

private final class StickerCell: UICollectionViewCell {
    static let id = "StickerCell"
    let player = StickerPlayerView()
    private let plus = UIImageView(image: UIImage(systemName: "plus",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)))
    private let check = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(player)
        plus.tintColor = .secondaryLabel
        plus.contentMode = .center
        contentView.addSubview(plus)
        check.contentMode = .scaleAspectFit
        contentView.addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        player.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
        plus.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
        check.frame = CGRect(x: contentView.bounds.width - 22, y: contentView.bounds.height - 22, width: 20, height: 20)
    }

    func showCreate() {
        player.setSticker(url: nil, pixelSize: 0)
        player.isHidden = true
        plus.isHidden = false
        plus.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        plus.layer.cornerRadius = 14
        plus.layer.cornerCurve = .continuous
        plus.clipsToBounds = true
        check.isHidden = true
        accessibilityLabel = "Create Sticker"
        isAccessibilityElement = true
    }

    func show(url: URL?, pixelSize: Int) {
        player.isHidden = false
        plus.isHidden = true
        player.setSticker(url: url, pixelSize: pixelSize)
        isAccessibilityElement = true
    }

    func setChecking(_ on: Bool, on picked: Bool) {
        check.isHidden = !on
        check.image = UIImage(systemName: picked ? "checkmark.circle.fill" : "circle")
        check.tintColor = picked ? .systemBlue : .white
        check.backgroundColor = picked ? .white : UIColor.black.withAlphaComponent(0.25)
        check.layer.cornerRadius = 10
        check.clipsToBounds = true
        player.alpha = on && !picked ? 0.75 : 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        player.stop()
        check.isHidden = true
        player.alpha = 1
    }
}

private final class ShelfHeader: UICollectionReusableView {
    static let id = "ShelfHeader"
    let title = UILabel()
    let edit = UIButton(type: .system)
    var onEdit: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabel
        addSubview(title)
        edit.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        edit.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        addSubview(edit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 14, y: 0, width: bounds.width - 100, height: bounds.height)
        edit.frame = CGRect(x: bounds.width - 70, y: 0, width: 60, height: bounds.height)
        edit.contentHorizontalAlignment = .right
    }

    @objc private func editTapped() { onEdit() }
}

/// The app-window layer the card grows in during GIF search: touches on the card only, the rest of
/// the screen behind it stays the chat's.
private final class PassthroughOverlayView: UIView {
    weak var targetView: UIView?
    var onTouch: () -> Void = {}
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = targetView else { return nil }
        let p = convert(point, to: target)
        guard target.bounds.contains(p) else { return nil }
        onTouch()
        return super.hitTest(point, with: event)
    }
}

/// The drag-to-grow pan's rules live on the panel; this only forwards. A separate object because
/// `gestureRecognizerShouldBegin(_:)` is also a UIView method, which the panel must not override.
@MainActor private final class ExpandPanDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: StickerKeyboardView?
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, let owner else { return false }
        return owner.expandShouldBegin(pan)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        owner?.expandShouldWait(for: other) ?? false
    }
}

/// The window above the keyboard the card shrinks back down in; same pass-through rule.
private final class PassthroughWindow: UIWindow {
    weak var targetView: UIView?
    var onTouch: () -> Void = {}
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = targetView else { return nil }
        let p = convert(point, to: target)
        guard target.bounds.contains(p) else { return nil }
        onTouch()
        return super.hitTest(point, with: event)
    }
}
