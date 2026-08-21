import Foundation
import Observation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore

// THE OFFICIAL CHANNEL — read from the reference app's source, then built our way.
//
// The one thing worth understanding before changing anything here: THERE IS NO ACCOUNT BEHIND THIS
// CHAT. The reference implementation makes a local contact with no service id and no phone
// number, names it after itself, mutes it forever and paints the app's own logo on it; iOS does the
// same with a hardcoded release-notes thread and a hardcoded unique id. Nobody can impersonate it
// because there is nothing to impersonate — the app itself decides what is official, and the id below
// is the whole decision. A real @fariin account could be copied as @fariinn, @fariin1, @far1in; this
// cannot.
//
// The second thing: announcements are PULLED, not pushed. One document is written once and every
// phone in the world reads the same one. Nothing is copied per user, so sending to a million people
// costs exactly one write. Who an announcement is FOR is decided here, on the phone, out of fields
// the announcement carries (app build, country, rollout bucket) — the same trick the reference app
// uses to run a worldwide release channel off one static file with no server state at all.
//
// The only exception is a send to CHOSEN people, which cannot work that way because the phone would
// have to be told the list. Those get a real copy under `users/{uid}/announcements/{id}`, which is
// cheap precisely because the list is short.
enum OfficialChannel {
    /// The conversation id. Fixed, and deliberately NOT a valid uid shape (real ids never contain a
    /// dash, and a 1:1 cid is "uidA_uidB") so it can never collide with a real chat or be minted by
    /// anyone. Everything official in the app is gated on `cid == OfficialChannel.cid` and nothing else.
    static let cid = "official-fariin"
    static let name = "Fariin"
    /// Reserved in the `usernames` collection so no user can ever register it. Not an account — the
    /// reservation exists purely to burn the name.
    static let handle = "fariin"
    static let subtitle = "Official Chat"
    /// Bottom bar where the composer would be. Another mainstream messenger says only it can send
    /// messages; the reference app names the contact after itself. Ours says what it is and who it is from.
    static let cannotReply = "Only Fariin can send messages"

    static func isOfficial(_ cid: String) -> Bool { cid == OfficialChannel.cid }
}

/// The one thing about the channel that is not an announcement: where "Update Now" should send
/// somebody. It cannot be hardcoded — the app is not on the App Store yet, so there is no numeric id
/// to hardcode — and a button that opens nothing is exactly the fake feature this project forbids.
/// So the owner sets it once, and until it is set the compose screen refuses to offer an Update
/// button and says why.
@Observable
final class OfficialConfig {
    static let shared = OfficialConfig()
    private init() {}

    private var listener: ListenerRegistration?
    private(set) var appStoreUrl: String = ""

    var hasAppStoreUrl: Bool { URL(string: appStoreUrl)?.scheme?.hasPrefix("http") == true }

    func start() {
        stop()
        listener = Firestore.firestore().collection("config").document("official")
            .addSnapshotListener { [weak self] snap, _ in
                self?.appStoreUrl = snap?.data()?["appStoreUrl"] as? String ?? ""
            }
    }

    func stop() { listener?.remove(); listener = nil }

    /// Owner only; the rules enforce that, not this.
    func setAppStoreUrl(_ url: String) async throws {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Firestore.firestore().collection("config").document("official")
            .setData(["appStoreUrl": clean], merge: true)
        appStoreUrl = clean
    }
}

// MARK: - What an announcement is

/// The kind of announcement. Drives the small coloured label above the title, nothing else — the
/// bubble itself is identical, because a maintenance notice that looks like a different app is
/// exactly the confusion this chat exists to prevent.
enum AnnouncementKind: String, CaseIterable, Identifiable {
    case feature, release, maintenance, security, news

    var id: String { rawValue }
    var label: String {
        switch self {
        case .feature:     return "New Feature"
        case .release:     return "Release Notes"
        case .maintenance: return "Maintenance"
        case .security:    return "Security"
        case .news:        return "News"
        }
    }
    var icon: String {
        switch self {
        case .feature:     return "sparkles"
        case .release:     return "shippingbox"
        case .maintenance: return "wrench.and.screwdriver"
        case .security:    return "lock.shield"
        case .news:        return "megaphone"
        }
    }
    /// Security is the only one that gets a colour of its own. Everything else is quiet, because a
    /// chat where every message shouts is a chat people mute for real.
    var isUrgent: Bool { self == .security }
}

/// A tappable button under an announcement. The reference app allows exactly ONE (a `ctaId` string mapped to an
/// in-app action); we allow up to three, because the owner asked for "Update Now / Learn More / View
/// Features" and three is where a row of buttons stops fitting a phone.
struct AnnouncementButton: Equatable, Identifiable {
    enum Action: String, CaseIterable, Identifiable {
        case link          // open a web address
        case appStore      // open our App Store page (the "Update Now" button)
        case screen        // jump to a screen inside the app

        var id: String { rawValue }
        var label: String {
            switch self {
            case .link:     return "Open a link"
            case .appStore: return "Update the app"
            case .screen:   return "Open a screen in the app"
            }
        }
    }

    /// Screens a button is allowed to open. AN ALLOWLIST ON PURPOSE: the value travels in a document,
    /// and a free-form route string in a document is a way to send someone somewhere they should not
    /// be sent. Adding a destination is a code change, which is the point.
    /// Only pages that stand on their own. Settings itself and the Account page are deliberately NOT
    /// here: Settings is a tab root, so pushing it inside a chat gives you settings inside a
    /// conversation, and the Account page needs a sign-out handler this screen has no honest way to
    /// provide — a button that opens a page whose main action does nothing is worse than no button.
    enum Screen: String, CaseIterable, Identifiable {
        case appearance, chats, stories, privacy, storage, notifications, invite

        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance:    return "Appearance"
            case .chats:         return "Chats settings"
            case .stories:       return "Stories settings"
            case .privacy:       return "Privacy and Security"
            case .storage:       return "Storage and Data"
            case .notifications: return "Notifications"
            case .invite:        return "Invite Friends"
            }
        }
    }

    /// Identity for SwiftUI's list editing only, never written anywhere. It is DELIBERATELY left out
    /// of `==` below: a fresh UUID is minted every time a button is parsed from Firestore, so an
    /// id-aware equality would make two identical announcements compare unequal on every snapshot —
    /// and the store's "did anything actually change" check would then republish the whole channel on
    /// every listener tick, re-rendering the chat list forever.
    var id = UUID().uuidString
    var label: String
    var action: Action
    /// A web address for `.link`, a `Screen` raw value for `.screen`, ignored for `.appStore`.
    var value: String

    static func == (l: AnnouncementButton, r: AnnouncementButton) -> Bool {
        l.label == r.label && l.action == r.action && l.value == r.value
    }

    /// Named `asMap`, not `map`: `buttons.map(\.map)` is a key path called `map` handed to a method
    /// called `map`, which is legal and awful to read and exactly where a confusing type-check error
    /// comes from.
    var asMap: [String: Any] { ["label": label, "action": action.rawValue, "value": value] }

    init(label: String, action: Action, value: String) {
        self.label = label
        self.action = action
        self.value = value
    }

    init?(map: [String: Any]) {
        guard let label = map["label"] as? String, !label.isEmpty,
              let raw = map["action"] as? String, let action = Action(rawValue: raw)
        else { return nil }
        self.label = label
        self.action = action
        self.value = map["value"] as? String ?? ""
    }

    /// Nothing renders a button we cannot honour — a link with no address is a dead tap.
    var isUsable: Bool {
        switch action {
        case .link:     return URL(string: value)?.scheme?.hasPrefix("http") == true
        case .appStore: return true
        case .screen:   return Screen(rawValue: value) != nil
        }
    }
}

/// Who an announcement is for. Every field here is read ON THE PHONE — see `reaches`.
struct AnnouncementAudience: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case everyone, countries, chosen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyone:  return "Everyone"
            case .countries: return "By country"
            case .chosen:    return "Chosen people"
            }
        }
    }

    var scope: Scope = .everyone
    /// ISO region codes ("SO", "GB"). Matched against the region the PHONE is set to, which is the
    /// only country we honestly know: not every account has a phone number, and we deliberately do
    /// not collect location. The reference app matches on the phone number's calling code for the same purpose.
    var countries: [String] = []
    /// Rollout size in parts per million, the reference app's unit. 1_000_000 = everybody who passes the other
    /// filters. Below that, each phone hashes its own id with the announcement id to decide, so the
    /// same people stay in the rollout on every launch and the server never has to remember anyone.
    var ppm: Int = 1_000_000
    /// Hide from builds older than this. An announcement about a feature an old app does not have is
    /// worse than no announcement.
    var minBuild: Int = 0
    /// Number of chosen recipients, carried for the admin history screen. The list itself is NEVER
    /// stored on the broadcast document — that would publish a list of user ids to every phone in the
    /// world. The copies under each recipient are the only record.
    var chosenCount: Int = 0

    var asMap: [String: Any] {
        ["scope": scope.rawValue, "countries": countries, "ppm": ppm,
         "minBuild": minBuild, "chosenCount": chosenCount]
    }

    init() {}

    init(map: [String: Any]) {
        scope = Scope(rawValue: map["scope"] as? String ?? "") ?? .everyone
        countries = map["countries"] as? [String] ?? []
        ppm = (map["ppm"] as? NSNumber)?.intValue ?? 1_000_000
        minBuild = (map["minBuild"] as? NSNumber)?.intValue ?? 0
        chosenCount = (map["chosenCount"] as? NSNumber)?.intValue ?? 0
    }

    var summary: String {
        switch scope {
        case .everyone:
            return ppm >= 1_000_000 ? "Everyone" : "\(Int(Double(ppm) / 10_000))% of everyone"
        case .countries:
            let names = countries.prefix(3).map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
            let more = countries.count > 3 ? " +\(countries.count - 3)" : ""
            return names.joined(separator: ", ") + more
        case .chosen:
            return "\(chosenCount) \(chosenCount == 1 ? "person" : "people")"
        }
    }
}

/// One announcement. Plain text and plain media on purpose: this is a public broadcast to everybody,
/// so sealing it would be theatre — every phone would hold the key.
struct Announcement: Identifiable, Equatable {
    let id: String
    var kind: AnnouncementKind
    var title: String
    var body: String
    var mediaUrl: String?
    var mediaWidth: Double?
    var mediaHeight: Double?
    var buttons: [AnnouncementButton]
    var audience: AnnouncementAudience
    var publishAt: Date
    var expiresAt: Date?
    var deleted: Bool
    var editedAt: Date?
    var createdBy: String
    var createdAt: Date
    /// Set on the copies written into `users/{uid}/announcements` so the phone knows it was picked
    /// personally and must not re-run the country / rollout filters (it already passed them: a human
    /// chose it).
    var isPersonal: Bool = false
    /// Who a chosen send went to. Present ONLY on the admin-only record in `announcementLog`, never
    /// on anything a phone can read, and it exists for one reason: taking the announcement back. A
    /// withdrawal has to reach every private copy, and without the list there is nothing to reach.
    var recipients: [String] = []

    init(id: String, data: [String: Any], personal: Bool = false) {
        self.id = id
        self.kind = AnnouncementKind(rawValue: data["kind"] as? String ?? "") ?? .news
        self.title = data["title"] as? String ?? ""
        self.body = data["body"] as? String ?? ""
        self.mediaUrl = (data["mediaUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.mediaWidth = (data["mediaWidth"] as? NSNumber)?.doubleValue
        self.mediaHeight = (data["mediaHeight"] as? NSNumber)?.doubleValue
        self.buttons = (data["buttons"] as? [[String: Any]] ?? []).compactMap(AnnouncementButton.init(map:))
        self.audience = AnnouncementAudience(map: data["audience"] as? [String: Any] ?? [:])
        self.publishAt = (data["publishAt"] as? Timestamp)?.dateValue() ?? Date.distantPast
        self.expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue()
        self.deleted = data["deleted"] as? Bool ?? false
        self.editedAt = (data["editedAt"] as? Timestamp)?.dateValue()
        self.createdBy = data["createdBy"] as? String ?? ""
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast
        self.isPersonal = personal
        self.recipients = data["recipients"] as? [String] ?? []
    }

    /// One-line version for the chat list. Deliberately the TITLE, not the body: a release note opens
    /// with "Fariin 2.4 is here", which is what somebody scanning a chat list needs, while the body
    /// opens with a sentence that reads as nothing out of context.
    var preview: String { title.isEmpty ? body : title }

    /// Display order key. The publish time, not the write time, so a scheduled announcement lands
    /// where its date says rather than where it happened to be typed.
    var sortAt: Date { publishAt > Date.distantPast ? publishAt : createdAt }
}

// MARK: - Who gets what, decided here

extension Announcement {
    /// The reference implementation's bucketing method: hash a stable key with the user id into 0..<1_000_000. The
    /// same person always lands in the same bucket for the same announcement, so a 5% rollout is 5%
    /// of people rather than 5% of app launches, and no server has to remember who was picked.
    static func bucket(_ salt: String, _ uid: String) -> Int {
        let digest = SHA256.hash(data: Data("\(salt).\(uid)".utf8))
        var v: UInt64 = 0
        for b in digest.prefix(8) { v = (v << 8) | UInt64(b) }
        return Int(v % 1_000_000)
    }

    /// Is this announcement for me, on this phone, right now?
    ///
    /// Read the order: cheap and certain first (deleted, not yet due, expired), then the app build,
    /// then country, then the rollout dice. A personally-chosen announcement skips country and
    /// rollout entirely — somebody picked this person by hand and a dice roll must not overrule that.
    func reaches(uid: String, build: Int, region: String?, now: Date = Date()) -> Bool {
        if deleted { return false }
        if publishAt > now { return false }
        if let expiresAt, expiresAt <= now { return false }
        if build < audience.minBuild { return false }
        if isPersonal { return true }

        if audience.scope == .countries {
            guard let region, audience.countries.contains(region) else { return false }
        }
        // A broadcast document should never carry `chosen` — but if one does, it is not for anybody
        // who did not receive a personal copy, and silence is the safe reading.
        if audience.scope == .chosen { return false }

        if audience.ppm < 1_000_000 {
            guard Announcement.bucket(id, uid) < audience.ppm else { return false }
        }
        return true
    }
}

// MARK: - Per-person state (device + server, one small document)

/// What THIS person has done with the channel. One document, written only by its owner.
///
/// Muted is the default and costs no write: the reference app mutes the release channel forever at
/// creation (a max-value mute timestamp on each platform) and the promise in the
/// welcome message — "we are here to share important updates, not spam your notifications" — is only
/// true if the mute is real before anybody touches anything.
/// Document shape, for reference when reading the writers below:
/// `{ muted: Bool, blocked: Bool, pinned: Bool, archived: Bool, lastReadAt: ms, clearedAt: ms }`.
/// Every setter writes ONE field with `merge: true` rather than the whole document, so two settings
/// changed on two devices in the same second cannot overwrite each other.
struct OfficialChannelState: Equatable {
    var muted: Bool = true
    var blocked: Bool = false
    var pinned: Bool = false
    var archived: Bool = false
    var lastReadAtMillis: Double = 0
    /// Delete-for-me watermark, same idea as a normal chat's `clearedAt`.
    var clearedAtMillis: Double = 0

    init() {}

    init(data: [String: Any]) {
        muted = data["muted"] as? Bool ?? true
        blocked = data["blocked"] as? Bool ?? false
        pinned = data["pinned"] as? Bool ?? false
        archived = data["archived"] as? Bool ?? false
        lastReadAtMillis = (data["lastReadAt"] as? NSNumber)?.doubleValue ?? 0
        clearedAtMillis = (data["clearedAt"] as? NSNumber)?.doubleValue ?? 0
    }
}

// MARK: - The store

@Observable
final class OfficialChannelStore {
    static let shared = OfficialChannelStore()
    private init() {}

    private let db = Firestore.firestore()
    private var broadcastListener: ListenerRegistration?
    private var personalListener: ListenerRegistration?
    private var stateListener: ListenerRegistration?
    private var dueTimer: Timer?

    /// Everything the server has that could ever be for me, unfiltered. Kept raw so the due-timer can
    /// re-filter without another read when a scheduled announcement's time arrives.
    private var broadcast: [Announcement] = []
    private var personal: [Announcement] = []

    /// What this person should actually see, newest last (chat order).
    private(set) var visible: [Announcement] = []
    private(set) var state = OfficialChannelState()
    private(set) var hasLoaded = false

    // MARK: What the rest of the app asks

    /// The channel shows itself only once it has something to say. The reference app does the same
    /// (a visibility flag that stays false until the first note lands) and it is why a brand-new account
    /// does not open onto an empty official chat.
    ///
    /// `visible` already accounts for a block — see `recompute`, where a blocked channel keeps only
    /// security alerts — so there is no separate blocked check here.
    var isVisible: Bool { !visible.isEmpty }

    var unreadCount: Int {
        visible.filter { $0.sortAt.timeIntervalSince1970 * 1000 > state.lastReadAtMillis }.count
    }

    var latest: Announcement? { visible.last }

    /// The row the chat list draws. A real `Conversation` value so every filter, sort, swipe action
    /// and badge in `ChatsView` keeps working without learning about announcements — the list should
    /// not need a second code path just because one of its rows is ours.
    var listEntry: Conversation? {
        // THE COLD-LAUNCH ROW. This entry exists only once three Firestore listeners have answered,
        // so on every cold start the chat list was drawn WITHOUT it and the row then appeared a beat
        // later and pushed the list around — the owner's report, and the reason the list's own
        // `listSettled` grace exists at all ("the official channel then lands from its own store a
        // moment later and flies in alone").
        //
        // ⚠️ The cached row is only ever used BEFORE the real answer arrives. The moment `hasLoaded`
        // is true the live data decides alone, so an announcement that has been cleared, blocked or
        // has expired removes the row exactly as it always did. A cache that could outlive its own
        // contradiction would be worse than the flicker it replaces.
        if !hasLoaded, let cached = Self.cachedEntry { return cached }
        guard isVisible, let latest, let uid = AuthService.shared.uid else { return nil }
        let at = latest.sortAt
        let conv = Conversation(id: OfficialChannel.cid, data: [
            "users": [uid, OfficialChannel.cid],
            "names": [OfficialChannel.cid: OfficialChannel.name],
            "photos": [String: String](),
            // Plaintext, and `decodedLast` in the chat list knows not to try to decrypt it.
            "lastMessage": latest.preview,
            "lastSender": OfficialChannel.cid,
            "unreadCount": [uid: unreadCount],
            "mutedBy": [uid: state.muted ? Double.greatestFiniteMagnitude : 0],
            "pinnedBy": [uid: state.pinned],
            "archivedBy": [uid: state.archived],
            "clearedAt": [uid: state.clearedAtMillis],
            "updatedAt": Timestamp(date: at),
            "type": "",
            // No `startedBy`, so nothing anywhere reads this as a message request.
        ])
        return conv
    }

    // MARK: Lifecycle

    func start() {
        guard let uid = AuthService.shared.uid else { return }
        stop()

        // The BROADCAST feed: one document per announcement, the same for everybody on earth.
        // No `where` on publishAt — a query filtered by a timestamp captured at attach time would
        // never see an announcement published a minute later, which is every immediate send. The
        // due check lives in `reaches` instead, and the timer below re-runs it.
        //
        // The cost of that: a scheduled announcement sits on the server, readable, from the moment it
        // is written. That is exactly the reference app's exposure (their release-notes file is public on a CDN
        // the moment it is uploaded), and it is why scheduling is a convenience and not a secret.
        broadcastListener = db.collection("announcements")
            .order(by: "publishAt", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snap, error in
                guard let self else { return }
                if let error { print("announcements listen error:", error); return }
                guard let snap else { return }
                self.broadcast = snap.documents.map { Announcement(id: $0.documentID, data: $0.data()) }
                self.recompute()
            }

        // Announcements sent to THIS person by hand. A real copy, because the phone cannot filter on
        // a list it is not allowed to see.
        personalListener = db.collection("users").document(uid).collection("announcements")
            .order(by: "publishAt", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                self.personal = snap.documents.map {
                    Announcement(id: $0.documentID, data: $0.data(), personal: true)
                }
                self.recompute()
            }

        stateListener = db.collection("users").document(uid)
            .collection("officialChannel").document("state")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                // A missing document is the muted default, not an error. Nobody should have to pay a
                // write to be left alone.
                self.state = OfficialChannelState(data: snap?.data() ?? [:])
                self.recompute()
                // THE ONLY PLACE THAT DECIDES WHAT THIS PHONE HEARS. Put here rather than in
                // `setMuted` because this fires for all three ways the answer can change: the app
                // launching, this phone muting, and the account's OTHER phone muting. A mute made on
                // one device that left the other still being knocked on would read as the switch
                // being broken.
                OfficialPushTopics.sync(muted: self.state.muted)
            }

        // A scheduled announcement becomes due while the app is open, and no snapshot fires for the
        // passage of time. One minute is fine: this is a release note, not a message.
        //
        // Scheduled on the MAIN queue explicitly. A Timer attaches to the run loop of whatever thread
        // creates it, and a background thread's run loop is not running — the timer would simply
        // never fire, silently, and only for scheduled announcements, which is the hardest kind of
        // bug to notice.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.broadcastListener != nil else { return }   // stopped before we landed
            self.dueTimer?.invalidate()
            self.dueTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.recompute()
            }
        }
    }

    func stop() {
        broadcastListener?.remove(); broadcastListener = nil
        personalListener?.remove(); personalListener = nil
        stateListener?.remove(); stateListener = nil
        dueTimer?.invalidate(); dueTimer = nil
    }

    /// Sign-out / account switch: the next account on this phone must not inherit the last one's
    /// channel, its read watermark or its mute.
    func reset() {
        stop()
        broadcast = []
        personal = []
        visible = []
        state = OfficialChannelState()
        hasLoaded = false
        // Topics outlive a sign-out: they are attached to the phone's FCM token, not to the account.
        // Left alone, the next person to sign in on this handset would inherit the last one's alerts.
        OfficialPushTopics.leaveAll()
    }

    // MARK: The filter

    private func recompute() {
        guard let uid = AuthService.shared.uid else { return }
        let build = Self.currentBuild
        let region = Locale.current.region?.identifier
        let cleared = state.clearedAtMillis

        // A personal copy WINS over a broadcast of the same id: it means somebody picked this person
        // deliberately, and its `isPersonal` flag is what waives the rollout dice.
        //
        // WITH ONE EXCEPTION, and it is the whole reason this is not a one-line merge. Taking an
        // announcement back writes the tombstone on the SHARED document — the shared document cannot
        // carry the list of who got a personal copy (that would publish user ids to every phone on
        // earth), so a withdrawal cannot reach into everybody's private collection to strike their
        // copy too. If the personal copy simply won, a deleted announcement would stay on screen
        // forever for exactly the people it was sent to by hand. So: personal wins on CONTENT,
        // deletion wins from either side.
        var byId: [String: Announcement] = [:]
        for a in broadcast { byId[a.id] = a }
        for a in personal {
            var merged = a
            if byId[a.id]?.deleted == true { merged.deleted = true }
            byId[a.id] = merged
        }

        let next = byId.values
            .filter { $0.reaches(uid: uid, build: build, region: region) }
            .filter { $0.sortAt.timeIntervalSince1970 * 1000 > cleared }   // delete-for-me
            // BLOCKING STOPS THE NEWS, NOT THE ALARM. Read from another mainstream messenger's own block sheet, which
            // says so out loud: "You may still receive messages with important information about your
            // account". Somebody who blocks this chat is saying they do not want to hear about new
            // features. They are not saying they would rather not be told that their account was
            // signed into from another country.
            //
            // Muting is the softer of the two and stops nothing; blocking is the hard one and stops
            // everything except this. Without the carve-out, the Chat Info screen's promise that
            // blocking "does not stop us telling you if something happens to your account" would be a
            // sentence the app does not keep, which is worse than not offering the block at all.
            .filter { !state.blocked || $0.kind == .security }
            .sorted { $0.sortAt == $1.sortAt ? $0.id < $1.id : $0.sortAt < $1.sortAt }

        hasLoaded = true
        if next != visible { visible = next }   // assign only on a real change: no needless re-render
        // ⚠️ THE CACHE IS REFRESHED EVEN WHEN THE ANNOUNCEMENTS DID NOT CHANGE, and that is the
        // whole point. This used to sit behind `guard next != visible else { return }`, so it only
        // ran when the LIST changed — but the unread count, the mute flag and the pin come from
        // `state`, which has its own listener and leaves the list untouched. Reading the channel
        // therefore never rewrote the cache, and the next cold start dealt out the old badge:
        // "3" on the first frame and nothing a moment later, which is exactly what the owner
        // photographed frame by frame (2026-08-16).
        //
        // A cache that is only refreshed when part of its content changes is a cache that lies about
        // the rest of it.
        Self.cacheEntry(listEntry)
    }

    // MARK: The launch copy

    /// One row, on disk, read synchronously so the FIRST frame of the chat list can include it.
    ///
    /// Deliberately the finished row rather than the announcements behind it: rebuilding those means
    /// re-running the audience, schedule, block and delete-for-me filters, and every one of those can
    /// change while the app is closed. Storing the answer and throwing it away the instant the real
    /// one arrives keeps this to one honest job — filling a gap, never deciding anything.
    private static let entryDefaultsKey = "official.listEntry.v1"

    private static var cachedEntry: Conversation? {
        guard let uid = AuthService.shared.uid,
              let box = UserDefaults.standard.dictionary(forKey: entryDefaultsKey),
              // Per account. Without this the next person to sign in on this phone is handed the
              // last one's unread count and pinned state on their first frame.
              box["uid"] as? String == uid,
              let body = box["doc"] as? [String: Any],
              let millis = box["updatedAtMillis"] as? Double
        else { return nil }
        var doc = body
        // `updatedAt` is a `Timestamp`, which no property list can hold, so it travels as a number
        // and is rebuilt here. It is load-bearing: the chat list sorts on it, and a row arriving
        // with no date sorts to the bottom of the list, which is not where this row lives.
        doc["updatedAt"] = Timestamp(date: Date(timeIntervalSince1970: millis / 1000))
        return Conversation(id: OfficialChannel.cid, data: doc)
    }

    private static func cacheEntry(_ entry: Conversation?) {
        guard let uid = AuthService.shared.uid else { return }
        guard let entry else {
            UserDefaults.standard.removeObject(forKey: entryDefaultsKey)
            return
        }
        let doc: [String: Any] = [
            "users": entry.users,
            "names": entry.names,
            "photos": [String: String](),
            "lastMessage": entry.lastMessageCipher,
            "lastSender": entry.lastSender,
            "unreadCount": entry.unreadCount,
            "mutedBy": entry.mutedBy,
            "pinnedBy": entry.pinnedBy,
            "archivedBy": entry.archivedBy,
            "clearedAt": entry.clearedAt,
            "type": "",
        ]
        UserDefaults.standard.set(["uid": uid, "doc": doc, "updatedAtMillis": entry.updatedAtMillis],
                                  forKey: entryDefaultsKey)
    }

    /// Signing out takes the launch copy with it — see SessionWipe.
    static func clearCachedEntry() {
        UserDefaults.standard.removeObject(forKey: entryDefaultsKey)
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    // MARK: What the person can do

    private var stateRef: DocumentReference? {
        guard let uid = AuthService.shared.uid else { return nil }
        return db.collection("users").document(uid).collection("officialChannel").document("state")
    }

    func markRead() {
        guard let latest, !visible.isEmpty else { return }
        let at = latest.sortAt.timeIntervalSince1970 * 1000
        guard at > state.lastReadAtMillis else { return }
        state.lastReadAtMillis = at          // optimistic, so the badge clears on the tap
        stateRef?.setData(["lastReadAt": at], merge: true)
        // The read COUNT is not bumped here. It is bumped by each bubble as it comes on screen, so
        // "opened by" means somebody actually looked at that announcement — and so that opening a
        // channel holding twenty of them does not fire twenty writes in one breath.
    }

    func setMuted(_ muted: Bool) {
        state.muted = muted
        stateRef?.setData(["muted": muted], merge: true)
        // Locally too, not only through the listener above. The write has to reach Doha and come
        // back before that fires, and on a bad connection that is seconds in which the bell reads
        // OFF while an announcement could still knock. Both calls land on the same set, and the
        // second one is free.
        OfficialPushTopics.sync(muted: muted)
    }

    /// Mark Unread from the chat list: pull the watermark back behind the newest announcement so
    /// exactly one comes back unread, which is what the badge on a normal chat does.
    func markUnread() {
        guard let latest else { return }
        let at = latest.sortAt.timeIntervalSince1970 * 1000 - 1
        state.lastReadAtMillis = at
        stateRef?.setData(["lastReadAt": at], merge: true)
    }

    func setPinned(_ pinned: Bool) {
        state.pinned = pinned
        stateRef?.setData(["pinned": pinned], merge: true)
    }

    func setArchived(_ archived: Bool) {
        state.archived = archived
        stateRef?.setData(["archived": archived], merge: true)
    }

    /// The way out the welcome message promises. Blocking hides the chat completely and stops the
    /// read counters; it does not delete anything, so unblocking brings the history back.
    func setBlocked(_ blocked: Bool) {
        state.blocked = blocked
        stateRef?.setData(["blocked": blocked], merge: true)
    }

    func clearHistory() {
        let now = Date().timeIntervalSince1970 * 1000
        state.clearedAtMillis = now
        stateRef?.setData(["clearedAt": now], merge: true)
        recompute()
    }
}

// MARK: - How many people read it

/// Read counts without a row per person. Every phone that opens an announcement bumps ONE of a
/// hundred counter documents picked at random, and the admin screen adds them up — a plain
/// `increment` on a single document would serialise every reader in the world behind one lock, which
/// Firestore caps at roughly one write a second.
///
/// This gives a NUMBER, never a name. For a send to chosen people the per-person copy already says
/// exactly who, so that screen can be honest about individuals; a broadcast cannot and should not.
enum AnnouncementStats {
    static let shardCount = 100

    private static var countedThisLaunch = Set<String>()
    private static let lock = NSLock()

    static func countRead(_ a: Announcement) {
        guard let uid = AuthService.shared.uid else { return }
        // Once per person per announcement, remembered on the device. The point of the number is
        // "how many people saw this", so re-opening the chat must not inflate it.
        let key = "officialRead-\(uid)-\(a.id)"
        lock.lock()
        let alreadyThisLaunch = countedThisLaunch.contains(key)
        if !alreadyThisLaunch { countedThisLaunch.insert(key) }
        lock.unlock()
        guard !alreadyThisLaunch, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let shard = Int.random(in: 0..<shardCount)
        Firestore.firestore()
            .collection("announcements").document(a.id)
            .collection("readShards").document("\(shard)")
            .setData(["count": FieldValue.increment(Int64(1))], merge: true)
    }

    /// Adds the hundred shards up. Admin screens only.
    static func readTotal(_ announcementId: String) async -> Int {
        let snap = try? await Firestore.firestore()
            .collection("announcements").document(announcementId)
            .collection("readShards").getDocuments()
        return (snap?.documents ?? []).reduce(0) { $0 + (($1.data()["count"] as? NSNumber)?.intValue ?? 0) }
    }
}
