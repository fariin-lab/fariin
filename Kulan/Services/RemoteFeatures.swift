import Foundation
import FirebaseFirestore
import Observation

/// FEATURE SWITCHES THE OWNER FLIPS FROM THE ADMIN PANEL (admin.fariin.com → Feature controls),
/// 2026-10-12. One document, `config/features`, written only by the adminApi function (the rules let
/// signed-in phones read it and nobody write it). Each key is a Bool.
///
/// How a switch resolves: the value from the server if it has one, otherwise the default this build
/// ships with (the old `static let`). Two kinds of switch, the owner's rule:
///   • finished features may go ON or OFF from the panel;
///   • unfinished ones (groups, group calls, call links, two-step) may only be turned OFF. A remote
///     `true` is ignored for them, so a half-built feature can never be switched on by accident; a
///     future build that ships one ON can still be killed from the panel.
///
/// WHEN IT APPLIES: the next time the app opens. The listener saves what the server says; the switches
/// read a snapshot taken once per launch. Changing a feature's doors under a screen that is already
/// drawn (a tab disappearing mid-scroll) is worse than waiting for the next open, and a snapshot is
/// also what lets these be read from any thread without a lock.
final class RemoteFeatures {
    static let shared = RemoteFeatures()
    private init() {}

    private static let storeKey = "remoteFeatures.v1"

    /// What the server said, as of the last launch. Read once; never changes while the app runs.
    private static let snapshot: [String: Bool] = {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Bool]) ?? [:]
    }()

    /// A finished feature: the server's value wins either way.
    static func value(_ key: String, default shipped: Bool) -> Bool {
        snapshot[key] ?? shipped
    }

    /// An unfinished feature: the server can only take it away.
    static func offOnly(_ key: String, default shipped: Bool) -> Bool {
        shipped && snapshot[key] != false
    }

    private var listener: ListenerRegistration?

    /// Started with AppLimits. An error or a missing document leaves the saved values alone, the same
    /// rule AppLimits follows: a dropped listener is not a reason to undo the owner's last choice.
    func start() {
        stop()
        watchSwaps()
        listener = FirestoreHub.db.collection("config").document("features")
            .addSnapshotListener { snap, _ in
                guard let snap, snap.exists else { return }
                var out: [String: Bool] = [:]
                for (k, v) in snap.data() ?? [:] { if let b = v as? Bool { out[k] = b } }
                UserDefaults.standard.set(out, forKey: Self.storeKey)
                let cloud = MemberCloudSetting(snap.data()?["memberCloud"])
                UserDefaults.standard.set(cloud.stored, forKey: MemberCloudSetting.storeKey)
                let badges = NewBadges.parse(snap.data()?["newBadges"])
                UserDefaults.standard.set(badges, forKey: NewBadges.storeKey)
                let emoji = UploadedEmoji.parse(snap.data()?["customEmoji"])
                UserDefaults.standard.set(UploadedEmoji.stored(emoji), forKey: UploadedEmoji.storeKey)
                UploadedEmoji.set(emoji)
                // Built-in custom emoji the admin panel hid (owner 2026-11-06): left out of the picker.
                let hidden = Set((snap.data()?["customEmojiHidden"] as? [String]) ?? [])
                UserDefaults.standard.set(Array(hidden), forKey: "remoteFeatures.customEmojiHidden.v1")
                // Built-in wallpapers and bubble styles the admin panel hid: left out of the pickers only.
                let wpHidden = Set((snap.data()?["wallpapersHidden"] as? [String]) ?? [])
                UserDefaults.standard.set(Array(wpHidden), forKey: "remoteFeatures.wallpapersHidden.v1")
                let bsHidden = Set((snap.data()?["bubblesHidden"] as? [String]) ?? [])
                UserDefaults.standard.set(Array(bsHidden), forKey: "remoteFeatures.bubblesHidden.v1")
                // The chat list card (owner 2026-11-13): applied live like newBadges. Kept as plain
                // values only, so a malformed entry can never reach UserDefaults.
                let cards = ChatCard.parse(snap.data()?["chatCards"])
                UserDefaults.standard.set(cards.map(\.stored), forKey: ChatCard.storeKey)
                DispatchQueue.main.async {
                    LiveFeatures.shared.values = out
                    LiveFeatures.shared.memberCloud = cloud
                    LiveFeatures.shared.newBadges = badges
                    if LiveFeatures.shared.customEmoji != emoji { LiveFeatures.shared.customEmoji = emoji }
                    if LiveFeatures.shared.customEmojiHidden != hidden { LiveFeatures.shared.customEmojiHidden = hidden }
                    if LiveFeatures.shared.wallpapersHidden != wpHidden { LiveFeatures.shared.wallpapersHidden = wpHidden }
                    if LiveFeatures.shared.bubblesHidden != bsHidden { LiveFeatures.shared.bubblesHidden = bsHidden }
                    if LiveFeatures.shared.chatCards != cards { LiveFeatures.shared.chatCards = cards }
                }
            }
    }

    func stop() { listener?.remove(); listener = nil }

    /// 2026-10-20 (owner): after `FirestoreHub.swap` the listener belongs to the stuck client. Let go
    /// of it off-main and attach again on the fresh one. Added once, on the first `start()`.
    private var swapObserver: NSObjectProtocol?
    private func watchSwaps() {
        guard swapObserver == nil else { return }
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.listener != nil else { return }
            FirestoreHub.drop([self.listener])
            self.listener = nil
            self.start()
        }
    }
}

/// ⛔ THE SWITCHES THAT APPLY AT ONCE — owner 2026-10-18 ("Create new groups" from the admin panel,
/// "without a new build", while the app is open). The snapshot above is deliberately once per launch;
/// a switch that only closes a door (a button that should not be offered) is safe to change under a
/// drawn screen, so those read this live copy instead. `@Observable`: a view reading a value redraws
/// when the panel flips it. Starts from what was saved last time.
@Observable final class LiveFeatures {
    static let shared = LiveFeatures()
    var values: [String: Bool] =
        (UserDefaults.standard.dictionary(forKey: "remoteFeatures.v1") as? [String: Bool]) ?? [:]
    /// The group page's member cloud (not a Bool, so it lives beside `values`).
    var memberCloud = MemberCloudSetting(UserDefaults.standard.dictionary(forKey: MemberCloudSetting.storeKey))
    /// Spots wearing "New", spot id -> end time in ms (see `NewBadges`).
    var newBadges: [String: Double] = NewBadges.parse(UserDefaults.standard.dictionary(forKey: NewBadges.storeKey))
    /// Custom emoji uploaded in the admin panel (see `UploadedEmoji`), in the panel's order.
    var customEmoji: [UploadedEmoji.Item] = UploadedEmoji.parse(UserDefaults.standard.array(forKey: UploadedEmoji.storeKey))
    /// Built-in custom emoji hidden in the admin panel ("ce_N"); the picker leaves them out.
    var customEmojiHidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "remoteFeatures.customEmojiHidden.v1") ?? [])
    /// Built-in wallpaper ids (gradient and animated) hidden in the admin panel; pickers leave them out.
    var wallpapersHidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "remoteFeatures.wallpapersHidden.v1") ?? [])
    /// Bubble style ids hidden in the admin panel; pickers leave them out.
    var bubblesHidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "remoteFeatures.bubblesHidden.v1") ?? [])
    /// The panel's chat list cards (owner 2026-11-13), in the panel's order; see `ChatCard`.
    var chatCards: [ChatCard] = ChatCard.parse(UserDefaults.standard.array(forKey: ChatCard.storeKey))
    private init() {}
}

/// ⛔ THE "NEW" BADGE ON A SETTINGS ROW — owner 2026-11-06, set from the admin panel; on any spot in
/// `NewBadgeSpots` since 2026-11-07: `config/features.newBadges = { "<spot id>": <end time, ms> }`. A row shows the badge while the
/// end time is still ahead. Opening the row does NOT remove it (owner's word): it leaves only when an
/// admin removes it or the end time passes. Applies live (LiveFeatures).
enum NewBadges {
    static let storeKey = "remoteFeatures.newBadges.v1"

    /// The Settings page's own rows, key -> title: `SettingsRowLabel` (and the settings search)
    /// finds a row's badge by its title. Every other spot names its id (`.newBadge`, see
    /// `NewBadgeSpots`, the catalog the panel offers).
    static let rows: [String: String] = [
        "subscriptions": "Subscriptions", "account": "Account", "devices": "Devices",
        "notifications": "Notifications", "appearance": "Appearance", "chats": "Chats",
        "stories": "Stories", "privacy": "Privacy & Security", "storage": "Storage and Data",
        "invite": "Invite Friends", "safety": "Safety", "help": "Help & About",
        "myProfile": "My Profile",
    ]
    private static let keyByTitle: [String: String] =
        Dictionary(uniqueKeysWithValues: rows.map { ($0.value, $0.key) })

    static func key(forTitle title: String) -> String? { keyByTitle[title] }

    /// Anything that is not a positive number, or not a spot in the catalog, is ignored.
    static func parse(_ raw: Any?) -> [String: Double] {
        guard let d = raw as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in d {
            if let n = v as? NSNumber, n.doubleValue > 0, NewBadgeSpots.all[k] != nil { out[k] = n.doubleValue }
        }
        return out
    }

    /// The end time of this row's badge, or nil. Read from a view, so it redraws when the panel
    /// changes it; the view compares it with the clock itself (see SettingsRowLabel).
    @MainActor static func until(_ key: String) -> Double? { LiveFeatures.shared.newBadges[key] }
}

/// THE GROUP PAGE'S BUBBLE CLOUD (owner 2026-10-19, admin panel): `config/features.memberCloud` =
/// `{ mode: "off" | "all" | "groups", groups: [conversationId] }`. Missing or anything unexpected
/// reads as off. Only shows or hides a card, so it applies live.
struct MemberCloudSetting: Equatable {
    static let storeKey = "remoteFeatures.memberCloud.v1"

    enum Mode: String { case off, all, groups }
    let mode: Mode
    let groups: Set<String>

    init(_ raw: Any?) {
        let d = raw as? [String: Any]
        let m = (d?["mode"] as? String).flatMap(Mode.init(rawValue:)) ?? .off
        let g = (d?["groups"] as? [Any])?.compactMap { $0 as? String } ?? []
        mode = m
        groups = Set(g)
    }

    func isOn(for cid: String) -> Bool {
        switch mode {
        case .off: return false
        case .all: return true
        case .groups: return groups.contains(cid)
        }
    }

    /// The shape saved for the next launch (plist types only).
    var stored: [String: Any] { ["mode": mode.rawValue, "groups": Array(groups)] }
}
