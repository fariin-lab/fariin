import SwiftUI
import UIKit

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
// That is the whole hand-off, and it is what makes the sheet and the list feel like one surface —
// which is what he asked for and what the arbiter was imitating.
//
// WHAT IS STILL SWIFTUI, DELIBERATELY: the row's contents, through `UIHostingConfiguration`. The
// scrolling and the gestures are the part that had to be native; the avatar, the reaction badge and
// the tick are already right and re-drawing them in UIKit would only be a chance to make them differ.
final class StoryViewersSheetView: UIView {

    // MARK: Public surface

    /// 0 shut, 1 fully open. The host reads this to drive the live story's morph, so it is the same
    /// number the card is scaled by — the sheet and the story cannot disagree about how far open it is.
    var onProgress: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    var onSendMessage: ((StoryViewerInfo) -> Void)?

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

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    /// Progress when the current drag began, so the finger maps 1:1 from wherever it grabbed.
    private var dragStart: CGFloat = 0
    /// True once a drag has decided the SHEET owns it rather than the list.
    private var dragOwnsSheet = false
    private var settle: UIViewPropertyAnimator?

    private var sheetHeight: CGFloat { bounds.height * Self.heightFraction }

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        buildHierarchy()
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

    private func animate(to target: CGFloat, velocity: CGFloat) {
        settle?.stopAnimation(true)
        // Apple's own spring, with the finger's velocity handed straight to it — which is what makes a
        // flick continue at the speed it was thrown instead of restarting from nothing. The SwiftUI
        // version had to run its own display-link spring to get this.
        let distance = max(1, abs(target - progress) * sheetHeight)
        let initial = CGVector(dx: 0, dy: min(30, abs(velocity) / distance))
        let timing = UISpringTimingParameters(mass: 1, stiffness: 260, damping: 28, initialVelocity: initial)
        let a = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
        let from = progress
        a.addAnimations { [weak self] in
            guard let self else { return }
            // A property animator interpolates its own `fractionComplete`, so stepping progress here
            // gives the same curve to the sheet AND to whatever the host drives from `onProgress`.
            self.progress = target
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        a.addAnimations { [weak self] in
            _ = from
            self?.onProgress?(target)
        }
        a.addCompletion { [weak self] _ in
            guard let self else { return }
            if target <= 0.001 { self.onClose?() }
        }
        settle = a
        a.startAnimation()
    }

    // MARK: Gesture

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let translation = g.translation(in: self).y
        let velocity = g.velocity(in: self).y

        switch g.state {
        case .began:
            settle?.stopAnimation(true)
            dragStart = progress
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
                }
                return
            }
            table.contentOffset.y = 0          // pin it while the sheet owns the movement
            setProgress(dragStart - g.translation(in: self).y / sheetHeight)
        case .ended, .cancelled:
            guard dragOwnsSheet else { return }
            dragOwnsSheet = false
            // Where it would land if the finger kept going. Same projection UIKit uses for its own
            // scroll views, so a flick behaves the way every other flick in iOS does.
            let projected = progress - (velocity * 0.15) / sheetHeight
            animate(to: projected >= 0.5 ? 1 : 0, velocity: velocity)
        default:
            break
        }
        _ = translation
    }

    /// The one question the hand-off turns on.
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
    /// paper over.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Never start on a horizontal drag: the carousel above owns those.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let p = g as? UIPanGestureRecognizer else { return true }
        let v = p.velocity(in: self)
        return abs(v.y) >= abs(v.x)
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
/// from inside UIKit, and the host's own opens and closes (the swipe-up on the story, the tap on the
/// dark area, the parked-sheet self-heal) write it from outside. One number, either direction, and
/// the live story's morph reads the same one — so the sheet and the card behind it cannot disagree
/// about how far open the sheet is.
struct StoryViewersSheet: UIViewRepresentable {
    let activeStoryId: String
    @Binding var progress: CGFloat
    var onClose: () -> Void

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
