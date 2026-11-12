import Foundation
import Security
import Sodium

/// The platform-store key of the chat backup (format v1, see BackupArchive): 32 random bytes that
/// lock every backup's archive key in header.json. Kept in the Keychain as a SYNCHRONIZABLE item, so
/// iCloud Keychain (end-to-end encrypted by Apple, never by us) carries it to the person's new
/// iPhone and the backup opens there with no password. Android keeps its own in Block Store.
///
/// One key per account: `fariin_backup_store_key.<uid>`. Available after first unlock, so a backup
/// can run in the background while the phone is locked.
enum BackupStoreKey {
    private static let service = "com.fariin.messenger.backup"

    private static func account(_ uid: String) -> String { "fariin_backup_store_key.\(uid)" }

    /// This account's key, or nil when this phone has none (yet: iCloud Keychain can take a while
    /// to bring it to a new phone).
    static func get(uid: String) -> Bytes? {
        guard !uid.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(uid),
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == BackupArchive.keyBytes else { return nil }
        return Bytes(data)
    }

    /// The key, made and saved first if this account has none. A key that iCloud Keychain brought
    /// in at the same moment wins over the one made here. Nil only if the Keychain refuses the write.
    static func getOrCreate(uid: String) -> Bytes? {
        if let key = get(uid: uid) { return key }
        guard !uid.isEmpty, let key = BackupArchive.newKey() else { return nil }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(uid),
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(key),
        ]
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return key
        case errSecDuplicateItem: return get(uid: uid)
        default: return nil
        }
    }

    /// Account deletion: the key goes from every device on this iCloud Keychain.
    static func delete(uid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(uid),
            kSecAttrSynchronizable as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
