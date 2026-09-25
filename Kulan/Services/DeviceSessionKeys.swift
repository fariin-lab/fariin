import Foundation
import Security
import UIKit
import FirebaseAuth
import FirebaseFunctions

/// ⛔ ONE-TAP SIGN-IN FOR SAVED ACCOUNTS — owner, 2026-09-25: "when I tap a saved account, log in
/// automatically, don't ask anything; only ask for the password when it was changed somewhere else,
/// or after 30 days not used. Store it securely."
///
/// Each account signed in on this phone gets a DEVICE KEY from the server (functions-account
/// `issueDeviceSession`). It lives in the iOS Keychain: this device only, readable after the first
/// unlock, never in a backup and never synced to iCloud. Tapping the account's card sends it back
/// (`resumeDeviceSession`) and the server answers with a sign-in token, the same custom-token path
/// passkeys use. The server rolls the key on every use and drops it after 30 days unused, on a
/// password change, or when this phone is signed out from another device's Devices page; then the
/// card falls back to the account's usual sign-in.
enum DeviceSessionKeys {
    private static let service = "com.kulan.messenger.native.deviceSession"

    static var deviceId: String { UIDevice.current.identifierForVendor?.uuidString ?? "" }

    // MARK: Keychain

    static func key(for uid: String) -> String? {
        var q = base(uid)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ secret: String, for uid: String) {
        let data = Data(secret.utf8)
        let q = base(uid)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(q as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func forget(_ uid: String) {
        SecItemDelete(base(uid) as CFDictionary)
    }

    private static func base(_ uid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: uid,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    // MARK: Server

    private static var functions: Functions { Functions.functions(region: "me-central1") }

    /// Signed in: make sure this phone holds a key for this account. Cheap when it already does.
    static func ensureIssued() async {
        guard let uid = Auth.auth().currentUser?.uid, !deviceId.isEmpty, key(for: uid) == nil else { return }
        guard let res = try? await functions.httpsCallable("issueDeviceSession").call(["deviceId": deviceId]),
              let secret = (res.data as? [String: Any])?["secret"] as? String else { return }
        store(secret, for: uid)
    }

    /// Signed out: sign in to `uid` with its key. True when signed in; false when there is no key or
    /// the server refused it (expired, password changed, signed out remotely), and the key is
    /// then forgotten so the card goes straight to the usual sign-in next time.
    static func resume(uid: String) async -> Bool {
        guard let secret = key(for: uid), !deviceId.isEmpty else { return false }
        do {
            let res = try await functions.httpsCallable("resumeDeviceSession")
                .call(["uid": uid, "deviceId": deviceId, "secret": secret])
            guard let d = res.data as? [String: Any], let token = d["token"] as? String else { return false }
            if let next = d["secret"] as? String { store(next, for: uid) }
            _ = try await Auth.auth().signIn(withCustomToken: token)
            return Auth.auth().currentUser?.uid == uid
        } catch {
            let ns = error as NSError
            // Only a real refusal forgets the key; offline keeps it for the next try.
            if ns.domain == FunctionsErrorDomain,
               ns.code == FunctionsErrorCode.failedPrecondition.rawValue {
                forget(uid)
            }
            return false
        }
    }

    /// Signed in: end other phones' keys ("sign out" on the Devices page). Best effort.
    static func revoke(deviceIds: [String]) async {
        _ = try? await functions.httpsCallable("revokeDeviceSessions").call(["deviceIds": deviceIds])
    }

    static func revokeAllOthers() async {
        _ = try? await functions.httpsCallable("revokeDeviceSessions").call(["allExcept": deviceId])
    }
}
