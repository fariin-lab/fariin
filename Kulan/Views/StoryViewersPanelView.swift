import SwiftUI
import UIKit
import FirebaseFirestore

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
    /// Non-nil for exactly as long as a sideways page drag is in flight — see `freezeScroll`.
    private var frozenOffsetY: CGFloat?

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

    /// Reads kept failing (owner 2026-10-24: skeleton rows forever under a story reading 0). The
    /// skeleton gives way to a line that says so; the sheet keeps asking, and a list replaces it.
    var loadFailed = false {
        didSet {
            guard loadFailed != oldValue, !showingViewsOff else { return }
            emptyLabel.text = loadFailed ? "Couldn't load viewers. Trying again…" : "No views yet"
            setNeedsLayout()
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

    /// GROUP STORY (owner 2026-10-23, group stories v2, the reference app's group-story replies):
    /// non-nil turns the two tabs into "Views" and "Replies", and the second lists the story's
    /// shared reply thread instead of friends. The listener lives as long as this panel does.
    var groupId: String? {
        didSet {
            guard groupId != oldValue else { return }
            replyBox.reg?.remove()
            replyBox.reg = nil
            replies = []
            if groupId != nil {
                replyBox.reg = StoriesService.shared.listenGroupReplies(storyId: storyId) { [weak self] rows in
                    self?.replies = rows
                }
            }
            applyAudienceTabs()
        }
    }

    /// Members' door (owner 2026-10-23): only the Replies tab, no Views, for a group story that is
    /// not mine. Set before `groupId`.
    var repliesOnly = false {
        didSet { if repliesOnly != oldValue { applyAudienceTabs() } }
    }

    /// An admin who did not post it sees the Views tab without the row's "…" (owner 2026-10-23).
    var viewersReadOnly = false

    /// The composer at the foot of the Replies tab (owner 2026-10-23 mockup). Its "Reply" link on a
    /// row prefills "@name " here.
    private let composerModel = GroupReplyComposerModel()
    private lazy var composerHost: UIHostingController<GroupStoryReplyComposer> = {
        let h = UIHostingController(rootView: GroupStoryReplyComposer(
            model: composerModel,
            onSend: { [weak self] text, emoji in self?.sendReply(text: text, emoji: emoji) },
            onFocus: { [weak self] on in if on { self?.onSearchActive?(true) } },
            onResize: { [weak self] in self?.setNeedsLayout() }))
        h.safeAreaRegions = []   // laid out by frame; the keyboard lift is ours (`keyboardWillChange`)
        h.view.backgroundColor = .clear
        return h
    }()
    /// ⛔ THE OWNER AND ADMINS READ, THEY DO NOT ANSWER HERE (owner 2026-10-25: "they can see the
    /// comments but can't reply, don't show react and reply bar"). Only the members' door writes.
    private var canReplyHere: Bool { repliesOnly }
    private var composerVisible: Bool { isGroupStory && showingReplies && canReplyHere }
    /// How far the keyboard covers the panel's foot while the composer is being typed in.
    private var composerLift: CGFloat = 0
    private var lastReplyCount = 0

    private func sendReply(text: String, emoji: String) {
        let sid = storyId
        Task {
            do { try await StoriesService.shared.sendGroupReply(storyId: sid, text: text, emoji: emoji) }
            catch { await MainActor.run { UINotificationFeedbackGenerator().notificationOccurred(.error) } }
        }
    }

    private var replies: [GroupStoryReply] = [] {
        didSet {
            // The reference app opens on Replies when there are any. Once, and never over a tab
            // the person picked themselves.
            if !replies.isEmpty, !autoPickedReplies, !userPickedTab, isGroupStory, tab == 0 {
                autoPickedReplies = true
                tab = 1
                configureTab(allTab, allTabTitle, selected: false)
                configureTab(friendsTab, secondTabTitle, selected: true)
                setNeedsLayout()
            }
            applyFilter()
        }
    }
    private var filteredReplies: [GroupStoryReply] = []
    /// Removed in `deinit` by the box itself, and on leaving the sheet in `willMove(toSuperview:)`.
    private let replyBox = ListenerBox()
    private var autoPickedReplies = false
    private var userPickedTab = false
    private var isGroupStory: Bool { groupId != nil }
    private var showingReplies: Bool { isGroupStory && tab == 1 }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            replyBox.reg?.remove()
            replyBox.reg = nil
        }
    }

    // MARK: Views

    private let grabber = UIView()
    private let allTab = UIButton(type: .system)
    private let friendsTab = UIButton(type: .system)
    private let underline = UIView()
    private let search = UISearchTextField()
    private let table = UITableView(frame: .zero, style: .plain)
    /// ⛔ SKELETON ROWS, NOT A SPINNER — owner 2026-10-15: "this loading, change it to skeleton".
    /// Rows the shape of a viewer row (`StoryViewerSkeleton`), so nothing jumps when the real ones land.
    /// The controller is kept: its view only animates while its controller is alive.
    private let loadingHost = UIHostingController(rootView: StoryViewerSkeleton())
    private var loadingView: UIView { loadingHost.view }
    private let emptyLabel = UILabel()
    private var showingViewsOff = false

    private var filtered: [StoryViewerInfo] = []
    private var tab = 0
    /// The uids of my 1:1 chats, for the Friends tab. Read once per filter rather than per row.
    private var friendUids: Set<String> = []

    // MARK: What the sheet's gestures need from the list

    /// How far the list is scrolled. The sheet's vertical drag hands movement to the list once this
    /// is off zero, and takes it back when the list has come home.
    var scrollOffsetY: CGFloat { table.contentOffset.y }
    func pinScrollToTop() { if frozenOffsetY == nil { table.contentOffset.y = 0 } }
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
        configureTab(friendsTab, secondTabTitle, selected: false)
        allTab.addTarget(self, action: #selector(pickAll), for: .touchUpInside)
        friendsTab.addTarget(self, action: #selector(pickFriends), for: .touchUpInside)
        underline.backgroundColor = .white
        underline.layer.cornerRadius = 1
        addSubview(allTab); addSubview(friendsTab); addSubview(underline)

        search.placeholder = "Search"
        // ⚠️ MEASURED OFF HIS SCREENSHOT: THE PILL WAS 80 ON A SHEET OF 25, WHICH IS WHY IT READ AS A
        // LIGHT GREY BLOCK RATHER THAN AS A FIELD.
        //
        // `UISearchTextField` draws its OWN rounded fill, and `backgroundColor` goes BEHIND that
        // rather than instead of it. So `white 0.12` — which on its own over this sheet works out
        // near 53 — was composited under the system's fill and came out at 80. Every earlier attempt
        // to darken it was tuning the wrong one of the two layers, which is why it stayed pale.
        //
        // `borderStyle = .none` is what stands the system fill down, and an OPAQUE colour is what
        // makes the result predictable: with nothing left to composite, the pill is exactly the
        // number written here. 0.17 is 43, which sits just off the sheet the way iOS draws a dark
        // field, instead of a block that competes with the names under it.
        //
        // ⚠️ THE CORNER HAS TO BE OURS NOW TOO. It came with the system fill, so dropping one drops
        // the other, and a square field is a worse bug than a pale one. Half of the 38pt height in
        // `layoutSubviews`, so the two cannot drift apart.
        search.borderStyle = .none
        search.backgroundColor = UIColor(white: 0.17, alpha: 1)
        search.layer.cornerRadius = 19
        search.layer.cornerCurve = .continuous
        search.clipsToBounds = true
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

        loadingHost.safeAreaRegions = []   // laid out by frame; no screen-edge padding of its own
        loadingView.backgroundColor = .clear
        loadingView.isUserInteractionEnabled = false
        loadingView.isHidden = true
        addSubview(loadingView)

        emptyLabel.text = "No views yet"
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        composerHost.view.isHidden = true
        addSubview(composerHost.view)
    }

    // MARK: Tabs

    /// THE FIRST TAB IS ALWAYS THE AUDIENCE'S OWN NAME, which makes the whole rule one sentence: the
    /// first tab names who this story went to, and the second exists only when that was Everyone.
    /// A group story's tabs are "Views" and "Replies" (owner 2026-10-23), whatever its audience.
    private var allTabTitle: String { isGroupStory ? "All Viewers" : audience.title }
    private var secondTabTitle: String { isGroupStory ? "Replies" : "Friends" }
    /// Members see only Replies, so the second tab is the one shown and the first is gone.
    private var membersRepliesOnly: Bool { isGroupStory && repliesOnly }
    private var showsBothTabs: Bool { isGroupStory ? !repliesOnly : audience.bothTabs }

    private func applyAudienceTabs() {
        // A HIDDEN FRIENDS TAB MUST NOT LEAVE ITS FILTER ON — a story whose audience has no second
        // tab would otherwise show its list still narrowed, under a tab that is not on screen to
        // say so.
        if membersRepliesOnly {
            if tab != 1 { tab = 1; applyFilter() }
        } else if !showsBothTabs, tab != 0 {
            tab = 0
            applyFilter()
        }
        allTab.isHidden = membersRepliesOnly
        friendsTab.isHidden = !showsBothTabs && !membersRepliesOnly
        // Nothing to switch to, so it stops behaving like a button: no highlight, no touch feedback
        // on a tap that cannot change anything. It is a label with an underline at that point.
        allTab.isUserInteractionEnabled = showsBothTabs
        friendsTab.isUserInteractionEnabled = showsBothTabs
        configureTab(allTab, allTabTitle, selected: tab == 0)
        configureTab(friendsTab, secondTabTitle, selected: tab == 1)
        applyFilter()
        setNeedsLayout()
    }

    private func configureTab(_ b: UIButton, _ title: String, selected: Bool) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
        b.setTitleColor(selected ? .white : UIColor.white.withAlphaComponent(0.5), for: .normal)
    }

    @objc private func pickAll() { userPickedTab = true; setTab(0) }
    @objc private func pickFriends() { userPickedTab = true; setTab(1) }

    private func setTab(_ i: Int) {
        guard tab != i else { return }
        tab = i
        configureTab(allTab, allTabTitle, selected: i == 0)
        configureTab(friendsTab, secondTabTitle, selected: i == 1)
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
        // Members' replies-only panel: the one tab stands where the first one would.
        let secondX = membersRepliesOnly ? 18 : allTab.frame.maxX + 24
        friendsTab.frame = CGRect(x: secondX, y: tabY, width: friendsTab.bounds.width, height: 26)
        let active = tab == 0 ? allTab : friendsTab
        underline.frame = CGRect(x: active.frame.minX, y: allTab.frame.maxY + 4,
                                 width: active.bounds.width, height: 2)

        search.frame = CGRect(x: 16, y: underline.frame.maxY + 12, width: w - 32, height: 38)
        let top = search.frame.maxY + 10
        // The Replies tab's composer sits at the foot, above the home bar or the keyboard.
        var listBottom = bounds.height
        composerHost.view.isHidden = !composerVisible
        if composerVisible {
            let safe = window?.safeAreaInsets.bottom ?? 0
            let ch = ceil(composerHost.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude)).height)
            let bottom = bounds.height - max(safe, composerLift)
            composerHost.view.frame = CGRect(x: 0, y: bottom - ch, width: w, height: ch)
            listBottom = bottom - ch
        }
        table.frame = CGRect(x: 0, y: top, width: w, height: max(0, listBottom - top))
        // A list scrolled to its end stays at its end as the sheet grows: the extra room opens above
        // the rows, not as a blank gap under the last one. A held offset is lowered with it.
        let maxY = max(0, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        if table.contentOffset.y > maxY + 0.5, frozenOffsetY != nil || !table.isDragging {
            if frozenOffsetY != nil { frozenOffsetY = maxY }
            table.contentOffset.y = maxY
        }
        loadingView.frame = CGRect(x: 0, y: top, width: w, height: max(0, listBottom - top))
        // Two lines and a title when receipts are off (2026-10-17), one line otherwise.
        let emptyH = showingViewsOff
            ? ceil(emptyLabel.sizeThatFits(CGSize(width: w - 48, height: .greatestFiniteMagnitude)).height)
            : 22
        emptyLabel.frame = CGRect(x: 24, y: top + 40, width: w - 48, height: emptyH)
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
        // The Replies composer: the whole bar rides up on the keyboard instead of the list insetting.
        let lift: CGFloat
        if hiding || !composerVisible || search.isFirstResponder || window == nil {
            lift = 0
        } else {
            lift = max(0, bounds.height - convert(end, from: nil).minY)
        }
        if abs(lift - composerLift) > 0.5 {
            composerLift = lift
            let d = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            let c = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
            UIView.animate(withDuration: d, delay: 0,
                           options: [UIView.AnimationOptions(rawValue: UInt(c) << 16), .beginFromCurrentState]) {
                self.setNeedsLayout(); self.layoutIfNeeded()
            } completion: { _ in self.scrollRepliesToEnd(animated: true) }
        }
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
        // A group story's second tab is its reply thread, oldest first as it arrives.
        if showingReplies {
            let q = (search.text ?? "").trimmingCharacters(in: .whitespaces)
            filteredReplies = q.isEmpty ? replies
                : replies.filter { replyPerson($0.uid).name.localizedCaseInsensitiveContains(q)
                    || $0.text.localizedCaseInsensitiveContains(q) }
            table.reloadData()
            updateEmptyState()
            setNeedsLayout()
            // Oldest at the top, newest at the foot by the composer: land on the newest when the
            // thread opens and whenever a reply arrives.
            if filteredReplies.count != lastReplyCount {
                let first = lastReplyCount == 0
                lastReplyCount = filteredReplies.count
                layoutIfNeeded()
                scrollRepliesToEnd(animated: !first)
            }
            return
        }
        lastReplyCount = 0
        setNeedsLayout()
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

    private func scrollRepliesToEnd(animated: Bool) {
        guard showingReplies, !filteredReplies.isEmpty, frozenOffsetY == nil,
              table.numberOfRows(inSection: 0) == filteredReplies.count else { return }
        table.scrollToRow(at: IndexPath(row: filteredReplies.count - 1, section: 0), at: .bottom, animated: animated)
    }

    private func updateEmptyState() {
        // 2026-10-17 (owner): receipts off and nobody had watched before I turned them off, so the
        // list is empty because of my setting, not because nobody watched. Say so.
        let off = !showingReplies && viewers.isEmpty && !StoryPrefs.viewReceiptsOn
        if off != showingViewsOff {
            showingViewsOff = off
            if off {
                let title = NSAttributedString(string: "Views not available\n", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .headline),
                    .foregroundColor: UIColor.white])
                let body = NSAttributedString(
                    string: "Can't see views because you disabled Read Receipts in Settings > Stories",
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline),
                                 .foregroundColor: UIColor.white.withAlphaComponent(0.55)])
                let text = NSMutableAttributedString(attributedString: title)
                text.append(body)
                emptyLabel.numberOfLines = 0
                emptyLabel.attributedText = text
                emptyLabel.textAlignment = .center
            } else {
                emptyLabel.numberOfLines = 1
                emptyLabel.attributedText = nil
                emptyLabel.text = "No views yet"
                emptyLabel.textColor = UIColor.white.withAlphaComponent(0.55)
                emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
                emptyLabel.textAlignment = .center
            }
            setNeedsLayout()
        }
        // Group story replies (owner 2026-10-23): their own empty line, and the viewers' skeleton
        // never stands over the thread.
        if !showingViewsOff { emptyLabel.text = showingReplies ? "No replies yet" : "No views yet" }
        loadingView.isHidden = !isLoading || showingReplies
        emptyLabel.isHidden = showingReplies ? !filteredReplies.isEmpty : (isLoading || !filtered.isEmpty)
    }

    /// The name and photo for a reply's writer: me, then the group's own member maps, then a 1:1
    /// chat, the same conversation-backed lookup the viewers list makes (`fetchViewers`).
    fileprivate func replyPerson(_ uid: String) -> (name: String, photo: String?) {
        let me = AuthService.shared.uid ?? ""
        if uid == me { return ("You", ProfileStore.shared.me?.photoUrl) }
        let convs = ConversationsRepository.shared.conversations
        if let gid = groupId, let g = convs.first(where: { $0.id == gid }),
           let n = g.names[uid], !n.isEmpty {
            let p = g.photos[uid] ?? ""
            return (n, p.isEmpty ? nil : p)
        }
        if let c = convs.first(where: { !$0.isGroup && $0.otherUid(me) == uid }) {
            return (c.name(for: me), c.photoUrl(for: me))
        }
        return ("Someone", nil)
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
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showingReplies ? filteredReplies.count : filtered.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "viewer", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        if showingReplies {
            return replyCell(cell, filteredReplies[indexPath.row])
        }
        let v = filtered[indexPath.row]
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
                isHidden: StoryAudienceStore.shared.isHidden(v.id),
                // owner 2026-10-25: no "…" on a group story's viewers, the poster's own included.
                readOnly: viewersReadOnly || isGroupStory)
        }
        .margins(.horizontal, 16)
        .margins(.vertical, 9)
        return cell
    }

    /// One reply in a group story's thread (owner 2026-10-23). Same hosting and margins as a viewer
    /// row, so the two tabs read as one list.
    private func replyCell(_ cell: UITableViewCell, _ r: GroupStoryReply) -> UITableViewCell {
        let who = replyPerson(r.uid)
        let canDelete = groupId.map { StoriesService.canDeleteGroupReply(r, groupId: $0) } ?? false
        let sid = storyId
        let info = StoryViewerInfo(id: r.uid, name: who.name, photoUrl: who.photo,
                                   viewedAt: r.createdAt, reaction: nil)
        let isMe = r.uid == (AuthService.shared.uid ?? "")
        cell.contentConfiguration = UIHostingConfiguration {
            GroupStoryReplyRowContent(
                reply: r, name: who.name, photoUrl: who.photo, canDelete: canDelete, canReply: canReplyHere,
                onOpenProfile: { [weak self] in
                    guard !isMe else { return }
                    self?.onOpenProfile?(info)
                },
                onDelete: { [weak self] in
                    // Off the list at once; the listener confirms it, or brings it back on a refusal.
                    self?.replies.removeAll { $0.id == r.id }
                    Task { try? await StoriesService.shared.deleteGroupReply(storyId: sid, replyId: r.id) }
                },
                onReply: { [weak self] in
                    // "Reply" under a comment starts an answer to its writer (owner 2026-10-23 mockup).
                    guard let self, !isMe else { return }
                    self.composerModel.text = "@\(who.name) "
                    self.composerModel.focusTick &+= 1
                })
        }
        .margins(.horizontal, 16)
        .margins(.vertical, 9)
        return cell
    }

    /// The table's own scrolling is untouched while the list owns the drag; this only stops it
    /// rubber-banding UPWARD past its top while the sheet is the thing that should be moving.
    ///
    /// The freeze is checked FIRST and wins, because the two want different things: the sheet's
    /// vertical drag wants the top of the list, a sideways page drag wants wherever the list already
    /// was. See `freezeScroll`.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let y = frozenOffsetY { scrollView.contentOffset.y = y; return }
        if shouldPinScroll?() == true { scrollView.contentOffset.y = 0 }
    }

    /// Hold this list exactly where it is for the length of a sideways page drag.
    ///
    /// ⚠️ IT CATCHES PROGRAMMATIC MOVEMENT TOO, WHICH IS HALF THE POINT. `scrollViewDidScroll` fires
    /// for a `reloadData` that shifts content just as it does for a finger, so a batch of viewers
    /// arriving for the story sliding in cannot drag the rows of the story sliding out.
    ///
    /// Idempotent on the way in: a second `true` must not re-read the offset, or a list that had
    /// already been nudged would adopt the nudged position as its anchor.
    func freezeScroll(_ on: Bool) {
        if on {
            guard frozenOffsetY == nil else { return }
            frozenOffsetY = table.contentOffset.y
        } else {
            frozenOffsetY = nil
        }
    }
}

/// The viewer list while it loads: rows the shape of `StoryViewerRowContent` (46pt face, name, the
/// time under it, the ••• at the end), in the app's shimmer (`SkeletonFill`).
struct StoryViewerSkeleton: View {
    private let nameWidths: [CGFloat] = [130, 96, 150, 110, 84, 140]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(nameWidths.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    SkeletonCircle(size: 46)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(width: nameWidths[i], height: 13)
                        SkeletonBlock(width: 64, height: 10)
                    }
                    Spacer(minLength: 8)
                    SkeletonBlock(width: 22, height: 6, radius: 3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Spacer(minLength: 0)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// ONE REPLY IN A GROUP STORY'S THREAD, AS A COMMENT (owner 2026-10-23 mockup): the face on the
/// left, the name in bold, the reply under it in white, and a small "Reply" link that starts an
/// answer to this person. No bubble or card; rows are kept apart by space alone. A reaction reads
/// "Reacted to the story" with the emoji large at the end, as the reference app draws one.
/// Long press: Copy for text, Delete for the writer and the group's owner or admins.
struct GroupStoryReplyRowContent: View {
    let reply: GroupStoryReply
    let name: String
    let photoUrl: String?
    let canDelete: Bool
    /// The "Reply" link (owner 2026-10-25: none for the owner and admins).
    var canReply = true
    var onOpenProfile: () -> Void = {}
    var onDelete: () -> Void = {}
    var onReply: () -> Void = {}

    /// Number and one letter, as the story header writes its own age ("12s", "5m", "3h").
    private var ago: String {
        let s = max(0, Int(Date().timeIntervalSince(reply.createdAt)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    private var isMe: Bool { reply.uid == (AuthService.shared.uid ?? "") }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: name, photoUrl: photoUrl, size: 40)
                .onTapGesture { onOpenProfile() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                    Text(ago).font(.caption).foregroundStyle(.white.opacity(0.45))
                }
                .onTapGesture { onOpenProfile() }
                if reply.isReaction {
                    Text("Reacted to the story").font(.body).foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(reply.text).font(.body).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canReply && !isMe {
                    Button(action: onReply) {
                        Text("Reply").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.66, blue: 0.80))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if reply.isReaction {
                Text(reply.emoji).font(.system(size: 30))
            }
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        row.contextMenu {
            if !reply.isReaction {
                Button { UIPasteboard.general.string = reply.text } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

/// What the composer holds, shared with the panel so a row's "Reply" can prefill it.
final class GroupReplyComposerModel: ObservableObject {
    @Published var text = ""
    @Published var focusTick = 0
}

/// THE FOOT OF THE REPLIES TAB (owner 2026-10-23): a row of quick reactions over a growing text
/// field with its send button, the reference app's group reply bar in the app's own dark look.
/// A reaction is sent on tap; text is sent with the arrow.
struct GroupStoryReplyComposer: View {
    @ObservedObject var model: GroupReplyComposerModel
    var onSend: (_ text: String, _ emoji: String) -> Void
    var onFocus: (Bool) -> Void
    var onResize: () -> Void
    @FocusState private var focused: Bool

    /// The same quick reactions the reply bar offers on a 1:1 story.
    static let emojis = ["😭", "😍", "🤣", "❤️", "😄", "🔥", "❤️‍🔥"]

    private var trimmed: String { model.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Self.emojis, id: \.self) { e in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onSend("", e)
                    } label: {
                        Text(e).font(.system(size: 26))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: $model.text,
                          prompt: Text("Write a reply…").foregroundStyle(.white.opacity(0.45)),
                          axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(white: 0.17)))
                if !trimmed.isEmpty {
                    Button {
                        let t = trimmed
                        model.text = ""
                        onSend(t, "")
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, .white)
                            .font(.system(size: 36))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(white: 0.10))
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.15), value: trimmed.isEmpty)
        .onChange(of: focused) { _, on in onFocus(on) }
        .onChange(of: model.text) { _, _ in onResize() }
        .onChange(of: model.focusTick) { _, _ in focused = true }
    }
}

/// 2026-10-25: the owner's and admins' own group-story footer and replies sheet are gone. They
/// get the poster's bar and sheet (`StoryViewer.hasOwnerBar`), owner: "same as the owner".
