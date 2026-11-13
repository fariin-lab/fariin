import SwiftUI
import UIKit
import Observation
import UserNotifications
import FirebaseAuth

// THE CHAT LIST CARD (owner 2026-11-13). One small glass card at the top of the All chats list,
// modelled on the reference app's chat-list suggestion card (studied, not copied). Two sources:
//   - admin cards from `config/features.chatCards` (read live by RemoteFeatures, like newBadges),
//   - three built-in cards the phone decides itself: profile photo, username, notifications.
// Admin cards come first (priority high to low, then the panel's order), then the built-ins in that
// order. The first one that applies and was not closed on this phone is the one shown.
// The X closes a card for good on this phone for this account (`chatCardsDismissed-<uid>`).
// The Android app and the admin panel read the same contract; keep field names in step with them.

/// One card, admin or built-in. Equatable so the table only redraws when something real changed.
struct ChatCard: Equatable, Identifiable {
    enum Builtin: String { case photo, username, notifications }

    let id: String
    var title: String
    var subtitle: String
    /// "https://..." opens the in-app browser, "fariin://..." routes inside the app; nil = text only.
    var link: String?
    var platforms: [String] = []
    var minBuild = 0
    var maxBuild = 0
    var countries: [String] = []
    var ppm = 1_000_000
    var startsAt: Double?
    var endsAt: Double?
    var dismissible = true
    var priority = 0
    var builtin: Builtin?

    static let storeKey = "remoteFeatures.chatCards.v1"

    /// Reads the panel's array. A malformed entry is skipped rather than failing the whole list,
    /// because one bad card from the panel must not take the good ones off every phone.
    static func parse(_ raw: Any?) -> [ChatCard] {
        guard let list = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [ChatCard] = []
        for item in list {
            guard let m = item as? [String: Any], let c = ChatCard(map: m), !seen.contains(c.id) else { continue }
            seen.insert(c.id)
            out.append(c)
        }
        return out
    }

    private init?(map m: [String: Any]) {
        guard let id = m["id"] as? String,
              id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
              !id.hasPrefix("builtin_"),   // the phone's own cards; the panel may not shadow them
              let title = (m["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        self.id = id
        self.title = String(title.prefix(60))
        self.subtitle = String(((m["subtitle"] as? String) ?? "").prefix(140))
        if let l = m["link"] as? String, let u = URL(string: l),
           ["https", "fariin"].contains(u.scheme?.lowercased() ?? "") { link = l }
        platforms = ((m["platforms"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
        minBuild = (m["minBuild"] as? NSNumber)?.intValue ?? 0
        maxBuild = (m["maxBuild"] as? NSNumber)?.intValue ?? 0
        countries = ((m["countries"] as? [Any]) ?? []).compactMap { ($0 as? String)?.uppercased() }
        if let p = m["ppm"] as? NSNumber { ppm = min(max(p.intValue, 0), 1_000_000) }
        startsAt = (m["startsAt"] as? NSNumber)?.doubleValue
        endsAt = (m["endsAt"] as? NSNumber)?.doubleValue
        dismissible = (m["dismissible"] as? Bool) ?? true
        priority = (m["priority"] as? NSNumber)?.intValue ?? 0
    }

    private init(builtin: Builtin, title: String, subtitle: String) {
        id = "builtin_" + builtin.rawValue
        self.title = title
        self.subtitle = subtitle
        self.builtin = builtin
    }

    /// What is kept in UserDefaults: plain property-list values only (a Firestore Timestamp in a
    /// malformed entry would crash `UserDefaults.set`), and it parses back through `parse`.
    var stored: [String: Any] {
        var m: [String: Any] = ["id": id, "title": title, "subtitle": subtitle, "platforms": platforms,
                                "minBuild": minBuild, "maxBuild": maxBuild, "countries": countries,
                                "ppm": ppm, "dismissible": dismissible, "priority": priority]
        if let link { m["link"] = link }
        if let startsAt { m["startsAt"] = startsAt }
        if let endsAt { m["endsAt"] = endsAt }
        return m
    }

    /// Is this admin card for me, on this phone, now? The official channel's rules
    /// (`Announcement.reaches`): the server-corrected clock, the app build, the phone's region and
    /// the same stable rollout bucket, plus the platform, which announcements do not have.
    func reaches(uid: String, build: Int, region: String?, now: Date) -> Bool {
        let ms = now.timeIntervalSince1970 * 1000
        if let startsAt, startsAt > ms { return false }
        if let endsAt, endsAt <= ms { return false }
        if !platforms.isEmpty, !platforms.contains("ios") { return false }
        if build < minBuild { return false }
        if maxBuild > 0, build > maxBuild { return false }
        if !countries.isEmpty {
            guard let region, countries.contains(region.uppercased()) else { return false }
        }
        if ppm < 1_000_000 {
            guard Announcement.bucket(id, uid) < ppm else { return false }
        }
        return true
    }

    static let photo = ChatCard(builtin: .photo, title: "Add a profile photo",
                                subtitle: "Help your friends recognise you.")
    static let username = ChatCard(builtin: .username, title: "Choose a username",
                                   subtitle: "People can find you without your phone number.")
    static let notifications = ChatCard(builtin: .notifications, title: "Turn on notifications",
                                        subtitle: "So you don't miss messages and calls.")
}

/// What this phone has closed, per account, and the notification permission the built-in card
/// asks about. Observable so the chat list redraws when either changes.
@Observable
final class ChatCardsStore {
    static let shared = ChatCardsStore()

    private(set) var version = 0
    /// nil until the first read comes back, so the card never flashes before the answer is known.
    private(set) var notifStatus: UNAuthorizationStatus?

    private init() {
        refreshNotifications()
        // Coming back from the Settings app is how a denied permission gets turned on.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshNotifications()
        }
    }

    private func key(_ uid: String) -> String { "chatCardsDismissed-\(uid)" }

    func dismissed(_ uid: String) -> Set<String> {
        _ = version
        return Set(UserDefaults.standard.stringArray(forKey: key(uid)) ?? [])
    }

    func dismiss(_ id: String, uid: String) {
        guard !uid.isEmpty else { return }
        var set = dismissed(uid)
        guard set.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(set), forKey: key(uid))
        version += 1
    }

    func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            DispatchQueue.main.async {
                if ChatCardsStore.shared.notifStatus != status { ChatCardsStore.shared.notifStatus = status }
            }
        }
    }
}

enum ChatCards {
    /// The one card to show at the top of the list, or nil. Read from the list's render, so every
    /// value it touches (panel cards, closed set, profile, permission) redraws the list when it
    /// changes. `hidden`: not the All list, or a search is open.
    @MainActor static func pick(uid: String, hidden: Bool) -> ChatCard? {
        guard !hidden, !uid.isEmpty else { return nil }
        let closed = ChatCardsStore.shared.dismissed(uid)
        let build = OfficialChannelStore.currentBuild
        let region = Locale.current.region?.identifier
        let now = ServerClock.now
        // Priority high to low; equal priorities keep the panel's order.
        let admin = LiveFeatures.shared.chatCards.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)
        if let c = admin.first(where: { !closed.contains($0.id) && $0.reaches(uid: uid, build: build, region: region, now: now) }) {
            return c
        }
        return builtins(now: now).first { !closed.contains($0.id) }
    }

    /// The phone's own cards. Not in the account's first day: the onboarding card at the bottom
    /// covers that day, and two cards asking for things at once is too much (owner 2026-11-13).
    @MainActor private static func builtins(now: Date) -> [ChatCard] {
        guard let me = ProfileStore.shared.me,
              let joined = me.joinedAt ?? Auth.auth().currentUser?.metadata.creationDate,
              now.timeIntervalSince(joined) > 86_400 else { return [] }
        var out: [ChatCard] = []
        if (me.photoUrl ?? "").isEmpty { out.append(.photo) }
        if me.handle.isEmpty { out.append(.username) }
        if let s = ChatCardsStore.shared.notifStatus, s == .denied || s == .notDetermined { out.append(.notifications) }
        return out
    }

    /// The card's tap. Built-ins open their screen; an admin card follows its link.
    @MainActor static func perform(_ card: ChatCard, from vc: UIViewController) {
        switch card.builtin {
        case .photo?:
            present(UIHostingController(rootView: EditProfileView()), from: vc)
        case .username?:
            present(UIHostingController(rootView: ChatCardUsernameSheet()), from: vc)
        case .notifications?:
            Task { @MainActor in
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if status == .notDetermined {
                    let granted = (try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                } else if let u = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(u)
                }
                ChatCardsStore.shared.refreshNotifications()
            }
        case nil:
            guard let s = card.link, let url = URL(string: s) else { return }
            switch url.scheme?.lowercased() {
            case "https":
                WebLink.open(url)
            case "fariin":
                // The app's registered scheme is kulan://, and the deep-link handler already reads
                // every in-app route from it, so a fariin:// link is the same route under that scheme.
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.scheme = "kulan"
                if let u = c?.url { UIApplication.shared.open(u) }
            default:
                return
            }
        }
    }

    @MainActor private static func present(_ child: UIViewController, from vc: UIViewController) {
        var top: UIViewController? = vc.view.window?.rootViewController ?? vc
        while let p = top?.presentedViewController { top = p }
        top?.present(child, animated: true)
    }
}

/// The username screen in its own stack, seeded with the current name (empty, or the card would
/// not be showing). `UsernameEditView` saves and refreshes the profile itself.
private struct ChatCardUsernameSheet: View {
    @State private var handle = ProfileStore.shared.me?.handle ?? ""
    var body: some View {
        NavigationStack { UsernameEditView(handle: $handle) }
    }
}

/// The card itself: the app's liquid glass, inset 16 each side, radius 20 (a capsule when it is one
/// line tall), title over up to three lines of subtitle, X on the right.
struct ChatCardView: View {
    let card: ChatCard
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.trailing, 40)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { if card.dismissible { closeButton } }
        .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .padding(8)   // the extra hit area around the glyph
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .accessibilityLabel("Close")
    }
}

/// The table header that holds the card. A header (not a row and not an overlay) so the card
/// scrolls with the list's top and can never sit over a chat, and it stays out of the row diff.
@MainActor
final class ChatListCardHeader {
    private final class Box: UIView {
        var onWidth: ((CGFloat) -> Void)?
        private var lastWidth: CGFloat = 0
        override func layoutSubviews() {
            super.layoutSubviews()
            guard abs(bounds.width - lastWidth) > 0.5 else { return }
            lastWidth = bounds.width
            let w = bounds.width
            DispatchQueue.main.async { [weak self] in self?.onWidth?(w) }
        }
    }

    private weak var table: UITableView?
    private weak var presenter: UIViewController?
    private let box = Box()
    private var host: UIHostingController<ChatCardView>?
    private var shown: ChatCard?
    private var wanted: ChatCard?
    private var animating = false
    private var dark: Bool?
    /// The first section's top with no header at all. A grouped table may add its own spacing
    /// when it has no header; the card grows from and shrinks back to exactly that, so putting the
    /// header in and taking it out never makes the rows jump.
    private var gap: CGFloat = 0

    init() {
        box.clipsToBounds = true
        box.backgroundColor = .clear
        box.onWidth = { [weak self] _ in self?.resize(animated: false) }
    }

    func update(_ card: ChatCard?, table: UITableView, presenter: UIViewController, dark: Bool) {
        self.table = table
        self.presenter = presenter
        if self.dark != dark {
            self.dark = dark
            host?.overrideUserInterfaceStyle = dark ? .dark : .light
        }
        wanted = card
        guard !animating else { return }   // the running animation picks `wanted` up when it ends
        settle()
    }

    private func settle() {
        if let s = shown, let w = wanted, s.id == w.id {
            guard s != w else { return }
            shown = w
            host?.rootView = view(for: w)
            resize(animated: true)
            return
        }
        if shown != nil { leave() } else if let w = wanted { enter(w) }
    }

    private func view(for card: ChatCard) -> ChatCardView {
        ChatCardView(card: card, onTap: { [weak self] in
            guard let vc = self?.presenter else { return }
            ChatCards.perform(card, from: vc)
        }, onClose: {
            ChatCardsStore.shared.dismiss(card.id, uid: AuthService.shared.uid ?? "")
        })
    }

    /// Is any of the header on screen? Off screen, a change is made at once and the scroll position
    /// moved by the same amount, so the chats being read do not shift.
    private func headerVisible(_ t: UITableView) -> Bool {
        t.contentOffset.y + t.adjustedContentInset.top < max(box.frame.height, 1)
    }

    private func fittedHeight(_ width: CGFloat) -> CGFloat {
        guard let host, width > 0 else { return gap }
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private func setHeight(_ h: CGFloat, on t: UITableView) {
        box.frame = CGRect(x: 0, y: 0, width: t.bounds.width, height: max(h, .leastNormalMagnitude))
        t.tableHeaderView = box
        t.layoutIfNeeded()
    }

    private func enter(_ card: ChatCard) {
        guard let t = table, let p = presenter else { return }
        t.layoutIfNeeded()
        gap = t.tableHeaderView == nil && t.numberOfSections > 0 ? max(0, t.rect(forSection: 0).minY) : 0
        let h = UIHostingController(rootView: view(for: card))
        h.view.backgroundColor = .clear
        h.safeAreaRegions = []
        if let dark { h.overrideUserInterfaceStyle = dark ? .dark : .light }
        p.addChild(h)
        box.addSubview(h.view)
        h.didMove(toParent: p)
        host = h
        shown = card
        let width = t.bounds.width
        let target = fittedHeight(width)
        h.view.frame = CGRect(x: 0, y: 0, width: width, height: target)
        h.view.autoresizingMask = [.flexibleWidth]
        let visible = t.contentOffset.y + t.adjustedContentInset.top < 1
        guard visible else {
            setHeight(target, on: t)
            t.contentOffset.y += target - gap
            return
        }
        setHeight(gap, on: t)
        h.view.alpha = 0
        animating = true
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.setHeight(target, on: t)
            h.view.alpha = 1
        } completion: { _ in
            self.animating = false
            self.settle()
        }
    }

    private func leave() {
        guard let t = table, let h = host else { finishLeave(); return }
        guard headerVisible(t) else {
            let delta = box.frame.height - gap
            t.tableHeaderView = nil
            t.contentOffset.y -= delta
            finishLeave()
            return
        }
        animating = true
        // Fade out while the height closes, so the list slides up into the space.
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            h.view.alpha = 0
            self.setHeight(self.gap, on: t)
        } completion: { _ in
            t.tableHeaderView = nil
            self.finishLeave()
        }
    }

    private func finishLeave() {
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        host = nil
        shown = nil
        animating = false
        settle()
    }

    /// A new width (rotation, split view) or new text: measure again.
    private func resize(animated: Bool) {
        guard let t = table, let h = host, shown != nil, !animating else { return }
        let width = t.bounds.width
        let target = fittedHeight(width)
        h.view.frame = CGRect(x: 0, y: 0, width: width, height: target)
        guard abs(box.frame.height - target) > 0.5 else { return }
        if animated, headerVisible(t) {
            UIView.animate(withDuration: 0.25) { self.setHeight(target, on: t) }
        } else {
            setHeight(target, on: t)
        }
    }
}
