import Foundation
import os
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
        Task { @MainActor in WidgetShare.cleared() }
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
        var faces: [String] = []
        for c in convs {
            var e: [String: Any] = [:]
            if c.isGroup {
                e[NotifShared.Chat.group] = "1"
                e[NotifShared.Chat.name] = c.displayName(me)
                if let p = c.avatarUrl, shareable(p) { e[NotifShared.Chat.photo] = p; faces.append(p) }
                var members: [String: String] = [:]
                for (uid, url) in c.photos where uid != me && shareable(url) {
                    if members.count >= memberPhotoCap { break }
                    members[uid] = url
                    faces.append(url)
                }
                if !members.isEmpty { e[NotifShared.Chat.members] = members }
            } else {
                e[NotifShared.Chat.name] = c.displayName(me)
                if let p = c.displayPhoto(me), shareable(p) { e[NotifShared.Chat.photo] = p; faces.append(p) }
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
        warmFaces(faces)
    }

    /// A photo the banner can show: a plain download, or a `fariin-photo://` name, which the banner
    /// reads from the copy the app leaves (`NotifShared.saveAvatar`). Only https used to pass, so a
    /// profile photo never reached the banner at all (owner 2026-11-02: grey face from kream).
    private static func shareable(_ url: String) -> Bool {
        url.hasPrefix("https://") || url.hasPrefix("fariin-photo://")
    }

    /// ⛔ THE FACES ARE READY BEFORE THE FIRST BANNER (owner 2026-11-02). A copy for the banner was
    /// only made when a photo was drawn, so a chat not scrolled to yet still got a grey face. The
    /// chats' photo names are loaded here, quietly, through the app's own loader (which leaves the
    /// copy, and asks the storage rules as the viewer). Capped, two at a time, missing copies only.
    private static let warming = OSAllocatedUnfairLock(initialState: false)
    private static func warmFaces(_ urls: [String]) {
        guard urls.contains(where: { $0.hasPrefix("fariin-photo://") }),
              warming.withLock({ busy in if busy { return false }; busy = true; return true }) else { return }
        Task.detached(priority: .utility) {
            defer { warming.withLock { $0 = false } }
            // Off the main thread: one file check per face.
            var seen = Set<String>()
            let list = Array(urls.filter { u in
                guard u.hasPrefix("fariin-photo://"), seen.insert(u).inserted,
                      let f = NotifShared.avatarFile(u) else { return false }
                return !FileManager.default.fileExists(atPath: f.path)
            }.prefix(80))
            for start in stride(from: 0, to: list.count, by: 2) {
                await withTaskGroup(of: Void.self) { g in
                    for u in list[start..<min(start + 2, list.count)] {
                        g.addTask { _ = await ProfilePhotoLoader.shared.avatar(u) }
                    }
                }
            }
        }
    }
}
