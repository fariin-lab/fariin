import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

/// Every phone signed in to this account, as a real list you can act on.
///
/// Replaces the old "Linked Devices" screen, which advertised a desktop app that does not
/// exist. the reference app's Devices screen was the reference: what is signed in, which one you are
/// holding, and a way to throw the others off.
///
/// The record lives at `users/{uid}/devices/{deviceId}`, keyed by `identifierForVendor` —
/// stable for as long as Fariin stays installed, and reset by a delete + reinstall, which is
/// the behaviour we want: a reinstall IS a new session.
///
/// TWO THINGS THIS DELIBERATELY DOES NOT PROMISE (both true of the reference app's screen too):
///  * A device that is switched off is signed out when it next opens, not the instant you tap.
///    Its push tokens go immediately though, so it stops ringing and stops receiving right away.
///  * Messages already on that phone stay on it. They are stored locally and encrypted, and no
///    server command can reach in and delete them.
@MainActor
final class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()
    private init() {}

    /// Set when the server says this device's record is gone: someone signed us out from
    /// another phone. RootView watches this and performs the sign-out.
    @Published private(set) var revoked = false

    private var watcher: ListenerRegistration?
    private var registered = false

    private var db: Firestore { Firestore.firestore() }
    private var uid: String? { Auth.auth().currentUser?.uid }

    /// This install's id. Empty only if iOS refuses to give one, in which case we skip the
    /// whole feature rather than invent an id that would multiply on every launch.
    /// `nonisolated` because `DeviceSession` (a plain struct, built off the Firestore callback)
    /// compares against it.
    nonisolated static var thisDeviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? ""
    }

    private func devices(_ uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("devices")
    }

    // MARK: - This device

    /// Record this device and start watching for a remote sign-out. Safe to call on every
    /// launch and after every sign-in.
    func start() {
        Task { await registerThisDevice() }
    }

    private func registerThisDevice() async {
        guard let uid, !Self.thisDeviceId.isEmpty else { return }
        let ref = devices(uid).document(Self.thisDeviceId)

        var data: [String: Any] = [
            "model": UIDevice.current.model,                       // "iPhone"
            "hardware": Self.hardwareIdentifier,                   // "iPhone16,1" — for support, not shown
            "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "appVersion": Self.appVersion,
            "lastSeenAt": FieldValue.serverTimestamp(),
        ]
        // First sign-in on this device sets the date it started. Written only when the record
        // is new, so "signed in on" keeps meaning the first time, not the last launch.
        let existing = try? await ref.getDocument()
        if existing?.exists != true { data["createdAt"] = FieldValue.serverTimestamp() }

        do {
            try await ref.setData(data, merge: true)
            registered = true
            watchThisDevice()
        } catch {
            // A failed write must NOT arm the watcher: it would see no record and sign the
            // user out of a device that simply never managed to register.
            registered = false
        }
    }

    /// Keep the push tokens on the record, so signing this device out from another phone can
    /// strip exactly this device's tokens and nothing else.
    func recordFCMToken(_ token: String) {
        guard let uid, !Self.thisDeviceId.isEmpty else { return }
        devices(uid).document(Self.thisDeviceId)
            .setData(["fcmToken": token, "lastSeenAt": FieldValue.serverTimestamp()], merge: true)
    }

    func recordVoipToken(_ token: String) {
        guard let uid, !Self.thisDeviceId.isEmpty else { return }
        devices(uid).document(Self.thisDeviceId)
            .setData(["voipToken": token, "lastSeenAt": FieldValue.serverTimestamp()], merge: true)
    }

    /// Watch our own record. If it stops existing, another device signed us out.
    private func watchThisDevice() {
        guard let uid, watcher == nil, !Self.thisDeviceId.isEmpty else { return }
        watcher = devices(uid).document(Self.thisDeviceId).addSnapshotListener { [weak self] snap, _ in
            guard let self, self.registered else { return }
            // `isFromCache` matters: offline, Firestore reports a document it has never seen as
            // missing. Only the SERVER's word that it is gone counts as a sign-out.
            guard let snap, !snap.metadata.isFromCache, !snap.exists else { return }
            Task { @MainActor in self.revoked = true }
        }
    }

    /// Sign this device out because another device said so. Same teardown as tapping Sign Out.
    func performRevokedSignOut() async {
        stopWatching()
        await Push.unregister()          // needs auth, so before signOut
        try? Auth.auth().signOut()
        SessionWipe.wipeAccountData()
        revoked = false
    }

    /// Normal sign-out on this phone: drop our own record so it does not linger as a ghost
    /// session in the list. Called BEFORE `Auth.signOut()`, while we still have permission.
    func removeThisDevice() async {
        stopWatching()
        guard let uid, !Self.thisDeviceId.isEmpty else { return }
        try? await devices(uid).document(Self.thisDeviceId).delete()
    }

    func stopWatching() {
        watcher?.remove()
        watcher = nil
        registered = false
    }

    // MARK: - The list

    /// Live list, most recently active first.
    func listen(_ onChange: @escaping ([DeviceSession]) -> Void) -> ListenerRegistration? {
        guard let uid else { return nil }
        return devices(uid).addSnapshotListener { snap, _ in
            let all = (snap?.documents ?? []).compactMap(DeviceSession.init)
            // This device pinned to the top, the rest by when they were last active.
            onChange(all.sorted {
                if $0.isThisDevice != $1.isThisDevice { return $0.isThisDevice }
                return $0.lastSeenAt > $1.lastSeenAt
            })
        }
    }

    /// Sign another device out: its record goes, and its push tokens come off the account in
    /// the same batch, so it stops ringing and receiving even before it notices.
    func signOut(deviceId: String) async throws {
        guard let uid else { throw AuthFlowError.notSignedIn }
        guard deviceId != Self.thisDeviceId else { return }   // use Sign Out for this phone

        let ref = devices(uid).document(deviceId)
        let snap = try await ref.getDocument()
        let data = snap.data() ?? [:]

        let batch = db.batch()
        var tokenRemovals: [String: Any] = [:]
        if let fcm = data["fcmToken"] as? String {
            tokenRemovals["fcmTokens"] = FieldValue.arrayRemove([fcm])
        }
        if let voip = data["voipToken"] as? String {
            tokenRemovals["voipTokens"] = FieldValue.arrayRemove([voip])
        }
        if !tokenRemovals.isEmpty {
            batch.updateData(tokenRemovals, forDocument: db.collection("users").document(uid))
        }
        batch.deleteDocument(ref)
        try await batch.commit()
    }

    func signOutAllOthers(_ sessions: [DeviceSession]) async throws {
        for s in sessions where !s.isThisDevice {
            try await signOut(deviceId: s.id)
        }
    }

    // MARK: - Bits about this hardware

    nonisolated static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// "iPhone16,1". Stored for support questions, never shown: it means nothing to a user.
    nonisolated static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "" }
        }
    }
}

/// One signed-in device, as shown in the list.
struct DeviceSession: Identifiable, Hashable {
    let id: String
    let model: String
    let os: String
    let appVersion: String
    let createdAt: Date?
    let lastSeenAt: Date

    var isThisDevice: Bool { id == DeviceRegistry.thisDeviceId }

    init?(_ doc: QueryDocumentSnapshot) {
        let d = doc.data()
        self.id = doc.documentID
        self.model = d["model"] as? String ?? "Phone"
        self.os = d["os"] as? String ?? ""
        self.appVersion = d["appVersion"] as? String ?? ""
        self.createdAt = (d["createdAt"] as? Timestamp)?.dateValue()
        // A record whose server timestamp has not landed yet reads as now, which is true
        // enough: it is being written by a device that is active this second.
        self.lastSeenAt = (d["lastSeenAt"] as? Timestamp)?.dateValue() ?? Date()
    }
}
