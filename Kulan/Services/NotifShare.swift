import Foundation
import FirebaseAuth

/// ⛔ READABLE BANNERS — owner 2026-10-18 (see Shared/NotifShared.swift for the whole design).
///
/// The app's half: keeps what the notification extension needs to open a message and draw the
/// sender's photo up to date in the App Group. Called from Crypto.swift (the key copy and the
/// public keys) and from ConversationsRepository (names and photos). Every call is best effort and
/// cheap: a failed write only means a banner shows the server's hint ("New message"), as before.
enum NotifShare {
    private static let queue = DispatchQueue(label: "fariin.notifshare", qos: .utility)
    /// The chat map last written, so an unchanged chat list costs a dictionary compare, not a write.
    private static let lastChats = NSLock()
    nonisolated(unsafe) private static var lastChatsValue: [String: [String: Any]]? = nil

    /// Group member photos kept per group. A banner only ever needs the sender's, and a very large
    /// group would otherwise put thousands of URLs into a file the extension reads on every push.
    private static let memberPhotoCap = 256

    /// This account's identity is loaded: store the shared key copy and say who is signed in.
    static func storeIdentity(uid: String, secretKeyB64: String) {
        queue.async {
            NotifShared.storeSecretKey(secretKeyB64, uid: uid)
            NotifShared.defaults?.set(uid, forKey: NotifShared.uidKey)
        }
    }

    /// Sign-out / account deletion: the copy, the uid, the chat details and cached avatars go.
    static func clearAccount() {
        lastChats.withLock { lastChatsValue = nil }
        queue.async { NotifShared.clearAccount() }
    }

    /// Mirrors Crypto's disk cache of peers' public keys (`crypto.pubKeys.v1`).
    static func mirrorPubKeys(_ dict: [String: String]) {
        queue.async { NotifShared.defaults?.set(dict, forKey: NotifShared.pubKeysKey) }
    }

    /// Mirrors Crypto's ring of earlier public keys (`crypto.pubRing.v1`).
    static func mirrorRing(_ ring: [String: [String]]) {
        queue.async { NotifShared.defaults?.set(ring, forKey: NotifShared.pubRingKey) }
    }

    /// The chat list changed: names and photo URLs per chat, as this phone shows them.
    static func noteConversations(_ convs: [Conversation]) {
        guard let me = Auth.auth().currentUser?.uid else { return }
        var map: [String: [String: Any]] = [:]
        for c in convs {
            var e: [String: Any] = [:]
            if c.isGroup {
                e[NotifShared.Chat.group] = "1"
                e[NotifShared.Chat.name] = c.displayName(me)
                if let p = c.avatarUrl, p.hasPrefix("https://") { e[NotifShared.Chat.photo] = p }
                var members: [String: String] = [:]
                for (uid, url) in c.photos where uid != me && url.hasPrefix("https://") {
                    if members.count >= memberPhotoCap { break }
                    members[uid] = url
                }
                if !members.isEmpty { e[NotifShared.Chat.members] = members }
            } else {
                e[NotifShared.Chat.name] = c.displayName(me)
                if let p = c.displayPhoto(me), p.hasPrefix("https://") { e[NotifShared.Chat.photo] = p }
            }
            map[c.id] = e
        }
        let changed: Bool = lastChats.withLock {
            if let last = lastChatsValue, NSDictionary(dictionary: last).isEqual(to: map) { return false }
            lastChatsValue = map
            return true
        }
        guard changed else { return }
        queue.async { NotifShared.defaults?.set(map, forKey: NotifShared.chatsKey) }
    }
}
