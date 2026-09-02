import Foundation
import FirebaseFirestore

// ===== What the Glow screens read =====
//
// One loader per screen, each an `@Observable` with the three states every one of them needs:
// loading, loaded, failed. His requirements 12–14 are empty / loading / error states, and they are
// answered once here rather than four times in four views.
//
// ⚠️ NOTHING HERE WRITES. Giving and taking back a glow is `GlowService`; these types read.

/// One person, resolved for a list row. Deliberately not a `UserProfile`: a row needs four fields
/// and re-resolving a whole profile per row is what makes a list of forty people slow.
struct GlowPerson: Identifiable, Equatable, Hashable {
    let id: String          // uid
    var name: String
    var handle: String
    var photoUrl: String?
    /// When the glow was given — the "Dec 23, 2025" in his notifications screenshot.
    var at: Date = .distantPast
}

/// The three states every Glow screen can be in. `.loaded([])` and `.failed` are different answers
/// and must look different: an empty list says "nobody yet", a failure says "we could not ask".
/// Collapsing them is how a network error comes to read as "you have no glowers".
enum GlowLoad<T: Equatable>: Equatable {
    case loading
    case loaded(T)
    case failed

    var value: T? { if case .loaded(let v) = self { return v }; return nil }
    var isLoading: Bool { if case .loading = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// One of this author's still-live stories, as the profile card and the Posted Stories page draw it.
struct PostedStory: Identifiable, Equatable {
    let id: String
    var thumbUrl: String
    var blurThumb: String
    var createdAt: Date
    var expiresAt: Date
    var isVideo: Bool
    /// The badge in his screenshot ("25.6K"). Nil while unknown — the card then draws no badge
    /// rather than a confident zero, which is the mistake `fetchViewSummary`'s own note records.
    var views: Int?
    /// "everyone" | "friends" | "glowers" | "custom" — what the Posted Stories filter groups by.
    var audience: String
}

/// Resolves uids into rows for the Glowers / Glowing lists and the notifications page.
///
/// ⚠️ NAMES COME FROM THE CHAT LIST FIRST AND THE SERVER SECOND, which is the same order
/// `StoriesService.face` uses. A glower is very often somebody you have never chatted with — that
/// is the entire feature — so unlike every other list in this app the chat list will usually MISS,
/// and the profile fetch is the normal path rather than the fallback.
@MainActor @Observable final class GlowPeopleLoader {
    private(set) var state: GlowLoad<[GlowPerson]> = .loading
    private var loadedKey = ""

    /// `uids` is ordered; the rows come back in that order. Re-running for the same set is a no-op,
    /// so a view that re-renders does not re-fetch.
    func load(_ uids: [String], dates: [String: Date] = [:], key: String) async {
        guard key != loadedKey else { return }
        loadedKey = key
        // Demo: his account only, see GlowDemo. Resolving fake uids against the server would
        // fetch nothing, so the rows are handed over whole.
        if GlowDemo.isOn, uids.allSatisfy(GlowDemo.isDemoPerson) {
            let all = GlowDemo.glowers + GlowDemo.glowing
            state = .loaded(uids.compactMap { u in all.first { $0.id == u } })
            return
        }
        guard !uids.isEmpty else { state = .loaded([]); return }
        state = .loading
        var out: [GlowPerson] = []
        var anyFailed = false
        for uid in uids {
            if let p = await ProfileStore.shared.fetch(uid) {
                out.append(GlowPerson(id: uid, name: p.name, handle: p.handle,
                                      photoUrl: p.photoUrl, at: dates[uid] ?? .distantPast))
            } else {
                anyFailed = true
            }
        }
        // ⚠️ A PARTIAL ANSWER IS STILL AN ANSWER. One profile that will not load — a deleted
        // account, a blocked read — must not turn the whole page into an error; it just is not a
        // row. Only a total failure with people to show is reported as failed.
        if out.isEmpty && anyFailed { state = .failed } else { state = .loaded(out) }
    }

    /// Drop the memo so the next `load` really reloads — the pull-to-refresh and error-retry door.
    func invalidate() { loadedKey = "" }
}

/// The still-live stories of ONE author, for the profile card and the Posted Stories page.
///
/// ⚠️ READS `users/{uid}/publicStories`, THE MIRROR, NOT `stories`. The real story document carries
/// `recipientUids` and is readable only by its audience; the mirror is the public face and carries
/// no audience at all. That split is what lets somebody else's profile show their stories without
/// handing over who else can see them — see `writePublicMirror`. It also means a profile shows only
/// what the author made public, which is the honest thing for it to show.
@MainActor @Observable final class PostedStoriesLoader {
    private(set) var state: GlowLoad<[PostedStory]> = .loading
    private var loadedUid = ""

    func load(uid: String, force: Bool = false) async {
        guard force || uid != loadedUid else { return }
        loadedUid = uid
        if GlowDemo.isOn, GlowDemo.isDemoPerson(uid) {
            state = .loaded(GlowDemo.stories(for: uid))
            return
        }
        guard !uid.isEmpty else { state = .loaded([]); return }
        state = .loading
        let db = Firestore.firestore()
        do {
            let snap = try await db.collection("users").document(uid)
                .collection("publicStories")
                // Live only, his requirement: "stories the user has posted that are still active".
                .whereField("expiresAt", isGreaterThan: Timestamp(date: Date()))
                .order(by: "expiresAt", descending: true)
                .limit(to: 60)
                .getDocuments()
            let rows: [PostedStory] = snap.documents.map { d in
                let data = d.data()
                return PostedStory(
                    id: d.documentID,
                    thumbUrl: (data["thumbUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (data["mediaUrl"] as? String ?? ""),
                    blurThumb: data["blurThumb"] as? String ?? "",
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                    expiresAt: (data["expiresAt"] as? Timestamp)?.dateValue() ?? Date(),
                    isVideo: (data["type"] as? String) == "video",
                    views: nil,
                    audience: data["audience"] as? String ?? "everyone")
            }
            state = .loaded(rows)
        } catch {
            state = .failed
        }
    }

    /// View counts, only for MY OWN stories and only once the rows exist.
    ///
    /// ⚠️ SEPARATE FROM THE LOAD, AND ONLY FOR ME. `stories/{id}/meta/views` is author-readable, so
    /// asking for somebody else's would fail every time and cost a round trip per card to learn it.
    /// The badge in his screenshot is on his own profile; on somebody else's there is no number to
    /// show and the card draws none.
    func loadViewCounts(isMe: Bool) async {
        guard isMe, case .loaded(let rows) = state, !rows.isEmpty else { return }
        var updated = rows
        for (i, row) in rows.enumerated() {
            if let s = await StoriesService.shared.fetchViewSummary(storyId: row.id) {
                updated[i].views = s.count
            }
        }
        state = .loaded(updated)
    }

    func invalidate() { loadedUid = "" }
}

/// One card in the Stories tab's "Glowing" grid: somebody you have a glow with, and the newest
/// live story they have posted.
struct GlowStoryCard: Identifiable, Equatable {
    var id: String { person.id }
    let person: GlowPerson
    let story: PostedStory
}

/// The Stories tab's Glowing grid — his sixth reference, 2026-09-02: large two-column story cards
/// with the author's name and face on them, NOT a row of avatars.
///
/// ⚠️ ONE PERSON, ONE CARD, and it is the NEWEST live story. A grid with three cards from the same
/// person would push everybody else off the screen; the section is "who is glowing", not "every
/// glow story ever posted". Opening the card is what pages through the rest.
///
/// ⚠️ READS THE PUBLIC MIRROR, like every other Glow surface — see `PostedStoriesLoader`. That
/// means the grid shows a glow person's story only when they posted it publicly or to an audience
/// this account is in; it never leaks the audience itself.
@MainActor @Observable final class GlowStoriesLoader {
    private(set) var state: GlowLoad<[GlowStoryCard]> = .loading
    private var loadedKey = ""

    func load(_ uids: [String], key: String) async {
        guard key != loadedKey else { return }
        loadedKey = key
        if GlowDemo.isOn {
            state = .loaded(GlowDemo.storyCards)
            return
        }
        guard !uids.isEmpty else { state = .loaded([]); return }
        state = .loading
        var cards: [GlowStoryCard] = []
        for uid in uids {
            guard let p = await ProfileStore.shared.fetch(uid) else { continue }
            let one = PostedStoriesLoader()
            await one.load(uid: uid)
            // Newest first is the order `PostedStoriesLoader` already returns.
            guard let newest = one.state.value?.first else { continue }
            cards.append(GlowStoryCard(
                person: GlowPerson(id: uid, name: p.name, handle: p.handle, photoUrl: p.photoUrl),
                story: newest))
        }
        state = .loaded(cards)
    }

    func invalidate() { loadedKey = "" }
}

/// One line on the Glow notifications page. Three kinds share one row shape, which is what his
/// reference shows: a face, a sentence, a time, and — for the two that are about a story — the
/// story's own thumbnail on the right.
struct GlowEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case glowed                  // they gave me a glow
        case loved(String)           // they reacted to my story; the emoji they used
        case replied(String)         // they replied to my story; what they said
    }
    let id: String
    var person: GlowPerson
    var kind: Kind
    var at: Date
    /// The story this is about — nil for a glow, which is about a person rather than a post.
    var storyThumb: String?

    var isGlow: Bool { if case .glowed = kind { return true }; return false }
    var isLove: Bool { if case .loved = kind { return true }; return false }
    var isReply: Bool { if case .replied = kind { return true }; return false }
}

/// EVERYTHING THAT HAPPENED TO ME — glows given to me, and reactions left on my own live stories.
///
/// ⛔ THE LOVES ARE REAL, and they come from a place that already exists: a reaction is stored ON
/// the view receipt (`stories/{id}/views/{uid}.reaction`), which is what the Seen-by sheet has been
/// reading all along. So "who loved my story" needs no new collection, no new write path and no
/// function — it is my own stories' receipts, filtered to the ones carrying an emoji.
///
/// ⚠️ AUTHOR-ONLY AND RECIPROCAL, BOTH BY THE RULES AND BY `fetchViewers` ITSELF. Receipts are
/// readable by the story's author, and `fetchViewers` refuses when the person has turned view
/// receipts off — "if disabled, you won't see when others view your stories" is a promise this page
/// has to keep too, so with receipts off the Loves list is honestly empty rather than quietly full.
///
/// ⚠️ `fetchViewers` RETURNS NIL FOR A FAILED READ AND [] FOR "NOBODY", and that distinction is
/// load-bearing — its own note records a bug where the two were collapsed and a dropped request
/// read as "nobody watched this". A nil here skips that story rather than claiming it had no loves.
@MainActor @Observable final class GlowEventsLoader {
    private(set) var state: GlowLoad<[GlowEvent]> = .loading
    private var loading = false

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        state = .loading
        if GlowDemo.isOn { state = .loaded(GlowDemo.events); return }

        var out: [GlowEvent] = []

        // 1. Glows aimed at me. The edge document IS the record — see `GlowService.recentGlowers`.
        let glows = await GlowService.shared.recentGlowers()
        let people = GlowPeopleLoader()
        await people.load(glows.map(\.uid),
                          dates: Dictionary(glows.map { ($0.uid, $0.at) }, uniquingKeysWith: { a, _ in a }),
                          key: "events-" + glows.map(\.uid).joined())
        let resolved = people.state.value ?? []
        for g in glows {
            guard let p = resolved.first(where: { $0.id == g.uid }) else { continue }
            out.append(GlowEvent(id: "glow-\(g.uid)", person: p, kind: .glowed, at: g.at,
                                 storyThumb: nil))
        }

        // 2. Reactions on my own live stories.
        let me = AuthService.shared.uid ?? ""
        if !me.isEmpty {
            let mine = PostedStoriesLoader()
            await mine.load(uid: me)
            for story in mine.state.value ?? [] {
                guard let viewers = await StoriesService.shared.fetchViewers(storyId: story.id)
                else { continue }   // nil = a failed read, not an empty one
                for v in viewers where !(v.reaction ?? "").isEmpty {
                    out.append(GlowEvent(
                        id: "love-\(story.id)-\(v.id)",
                        person: GlowPerson(id: v.id, name: v.name, handle: "", photoUrl: v.photoUrl),
                        kind: .loved(v.reaction ?? "❤️"),
                        at: v.viewedAt,
                        storyThumb: story.thumbUrl))
                }
            }
        }

        state = .loaded(out.sorted { $0.at > $1.at })
    }
}

/// OPENING A GLOW PERSON'S STORY — his correction, 2026-09-02: "when I click story glowing, open
/// story, don't open profile, I want to see that story".
///
/// He is right and the split is the same one the notifications row already uses: **the picture
/// opens the picture, the face opens the person.** A card whose whole surface went to a profile
/// made the photograph a decoration.
///
/// ⚠️ IT FETCHES THE WHOLE SET FIRST, not just the one story the card is showing. The card carries
/// only the NEWEST — that is what makes the grid one card per person — but opening should page
/// through everything they have live, which is what the viewer is for.
@MainActor enum GlowStoryOpen {
    static func open(_ person: GlowPerson) async {
        let loader = PostedStoriesLoader()
        await loader.load(uid: person.id, force: true)
        let rows = loader.state.value ?? []
        guard !rows.isEmpty else { return }
        // ⚠️ OLDEST → NEWEST. `StoryGroup.stories` is documented in that order and the viewer pages
        // forward through it; the loader returns newest first, so this reverses rather than trusting
        // the two to agree by luck.
        let stories: [Story] = rows.reversed().map { s in
            Story(id: s.id, authorUid: person.id, createdAt: s.createdAt, expiresAt: s.expiresAt,
                  // A demo row has no uploaded media — its picture IS the thumbnail, drawn on the
                  // phone. Falling back to it keeps the demo openable instead of black.
                  mediaUrl: s.thumbUrl, allowsReplies: false, caption: "",
                  isVideo: s.isVideo, duration: 0, thumbUrl: s.thumbUrl)
        }
        let group = StoryGroup(authorUid: person.id, name: person.name, photoUrl: person.photoUrl,
                               stories: stories, lastViewedAt: nil, isMine: false)
        // `pinned: true` — this door opens ONE person, so the viewer must not page away to
        // somebody else's story the way the friends row's unpinned door does.
        // `deliveredToMe: false` — a glow story is not addressed to me through my chat list, so the
        // reply bar must not offer to reply as though it were.
        StoryDoor.open(group, among: [group], from: group.id, pinned: true, deliveredToMe: false)
    }
}

/// Short form for a view count badge — 25600 → "25.6K", his screenshot's own format.
enum GlowCount {
    static func short(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000:
            let k = Double(n) / 1_000
            return k < 10 ? String(format: "%.1fK", k) : "\(Int(k))K"
        default:
            let m = Double(n) / 1_000_000
            return m < 10 ? String(format: "%.1fM", m) : "\(Int(m))M"
        }
    }
}
