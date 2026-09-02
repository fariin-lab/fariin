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
struct GlowPerson: Identifiable, Equatable {
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
