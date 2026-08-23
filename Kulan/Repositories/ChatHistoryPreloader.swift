import Foundation

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
    private init() {}

    /// Their number, and it is not arbitrary: three is enough to cover the chat you are about to open
    /// and the two behind it, and small enough that a busy morning cannot turn into a fetch storm.
    private static let maxConcurrent = 3
    /// A warm-up that never reports in is dropped rather than held. A listener that cannot reach the
    /// server would otherwise sit in the slot forever and block the chats behind it.
    private static let giveUpAfter: TimeInterval = 8

    /// Live warm-ups, by conversation id. Holding the repository IS the warm-up: it attaches the same
    /// listener a real thread would, runs the same decrypt, and writes the same cache.
    private var warming: [String: ThreadRepository] = [:]
    /// The `updatedAt` each chat had when we last finished warming it.
    private var warmedAt: [String: Double] = [:]

    /// Called whenever the conversation list changes. Cheap when nothing went stale, which is most of
    /// the time — the whole body is a sort over an already-filtered handful.
    func refresh(_ conversations: [Conversation], me: String) {
        guard !me.isEmpty else { return }
        let now = Date().timeIntervalSince1970

        let stale = conversations.filter { c in
            // The open chat has a real repository of its own doing exactly this work. Warming it
            // again would be a second listener on the same collection for the same result.
            guard c.id != AppRouter.shared.activeChatId else { return false }
            guard warming[c.id] == nil else { return false }
            let seen = warmedAt[c.id] ?? 0
            return c.displayUpdatedAt(me) > seen
        }
        guard !stale.isEmpty else { return }

        // THEIR ORDER, in their sequence. Unmuted first because a muted chat is one you have already
        // said you are not in a hurry about; unread before read because that is the chat you are
        // walking towards; recency last as the tie-break.
        let ranked = stale.sorted { a, b in
            let aMuted = a.isMuted(me, now: now), bMuted = b.isMuted(me, now: now)
            if aMuted != bMuted { return !aMuted }
            let aUnread = a.hasUnreadMark(me), bUnread = b.hasUnreadMark(me)
            if aUnread != bUnread { return aUnread }
            return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)
        }

        for conv in ranked {
            guard warming.count < Self.maxConcurrent else { break }
            warm(conv, me: me)
        }
    }

    /// Every conversation is gone (sign-out, account wipe). Drop the listeners with them.
    func stopAll() {
        warming.values.forEach { $0.stop() }
        warming.removeAll()
        warmedAt.removeAll()
    }

    private func warm(_ conv: Conversation, me: String) {
        let cid = conv.id
        let stamp = conv.displayUpdatedAt(me)
        let repo = ThreadRepository(cid: cid)
        warming[cid] = repo
        repo.start()

        Task { @MainActor in
            let deadline = Date().addingTimeInterval(Self.giveUpAfter)
            // ThreadRepository writes ThreadMessageCache every time its message set settles, so the
            // work here is only to know WHEN to let go. Polling rather than observing: this is not a
            // view, and one flag every 200ms for a few seconds is cheaper than wiring observation
            // into a type that exists to feed a screen.
            while repo.didInitialLoad == false, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Only record success. A give-up leaves `warmedAt` untouched so the next list change
            // tries this chat again instead of writing it off.
            if repo.didInitialLoad { warmedAt[cid] = stamp }
            repo.stop()
            warming[cid] = nil
        }
    }
}
