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
