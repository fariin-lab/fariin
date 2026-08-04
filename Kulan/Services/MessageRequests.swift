import Foundation
import FirebaseFirestore
import FirebaseAuth

/// MESSAGE REQUESTS — a stranger's first message, and what you are allowed to do about it.
///
/// The owner's spec, in his words: "the first message is treated as a Message Request", "the sender
/// can send only one message", Accept and Delete "inside the conversation" rather than in a separate
/// inbox, and accepting makes you Friends. Two audiences only, Everyone and My Friends; there is
/// deliberately no No One.
///
/// THE WHOLE STATE IS TWO FIELDS ON THE CONVERSATION: `startedBy` (who opened it) and `accepted`
/// (whether the other person answered). No requests collection, no mirrored inbox, nothing to keep in
/// step — which is what lets the chat list, the thread and the rules all read the same truth without
/// any of them being able to disagree.
///
/// A conversation with NO `startedBy` is from before this existed and is open. That is the difference
/// between shipping a feature and turning everybody's existing chats into pending requests.
///
/// THIS FILE IS NOT THE ENFORCEMENT. It decides what the screen offers. The rules in
/// `firestore.rules` decide what the database accepts, and they are written to hold even if someone
/// runs a patched client — which is the only version of this that means anything.
enum MessageRequests {

    /// A first message is short on purpose. Long enough to say who you are and why, short enough that
    /// an unanswered request cannot be used to shout at someone.
    ///
    /// ENFORCED ON THE CLIENT ONLY, and that is not an oversight. Message bodies are end-to-end
    /// encrypted, so the server is handed a cipher and cannot measure the words inside it — a rule
    /// counting characters would be counting the encryption. What the rules DO enforce is the part
    /// that matters: exactly one message, from one person, until it is answered. A patched client can
    /// make that one message long; it cannot make it a second message.
    static let firstMessageLimit = 300

    /// What this conversation currently allows.
    enum Stance: Equatable {
        /// A normal chat: accepted, or a group, or one from before requests existed.
        case open
        /// I opened this and they have not answered. My one message is spent; I wait.
        case awaitingReply
        /// They opened this and I have not answered. Accept or Delete, shown in the thread.
        case incoming
        /// I opened this and have not sent my one message yet — it may be at most `firstMessageLimit`.
        case firstMessage
    }

    static func stance(_ c: Conversation, myUid: String = ChatService.uid) -> Stance {
        // Groups are never requests: you were added by a member, which is its own permission.
        guard c.convType != "group", !c.startedBy.isEmpty, !c.accepted else { return .open }
        // THE REQUESTER IS WHOEVER SPOKE FIRST, not whoever opened the document. Opening a chat and
        // never typing is not a request, and reading it as one produced the case where you tapped
        // somebody's name, said nothing, and they were shown "wants to send you a message" with no
        // message under it. `lastSender` answers both directions, so `startedBy` is left doing the
        // one job it is reliable for: marking this as a conversation from the request era at all.
        guard !c.lastSender.isEmpty else { return .firstMessage }
        return c.lastSender == myUid ? .awaitingReply : .incoming
    }

    /// Accept: this becomes an ordinary conversation, and the two of you are now Friends — which is
    /// what "My Friends" means everywhere else in the app.
    ///
    /// Also happens IMPLICITLY when you reply. Answering someone is accepting them; making you tap a
    /// button first would be ceremony for its own sake.
    static func accept(_ cid: String) async throws {
        try await Firestore.firestore().collection("conversations").document(cid)
            .setData(["accepted": true], merge: true)
        // If "Automatically Archive" was what put this chat in the archive, saying yes takes it
        // back out — you just accepted the person, and a normal chat lives in the chat list.
        await UnknownChatArchiver.undoAutoArchive(cid)
    }

    /// Delete: the conversation goes, and with it the request. Not a block — blocking is its own
    /// action and its own button, and quietly conflating the two would tell people they had done
    /// something they had not.
    static func decline(_ cid: String) async throws {
        try await Firestore.firestore().collection("conversations").document(cid).delete()
    }

    // THERE IS DELIBERATELY NO "may I open a chat with them" CHECK HERE.
    //
    // One was written and then deleted unused, which is the useful part to record. The thread should
    // OPEN either way and say why you cannot write — the same rule he set for calls: never hide the
    // button, show a sentence. ThreadView's own `cannotMessageThem` does that from the privacy it has
    // already loaded, and the rules refuse the write regardless. A third copy of the same question,
    // asked over the network before navigating, would only add a pause before an answer the screen
    // already has.
}

/// AUTOMATICALLY ARCHIVE NEW CHATS FROM UNKNOWN USERS (Settings > Chats), on the owner's word,
/// 2026-08-04.
///
/// It moves WHERE a request waits, and nothing else. There is still no separate requests inbox —
/// off, a stranger's request sits in the chat list; on, it sits in Archived Chats. Either way it is
/// an ordinary conversation carrying its Accept and Delete inside itself, which is the whole design
/// this feature was built on and the thing he asked not to break.
///
/// ARCHIVING IS DONE ONCE PER CHAT AND REMEMBERED. Without that ledger, taking a request out of the
/// archive by hand would last until the next snapshot and then silently undo itself, which reads as
/// the app fighting you.
enum UnknownChatArchiver {
    /// The key the Settings toggle binds to, so there is one spelling of it.
    static let defaultsKey = "chats.autoArchiveUnknown"
    private static let doneKey = "chats.autoArchiveUnknown.done"
    private static let doneCap = 400

    private static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    private static let lock = NSLock()

    private static func handled() -> [String] {
        UserDefaults.standard.stringArray(forKey: doneKey) ?? []
    }

    /// Claim a cid. False if this setting has already dealt with it once.
    private static func claim(_ cid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ids = handled()
        guard !ids.contains(cid) else { return false }
        ids.append(cid)
        if ids.count > doneCap { ids.removeFirst(ids.count - doneCap) }
        UserDefaults.standard.set(ids, forKey: doneKey)
        return true
    }

    /// Every chat-list snapshot. Cheap and off when the setting is off.
    static func sweep(_ convs: [Conversation]) {
        guard isOn else { return }
        let me = ChatService.uid
        guard !me.isEmpty else { return }
        for c in convs {
            // THEIR unanswered request only. A chat I started is not from an unknown user to me,
            // and an accepted one is a normal chat with a person I said yes to.
            guard MessageRequests.stance(c, myUid: me) == .incoming else { continue }
            guard !c.isArchived(me) else { continue }
            guard claim(c.id) else { continue }
            // Archive AND mute, which is what the setting says it does. Archiving alone would
            // still buzz the phone for a message you have chosen not to look at yet.
            Task {
                await ChatService.setArchived(c.id, true)
                await ChatService.setMuted(c.id, true)
            }
        }
    }

    /// Undo the archiving THIS setting did, when the request is accepted. Only for chats it moved:
    /// an archive you chose yourself is yours, and accepting somebody must not empty it behind you.
    static func undoAutoArchive(_ cid: String) async {
        lock.lock()
        var ids = handled()
        let wasOurs = ids.contains(cid)
        if wasOurs {
            ids.removeAll { $0 == cid }
            UserDefaults.standard.set(ids, forKey: doneKey)
        }
        lock.unlock()
        guard wasOurs else { return }
        await ChatService.setArchived(cid, false)
        await ChatService.setMuted(cid, false)
    }
}
