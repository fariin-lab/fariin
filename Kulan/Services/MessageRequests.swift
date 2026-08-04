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

    /// May I open a chat with this person at all?
    ///
    /// "My Friends" means an accepted conversation already exists. That is the same test the rules
    /// make, so the screen and the database agree about who is a friend.
    ///
    /// A MISS MEANS YES. If we have not read their settings we let the attempt through and let the
    /// rules refuse it — the same reasoning as [CallPrivacyIndex]: a stale guess must never be the
    /// thing that stops a legitimate message.
    static func mayStartChat(with other: UserProfile) async -> Bool {
        guard other.id != ChatService.uid else { return true }
        let audience = other.privacy["messages"] ?? Audience.everyone.rawValue
        guard audience == Audience.contacts.rawValue else { return true }
        let cid = ChatService.convId(ChatService.uid, other.id)
        guard let snap = try? await Firestore.firestore()
            .collection("conversations").document(cid).getDocument() else { return true }
        guard let data = snap.data() else { return false }         // no history, friends-only → no
        return Conversation(id: cid, data: data).accepted
    }
}
