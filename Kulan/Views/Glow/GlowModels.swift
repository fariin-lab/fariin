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
struct GlowPerson: Identifiable, Equatable, Hashable, Codable {
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
struct PostedStory: Identifiable, Equatable, Codable {
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
    /// ⛔ OPTIONAL, AND THE EMPTY STRING IS WHY — 2026-09-11, his screenshot of the Glowers picker
    /// spinning for ever.
    ///
    /// This was `= ""`, and the guard below is `key != loadedKey`. An empty key is a REAL key here:
    /// it is what every caller computes when the list it is keyed on is empty, which is the state of
    /// the glow relationship on every cold open, before the two listeners have landed. So `"" != ""`
    /// is false, the guard returns, and `state` never leaves the `.loading` it was born in. Nothing
    /// re-runs it either — `.task(id:)` only fires again when the id MOVES, and the id is that same
    /// empty string. A permanent spinner, and one that only appears when an account genuinely has
    /// nobody yet or the listeners are slow, which is why it survived this long.
    ///
    /// `nil` cannot collide with anything a caller can compute, so "never loaded" and "loaded the
    /// empty set" stop being the same value.
    private var loadedKey: String?

    /// `uids` is ordered; the rows come back in that order. Re-running for the same set is a no-op,
    /// so a view that re-renders does not re-fetch.
    func load(_ uids: [String], dates: [String: Date] = [:], key: String) async {
        guard key != loadedKey else { return }
        loadedKey = key
        // ⚠️ AND THE STAMP NEVER OUTLIVES A SPINNER. Every path below ends by setting `state`, so
        // this is a belt rather than a fix — but the one thing that must never happen here is a key
        // recorded as loaded while the view is still showing `.loading`, because the guard above
        // then refuses every retry and the spinner is permanent. If we ever leave without reaching
        // a terminal state, the stamp goes with us. This is the second stranding route the
        // 2026-09-05 audit recorded and the first one it did not reach.
        defer { if case .loading = state { loadedKey = nil } }
        // Demo: his account only, see GlowDemo. Resolving fake uids against the server would
        // fetch nothing, so the rows are handed over whole.
        if GlowDemo.isOn, uids.allSatisfy(GlowDemo.isDemoPerson) {
            let all = GlowDemo.glowers + GlowDemo.glowing
            state = .loaded(uids.compactMap { u in all.first { $0.id == u } })
            return
        }
        guard !uids.isEmpty else { state = .loaded([]); return }
        state = .loading
        // ⛔ ALL AT ONCE, NOT ONE AFTER ANOTHER — owner, 2026-09-11, reporting the Glowers picker
        // still spinning after the empty-key fix. That fix was real and was not this.
        //
        // ⚠️ THIS WAS A SERIAL LOOP OF NETWORK ROUND TRIPS. One `getDocument` per person, each
        // awaited before the next was even asked for — so the spinner lasted the SUM of every
        // fetch. His own account shows five Glowers and ten Glowing, which is fifteen round trips
        // end to end before a single row can be drawn; on a slow connection that is many seconds of
        // a screen that looks broken, and it gets linearly worse the more people he glows with.
        // A group asks for all of them together, so the wait is the slowest ONE, not the total.
        //
        // ⚠️ THE ORDER IS RESTORED FROM THE INDEX, not from the order they come back in. `uids` is
        // ordered and the rows must follow it — a task group finishes in whatever order the network
        // decides, so each result carries the slot it belongs in.
        var resolved = [GlowPerson?](repeating: nil, count: uids.count)
        await withTaskGroup(of: (Int, UserProfile?).self) { group in
            for (i, uid) in uids.enumerated() {
                group.addTask { (i, await ProfileStore.shared.fetch(uid)) }
            }
            for await (i, p) in group {
                guard let p else { continue }
                resolved[i] = GlowPerson(id: uids[i], name: p.name, handle: p.handle,
                                         photoUrl: p.photoUrl, at: dates[uids[i]] ?? .distantPast)
            }
        }
        let out = resolved.compactMap { $0 }
        let anyFailed = out.count < uids.count
        // ⚠️ A PARTIAL ANSWER IS STILL AN ANSWER. One profile that will not load — a deleted
        // account, a blocked read — must not turn the whole page into an error; it just is not a
        // row. Only a total failure with people to show is reported as failed.
        if out.isEmpty && anyFailed { state = .failed } else { state = .loaded(out) }
    }

    /// Drop the memo so the next `load` really reloads — the pull-to-refresh and error-retry door.
    func invalidate() { loadedKey = nil }
}

/// The still-live stories of ONE author, for the profile card and the Posted Stories page.
///
/// ⚠️ READS `users/{uid}/publicStories`, THE MIRROR, NOT `stories`. The real story document carries
/// `recipientUids` and is readable only by its audience; the mirror is the public face and carries
/// no audience at all. That split is what lets somebody else's profile show their stories without
/// handing over who else can see them — see `writePublicMirror`. It also means a profile shows only
/// what the author made public, which is the honest thing for it to show.
/// ⛔ THE LAST COUNT A STORY WAS KNOWN TO HAVE — owner, 2026-09-11: "when I enter posted stories the
/// count views is coming late".
///
/// ⚠️ IT COMES LATE BECAUSE IT IS A SECOND ROUND TRIP, and no amount of making that trip faster puts
/// a number on the first frame. The rows are fetched, drawn, and only then are the counts asked for
/// — they were serialised once and are parallel now (2026-09-11 morning), which took the wait from
/// five trips to one, and one trip after the picture is still a badge that appears afterwards. The
/// tiles deliberately draw nothing while the count is nil, so what he sees is pictures, then numbers.
///
/// This is the project's own rule applied to this page — render from cache on the first frame, let
/// the network correct it silently (AGENTS.md, "local-first, no spinners"). The number shown on
/// entry is the one this phone last saw for that exact story, which is right far more often than it
/// is wrong: views only ever go up, and the correction lands a moment later either way.
///
/// ⚠️ THE FIRST EVER VISIT STILL HAS NO NUMBER, and that is honest rather than fixed. A count nobody
/// has ever fetched cannot be shown, and inventing a zero is the lie `PostedStory.views` exists to
/// avoid. The real end of this is the counter document on the story itself, which is still on the
/// Glow feature's owed list — when that lands, this cache becomes a nicety instead of the answer.
///
/// Pruned against the ids currently alive, so it cannot grow: a story lives 24 hours and its entry
/// goes the first time a load does not mention it.
@MainActor enum StoryViewCountCache {
    private static let key = "storyViewCounts"

    static func get(_ id: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[id]
    }

    /// Write the fresh counts and drop every id not in `alive` — one pass, one write.
    static func put(_ counts: [String: Int], alive: Set<String>) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        for (id, n) in counts { d[id] = n }
        d = d.filter { alive.contains($0.key) }
        UserDefaults.standard.set(d, forKey: key)
    }
}

@MainActor @Observable final class PostedStoriesLoader {
    private(set) var state: GlowLoad<[PostedStory]> = .loading
    /// ⛔ OPTIONAL, AND THE EMPTY STRING IS WHY — 2026-09-11, his screenshot of the Glowers picker
    /// spinning for ever.
    ///
    /// This was `= ""`, and the guard below is `uid != loadedUid`. An empty key is a REAL key here:
    /// it is what every caller computes when the list it is keyed on is empty, which is the state of
    /// the glow relationship on every cold open, before the two listeners have landed. So `"" != ""`
    /// is false, the guard returns, and `state` never leaves the `.loading` it was born in. Nothing
    /// re-runs it either — `.task(id:)` only fires again when the id MOVES, and the id is that same
    /// empty string. A permanent spinner, and one that only appears when an account genuinely has
    /// nobody yet or the listeners are slow, which is why it survived this long.
    ///
    /// `nil` cannot collide with anything a caller can compute, so "never loaded" and "loaded the
    /// empty set" stop being the same value.
    private var loadedUid: String?

    func load(uid: String, force: Bool = false) async {
        guard force || uid != loadedUid else { return }
        loadedUid = uid
        // ⚠️ AND THE STAMP NEVER OUTLIVES A SPINNER. Every path below ends by setting `state`, so
        // this is a belt rather than a fix — but the one thing that must never happen here is a key
        // recorded as loaded while the view is still showing `.loading`, because the guard above
        // then refuses every retry and the spinner is permanent. If we ever leave without reaching
        // a terminal state, the stamp goes with us. This is the second stranding route the
        // 2026-09-05 audit recorded and the first one it did not reach.
        defer { if case .loading = state { loadedUid = nil } }
        if GlowDemo.isOn, GlowDemo.isDemoPerson(uid) {
            state = .loaded(GlowDemo.stories(for: uid))
            return
        }
        guard !uid.isEmpty else { state = .loaded([]); return }

        // ⛔ MY OWN STORIES COME FROM THE REPOSITORY, NOT FROM `publicStories` — owner, 2026-09-02:
        // "I upload a story but Posted stories never shows it".
        //
        // ⚠️ `publicStories` IS A MIRROR OF THE PUBLIC ONES AND ONLY THOSE. It is what lets a
        // STRANGER see what you have posted from your profile, so it is written for the Everyone
        // audience and for nothing else — post to Friends or to Glowers and that collection stays
        // empty, which is exactly what he did and exactly what the card then said. Reading it for my
        // own page asked a question about strangers on the one page where the answer is mine.
        //
        // `StoriesRepository.mine` is every live story I have posted whatever its audience, it is
        // already in memory off a listener, and it is what the story row itself draws. So this is
        // also instant where the query was a round trip.
        if uid == (AuthService.shared.uid ?? ""), let mine = StoriesRepository.shared.mine {
            state = .loaded(mine.stories.reversed().map { s in
                PostedStory(id: s.id,
                            thumbUrl: s.thumbUrl.isEmpty ? s.mediaUrl : s.thumbUrl,
                            blurThumb: s.blurThumb,
                            createdAt: s.createdAt,
                            expiresAt: s.expiresAt,
                            isVideo: s.isVideo,
                            // The number this phone last saw for this story, so the badge is on the
                            // first frame — see `StoryViewCountCache`. `loadViewCounts` corrects it.
                            views: StoryViewCountCache.get(s.id),
                            audience: s.audienceLabel)
            })
            return
        }

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
                    views: StoryViewCountCache.get(d.documentID),   // first-frame badge; see the cache
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
    /// ⛔ AND IT COUNTS THE RECEIPTS WHEN THERE IS NO COUNTER — his report, 2026-09-09: the posted
    /// stories on his own profile show no number at all.
    ///
    /// ⚠️ THE COUNTER DOCUMENT HAS NO WRITER YET. `fetchViewSummary` reads
    /// `stories/{id}/meta/views`, a document a server function is supposed to keep, and that
    /// function has never been built — it is still on the Glow feature's owed list. So the summary
    /// returns nil for every story, and the badge drew nothing, correctly, about a number nobody
    /// was keeping.
    ///
    /// The receipts themselves are real and are already author-readable: `stories/{id}/views` holds
    /// one document per viewer, which is what the Seen-by sheet lists. Counting them is the same
    /// number the counter would hold, derived instead of stored.
    ///
    /// ⚠️ THE SUMMARY IS STILL ASKED FIRST, and that order matters. When the function does land, its
    /// count is authoritative and cheap; this fallback is one extra read per story and exists only
    /// while the number has no other source. `nil` from the receipts read means the request failed,
    /// not that nobody watched — the badge stays absent rather than claiming zero.
    func loadViewCounts(isMe: Bool) async {
        guard isMe, case .loaded(let rows) = state, !rows.isEmpty else { return }
        // ⛔ ALL AT ONCE — owner, 2026-09-11: "in my profile the views count comes late when I enter
        // my profile". Two things made it late and this fixes both.
        //
        // ⚠️ THE ROUND TRIPS WERE SERIAL. One summary read per story, awaited before the next was
        // even asked for, and a story whose summary is missing costs a SECOND read for its viewer
        // list — so five stories was five to ten network round trips end to end. A task group asks
        // for all of them together and the wait becomes the slowest one instead of the total.
        //
        // ⚠️ AND NOTHING APPEARED UNTIL EVERY ONE HAD LANDED, which is what made it read as a flip
        // rather than as loading. `state` was written once, after the loop; the tiles draw no badge
        // at all while `views` is nil (deliberately — see `PostedStory.views`, a confident zero is
        // the worse lie), so the whole row sat blank and then filled in one go. With the reads
        // running together there is one publish either way, but it now arrives in the time of a
        // single read.
        //
        // ⚠️ THE FALLBACK STAYS PER STORY. `fetchViewSummary` is the counter document and
        // `fetchViewers` is the receipts behind it; asking for the second only when the first
        // answers nil is the rule `fetchViewSummary`'s own note sets out, and it belongs inside each
        // task rather than in a second pass over the whole list.
        var counts = [Int?](repeating: nil, count: rows.count)
        await withTaskGroup(of: (Int, Int?).self) { group in
            for (i, row) in rows.enumerated() {
                group.addTask {
                    if let s = await StoriesService.shared.fetchViewSummary(storyId: row.id) {
                        return (i, s.count)
                    }
                    if let viewers = await StoriesService.shared.fetchViewers(storyId: row.id) {
                        return (i, viewers.count)
                    }
                    return (i, nil)
                }
            }
            for await (i, n) in group { counts[i] = n }
        }
        var updated = rows
        var fresh: [String: Int] = [:]
        for (i, n) in counts.enumerated() {
            guard let n else { continue }   // a failed read keeps the cached number rather than blanking it
            updated[i].views = n
            fresh[updated[i].id] = n
        }
        // Remembered for the next entry, and every id that is no longer live is dropped in the same
        // write — see `StoryViewCountCache`.
        StoryViewCountCache.put(fresh, alive: Set(rows.map(\.id)))
        state = .loaded(updated)
    }

    func invalidate() { loadedUid = nil }
}

/// One card in the Stories tab's "Glowing" grid: somebody you have a glow with, and the newest
/// live story they have posted.
/// ⚠️ `Codable` SO THE PAGE CAN OPEN ON WHAT IT SAW LAST — see `GlowStoriesCache`. Every member of
/// this and of the two types it holds is a plain value, so all three synthesise it for nothing.
struct GlowStoryCard: Identifiable, Equatable, Codable {
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
/// ⛔ WHAT THE GLOWING GRID SAW LAST TIME — owner's spec, 2026-09-11: "please add proper cache
/// support for Glowing Stories. After the first successful load, cache the data. When the user
/// refreshes the app or returns to Stories, load the cached Glowing Stories immediately, fetch in
/// the background, and only update the UI when new data is available. Do not show the full skeleton
/// again just because the app was refreshed."
///
/// ⚠️ WHY THE PAGE WAS SLOW, AND IT IS NOT THE NETWORK BEING SLOW. Building this grid costs TWO
/// round trips PER PERSON — a profile fetch and a posted-stories load — run one after another in a
/// loop. With eight glow people that is sixteen sequential requests before the first card can be
/// drawn, every single time the page was opened, with nothing on screen in the meantime. The cache
/// does not make those requests faster; it takes them off the path between opening the tab and
/// seeing something.
///
/// ⚠️ EXPIRED CARDS ARE DROPPED ON READ, NOT ON WRITE. A story dies twenty-four hours after it was
/// posted, so a cache written last night is a page full of stories that no longer exist — and the
/// one thing worse than a slow grid is a fast grid showing things that are gone. Filtering on the
/// way out means the same file is correct at any age, and an entirely stale file reads as no cache
/// at all, which is exactly what it is.
///
/// ⚠️ KEYED PER ACCOUNT. Two people signing into one phone must not see each other's glow grid, even
/// for the frame before the fetch lands.
enum GlowStoriesCache {
    private static var uid: String { AuthService.shared.uid ?? "" }
    private static var fileURL: URL? {
        guard !uid.isEmpty else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glow-stories-\(uid).json")
    }

    /// Has this account ever finished a Glowing load on this device? The skeleton is shown on the
    /// first open and never again — see `StoriesTabView.showsFirstRunSkeleton`.
    static var hasEverLoaded: Bool {
        get { UserDefaults.standard.bool(forKey: "glowStories.everLoaded.\(uid)") }
        set { UserDefaults.standard.set(newValue, forKey: "glowStories.everLoaded.\(uid)") }
    }

    static func read() -> [GlowStoryCard]? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let cards = try? JSONDecoder().decode([GlowStoryCard].self, from: data) else { return nil }
        let live = cards.filter { $0.story.expiresAt > Date() }
        return live.isEmpty ? nil : live
    }

    static func write(_ cards: [GlowStoryCard]) {
        guard let fileURL else { return }
        hasEverLoaded = true
        guard let data = try? JSONEncoder().encode(cards) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Signing out takes the grid with it — see `read`'s note on keying per account.
    ///
    /// ⚠️ EVERY ACCOUNT'S FILE, NOT THIS ONE'S, AND THAT IS NOT OVER-REACH. `SessionWipe` runs AFTER
    /// `Auth.signOut()` on one of its two paths, so by the time this is called `uid` is very often
    /// already nil — a version of this keyed on the current account would quietly delete nothing on
    /// exactly the path that matters. Sweeping the prefix is also the honest rule: no signed-out
    /// account's grid has any reason to stay on the device.
    static func clear() {
        let fm = FileManager.default
        if let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("glow-stories-") {
                try? fm.removeItem(at: f)
            }
        }
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("glowStories.everLoaded.") {
            d.removeObject(forKey: k)
        }
    }
}

@MainActor @Observable final class GlowStoriesLoader {
    private(set) var state: GlowLoad<[GlowStoryCard]> = .loading
    /// ⛔ OPTIONAL, AND THE EMPTY STRING IS WHY — 2026-09-11, his screenshot of the Glowers picker
    /// spinning for ever.
    ///
    /// This was `= ""`, and the guard below is `key != loadedKey`. An empty key is a REAL key here:
    /// it is what every caller computes when the list it is keyed on is empty, which is the state of
    /// the glow relationship on every cold open, before the two listeners have landed. So `"" != ""`
    /// is false, the guard returns, and `state` never leaves the `.loading` it was born in. Nothing
    /// re-runs it either — `.task(id:)` only fires again when the id MOVES, and the id is that same
    /// empty string. A permanent spinner, and one that only appears when an account genuinely has
    /// nobody yet or the listeners are slow, which is why it survived this long.
    ///
    /// `nil` cannot collide with anything a caller can compute, so "never loaded" and "loaded the
    /// empty set" stop being the same value.
    private var loadedKey: String?

    func load(_ uids: [String], key: String) async {
        guard key != loadedKey else { return }
        loadedKey = key
        // ⚠️ AND THE STAMP NEVER OUTLIVES A SPINNER. Every path below ends by setting `state`, so
        // this is a belt rather than a fix — but the one thing that must never happen here is a key
        // recorded as loaded while the view is still showing `.loading`, because the guard above
        // then refuses every retry and the spinner is permanent. If we ever leave without reaching
        // a terminal state, the stamp goes with us. This is the second stranding route the
        // 2026-09-05 audit recorded and the first one it did not reach.
        defer { if case .loading = state { loadedKey = nil } }
        if GlowDemo.isOn {
            state = .loaded(GlowDemo.storyCards)
            return
        }
        guard !uids.isEmpty else {
            state = .loaded([])
            GlowStoriesCache.write([])
            return
        }
        // ⛔ THE LAST GRID GOES UP FIRST, AND THE FETCH RUNS BEHIND IT — his spec, 2026-09-11: "when
        // the user refreshes the app or returns to Stories, load the cached Glowing Stories
        // immediately, fetch in the background, and only update the UI when new data is available."
        //
        // ⚠️ `state = .loading` USED TO BE UNCONDITIONAL HERE, and that one line is most of what he
        // is describing. It threw away a perfectly good grid on every entry and put the page back to
        // its empty shape for as long as two round trips PER PERSON take — which is also why
        // `hasGlowGrid` flips, so the section collapsed and reopened and everything under it jumped.
        // Painting the cache means the shape never changes: there is a grid before the fetch and the
        // same grid after it.
        if let cached = GlowStoriesCache.read(), !cached.isEmpty {
            state = .loaded(cached)
        } else if state.value == nil {
            // Nothing remembered and nothing on screen — this is the genuine first run, and it is
            // the one case the page's skeleton is for.
            state = .loading
        }
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
        // ⚠️ ONLY WHEN IT ACTUALLY CHANGED — "only update the UI when new data is available". These
        // are `Equatable` all the way down, so an unchanged answer is one comparison rather than a
        // republish, and the grid does not rebuild its cards for a fetch that found nothing new.
        // The cache is written either way: the fetch is what proves the file is still current.
        if state.value != cards { state = .loaded(cards) }
        GlowStoriesCache.write(cards)
    }

    func invalidate() { loadedKey = nil }
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
    /// - Parameter sourceKey: the `.storyRow` rect key of the card that was tapped, so the viewer
    ///   grows out of THAT card and lands back on it. Nil falls back to the person's own id, which
    ///   is what a door with nothing registered wants; see `GlowStoryCardView.rectKey`.
    static func open(_ person: GlowPerson, from sourceKey: String? = nil) async {
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
        StoryDoor.open(group, among: [group], from: sourceKey ?? group.id,
                       pinned: true, deliveredToMe: false)
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
