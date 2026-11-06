import Foundation
import FirebaseFunctions

/// What a quoted channel post's card shows (owner 2026-11-06). Everything here comes from the
/// server's `getQuotes`, which decides per reader, every time, whether the source channel may be
/// seen: `.ok` is the post as it was when quoted, `.deleted` keeps the channel's face and says Post
/// deleted, `.hidden` shows nothing of the post (the channel is private to this reader, or closed).
struct QuoteCard: Equatable {
    enum State: Equatable { case ok, deleted, hidden, gone }
    var state: State
    var cid = ""
    var mid = ""
    var title = ""
    var photoUrl = ""
    var username = ""
    var text = ""
    /// "text", "photo", "video" or "album".
    var kind = "text"
    var image = ""

    init(state: State) { self.state = state }

    init?(_ d: [String: Any]) {
        switch d["state"] as? String {
        case "ok": state = .ok
        case "deleted": state = .deleted
        case "private": state = .hidden
        case "gone": state = .gone
        default: return nil
        }
        cid = d["cid"] as? String ?? ""
        mid = d["mid"] as? String ?? ""
        title = d["title"] as? String ?? ""
        photoUrl = d["photoUrl"] as? String ?? ""
        username = d["username"] as? String ?? ""
        text = d["text"] as? String ?? ""
        kind = d["kind"] as? String ?? "text"
        image = d["image"] as? String ?? ""
    }

    /// The card's lines, as the bubble draws them.
    var heading: String {
        switch state {
        case .ok, .deleted: return title.isEmpty ? "Channel" : title
        case .hidden, .gone: return "Channel post"
        }
    }

    var body: String {
        switch state {
        case .ok:
            if !text.isEmpty { return text }
            switch kind {
            case "photo": return "Photo"
            case "video": return "Video"
            case "album": return "Album"
            default: return "Post"
            }
        case .deleted: return "Post deleted"
        case .hidden: return "This channel is private"
        case .gone: return "Content unavailable"
        }
    }
}

/// ⛔ THE QUOTE CARDS, ASKED FROM THE SERVER (owner 2026-11-06). Rows ask `card(_:)` as they are
/// drawn; misses and answers older than `fresh` are fetched together (up to 50 ids a call). A
/// changed answer bumps the open chat's rows (`LiveGroupCard.noteChanged`), so a channel that
/// becomes visible again shows its quote without anyone reopening the chat.
@MainActor final class QuoteStore {
    static let shared = QuoteStore()

    nonisolated static func isQid(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    private var cards: [String: QuoteCard] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var queued = Set<String>()
    private var inFlight = Set<String>()
    private var flushScheduled = false
    /// How long an answer is trusted before the server is asked again (access can change).
    private let fresh: TimeInterval = 120

    private init() {}

    /// The card for `qid`, or nil while the first answer is on its way. Asking also schedules a
    /// refresh when the answer is old.
    func card(_ qid: String) -> QuoteCard? {
        let stale = fetchedAt[qid].map { Date().timeIntervalSince($0) > fresh } ?? true
        if stale { request(qid) }
        return cards[qid]
    }

    /// What the row signature carries for this quote.
    func token(_ qid: String) -> String {
        guard let c = cards[qid] else { return "?" }
        return "\(c.state)\(c.title.hashValue):\(c.text.hashValue):\(c.image.hashValue):\(c.photoUrl.hashValue)"
    }

    /// The answer `createQuote` gave the quoting phone: shown at once, no second request.
    func seed(_ qid: String, _ card: QuoteCard) {
        cards[qid] = card
        fetchedAt[qid] = Date()
    }

    private func request(_ qid: String) {
        guard Self.isQid(qid), !inFlight.contains(qid) else { return }
        queued.insert(qid)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)   // gather a screenful of rows into one call
            flushScheduled = false
            await flush()
        }
    }

    private func flush() async {
        let batch = Array(queued.prefix(50))
        guard !batch.isEmpty else { return }
        queued.subtract(batch)
        inFlight.formUnion(batch)
        defer { inFlight.subtract(batch) }
        do {
            let r = try await Functions.functions(region: "me-central1").httpsCallable("getQuotes").call(["qids": batch])
            let got = ((r.data as? [String: Any])?["quotes"] as? [String: Any]) ?? [:]
            var changed = false
            for q in batch {
                fetchedAt[q] = Date()
                guard let d = got[q] as? [String: Any], let card = QuoteCard(d) else { continue }
                if cards[q] != card { cards[q] = card; changed = true }
            }
            if changed { LiveGroupCard.noteChanged() }
        } catch {
            // Asked again on the next draw after a short pause, not in a loop.
            let retryAt = Date().addingTimeInterval(-fresh + 15)
            for q in batch where fetchedAt[q] == nil || fetchedAt[q]! < retryAt { fetchedAt[q] = retryAt }
        }
        if !queued.isEmpty { await flush() }
    }

    /// Quote a channel post: the server checks I may see it and keeps a snapshot. Returns the id the
    /// message will carry, and seeds the card so my own bubble shows it at once.
    static func create(cid: String, mid: String) async throws -> (qid: String, card: QuoteCard) {
        let r = try await Functions.functions(region: "me-central1").httpsCallable("createQuote").call(["cid": cid, "mid": mid])
        guard let d = r.data as? [String: Any], let qid = d["qid"] as? String, isQid(qid) else {
            throw NSError(domain: "Quote", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't quote this post."])
        }
        var card = QuoteCard(state: .ok)
        card.cid = cid; card.mid = mid
        card.title = d["title"] as? String ?? ""
        card.photoUrl = d["photoUrl"] as? String ?? ""
        card.username = d["username"] as? String ?? ""
        card.text = d["text"] as? String ?? ""
        card.kind = d["kind"] as? String ?? "text"
        card.image = d["image"] as? String ?? ""
        await MainActor.run { shared.seed(qid, card) }
        return (qid, card)
    }
}
