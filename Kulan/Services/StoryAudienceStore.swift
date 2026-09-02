import Foundation
import Observation
import FirebaseFirestore

// MARK: - The audience

/// ONE NAMED AUDIENCE a story can be posted to — the reference app calls these distribution lists, and the
/// reason they exist is that a story's audience is a decision you make once and reuse, not a form
/// you fill in every time you post.
///
/// THE AUDIENCE IS RESOLVED AT POST TIME AND THEN FORGOTTEN. A story carries the `recipientUids` it
/// was posted with; nothing about it points back at the list it came from. That is what makes the
/// owner's rule true by construction rather than by care: editing a list, renaming it, or deleting
/// it outright cannot reach a story that has already gone out. The reference app works the same way
/// and for the same reason.
struct StoryAudience: Identifiable, Codable, Equatable {
    /// The longest a custom story name may be — his 2026-08-12 limit.
    ///
    /// It lives on the model rather than on either screen because there are two ways in: the create
    /// sheet, which clamps as you type, and the rename alert, which cannot (an alert's builder has
    /// no `onChange`) and so trims on save. One number, two enforcement points, no way for them to
    /// drift apart.
    static let nameLimit = 25

    enum Kind: String, Codable {
        /// Everyone on Fariin. Not a feed: people you have interacted with get it in their tray like
        /// any other story, and anybody else can watch it only by reaching your profile. Fixed, not
        /// editable — the owner's rule.
        case everyone
        /// The people you share an accepted chat with, optionally narrowed. The reference app's equivalent audience.
        case myFriends
        /// A named list of specific people.
        case custom
        /// ⛔ GLOWERS — his Glow feature, 2026-09-02. Everyone in a glow relationship with me, in
        /// EITHER direction (people who glowed me, plus people I glowed), which is his ruling: a
        /// glow reaches immediately and "Glow back" is social rather than a key.
        ///
        /// ⚠️ **THE ONLY AUDIENCE THAT IS NOT A SUBSET OF YOUR CHATS, AND THAT IS THE WHOLE
        /// POINT.** Every other kind ends up intersected with the accepted-chat set, because every
        /// other kind describes people you talk to. Glow exists precisely so two people who have
        /// never chatted can reach each other — so intersecting this one would resolve it to
        /// nobody, silently, and the story would upload wearing a normal ring and reach no one.
        /// `rawRecipients` and `StoriesService.resolveAudience` each carry that exception; they are
        /// the two places a Glowers story could be quietly emptied.
        case glowers
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

    /// The fixed ids. Custom lists get a uuid, so none of these can ever be taken.
    static let everyoneId = "everyone"
    static let myFriendsId = "myFriends"
    static let glowersId = "glowers"
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
    /// ⚠️ BUILT-IN AND MEMBERLESS. Its people are the live glow relationship, not a stored list, so
    /// there is nothing to edit and nothing to keep in sync — the same shape as Everyone. It is
    /// never written to Firestore for that reason: a `storyLists` document for it would be a second
    /// copy of an answer `GlowService` already holds.
    static let glowersAudience = StoryAudience(id: glowersId, kind: .glowers, name: "Glowers",
                                               mode: .all, members: [], allowReplies: true,
                                               createdAt: sortsFirst)

    var title: String {
        switch kind {
        case .everyone: return "Everyone"
        case .myFriends: return "My Friends"
        case .glowers: return "Glowers"
        case .custom: return name
        case .hidden: return ""
        }
    }

    /// How many people this reaches, given the accepted-chat set. Everyone's count is the tray
    /// audience — the profile half has no number, because it is however many people find you.
    func viewerCount(contacts: Set<String>, glow: Set<String> = []) -> Int {
        recipients(contacts: contacts, glow: glow).count
    }

    /// THE ONE PLACE A LIST BECOMES A SET OF PEOPLE. Every caller — the post, the subtitle, the empty
    /// check — goes through this, so they cannot disagree about who an audience means.
    ///
    /// Everything is intersected with the accepted-chat set, so a list holding somebody you have
    /// since blocked or lost the chat with quietly stops reaching them instead of posting into a
    /// hole. Blocked people are already out of `contacts` before it gets here.
    /// ⚠️ `glow` IS PASSED IN, EXACTLY LIKE `contacts`, AND THAT IS NOT A STYLE CHOICE. This type is
    /// a pure value: it is `Sendable`, it is read from background contexts, and it answers questions
    /// off the sets it is HANDED. The first version of the Glowers audience reached into
    /// `GlowService.shared` from in here and the compiler refused it — "main actor-isolated property
    /// cannot be referenced from a nonisolated context", twice — which was the type defending the
    /// pattern. Callers that know the glow set pass it; the ones that cannot pass nothing, and a
    /// Glowers audience then honestly reaches nobody rather than lying from a stale singleton.
    func recipients(contacts: Set<String>, hiddenFrom: Set<String> = [],
                    glow: Set<String> = []) -> Set<String> {
        // ⚠️ NAMING SOMEBODY OUTRANKS HIDING THEM, and it did not. "Hide my stories from X" used
        // to be subtracted from EVERY audience, so a Custom list built by hand and containing one
        // person who happens to be on that list resolved to nobody — the owner hid Jini from
        // Everyone, put Jini in a custom list, and got "No one will see this" (2026-08-19).
        //
        // The two are different kinds of instruction. Hiding is a rule about BROADCAST reach: it
        // answers "when I post to everybody, who is not part of everybody". A custom list is not a
        // broadcast, it is a named set of people, and putting a name in it is a deliberate act that
        // has to beat a standing rule about crowds — otherwise the app silently refuses an
        // instruction it just watched somebody give, which is what he saw.
        //
        // Blocks are NOT affected: those are removed from `contacts` before this is called, in both
        // directions, and no list can put them back.
        let raw = rawRecipients(contacts: contacts, glow: glow)
        return appliesGlobalHide ? raw.subtracting(hiddenFrom) : raw
    }

    /// ⛔ THE HIDE LIST BELONGS TO **EVERYONE**, AND TO NOTHING ELSE (owner, 2026-08-20).
    ///
    /// Each audience keeps its own exclusions and they do not leak into one another. "Hide my
    /// stories from X" is reached from the Everyone page and answers one question — "when I post to
    /// everybody, who is not part of everybody". My Friends already carries its own except-list, a
    /// custom list is a set of names somebody typed, and a one-time story is a person chosen by
    /// hand; none of those should inherit a rule written for the crowd.
    ///
    /// Before this, the hide was subtracted from every audience that did not explicitly name people,
    /// so hiding A from Everyone also removed A from a My Friends post, and the one-time flow
    /// subtracted the list before it even reached here — which is how a story addressed to exactly
    /// one person resolved to nobody and refused to post.
    var appliesGlobalHide: Bool { kind == .everyone }


    /// Does this audience NAME people, or describe a crowd? A named set beats the global hide list;
    /// a crowd does not. See `recipients`.
    var namesPeopleExplicitly: Bool {
        switch kind {
        case .custom:    return true
        case .myFriends: return mode == .only    // "only these people" is a list, the others are rules
        case .everyone:  return false
        // A crowd, like Everyone: "whoever I have a glow with" is a rule, not a set of names
        // somebody typed. It never meets the global hide list anyway (`appliesGlobalHide` is
        // Everyone alone), so this only answers the question honestly rather than changing reach.
        case .glowers:   return false
        case .hidden:    return false
        }
    }

    private func rawRecipients(contacts: Set<String>, glow: Set<String>) -> Set<String> {
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
        case .glowers:
            return glow
            // ⛔ NOT INTERSECTED WITH `contacts`, AND THAT IS THE FEATURE. Every branch above ends
            // in the accepted-chat set because every audience above describes people you talk to.
            // Glow exists so two people who have NEVER chatted can reach each other, so an
            // intersection here would resolve this audience to the empty set for exactly the people
            // it was built for — silently, since an empty audience is an accepted post.
            //
            // Either direction, his ruling: people who glowed me plus people I glowed.
        case .hidden:
            return []          // never an audience — see Kind.hidden
        }
    }

    /// Reachable by anyone who lands on your profile. True for Everyone and nothing else.
    var isPublic: Bool { kind == .everyone }

    /// The grey line under the title in every list this appears in.
    func subtitle(contacts: Set<String>, glow: Set<String> = []) -> String {
        switch kind {
        case .everyone: return "All Fariin connections"
        case .myFriends:
            switch mode {
            case .all: return "All chats you accepted"
            case .except: return "All chats you accepted except \(members.count)"
            case .only: return "\(members.count) selected"
            }
        case .glowers:
            // Counted off the live relationship, not off `members` — this audience has none.
            let n = glow.count
            return n == 0 ? "People you have a Glow with"
                          : "\(n) \(n == 1 ? "person" : "people") you have a Glow with"
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
    /// ⛔ GLOWERS SITS THIRD, AFTER THE TWO BUILT-INS AND BEFORE THE CUSTOM LISTS — his feature,
    /// 2026-09-02. It is a built-in, not a custom list: memberless, never written to Firestore,
    /// and its people are `GlowService`'s live answer. Third rather than second so the two audiences
    /// that have always been there keep their order and their muscle memory.
    ///
    /// ⚠️ IT IS ALWAYS OFFERED, even with no glows yet. A row that appears only once somebody
    /// glows you is a feature nobody discovers — its subtitle carries the count, so an empty one
    /// explains itself, and posting to it is the same accepted-empty case every audience has.
    ///
    /// ⚠️ He has a CUSTOM list literally named "Glowers" from before this existed (his 2026-09-02
    /// screenshot of the share sheet). This does not touch it: it is a different id and a different
    /// kind, so the two can sit in the same sheet. Tell him to delete his by hand if he wants to.
    var all: [StoryAudience] { [everyone, myFriends, .glowersAudience] + custom }

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
    /// ⛔ THIS LIST IS THE **EVERYONE** AUDIENCE'S, AND NO OTHER AUDIENCE INHERITS IT (owner,
    /// 2026-08-20, reversing the earlier "not this person, ever" reading). Each audience keeps its
    /// own exclusions: My Friends has its except-list, a custom story has the names in it, a one-time
    /// story has the person picked for it. Hiding somebody from the crowd is not an instruction about
    /// a list you then build by hand. See `StoryAudience.appliesGlobalHide`.
    func setHidden(_ uid: String, _ hidden: Bool) {
        guard !uid.isEmpty else { return }
        if hidden { hiddenFrom.insert(uid) } else { hiddenFrom.remove(uid) }
        saveMirror()
        write(StoryAudience(id: StoryAudience.hiddenId, kind: .hidden, name: "",
                            mode: .except, members: Array(hiddenFrom), allowReplies: true,
                            createdAt: StoryAudience.sortsFirst))
        // ⚠️ AND THE STORIES THAT ARE ALREADY UP, which this did not touch.
        //
        // The hidden list was applied at POST time only (`resolveAudience`), so adding somebody here
        // did nothing to the stories they could already see: for up to 24 hours they kept the ring,
        // kept watching, and kept appearing in the author's Seen by list. Somebody hiding their
        // story from a person is not asking for that to start tomorrow.
        //
        // `revokeAudience` is exactly this operation and already existed — it is what BLOCK calls
        // (ChatService, on block), and it takes the uid out of `recipientUids` on every live story.
        // Hiding was simply never wired to it. Fire and forget for the same reason block does: the
        // list itself is already written above, so this is catching up the past, not the promise.
        //
        // Unhiding deliberately does NOT put them back. A story they were removed from was, from
        // that moment, not addressed to them, and silently restoring reach to something posted
        // while they were excluded is the surprise in the other direction.
        if hidden {
            // `publicOnly`: this list is the EVERYONE audience's. Pulling somebody out of a live
            // custom or one-time story that named them would be the same leak, one day later.
            Task { await StoriesRepository.shared.revokeAudience(for: uid, publicOnly: true) }
        }
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
        var mode = StoryAudience.Mode(rawValue: data["mode"] as? String ?? "") ?? .all
        let members = data["members"] as? [String] ?? []
        // SELF-HEAL AN EMPTY NARROWING. Builds before this one committed the mode on the tap, so
        // anybody who opened "All Except…" and backed out has `except` with nobody in it saved —
        // a mode that reaches exactly the same people as `all` while ticking a different row and
        // reporting "0 excluded". It IS `all`; say so, rather than leaving the screen lying.
        if kind == .myFriends, mode != .all, members.isEmpty { mode = .all }
        return StoryAudience(
            id: id,
            kind: kind,
            name: data["name"] as? String ?? "",
            mode: mode,
            members: members,
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
