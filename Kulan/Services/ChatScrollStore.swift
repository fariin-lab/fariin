import Foundation

// ⛔ WHERE EACH CHAT WAS LAST BEING READ — the reference app's `lastVisibleInteraction`, in our shape.
//
// Theirs keeps two things per conversation: the id of the last visible interaction, and how much of
// that row was on screen (`onScreenPercentage`). On open, their scroll priority is focus message →
// unread indicator → **last visible interaction, restored to the same on-screen position**. Ours had
// the first two and stopped, so every re-entry to a long chat lost your place.
//
// ⛔ IT LIVES FOR ONE APP RUN AND NO LONGER, AND THAT IS A DELIBERATE DIVERGENCE FROM THEIRS.
// The owner ruled it on 2026-09-05: scroll to the middle of a chat, leave, come back in the same app
// session and you must still be where you were — but once the app has been killed and relaunched,
// opening that chat must land on the NEWEST message.
//
// Theirs does the opposite, and it was read from their source rather than assumed.
// `LastVisibleInteractionStore` is described in their own words as "Tracks the last visible
// interaction per thread (the interaction we last scrolled to)", and it keeps that pair in a
// key-value collection inside their message database, encoded as JSON under the conversation's
// unique id. A database row survives the process, so their cold launch still puts the reader back in
// the middle of the conversation. We take their shape and their open priority and leave their
// lifetime behind, because the owner asked for the newest message after a relaunch and he is the one
// reading it.
//
// So the store is a dictionary and nothing else. It starts empty on launch because a new process
// gets a new dictionary — there is no flag to reset, no expiry to get right, and no file that could
// outlive the run it belongs to.
//
// Main-actor only (written from the list controller's settle points).
/// Not `Codable` any more: the conformance existed only to write this to disk, and there is no disk
/// in this story now.
struct ChatReadingPosition: Equatable {
    /// The row the reader was looking at — `Message.rowId`, which is `clientId ?? id` and therefore
    /// still names the same message after the chat screen has been torn down and rebuilt, unlike an
    /// index or an offset.
    let rowId: String
    /// How far that row's top sat below the top of the visible area when we looked, in points. Their
    /// `onScreenPercentage` expressed the same idea as a fraction of the row; points survive a row
    /// that comes back at a different height just as well and need no second lookup to apply.
    let offsetFromTop: CGFloat
    /// The list's top inset (the bar) when `offsetFromTop` was measured. On reopen the bar's inset
    /// arrives a few milliseconds AFTER the first land, and the land is wrong by exactly it until the
    /// one-time re-pin; knowing the saved inset lets the list keep the row hidden until then (owner,
    /// 2026-10-07: "a small jumping movement" on every reopen). 0 where nobody measured it.
    var topInset: CGFloat = 0
}

final class ChatScrollStore {
    static let shared = ChatScrollStore()
    private init() { purgeLegacyDefaults() }

    /// Every chat's reading position for this run of the app, keyed by conversation id. Its emptiness
    /// at launch is the feature — see the note above.
    private var byCid: [String: ChatReadingPosition] = [:]

    func save(_ cid: String, _ position: ChatReadingPosition) {
        byCid[cid] = position
    }

    /// ⛔ CLEARED WHEN THE READER IS AT THE NEWEST MESSAGE, not saved as "bottom". A chat you left at
    /// the bottom should open at the bottom, and that is what having no stored position already
    /// means — storing a sentinel for it would be a second way to say the same thing, and the two
    /// could disagree.
    func clear(_ cid: String) {
        byCid.removeValue(forKey: cid)
    }

    func position(for cid: String) -> ChatReadingPosition? { byCid[cid] }

    /// The version of this store that shipped wrote every position into `UserDefaults` under
    /// `chatReadingPosition.<conversation id>`, so a phone that ran it is carrying one saved position
    /// for every chat its owner ever scrolled up in. Nothing reads those keys now, but leaving them
    /// on the device keeps a working copy of the behaviour that was just removed, one line of code
    /// away from coming back — and the next person to open this file would find real data under a key
    /// with no reader and have to work out which of the two was the truth. Swept once, on the first
    /// use of the store, and off the main thread because it walks the whole defaults dictionary and no
    /// one is waiting on the answer.
    private func purgeLegacyDefaults() {
        DispatchQueue.global(qos: .utility).async {
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("chatReadingPosition.") {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

// ⛔ HEIGHTS A ROW HAS ACTUALLY RENDERED AT, KEPT ACROSS LEAVING AND RE-ENTERING THE CHAT.
//
// THE BUG (owner, 2026-08-28): open a chat, scroll up through older messages, leave, come back, and
// the messages jitter. Every time. It never settles.
//
// WHY IT ONLY HAPPENS AFTER SCROLLING. A reading position is stored only for a reader who is NOT at
// the newest message, so a chat you left at the bottom reopens at the bottom — and at the bottom
// `adoptHeight` re-pins to the bound, which hides every late height correction. Reopen mid-history
// and the very same corrections preserve an anchor instead, so each one visibly moves the list.
//
// WHERE THE CORRECTIONS COME FROM. Rows still drawn by SwiftUI — photos, albums, voice, cards — are
// measured off-screen by a sizer, and when they render they can disagree. The list already handles
// that: `sizerRefused` and `renderedHeights` record which rows lied and what they really are, and
// `measure()` then returns the truth. But both of those live on the view controller, which dies with
// the screen. So every re-entry threw the answer away and re-learned it from scratch, the same way,
// with the same jump. THAT is why it repeats forever rather than settling after the first time.
//
// This is that answer, kept where the screen cannot take it with it. Theirs has no equivalent because
// it needs none: their cells are laid out from a measurement computed before the cell exists and
// cannot report a different height, so there is nothing to re-learn. Ours self-size, so the closest
// honest thing is to stop forgetting.
//
// Keyed by width as well as chat: a height is only true at the width it rendered at, which is the
// same rule `viewWillLayoutSubviews` already applies when it drops the caches on a rotation.
//
// In memory only, deliberately, and for its own reason rather than the reading position's: this is a
// cache of something re-derivable that is worth nothing once the process is gone, while that one is a
// place the owner chose to be forgotten at every launch.
//
// Main-actor only by convention, exactly as `ChatScrollStore` above is: it is written from the list
// controller's measure and settle points and read from its first land, all of which are main-thread.
final class RenderedHeightStore {
    static let shared = RenderedHeightStore()
    private init() {}

    private struct Key: Hashable {
        let cid: String
        let width: Int      // whole points: a width is a device fact, never a fraction that matters
        // The chat's text follows the phone's text size now (BubbleMetrics), so a height measured at
        // one size is not true at another, the same way it is not true at another width.
        let textSize = BubbleMetrics.contentSizeCategory.rawValue
    }

    /// A height and the row's content signature when it rendered at it.
    /// owner audit 2026-10-06 chat #59: a height saved before the chat was closed was seeded back
    /// without asking whether the message changed meanwhile (an edit, a reaction, a tombstone landed
    /// while you were elsewhere). It is handed back only for the same signature.
    private struct Entry {
        let height: CGFloat
        let signature: String
    }

    private var byKey: [Key: [String: Entry]] = [:]
    /// Least-recently-used chat ids, so a long session moving through many conversations cannot grow
    /// this without bound. Heights are cheap, but "cheap" times two hundred chats is not.
    private var order: [Key] = []
    private let maxChats = 12

    /// owner audit 2026-10-06 chat #88: this was insertion order, so the chat used most (created
    /// first) was the first one dropped. A read or a write now moves the key to the back.
    private func touch(_ key: Key) {
        guard order.last != key else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Heights for the rows whose current content signature still matches the one they rendered
    /// with. A row with no signature now, or a different one, is left for the sizer.
    func heights(cid: String, width: CGFloat, signatures: [String: String]) -> [String: CGFloat] {
        guard !cid.isEmpty, width > 0 else { return [:] }
        let key = Key(cid: cid, width: Int(width.rounded()))
        guard let entries = byKey[key] else { return [:] }
        touch(key)
        var out: [String: CGFloat] = [:]
        for (id, e) in entries where signatures[id] == e.signature { out[id] = e.height }
        return out
    }

    func record(cid: String, width: CGFloat, id: String, height: CGFloat, signature: String?) {
        guard !cid.isEmpty, width > 0, height > 0 else { return }
        let key = Key(cid: cid, width: Int(width.rounded()))
        // No signature, nothing to check a later open against: do not keep a height that could be stale.
        guard let signature else { byKey[key]?.removeValue(forKey: id); return }
        if byKey[key] == nil {
            byKey[key] = [:]
            order.append(key)
            if order.count > maxChats { byKey.removeValue(forKey: order.removeFirst()) }
        } else {
            touch(key)
        }
        byKey[key]?[id] = Entry(height: height, signature: signature)
    }

    /// A message whose content changed is no longer described by what it rendered at last time.
    func forget(cid: String, id: String) {
        guard !cid.isEmpty else { return }
        for key in byKey.keys where key.cid == cid { byKey[key]?.removeValue(forKey: id) }
    }
}

// Reference box so per-row onAppear/onDisappear can update the visible-id set WITHOUT invalidating
// the SwiftUI body on every scroll tick (the same non-invalidating-box trick used elsewhere for
// gesture-adjacent flags). Reset per ThreadView instance.
final class VisibleRowsBox {
    var ids: Set<String> = []
    // Debounce for persisting the reading position: rows fire onAppear for EVERY row that scrolls in
    // (and the list keeps an extra viewport pre-rendered), so saving per-appearance meant an O(n) scan
    // plus a store write on every scroll tick — main-thread churn during exactly the frames that need
    // headroom. One trailing save 0.5s after the last appearance is just as durable.
    var persistWork: DispatchWorkItem?
}
