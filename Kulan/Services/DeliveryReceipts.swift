import Foundation
import FirebaseFirestore

/// "It reached my phone" — the recipient's half of the two grey ticks (owner, 2026-09-25).
///
/// Two writers, one field (`conversations/{cid}.delivered.{uid}`, milliseconds of the conversation's
/// `updatedAt` this phone has):
///  · THIS, while the app is running: every server snapshot of the chat list names the newest message
///    of each chat, so each 1:1 chat whose newest message is from the other person and is newer than
///    what I last confirmed gets confirmed.
///  · the server's `ackDelivered`, while the app is closed: the notification extension calls it the
///    moment the push lands on this phone.
///
/// Never for a chat I blocked (the blocked sender keeps one tick, which is what large messengers do
/// and says nothing a block has not already hidden), never for a group (no delivered state there),
/// never for the official channel or demo chats.
@MainActor
enum DeliveryReceipts {
    /// cid → the value already written this session, so a snapshot that changes nothing costs nothing.
    private static var written: [String: Double] = [:]

    static func mark(_ convs: [Conversation], me: String) {
        guard !me.isEmpty else { return }
        let db = Firestore.firestore()
        var batch: WriteBatch?
        var count = 0
        for c in convs {
            guard !c.isGroup,
                  !OfficialChannel.isOfficial(c.id), !DemoMode.isDemoConversation(c.id),
                  !c.lastSender.isEmpty, c.lastSender != me,
                  c.updatedAtMillis > 0,
                  c.updatedAtMillis > (c.delivered[me] ?? 0),
                  c.updatedAtMillis > (written[c.id] ?? 0),
                  c.blockedBy[me] != true,
                  !BlockList.shared.contains(c.otherUid(me))
            else { continue }
            if batch == nil { batch = db.batch() }
            batch?.updateData(["delivered.\(me)": c.updatedAtMillis],
                              forDocument: db.collection("conversations").document(c.id))
            written[c.id] = c.updatedAtMillis
            count += 1
            if count >= 400 { break }   // one batch; the next snapshot picks up the rest
        }
        guard let batch else { return }
        batch.commit { error in
            if let error { print("[delivered] mark failed: \(error.localizedDescription)") }
        }
    }

    /// Sign-out: the next account starts fresh.
    static func reset() { written = [:] }
}
