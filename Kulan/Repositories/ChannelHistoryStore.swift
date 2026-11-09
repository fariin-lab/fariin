import Foundation

// ⛔ A CHANNEL'S HISTORY LIVES ON THE PHONE (owner 2026-11-09, "okay go"; contract in
// Documents/fariin-activity/CHANNEL-SYNC-SPEC.md, sections 5-9). Modelled on the reference app's
// own message store:
//
// - every post this phone has seen, by id, decoded once;
// - deleted ids (tombstones are NOT rows: a deleted post never takes a visible slot);
// - the parts of the history already read, as ranges of `createdAt`. What lies between two ranges
//   is a HOLE, read later (createdAt-descending pages) until the view has enough visible posts;
// - `lastChg`, the channel's change counter applied so far. Sync is "every message doc with
//   chg > lastChg", applied one by one as add / edit / delete. The visible list is never replaced
//   wholesale and a row is never dropped because some window did not contain it.
//
// No Firebase in this file: `ChannelHistory` is a pure value the tests drive by hand
// (KulanTests/ChannelHistoryStoreTests.swift). ThreadRepository is the only adapter, and only for
// a channel; groups and 1:1 chats never come here.

/// What the store needs from a post. `Message` has all three.
protocol ChannelHistoryPost: Codable, Equatable {
    var id: String { get }
    var createdAt: Date { get }
    var deleted: Bool { get }
}

extension Message: ChannelHistoryPost {}

/// One message doc as it arrived: the decoded post and the doc's `chg` (nil until the server has
/// stamped it, or for an old doc the backfill has not reached).
struct ChannelDoc<Post: ChannelHistoryPost> {
    let post: Post
    let chg: Int?
}

struct ChannelHistory<Post: ChannelHistoryPost>: Codable {
    /// Every doc with `lo < createdAt <= hi` is known. `lo == .distantPast`: nothing older exists.
    /// `hi == .distantFuture`: up to the change counter (`lastChg`).
    struct Range: Codable, Equatable {
        var lo: Date
        var hi: Date
    }
    /// A deleted id, with the change that deleted it (when known) and when this phone learned it.
    struct Tomb: Codable, Equatable {
        var chg: Int?
        var at: Date
    }
    /// The next part of the history to read: docs with `createdAt <= upper`, newest first.
    /// `floor`: where the next known range begins below it (nil = unknown, down to the start).
    struct Hole: Equatable {
        let upper: Date
        let floor: Date?
    }
    enum Outcome: Equatable { case added, edited, removed, unchanged, ignored }
    struct PageResult: Equatable {
        var added = 0
        var edited = 0
        var removed = 0
        /// Rows kept from before a "too long" gap that this page proved gone.
        var dropped = 0
    }

    /// A deleted id keeps out any doc that is not a NEWER change than the delete, and for this long
    /// keeps out everything: a page read before the delete can still be on its way.
    static var tombGrace: TimeInterval { 60 }
    /// Tombstones kept at most (oldest go first).
    static var tombCap: Int { 4000 }

    private(set) var posts: [String: Post] = [:]
    private(set) var postChg: [String: Int] = [:]
    private(set) var tombs: [String: Tomb] = [:]
    private(set) var ranges: [Range] = []
    /// Rows kept on screen across a "too long" gap: not proven current until a page covers them.
    private(set) var unverified: Set<String> = []
    /// The last change applied from the messages (`chg`). nil: this channel has never synced.
    var lastChg: Int?
    /// The last hard delete applied from `changes`.
    var lastGoneChg: Int?

    init() {}

    var isSynced: Bool { lastChg != nil }

    /// Oldest first (ties by id, so the order is stable).
    var sortedPosts: [Post] {
        posts.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
    }

    /// The hole right under the newest known range (or the newest page itself when nothing is
    /// known yet). nil: the newest range reaches the start of the channel.
    var topHole: Hole? {
        guard let top = ranges.last else { return Hole(upper: .distantFuture, floor: nil) }
        guard top.lo > .distantPast else { return nil }
        let floor = ranges.count >= 2 ? ranges[ranges.count - 2].hi : nil
        return Hole(upper: top.lo, floor: floor)
    }

    /// Nothing older than the visible block exists.
    var reachedStart: Bool { topHole == nil }

    /// Posts in the newest contiguous block that the view would show. Rows below a hole do not
    /// count: the view wants N in one piece, the way the reference app's view stops at a hole.
    func visibleCount(_ isVisible: (Post) -> Bool) -> Int {
        // `>=`: the page's own oldest post sits exactly on the range's lower edge and is held.
        let floor = ranges.last?.lo ?? .distantFuture
        var n = 0
        for p in posts.values where p.createdAt >= floor && isVisible(p) { n += 1 }
        return n
    }

    /// Fewer than `want` visible posts in the newest block and a hole left to read under it.
    func needsFill(want: Int, _ isVisible: (Post) -> Bool) -> Bool {
        topHole != nil && visibleCount(isVisible) < want
    }

    // MARK: - Changes

    /// One change (from the `chg` listener, the newest-posts listener, or a page): add, edit or
    /// delete. Never older over newer: a doc whose `chg` is below what this post already has is
    /// ignored, and a doc without `chg` never overwrites one that has it.
    @discardableResult
    mutating func applyChange(_ doc: ChannelDoc<Post>, now: Date) -> Outcome {
        apply(doc, now: now, fromPage: false)
    }

    /// `fromPage`: a hole read, whose span is marked read right after. A listener's change for a
    /// post not held, outside every read range, is NOT added: it would sit next to the newest block
    /// with an unmarked gap between. The hole read brings it in later. A delete still goes to the
    /// tombstones.
    private mutating func apply(_ doc: ChannelDoc<Post>, now: Date, fromPage: Bool) -> Outcome {
        let id = doc.post.id
        if doc.post.deleted { return remove(id, chg: doc.chg, now: now) }
        if !fromPage, posts[id] == nil, !isKnown(doc.post.createdAt) { return .ignored }
        if let tomb = tombs[id] {
            guard let tc = tomb.chg, let dc = doc.chg, dc > tc,
                  now.timeIntervalSince(tomb.at) > Self.tombGrace else { return .ignored }
            tombs[id] = nil
        }
        if let known = postChg[id] {
            guard let dc = doc.chg, dc >= known else { return .ignored }
        }
        let old = posts[id]
        posts[id] = doc.post
        if let dc = doc.chg { postChg[id] = dc }
        unverified.remove(id)
        guard let old else { return .added }
        return old == doc.post ? .unchanged : .edited
    }

    /// The post is gone (deleted for everyone, or hard-deleted). Final: it is remembered, and no
    /// copy of it from an older read can bring it back.
    @discardableResult
    mutating func remove(_ id: String, chg: Int?, now: Date) -> Outcome {
        let had = posts.removeValue(forKey: id) != nil
        postChg[id] = nil
        unverified.remove(id)
        let prev = tombs[id]
        tombs[id] = Tomb(chg: [chg, prev?.chg].compactMap { $0 }.max(), at: prev?.at ?? now)
        if tombs.count > Self.tombCap + 500 { pruneTombs() }
        return had ? .removed : .unchanged
    }

    private mutating func pruneTombs() {
        let keep = tombs.sorted { $0.value.at > $1.value.at }.prefix(Self.tombCap)
        tombs = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: - Reading history

    /// A page read newest-first from `upper` (inclusive). Every doc is applied (tombstones
    /// included, which only remember the id), and when the SERVER answered the whole span it
    /// covers is marked read: from the page's oldest doc up to `upper`, or down to the start for a
    /// short page. A deleted post therefore never stops the fill: its range is read all the same.
    @discardableResult
    mutating func applyPage(_ docs: [ChannelDoc<Post>], upper: Date, full: Bool,
                            fromServer: Bool, now: Date) -> PageResult {
        var r = PageResult()
        for d in docs {
            switch apply(d, now: now, fromPage: true) {
            case .added: r.added += 1
            case .edited: r.edited += 1
            case .removed: r.removed += 1
            case .unchanged, .ignored: break
            }
        }
        guard fromServer else { return r }   // a cache answer may have holes of its own
        var lo: Date = .distantPast
        if full {
            let oldest = docs.map(\.post.createdAt).min() ?? upper
            // A full page of one single stamp would mark nothing and be read again for ever.
            lo = oldest < upper ? oldest : upper.addingTimeInterval(-0.001)
        }
        // Rows kept across a "too long" gap that the server no longer has in this span.
        if !unverified.isEmpty {
            let pageIds = Set(docs.map(\.post.id))
            let gone = unverified.filter { id in
                guard let p = posts[id], !pageIds.contains(id) else { return false }
                return p.createdAt > lo && p.createdAt <= upper
            }
            for id in gone {
                remove(id, chg: nil, now: now)
                r.dropped += 1
            }
        }
        markKnown(lo: lo, hi: upper)
        return r
    }

    /// `createdAt` lies inside a range already read.
    func isKnown(_ createdAt: Date) -> Bool {
        ranges.contains { $0.lo < createdAt && createdAt <= $0.hi }
    }

    /// Clear Messages on the server (`changes` record `{clear: true, before}`): every post created at
    /// or before `before` is gone. Returns the posts removed (their local copies go too).
    @discardableResult
    mutating func clearBefore(_ before: Date, now: Date) -> [Post] {
        let gone = posts.values.filter { $0.createdAt <= before }
        for p in gone { remove(p.id, chg: nil, now: now) }
        return gone
    }

    /// Marks `lo < createdAt <= hi` read, merging with any range it touches.
    mutating func markKnown(lo: Date, hi: Date) {
        guard lo < hi else { return }
        var merged = Range(lo: lo, hi: hi)
        var out: [Range] = []
        for r in ranges {
            if r.hi < merged.lo || r.lo > merged.hi {
                out.append(r)
            } else {
                merged.lo = min(merged.lo, r.lo)
                merged.hi = max(merged.hi, r.hi)
            }
        }
        out.append(merged)
        out.sort { $0.lo < $1.lo }
        ranges = out
    }

    /// More changes waited than one listener answer holds ("too long"). Everything held stays on
    /// screen but is no longer known to be current; the newest page read next goes on top, and
    /// what lies between it and the old rows is a hole.
    mutating func resetForTooLong() {
        unverified = Set(posts.keys)
        ranges = []
    }

    /// Rows paged in before this store knew the channel's change counter: shown, not yet proven.
    mutating func adoptUnverified(_ extra: [Post]) {
        for p in extra where !p.deleted && posts[p.id] == nil && tombs[p.id] == nil {
            posts[p.id] = p
            unverified.insert(p.id)
        }
    }

    /// Every message of the channel was cleared on the server: nothing is left, and that is known.
    mutating func clearAll() {
        posts = [:]
        postChg = [:]
        unverified = []
        ranges = [Range(lo: .distantPast, hi: .distantFuture)]
    }

    /// Keep the newest `n` visible posts (and the hidden ones among them). Older rows go, and the
    /// ranges are cut at the same place, so what went is a hole again, read back when needed.
    @discardableResult
    mutating func bound(keepVisible n: Int, _ isVisible: (Post) -> Bool) -> Int {
        var shown = 0
        var cut: Date?
        for p in sortedPosts.reversed() {
            if shown >= n { cut = p.createdAt; break }
            if isVisible(p) { shown += 1 }
        }
        guard let c = cut else { return 0 }
        let gone = posts.values.filter { $0.createdAt <= c }.map(\.id)
        for id in gone {
            posts[id] = nil
            postChg[id] = nil
            unverified.remove(id)
        }
        ranges = ranges.compactMap { r in r.hi <= c ? nil : Range(lo: max(r.lo, c), hi: r.hi) }
        return gone.count
    }
}

// MARK: - On disk

/// One channel's store, main thread only, saved to its own file off the main thread.
final class ChannelHistoryBox<Post: ChannelHistoryPost> {
    var history: ChannelHistory<Post>
    let url: URL
    private let io: DispatchQueue
    private let diskKeep: Int
    private let diskVisible: (Post) -> Bool
    private var saveQueued = false
    /// Set by `ChannelHistoryRegistry.removeAll`: a sign-out happened, never write again.
    fileprivate var retired = false

    init(history: ChannelHistory<Post>, url: URL, io: DispatchQueue,
         diskKeep: Int, diskVisible: @escaping (Post) -> Bool) {
        self.history = history
        self.url = url
        self.io = io
        self.diskKeep = diskKeep
        self.diskVisible = diskVisible
    }

    /// Saves within half a second; a burst of changes is one write.
    func scheduleSave() {
        guard !saveQueued, !retired else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveQueued = false
            self.saveNow()
        }
    }

    /// The newest `diskKeep` visible posts and their ranges, written on the disk queue.
    func saveNow() {
        guard !retired else { return }
        let copy = history
        let url = url, keep = diskKeep, visible = diskVisible
        io.async {
            var h = copy
            h.bound(keepVisible: keep, visible)
            guard let data = ChannelHistoryDisk.encode(h) else { return }
            ChannelHistoryDisk.write(data, to: url)
        }
    }

    /// Waits for every write already queued (tests, sign-out).
    func flush() { io.sync {} }
}

enum ChannelHistoryDisk {
    /// Decrypted posts on disk, the same decision and the same protection as ThreadMessageCache.
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    static func encode<P: ChannelHistoryPost>(_ h: ChannelHistory<P>) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(h)
    }

    static func decode<P: ChannelHistoryPost>(_ data: Data, as type: P.Type) -> ChannelHistory<P>? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        // A format this build does not read is simply no store: the channel syncs from scratch.
        return try? d.decode(ChannelHistory<P>.self, from: data)
    }

    static func read<P: ChannelHistoryPost>(_ url: URL, as type: P.Type) -> ChannelHistory<P>? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data, as: P.self)
    }

    static func write(_ data: Data, to url: URL) {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) { makeDirectory(dir) }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }

    /// Protected and never in a backup (the same rule as the other decrypted stores).
    static func makeDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: protection])
        var flagged = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? flagged.setResourceValues(values)
        // The account folder's parent too (the root holds every account's folder).
        var root = dir.deletingLastPathComponent()
        try? root.setResourceValues(values)
    }
}

/// Every channel store of this device, per account and channel. Main thread only. The repository
/// dies with its screen; the store does not, so leaving and reopening a channel (however fast)
/// finds the same rows, the same holes and the same `lastChg`.
final class ChannelHistoryRegistry<Post: ChannelHistoryPost> {
    let directory: URL
    private let io: DispatchQueue
    private let diskKeep: Int
    private let diskVisible: (Post) -> Bool
    private let memoryCap: Int
    private var boxes: [String: ChannelHistoryBox<Post>] = [:]
    private var touched: [String: Int] = [:]
    private var clock = 0
    private var waiting: [String: [(ChannelHistoryBox<Post>) -> Void]] = [:]
    private var generation = 0

    init(directory: URL, diskKeep: Int = 300, memoryCap: Int = 24,
         diskVisible: @escaping (Post) -> Bool = { _ in true }) {
        self.directory = directory
        self.diskKeep = diskKeep
        self.memoryCap = memoryCap
        self.diskVisible = diskVisible
        self.io = DispatchQueue(label: "fariin.chstore.disk", qos: .utility)
    }

    private static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "-" })
    }
    private static func key(_ uid: String, _ cid: String) -> String { uid + "/" + cid }

    func fileURL(uid: String, cid: String) -> URL {
        directory.appendingPathComponent(Self.safe(uid), isDirectory: true)
            .appendingPathComponent(Self.safe(cid) + ".json")
    }

    /// Already in memory (what a tap may ask on the main thread).
    func memory(uid: String, cid: String) -> ChannelHistoryBox<Post>? {
        let k = Self.key(uid, cid)
        if let b = boxes[k] { touch(k); return b }
        return nil
    }

    /// A store file exists for this channel (a stat, no read).
    func hasFile(uid: String, cid: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(uid: uid, cid: cid).path)
    }

    /// Memory, else the disk on the calling thread, else a new empty store (tests).
    func openSync(uid: String, cid: String) -> ChannelHistoryBox<Post> {
        let k = Self.key(uid, cid)
        if let b = boxes[k] { touch(k); return b }
        let url = fileURL(uid: uid, cid: cid)
        io.sync {}   // a write still queued lands before the read
        let h = ChannelHistoryDisk.read(url, as: Post.self) ?? ChannelHistory<Post>()
        return insert(k, h, url)
    }

    /// Memory at once (synchronously); otherwise the file is read off the main thread, on the disk
    /// queue so it always comes after any write still queued, and handed back on the main thread.
    func open(uid: String, cid: String, _ done: @escaping (ChannelHistoryBox<Post>) -> Void) {
        let k = Self.key(uid, cid)
        if let b = boxes[k] { touch(k); done(b); return }
        if waiting[k] != nil { waiting[k]?.append(done); return }
        waiting[k] = [done]
        let url = fileURL(uid: uid, cid: cid)
        let gen = generation
        io.async(qos: .userInitiated) { [weak self] in
            let h = ChannelHistoryDisk.read(url, as: Post.self)
            DispatchQueue.main.async {
                guard let self else { return }
                let calls = self.waiting.removeValue(forKey: k) ?? []
                // A sign-out in between: the old account's posts never come back into memory.
                guard self.generation == gen else { return }
                let box = self.boxes[k] ?? self.insert(k, h ?? ChannelHistory<Post>(), url)
                calls.forEach { $0(box) }
            }
        }
    }

    /// The channel's store is gone (Clear Messages while it was closed): memory and file.
    func forget(uid: String, cid: String) {
        let k = Self.key(uid, cid)
        boxes[k]?.retired = true
        boxes[k] = nil
        touched[k] = nil
        let url = fileURL(uid: uid, cid: cid)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Sign-out: every account's decrypted posts go, memory and disk, after any queued write.
    func removeAll() {
        for b in boxes.values { b.retired = true }
        boxes = [:]
        touched = [:]
        waiting = [:]
        generation += 1
        io.sync {}
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ k: String, _ h: ChannelHistory<Post>, _ url: URL) -> ChannelHistoryBox<Post> {
        let box = ChannelHistoryBox(history: h, url: url, io: io, diskKeep: diskKeep, diskVisible: diskVisible)
        boxes[k] = box
        touch(k)
        if boxes.count > memoryCap {
            // The least recently opened one leaves memory; its file stays.
            if let old = touched.min(by: { $0.value < $1.value })?.key, old != k {
                boxes[old]?.saveNow()
                boxes[old] = nil
                touched[old] = nil
            }
        }
        return box
    }

    private func touch(_ k: String) {
        clock += 1
        touched[k] = clock
    }
}

/// The app's channel stores (Application Support, per account). Wiped by SessionWipe.
enum ChannelHistoryStore {
    static let shared: ChannelHistoryRegistry<Message> = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Notices are not what the reader counts as posts; the disk keeps the newest 300 posts.
        return ChannelHistoryRegistry<Message>(directory: base.appendingPathComponent("chstore-v1", isDirectory: true),
                                               diskVisible: { !$0.isSystem })
    }()
}
