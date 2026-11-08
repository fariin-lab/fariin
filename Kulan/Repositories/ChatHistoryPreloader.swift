import Foundation
import UIKit

/// WARMS THE CHATS YOU ARE ABOUT TO OPEN, so the newest messages are already decrypted and on disk
/// before you tap.
///
/// THE PROBLEM (owner, 2026-08-23): "when some one send me new message and i open chat it's draw
/// after i full land on chat". He is right, and only for the chats that have something new — which
/// are the only chats anybody opens.
///
/// A thread already paints from `ThreadMessageCache` synchronously on its first frame, before the
/// push transition (see ThreadRepository.init). That is why an unchanged chat opens instantly. What
/// the cache does not hold is anything that ARRIVED SINCE you last had that chat open: it comes down
/// the live listener after you land, decrypts off the main thread, and draws a beat late. The pop.
///
/// HOW THE REFERENCE MESSENGER SOLVES IT, read from its source rather than guessed: every message is
/// written to a local database the moment it arrives, so by the time you tap there is nothing left to
/// fetch. On top of that its `ChatHistoryPreloadManager` warms a SMALL set in advance — at most three
/// chats at a time, ordered priority first, then unmuted before muted, then unread before read, then
/// most recently active, about sixty messages each, and only while online.
///
/// We have no local database and this is not the place to grow one. What we do have is the warm cache
/// the thread already reads on its first frame, so this fills the same gap from the other end: take
/// their selection rule exactly, warm the top three, write into the cache that is already there.
///
/// ⚠️ IT ONLY WARMS WHAT WENT STALE. A chat whose `updatedAt` has not moved since we last warmed it
/// is already correct in the cache, and re-reading it would be pure cost for no change. That single
/// test is what keeps this from becoming a background tax on a list of two hundred conversations.
@MainActor
final class ChatHistoryPreloader {
    static let shared = ChatHistoryPreloader()
    private init() {
        // Back in the foreground: the list seen in the background (skipped there) gets its pass,
        // whether or not a new list snapshot follows.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in ChatHistoryPreloader.shared.scheduleRerun(after: 0.5) }
        }
    }

    /// Their number, and it is not arbitrary: three is enough to cover the chat you are about to open
    /// and the two behind it, and small enough that a busy morning cannot turn into a fetch storm.
    private static let maxConcurrent = 3
    /// A warm-up that never reports in is dropped rather than held. A listener that cannot reach the
    /// server would otherwise sit in the slot forever and block the chats behind it.
    private static let giveUpAfter: TimeInterval = 8
    /// A warm-up that gave up is not tried again for this long (offline, a refused chat): every list
    /// snapshot would otherwise start the same doomed listener again.
    private static let retryAfterFailure: TimeInterval = 30
    /// How many chats with nothing in memory may have their disk copy read per pass to answer "is it
    /// behind?". The top of the list only, about the twelve the chat list prewarms.
    private static let diskLookups = 12
    /// Only the top of the list is about to be opened (shared rule with Android).
    private static let topOfList = 20
    /// A change must stand this long before its chat is fetched (shared rule with Android).
    private static let debounce: TimeInterval = 1.5
    /// When each chat's current `updatedAt` was first seen ahead of the cache (`debounce`).
    private var changedAt: [String: (stamp: Double, at: Date)] = [:]

    /// Live warm-ups, by conversation id. Holding the repository IS the warm-up: it attaches the same
    /// listener a real thread would, runs the same decrypt, and writes the same cache.
    private var warming: [String: ThreadRepository] = [:]
    /// The `updatedAt` each chat had when its cache was last known to be current (warmed, or found
    /// already holding a row as new as the chat).
    private var warmedAt: [String: Double] = [:]
    /// When a warm-up last gave up, by conversation id (`retryAfterFailure`).
    private var failedAt: [String: Date] = [:]
    /// Chats whose disk copy has been asked for once already (found or not).
    private var diskAsked = Set<String>()
    /// The last list handed in, so a refresh that was held back (a chat open, the launch seconds, all
    /// slots busy) runs again by itself instead of waiting for the next list snapshot.
    private var lastList: [Conversation] = []
    private var lastMe = ""
    private var rerun: Task<Void, Never>?

    /// First touched at app start (the conversations listener is one of the first things running),
    /// so this is close enough to launch time for a three-second hold.
    private static let launchedAt = Date()

    /// ⛔ IS THE CACHE BEHIND THE CHAT? (owner 2026-11-07: a chat opened from the list without the
    /// message that came in a quarter of an hour earlier, which popped in a moment later.) The chat
    /// list's `updatedAt` is live; the newest row the cache holds is what the chat draws first. Same
    /// test and the same 2 s of clock slack as `ThreadView.rowsBehindChat`. nil = nothing in memory.
    static func cacheIsBehind(_ conv: Conversation, me: String) -> Bool? {
        guard let rows = ThreadMessageCache.shared.memoryMessages(for: conv.id),
              let newest = rows.map(\.createdAt).max() else { return nil }
        return conv.displayUpdatedAt(me) > newest.timeIntervalSince1970 * 1000 + 2000
    }

    /// A warm-up has already been answered for the chat as it stands now (`updatedAt` unchanged), so
    /// a cache that still looks older than it has nothing to wait for: that `updatedAt` came from a
    /// write with no message in it. `ThreadView.openCacheBehind` asks before holding an open.
    func knownCurrent(_ conv: Conversation, me: String) -> Bool {
        (warmedAt[conv.id] ?? 0) >= conv.displayUpdatedAt(me)
    }

    /// Called whenever the conversation list changes. Cheap when nothing went stale, which is most of
    /// the time: one filter over the first page.
    func refresh(_ conversations: [Conversation], me: String) {
        guard !me.isEmpty else { return }
        lastList = conversations
        lastMe = me
        // Foreground only: a list snapshot in the background (or the seconds before suspension) is
        // not a reader about to tap. The return to the foreground brings a fresh snapshot.
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        // ⛔ THE SHARED RULES (iOS and Android, coordinator 2026-11-07): 1:1 chats and groups only,
        // and only the top 20 of the list. A channel can take a post a minute, and warming every
        // follower's copy would be a read storm; channels get only the open's safety net.
        let candidates = conversations.prefix(Self.topOfList).filter { c in
            guard !c.isChannel, warming[c.id] == nil,
                  c.displayUpdatedAt(me) > (warmedAt[c.id] ?? 0) else { return false }
            if let f = failedAt[c.id], now.timeIntervalSince(f) < Self.retryAfterFailure { return false }
            return true
        }
        // Debounce, per chat: a change is fetched once it has stood 1.5 s, so a burst of messages
        // (or of list snapshots for one message) costs one read of the window, not one per snapshot.
        let liveIds = Set(candidates.map(\.id))
        changedAt = changedAt.filter { liveIds.contains($0.key) }
        var due: [Conversation] = []
        var nextDue: TimeInterval?
        for c in candidates {
            let stamp = c.displayUpdatedAt(me)
            if let seen = changedAt[c.id], seen.stamp == stamp {
                let waited = now.timeIntervalSince(seen.at)
                if waited >= Self.debounce { due.append(c) }
                else { nextDue = min(nextDue ?? .infinity, Self.debounce - waited) }
            } else {
                changedAt[c.id] = (stamp, now)
                nextDue = min(nextDue ?? .infinity, Self.debounce)
            }
        }
        if let nextDue { scheduleRerun(after: nextDue + 0.05) }
        guard !due.isEmpty else { return }
        let candidatesDue = due
        // ⛔ NOT WHILE A CHAT IS OPEN, AND NOT IN THE FIRST SECONDS AFTER LAUNCH — owner, 2026-09-27,
        // the first chat opened after launch still late. At launch every chat reads as stale (nothing
        // is stamped yet), so each list snapshot started three full chat loads (listeners, keys,
        // decrypt, rebuild) exactly when he was tapping one, and they competed with it for the
        // database queue and the main thread.
        // ⛔ BUT COME BACK BY ITSELF (owner 2026-11-07). This used to wait for the NEXT list snapshot,
        // and a quiet list has none: a message that arrived while another chat was open, or in the
        // launch seconds, was never warmed, and its chat opened on the old rows.
        if AppRouter.shared.activeChatId != nil { scheduleRerun(after: 2); return }
        let sinceLaunch = now.timeIntervalSince(Self.launchedAt)
        if sinceLaunch <= 3 { scheduleRerun(after: 3.2 - sinceLaunch); return }
        let nowSecs = now.timeIntervalSince1970

        // THEIR ORDER, in their sequence. Unmuted first because a muted chat is one you have already
        // said you are not in a hurry about; unread before read because that is the chat you are
        // walking towards; recency last as the tie-break.
        let ranked = candidatesDue.sorted { a, b in
            let aMuted = a.isMuted(me, now: nowSecs), bMuted = b.isMuted(me, now: nowSecs)
            if aMuted != bMuted { return !aMuted }
            let aUnread = a.hasUnreadMark(me), bUnread = b.hasUnreadMark(me)
            if aUnread != bUnread { return aUnread }
            return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)
        }

        var lookups = 0
        for conv in ranked {
            let stamp = conv.displayUpdatedAt(me)
            switch Self.cacheIsBehind(conv, me: me) {
            case .some(false):
                // ⚠️ ONLY THE CHATS WHOSE CACHE IS ACTUALLY BEHIND. The cache already holds a row as
                // new as the chat (it was open when it changed, or I sent from here): nothing to
                // read. This keeps a fresh launch from re-reading the whole first page.
                warmedAt[conv.id] = stamp
            case .some(true):
                guard warming.count < Self.maxConcurrent else { continue }
                warm(conv, me: me)
            case .none:
                // Nothing in memory. Its disk copy is read first (off the main thread) and the chat
                // is asked about again when it lands. A chat with no copy at all is behind by
                // definition and is warmed.
                if !diskAsked.contains(conv.id) {
                    guard lookups < Self.diskLookups else { continue }
                    lookups += 1
                    diskAsked.insert(conv.id)
                    ThreadMessageCache.shared.loadAsync(conv.id) { _ in
                        Task { @MainActor in ChatHistoryPreloader.shared.scheduleRerun(after: 0.2) }
                    }
                } else {
                    guard warming.count < Self.maxConcurrent else { continue }
                    warm(conv, me: me)
                }
            }
        }
    }

    /// Every conversation is gone (sign-out, account wipe). Drop the listeners with them.
    func stopAll() {
        warming.values.forEach { $0.stop() }
        warming.removeAll()
        warmedAt.removeAll()
        failedAt.removeAll()
        diskAsked.removeAll()
        changedAt.removeAll()
        lastList = []
        lastMe = ""
        rerun?.cancel(); rerun = nil; rerunAt = nil
    }

    /// One pending re-run at a time; the sooner one wins (the re-run schedules whatever is left).
    private func scheduleRerun(after delay: TimeInterval) {
        let at = Date().addingTimeInterval(max(0.1, delay))
        if rerun != nil, let rerunAt, rerunAt <= at { return }
        rerun?.cancel()
        rerunAt = at
        let nanos = UInt64(max(0.1, delay) * 1_000_000_000)
        rerun = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.rerun = nil
            self.rerunAt = nil
            self.refresh(self.lastList, me: self.lastMe)
        }
    }
    private var rerunAt: Date?

    private func warm(_ conv: Conversation, me: String) {
        let cid = conv.id
        let stamp = conv.displayUpdatedAt(me)
        let repo = ThreadRepository(cid: cid, warmOnly: true)
        warming[cid] = repo
        repo.start()

        Task { @MainActor in
            let deadline = Date().addingTimeInterval(Self.giveUpAfter)
            // ⛔ WAIT FOR THE SERVER'S WINDOW, NOT `didInitialLoad` (owner 2026-11-07, the root of
            // the late message). A chat with rows in memory is seeded in `ThreadRepository.init`,
            // which sets `didInitialLoad` at once, and the first snapshot after that is Firestore's
            // LOCAL copy, which does not hold what arrived while no listener was on this chat. This
            // loop let go on that flag before the server had answered and stamped the chat as warm,
            // so the cache stayed behind and was not tried again until the next message.
            // ThreadRepository writes ThreadMessageCache every time its message set settles; the
            // work here is only to know WHEN to let go. A local copy that already holds the new rows
            // counts too: Firestore raises no second event when the server has nothing to add.
            func current() -> Bool {
                repo.serverWindowSettled || Self.cacheIsBehind(conv, me: me) == false
            }
            while !current(), Date() < deadline, AppRouter.shared.activeChatId != cid {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Opened meanwhile: the chat's own repository owns the cache from here.
            if current() {
                warmedAt[cid] = stamp
                failedAt[cid] = nil
            } else if AppRouter.shared.activeChatId != cid {
                // ⚠️ SILENCE IS AN ANSWER. Firestore raises no server event when the server has
                // nothing to add to its local copy, and `updatedAt` also moves on settings writes
                // that carry no message (a rename, a member switch). With the local snapshot in and
                // no listener error, the chat has nothing newer: it is stamped, never retried every
                // 30 s for a message that does not exist. A refused or dead listener is retried.
                if repo.didInitialLoad, !repo.listenerFailed {
                    warmedAt[cid] = stamp
                    failedAt[cid] = nil
                } else {
                    failedAt[cid] = Date()
                }
            }
            repo.stop()
            warming[cid] = nil
            // A slot is free: the chats that were behind the first three get their turn now.
            scheduleRerun(after: 0.3)
        }
    }
}
