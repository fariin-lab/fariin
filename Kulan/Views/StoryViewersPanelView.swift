import SwiftUI
import UIKit

/// ONE STORY'S VIEWERS PANEL, AS A REAL VIEW THAT CAN EXIST MORE THAN ONCE.
///
/// WHY THIS TYPE EXISTS. The sheet used to hold exactly one of everything a viewers list is made of
/// — one table, one search field, one tab pair, one `viewers` array, one `filtered` array, one
/// `tab` index, one friends set — all of them stored directly on `StoryViewersSheetView`, which was
/// also the table's own data source. So there could only ever be ONE panel. That is the whole
/// reason the sideways transition had to photograph something: to show two sheets at once with one
/// panel, the departing one became a `snapshotView` and the real panel was re-pointed at the
/// neighbour's list mid-drag. A photograph cannot scroll, cannot answer a touch, cannot finish a
/// fetch that lands while it is on screen, and is blank if the panel had not drawn since its
/// contents were last cleared.
///
/// The reference app never had that problem because its list is a component keyed by story id
/// (`viewLists: [StoryId: ViewList]`), so it simply builds the neighbour's real list beside the
/// current one and moves both. This type is that: everything a viewers list needs, owned per story,
/// so the sheet can hold three of them and slide the strip.
///
/// WHAT THE SHEET KEEPS: the sheet's height (`progress`/`expand`), every gesture, and the sideways
/// geometry. Those are properties of the SHEET, not of a list, and duplicating them per panel is
/// what would make two panels drift apart.
final class StoryViewersPanelView: UIView {

    /// The story this panel is showing. Set once, at build time — a panel is never re-pointed at a
    /// different story, which is the property that makes the neighbour real.
    let storyId: String

    /// Where this panel sits in the strip, in whole panel widths: 0 is the one on screen, -1 the
    /// previous story's, +1 the next story's. The sheet writes it; a panel left over from an
    /// interrupted page (two stories back) keeps whatever it was last shifted to, exactly as the
    /// reference app's `indexDistance` leaves a stale list parked off to the side.
    var slot: CGFloat = 0

    // MARK: Up to the sheet

    var onSendMessage: ((StoryViewerInfo) -> Void)?
    var onOpenProfile: ((StoryViewerInfo) -> Void)?
    var onBlock: ((StoryViewerInfo) -> Void)?
    /// Search gained focus (true) or left it with nothing typed (false). The sheet answers by
    /// growing to the full stop or stepping back to half — that is the SHEET's height, so the sheet
    /// owns it and the panel only reports what happened to its own field.
    var onSearchActive: ((Bool) -> Void)?
    /// Asked on every scroll event: is the sheet itself the thing that owns the current drag? While
    /// it is, the list must not rubber-band upward past its top underneath it.
    var shouldPinScroll: (() -> Bool)?

    // MARK: Contents

    var viewers: [StoryViewerInfo] = [] {
        didSet {
            // A NEW LIST IS A NEW READ OF WHO MY FRIENDS ARE. The set is read once and then kept,
            // so without this the Friends tab would answer with whatever the conversation list said
            // the first time that tab was opened. Cleared before the filter runs, never after.
            friendUids = []
            applyFilter()
        }
    }

    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            loadingView.isHidden = !isLoading
            updateEmptyState()
        }
    }

    /// WHAT THIS STORY'S AUDIENCE WAS, AND WHETHER A SECOND TAB SAYS ANYTHING.
    ///
    /// The owner's 2026-08-08 rule, in his words: Everyone shows Everyone plus Friends; My Friends
    /// shows only the friends tab; a custom list shows only that list's name; View Once shows only
    /// View Once. So the row never disappears — it always names the audience — and it only ever
    /// offers a CHOICE for a story that went to Everyone, because that is the only audience whose
    /// viewers can be a mix of friends and strangers.
    ///
    /// PER PANEL, which is the point: two stories side by side can have gone to two different
    /// audiences, and the incoming one arrives already wearing its own.
    var audience: (title: String, bothTabs: Bool) = ("All Viewers", true) {
        didSet {
            // Field by field rather than as a tuple: this is written on every host pass, so the
            // no-change case has to be cheap and certain, and tuple `!=` on a LABELLED tuple is the
            // kind of thing that resolves differently than it reads.
            guard audience.title != oldValue.title || audience.bothTabs != oldValue.bothTabs
            else { return }
            applyAudienceTabs()
        }
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

    // MARK: What the sheet's gestures need from the list

    /// How far the list is scrolled. The sheet's vertical drag hands movement to the list once this
    /// is off zero, and takes it back when the list has come home.
    var scrollOffsetY: CGFloat { table.contentOffset.y }
    func pinScrollToTop() { table.contentOffset.y = 0 }
    var isSearchFocused: Bool { search.isFirstResponder }
    func endSearchEditing() { search.resignFirstResponder() }

    // MARK: Init

    init(storyId: String) {
        self.storyId = storyId
        super.init(frame: .zero)
        // ALWAYS DARK (owner 2026-08-05: "search in viewer plz make it dark mode always"). Inherited
        // from the sheet in practice, set here as well so a panel is correct on its own terms — the
        // SYSTEM pieces (the search field's text, placeholder, loupe and cursor, the table's scroll
        // indicator) resolve from the interface style and came out light-on-light without it.
        overrideUserInterfaceStyle = .dark
        backgroundColor = UIColor(white: 0.10, alpha: 1)
        // Apple's sheet corner, one number for both of this app's hand-built sheets — see
        // `Theme.sheetCorner`. It was a 24 of this panel's own while the sticker tray next door
        // stood at 32, and 24 is what he circled.
        layer.cornerRadius = Theme.sheetCorner
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        buildHierarchy()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildHierarchy() {
        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        grabber.layer.cornerRadius = 2.5
        addSubview(grabber)

        // Placeholder titles only: `audience` is written by the sheet the moment this is built and
        // `applyAudienceTabs` puts the real ones in.
        configureTab(allTab, allTabTitle, selected: true)
        configureTab(friendsTab, "Friends", selected: false)
        allTab.addTarget(self, action: #selector(pickAll), for: .touchUpInside)
        friendsTab.addTarget(self, action: #selector(pickFriends), for: .touchUpInside)
        underline.backgroundColor = .white
        underline.layer.cornerRadius = 1
        addSubview(allTab); addSubview(friendsTab); addSubview(underline)

        search.placeholder = "Search"
        search.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        search.textColor = .white
        search.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        // The keyboard says SEARCH (his ask — the default return key said nothing useful), and
        // return only lowers the keyboard: the query and the expanded sheet stay.
        search.returnKeyType = .search
        search.delegate = self
        // Focus grows the sheet, leaving with an empty query shrinks it — both are the SHEET's
        // height, so both are reported upward rather than done here.
        search.addTarget(self, action: #selector(searchBegan), for: .editingDidBegin)
        search.addTarget(self, action: #selector(searchEnded), for: .editingDidEnd)
        addSubview(search)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 64
        table.contentInsetAdjustmentBehavior = .never
        // The bounce is what fought the collapse drag in the SwiftUI version and had to be switched
        // off there. It can stay on here: the sheet's pan only takes the movement when the list is
        // genuinely at its top, so the two never claim the same pixels.
        table.alwaysBounceVertical = true
        table.register(UITableViewCell.self, forCellReuseIdentifier: "viewer")
        addSubview(table)

        loadingView.color = .white
        loadingView.hidesWhenStopped = false
        loadingView.startAnimating()
        loadingView.isHidden = true
        addSubview(loadingView)

        emptyLabel.text = "No views yet"
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    // MARK: Tabs

    /// THE FIRST TAB IS ALWAYS THE AUDIENCE'S OWN NAME, which makes the whole rule one sentence: the
    /// first tab names who this story went to, and the second exists only when that was Everyone.
    private var allTabTitle: String { audience.title }

    private func applyAudienceTabs() {
        // A HIDDEN FRIENDS TAB MUST NOT LEAVE ITS FILTER ON — a story whose audience has no second
        // tab would otherwise show its list still narrowed, under a tab that is not on screen to
        // say so.
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

    private func configureTab(_ b: UIButton, _ title: String, selected: Bool) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
        b.setTitleColor(selected ? .white : UIColor.white.withAlphaComponent(0.5), for: .normal)
    }

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

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        grabber.frame = CGRect(x: (w - 38) / 2, y: 8, width: 38, height: 5)

        let tabY: CGFloat = 25
        allTab.sizeToFit()
        friendsTab.sizeToFit()
        allTab.frame = CGRect(x: 18, y: tabY, width: allTab.bounds.width, height: 26)
        friendsTab.frame = CGRect(x: allTab.frame.maxX + 24, y: tabY, width: friendsTab.bounds.width, height: 26)
        let active = tab == 0 ? allTab : friendsTab
        underline.frame = CGRect(x: active.frame.minX, y: allTab.frame.maxY + 4,
                                 width: active.bounds.width, height: 2)

        search.frame = CGRect(x: 16, y: underline.frame.maxY + 12, width: w - 32, height: 38)
        let top = search.frame.maxY + 10
        table.frame = CGRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
        loadingView.center = CGPoint(x: w / 2, y: top + 44)
        emptyLabel.frame = CGRect(x: 24, y: top + 40, width: w - 48, height: 22)
    }

    // MARK: Keyboard

    /// THE LIST MUST NOT RUN ON UNDER THE KEYBOARD.
    ///
    /// The table is laid out all the way down to the bottom of the panel and its
    /// `contentInsetAdjustmentBehavior` is `.never`, so nothing moves it out of the way by itself:
    /// with search focused the keyboard simply covered the last rows, which could then be neither
    /// read nor tapped. The one thing that changes here is the table's own bottom inset, which is
    /// what a scroll view is supposed to answer a keyboard with. The SHEET's height is left alone on
    /// purpose: its two resting heights are the reference app's and the host's settle maths is
    /// written against them, so making the keyboard a third one would put two height models on one
    /// drag.
    ///
    /// ⚠️ ONLY THE PANEL WHOSE FIELD IS FOCUSED ANSWERS. There are up to three of these alive at
    /// once now and the notification goes to all of them; a neighbour insetting its list for a
    /// keyboard it did not raise would arrive under the finger with a gap at the bottom.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        // A hide notification still carries a frame, and on some paths it is still the on-screen
        // one, so the hide case is answered with a flat zero rather than by measuring anything.
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        let overlap: CGFloat
        if hiding || !search.isFirstResponder {
            overlap = 0
        } else {
            // `from: nil` means the window, which is the space the keyboard frame is published in.
            let keyboardTop = convert(end, from: nil).minY
            let listBottom = convert(table.bounds, from: table).maxY
            overlap = max(0, listBottom - keyboardTop)
        }
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

    // MARK: Search + filter

    @objc private func searchChanged() { applyFilter() }
    @objc private func searchBegan() { onSearchActive?(true) }
    @objc private func searchEnded() {
        // Keyboard down with a live query keeps the tall sheet (results need the room);
        // down with an empty one has nothing to show and steps back to half.
        if (search.text ?? "").isEmpty { onSearchActive?(false) }
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
        // Reactions first, then most recent — the same order the SwiftUI sheet used, kept so the
        // list does not reorder itself the day this replaces it.
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

// MARK: - Search field

extension StoryViewersPanelView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
    /// The X is HIS exit: "when i click x button go back to small sheet" — and it is the only path
    /// that collapses, so backspacing a query to nothing never yanks the keyboard mid-thought
    /// (`textFieldShouldClear` fires for the clear BUTTON alone, never for typing).
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        textField.text = ""
        applyFilter()
        textField.resignFirstResponder()
        onSearchActive?(false)
        return false   // the clearing is done above; returning true would double-clear
    }
}

// MARK: - Table

extension StoryViewersPanelView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "viewer", for: indexPath)
        let v = filtered[indexPath.row]
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        // SwiftUI for the row's CONTENTS only. The avatar, its hashed letter fallback and the
        // reaction badge already exist and already look right; rebuilding them in UIKit would only
        // be a chance for the two to drift apart.
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
        if shouldPinScroll?() == true { scrollView.contentOffset.y = 0 }
    }
}
