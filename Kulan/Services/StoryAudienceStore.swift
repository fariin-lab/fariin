import Foundation
import Observation
import FirebaseFirestore

// MARK: - The audience

/// ONE NAMED AUDIENCE a story can be posted to — Signal calls these distribution lists, and the
/// reason they exist is that a story's audience is a decision you make once and reuse, not a form
/// you fill in every time you post.
///
/// THE AUDIENCE IS RESOLVED AT POST TIME AND THEN FORGOTTEN. A story carries the `recipientUids` it
/// was posted with; nothing about it points back at the list it came from. That is what makes the
/// owner's rule true by construction rather than by care: editing a list, renaming it, or deleting
/// it outright cannot reach a story that has already gone out. Signal works the same way and for the
/// same reason.
struct StoryAudience: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        /// Everyone on Fariin. Not a feed: people you have interacted with get it in their tray like
        /// any other story, and anybody else can watch it only by reaching your profile. Fixed, not
        /// editable — the owner's rule.
        case everyone
        /// The people you share an accepted chat with, optionally narrowed. Signal's "My Story".
        case myFriends
        /// A named list of specific people.
        case custom
        /// NOT AN AUDIENCE. The people hidden from your stories entirely, whichever audience you
        /// pick — "Hide my stories from X" off a viewer row. Stored as a list because it is one,
        /// and kept out of `all` so it can never be posted to.
        case hidden
    }

    /// How the underlying set of people is narrowed. `custom` is always `.only` over its own members.
    enum Mode: String, Codable { case all, except, only }

    let id: String
    var kind: Kind
    /// Custom lists only. The built-ins draw their own titles, and this is never shown to anybody
    /// else — "only you can see the name of this story."
    var name: String
    var mode: Mode
    /// `.except` → the people shut out. `.only` and every custom list → the people let in.
    var members: [String]
    var allowReplies: Bool
    var createdAt: Date

    /// The two fixed ids. Custom lists get a uuid, so neither can ever be taken.
    static let everyoneId = "everyone"
    static let myFriendsId = "myFriends"
    static let hiddenId = "hiddenFrom"

    /// ⚠️ NOT `Date.distantPast`, AND THIS CRASHED THE APP IN BUILD 470.
    ///
    /// The built-ins only need a date that sorts before any real custom story. `.distantPast` looked
    /// like the honest way to say that, and it is **two days below the earliest timestamp Firestore
    /// will accept**: Foundation puts it at -62135769600 seconds from 1970, Firestore's floor is
    /// -62135596800. `FIRTimestamp` does not return an error for that, it raises an NSException —
    /// so toggling "Allow Replies & Reactions" on the My Friends page killed the app, because that
    /// toggle writes the list and the list carried this date.
    ///
    /// The epoch sorts before everything real and is comfortably inside the range. `write` clamps as
    /// well, so no future date from any source can reach Firestore out of range.
    static let sortsFirst = Date(timeIntervalSince1970: 0)

    static let everyone = StoryAudience(id: everyoneId, kind: .everyone, name: "Everyone",
                                        mode: .all, members: [], allowReplies: true,
                                        createdAt: sortsFirst)
    static let defaultMyFriends = StoryAudience(id: myFriendsId, kind: .myFriends, name: "My Friends",
                                                mode: .all, members: [], allowReplies: true,
                                                createdAt: sortsFirst)

    var title: String {
        switch kind {
        case .everyone: return "Everyone"
        case .myFriends: return "My Friends"
        case .custom: return name
        case .hidden: return ""
        }
    }

    /// How many people this reaches, given the accepted-chat set. Everyone's count is the tray
    /// audience — the profile half has no number, because it is however many people find you.
    func viewerCount(contacts: Set<String>) -> Int {
        recipients(contacts: contacts).count
    }

    /// THE ONE PLACE A LIST BECOMES A SET OF PEOPLE. Every caller — the post, the subtitle, the empty
    /// check — goes through this, so they cannot disagree about who an audience means.
    ///
    /// Everything is intersected with the accepted-chat set, so a list holding somebody you have
    /// since blocked or lost the chat with quietly stops reaching them instead of posting into a
    /// hole. Blocked people are already out of `contacts` before it gets here.
    func recipients(contacts: Set<String>, hiddenFrom: Set<String> = []) -> Set<String> {
        // "Hide my stories from X" beats every audience, including Everyone. Subtracted last so no
        // list, however it was built, can put somebody back in.
        return rawRecipients(contacts: contacts).subtracting(hiddenFrom)
    }

    private func rawRecipients(contacts: Set<String>) -> Set<String> {
        switch kind {
        case .everyone:
            // Delivered to the tray of everyone you have a chat with, exactly like My Friends. What
            // "Everyone" adds is the `isPublic` flag below, which is a PROFILE reach, not a feed.
            return contacts
        case .myFriends:
            switch mode {
            case .all: return contacts
            case .except: return contacts.subtracting(members)
            case .only: return Set(members).intersection(contacts)
            }
        case .custom:
            return Set(members).intersection(contacts)
        case .hidden:
            return []          // never an audience — see Kind.hidden
        }
    }

    /// Reachable by anyone who lands on your profile. True for Everyone and nothing else.
    var isPublic: Bool { kind == .everyone }

    /// The grey line under the title in every list this appears in.
    func subtitle(contacts: Set<String>) -> String {
        switch kind {
        case .everyone: return "All Fariin connections"
        case .myFriends:
            switch mode {
            case .all: return "All chats you accepted"
            case .except: return "All chats you accepted except \(members.count)"
            case .only: return "\(members.count) selected"
            }
        case .custom:
            let n = members.count
            return "Custom story · \(n) \(n == 1 ? "viewer" : "viewers")"
        case .hidden: return ""
        }
    }
}

// MARK: - The store

/// Every audience the user owns, live.
///
/// FIRESTORE IS THE TRUTH AND THE DISK IS THE COPY. The lists live at `users/{me}/storyLists/{id}`
/// so they follow the account to a new phone, but the share sheet opens on a tap and cannot wait for
/// a network round trip to know what to draw — so every load is mirrored to disk and every launch
/// starts from that mirror. A cold start with no network shows the lists you had; the listener
/// corrects them when it arrives.
@Observable
final class StoryAudienceStore {
    static let shared = StoryAudienceStore()

    /// His ceiling ("the maximum number of Custom Stories is 5"). It also bounds the share sheet's
    /// height, which sizes itself to the list — see `ShareStorySheet`.
    static let maxCustom = 5

    /// Fixed. `Everyone` cannot be edited (owner's rule), so it is a constant rather than a document.
    let everyone = StoryAudience.everyone
    /// Editable, and stored — its mode and its except/only list have to follow the account.
    private(set) var myFriends = StoryAudience.defaultMyFriends
    private(set) var custom: [StoryAudience] = []
    /// People hidden from every story, whatever audience it is posted to. See `Kind.hidden`.
    private(set) var hiddenFrom: Set<String> = []

    /// Which audience the next post goes to. Remembered between posts, as every messenger does.
    ///
    /// Written through `select(_:)` rather than by a `didSet`: `@Observable` rewrites every stored
    /// property into a computed one over hidden storage, and a property observer on top of that is
    /// at best undefined. A method is one line longer and cannot be quietly dropped by a macro.
    private(set) var selectedId: String

    func select(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
    }

    private var listener: ListenerRegistration?
    private var loadedFor = ""
    private let db = Firestore.firestore()
    private static let mirrorKey = "storyAudienceMirror"
    private static let selectedKey = "storyAudienceSelected"

    private init() {
        selectedId = UserDefaults.standard.string(forKey: Self.selectedKey) ?? StoryAudience.myFriendsId
        loadMirror()
    }

    /// Everything the pickers draw, in the order they draw it: the two built-ins, then the custom
    /// lists oldest first so a new one appears at the bottom where it was added.
    var all: [StoryAudience] { [everyone, myFriends] + custom }

    func audience(id: String) -> StoryAudience? { all.first { $0.id == id } }

    /// The audience the next post should use. Falls back to My Friends rather than to nothing, so a
    /// list deleted while it was selected cannot leave a post with no audience at all.
    var selected: StoryAudience { audience(id: selectedId) ?? myFriends }

    // MARK: Loading

    func start(uid: String) {
        guard !uid.isEmpty, uid != loadedFor else { return }
        stop()
        loadedFor = uid
        listener = db.collection("users").document(uid).collection("storyLists")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                var friends = StoryAudience.defaultMyFriends
                var lists: [StoryAudience] = []
                var hidden: Set<String> = []
                for d in docs {
                    guard let a = Self.decode(id: d.documentID, data: d.data()) else { continue }
                    if a.id == StoryAudience.myFriendsId { friends = a }
                    else if a.kind == .hidden { hidden = Set(a.members) }
                    else if a.kind == .custom { lists.append(a) }
                }
                self.myFriends = friends
                self.hiddenFrom = hidden
                self.custom = lists.sorted { $0.createdAt < $1.createdAt }
                self.saveMirror()
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
        loadedFor = ""
    }

    /// Signing out must not leave the next account looking at this one's lists — the mirror is on
    /// disk and would otherwise outlive the session that wrote it.
    func clear() {
        stop()
        myFriends = .defaultMyFriends
        custom = []
        hiddenFrom = []
        select(StoryAudience.myFriendsId)
        UserDefaults.standard.removeObject(forKey: Self.mirrorKey)
    }

    // MARK: Writing

    /// Create a custom story and return it, already visible. The write is fire-and-forget and the
    /// listener will confirm it: the create flow ends by selecting this list and posting, and making
    /// that wait on a round trip is how a story post comes to depend on the network twice.
    var canAddCustom: Bool { custom.count < Self.maxCustom }

    func isHidden(_ uid: String) -> Bool { hiddenFrom.contains(uid) }

    /// "Hide my stories from X", and the same door back out again.
    ///
    /// GLOBAL, not per-audience. A custom list narrows one story; this one says "not this person,
    /// ever", and it has to survive whichever audience is picked next — which is why it is its own
    /// list and why `recipients(contacts:)` subtracts it for every kind including Everyone.
    func setHidden(_ uid: String, _ hidden: Bool) {
        guard !uid.isEmpty else { return }
        if hidden { hiddenFrom.insert(uid) } else { hiddenFrom.remove(uid) }
        saveMirror()
        write(StoryAudience(id: StoryAudience.hiddenId, kind: .hidden, name: "",
                            mode: .except, members: Array(hiddenFrom), allowReplies: true,
                            createdAt: StoryAudience.sortsFirst))
    }

    @discardableResult
    func createCustom(name: String, members: [String], allowReplies: Bool) -> StoryAudience {
        let a = StoryAudience(id: UUID().uuidString, kind: .custom,
                              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              mode: .only, members: members, allowReplies: allowReplies,
                              createdAt: Date())
        custom.append(a)
        saveMirror()
        write(a)
        return a
    }

    func update(_ a: StoryAudience) {
        if a.id == StoryAudience.myFriendsId {
            myFriends = a
        } else if let i = custom.firstIndex(where: { $0.id == a.id }) {
            custom[i] = a
        } else {
            return
        }
        saveMirror()
        write(a)
    }

    func delete(_ a: StoryAudience) {
        guard a.kind == .custom else { return }   // neither built-in can be removed
        custom.removeAll { $0.id == a.id }
        if selectedId == a.id { select(StoryAudience.myFriendsId) }
        saveMirror()
        guard !loadedFor.isEmpty else { return }
        db.collection("users").document(loadedFor).collection("storyLists").document(a.id).delete()
    }

    private func write(_ a: StoryAudience) {
        guard !loadedFor.isEmpty else { return }
        db.collection("users").document(loadedFor).collection("storyLists").document(a.id)
            .setData([
                "kind": a.kind.rawValue,
                "name": a.name,
                "mode": a.mode.rawValue,
                "members": a.members,
                "allowReplies": a.allowReplies,
                // CLAMPED, not trusted. Firestore raises rather than returning an error for a date
                // outside 0001-01-01 … 9999-12-31, and a raise from a background write is a crash
                // with no catch anywhere near it. This date comes from a decode, a disk mirror and
                // two constants, so it is exactly the kind of value that only has to be wrong once.
                "createdAt": Timestamp(date: Self.firestoreSafe(a.createdAt)),
            ], merge: true)
    }

    /// Firestore accepts 0001-01-01 through 9999-12-31 and RAISES outside it. Kept a decade inside
    /// each end, because nothing here needs the extremes and an exception on a write we do not await
    /// is a crash rather than a failure.
    private static func firestoreSafe(_ d: Date) -> Date {
        let floor = Date(timeIntervalSince1970: -62135596800 + 315_360_000)   // 0011-01-01
        let ceiling = Date(timeIntervalSince1970: 253402300800 - 315_360_000) // 9989-01-01
        return min(max(d, floor), ceiling)
    }

    private static func decode(id: String, data: [String: Any]) -> StoryAudience? {
        guard let kind = StoryAudience.Kind(rawValue: data["kind"] as? String ?? "") else { return nil }
        return StoryAudience(
            id: id,
            kind: kind,
            name: data["name"] as? String ?? "",
            mode: StoryAudience.Mode(rawValue: data["mode"] as? String ?? "") ?? .all,
            members: data["members"] as? [String] ?? [],
            allowReplies: data["allowReplies"] as? Bool ?? true,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }

    // MARK: The disk mirror

    private struct DiskCopy: Codable {
        var myFriends: StoryAudience
        var custom: [StoryAudience]
        /// Optional so a mirror written before hiding existed still decodes.
        var hiddenFrom: [String]? = nil
    }

    private func saveMirror() {
        let m = DiskCopy(myFriends: myFriends, custom: custom, hiddenFrom: Array(hiddenFrom))
        guard let d = try? JSONEncoder().encode(m) else { return }
        UserDefaults.standard.set(d, forKey: Self.mirrorKey)
    }

    private func loadMirror() {
        guard let d = UserDefaults.standard.data(forKey: Self.mirrorKey),
              let m = try? JSONDecoder().decode(DiskCopy.self, from: d) else { return }
        myFriends = m.myFriends
        custom = m.custom
        hiddenFrom = Set(m.hiddenFrom ?? [])
    }
}
