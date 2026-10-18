import Foundation
import Security

/// ⛔ READABLE BANNERS — owner 2026-10-18: "notifications must look like the big messengers": the
/// sender's name, the real message text and the sender's photo, for 1:1 chats and groups. The text
/// is end-to-end encrypted, so the server cannot write it into the push. The reference apps' model
/// is the one used here: the push carries the CIPHERTEXT, and the notification extension opens it on
/// this phone with this account's key. The server never sees a word.
///
/// This file is what the app and the extension (NotificationService/) agree on, compiled into BOTH
/// targets, so it uses Foundation and Security only. The app WRITES (Kulan/Services/NotifShare.swift,
/// Crypto.swift); the extension READS.
///
/// What is shared, and where:
/// - A COPY of this account's secret key, in the keychain under the App Group as access group
///   (iOS accepts an app group name as a keychain access group for every target that carries the
///   group in `com.apple.security.application-groups`; no `keychain-access-groups` entitlement and
///   no team prefix needed). Same accessibility as the private item (after first unlock, this
///   device only). Its own SERVICE name, so the app's private item, queried without an access
///   group, never meets it, and `Keychain.set`'s delete-then-add on the private item cannot touch it.
///   The private item in Crypto.swift stays exactly where it was: it is the original, this is a copy.
/// - The signed-in uid, peers' PUBLIC keys (current + earlier ring) and, per chat, the display name
///   and photo URLs, in the App Group's UserDefaults suite. Nothing there is secret.
///
/// Everything is removed on sign-out and on account deletion (`clearAccount`).
enum NotifShared {
    static let appGroup = "group.com.kulan.messenger.native"

    /// Keychain: the shared copy of the secret key, one item per account.
    static let keyService = "com.fariin.messenger.crypto.notif"
    static func keyAccount(_ uid: String) -> String { "notif_secret_key_v1.\(uid)" }

    /// App Group defaults keys.
    static let uidKey = "notif.uid.v1"          // who is signed in on this phone right now
    static let pubKeysKey = "notif.pubKeys.v1"   // uid -> b64 current public key (mirror of crypto.pubKeys.v1)
    static let pubRingKey = "notif.pubRing.v1"   // uid -> [b64] earlier keys, newest first (mirror of crypto.pubRing.v1)
    static let chatsKey = "notif.chats.v1"       // cid -> ChatInfo dictionary, see below

    /// Per chat, as stored under `chatsKey[cid]`:
    ///   "g": "1" for a group
    ///   "n": 1:1 = the name this phone shows for the other person (a saved contact name wins);
    ///        group = the group's name
    ///   "p": 1:1 = the other person's photo URL; group = the group photo URL
    ///   "m": group only, sender uid -> photo URL (capped, see NotifShare)
    enum Chat {
        static let group = "g", name = "n", photo = "p", members = "m"
    }

    /// Folder in the App Group container where the extension keeps downloaded avatars.
    static let avatarFolder = "NotifAvatars"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // MARK: Keychain (shared copy)

    @discardableResult
    static func storeSecretKey(_ b64: String, uid: String) -> Bool {
        guard !uid.isEmpty, !b64.isEmpty else { return false }
        if readSecretKey(uid: uid) == b64 { return true }   // already there: no churn on every launch
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount(uid),
            kSecAttrAccessGroup as String: appGroup,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(b64.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func readSecretKey(uid: String) -> String? {
        guard !uid.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount(uid),
            kSecAttrAccessGroup as String: appGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every shared key copy (all accounts), plus the uid, the chat details and the downloaded
    /// avatars (the old account's contacts). Public keys stay: they belong to nobody's session, the
    /// same reasoning as `Crypto.wipeIdentity`.
    static func clearAccount() {
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(avatarFolder, isDirectory: true))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccessGroup as String: appGroup,
        ]
        SecItemDelete(query as CFDictionary)
        defaults?.removeObject(forKey: uidKey)
        defaults?.removeObject(forKey: chatsKey)
    }
}
