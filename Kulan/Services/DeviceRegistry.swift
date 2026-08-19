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

    /// "This install has been registered for this account before." Per account, so signing in as
    /// somebody else on the same phone starts clean. UserDefaults on purpose: a delete-and-reinstall
    /// clears it, and a reinstall IS a new session (`identifierForVendor` resets with it too).
    private static func registeredKey(_ uid: String) -> String { "device.registered.\(uid)" }

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
        // ⚠️ SIGNED OUT WHILE WE WERE CLOSED. Until now this method wrote the record back
        // unconditionally, so signing a device out from another phone only ever worked against a
        // phone that happened to be RUNNING and listening. A closed one simply re-created its own
        // record on next launch and carried on — while the screen's own footer promised it would be
        // signed out the next time it was opened. The automatic sweep on the server has the same
        // dependency, so this had to be true before that could mean anything.
        //
        // The local marker is what makes the question answerable: an account with NO record and no
        // marker is a first launch, and an account with no record but a marker had one taken away.
        // `source: .server` because Firestore answers from its cache when offline and reports a
        // document it has never seen as missing — which would sign people out for being on a plane.
        // A throw means we could not ask, so we say nothing and register as before.
        let marker = Self.registeredKey(uid)
        let hadRegistered = UserDefaults.standard.bool(forKey: marker)
        var existing: DocumentSnapshot?
        do {
            let fromServer = try await ref.getDocument(source: .server)
            existing = fromServer
            if !fromServer.exists && hadRegistered {
                revoked = true
                return
            }
        } catch {
            existing = try? await ref.getDocument()   // offline: fall through and write as before
        }

        // First sign-in on this device sets the date it started. Written only when the record
        // is new, so "signed in on" keeps meaning the first time, not the last launch.
        if existing?.exists != true { data["createdAt"] = FieldValue.serverTimestamp() }

        do {
            try await ref.setData(data, merge: true)
            UserDefaults.standard.set(true, forKey: marker)
            registered = true
            watchThisDevice()
            startHeartbeat()   // the registration write IS the first beat; this keeps it honest after
        } catch {
            // A failed write must NOT arm the watcher: it would see no record and sign the
            // user out of a device that simply never managed to register.
            registered = false
        }
    }

    // MARK: - Heartbeat

    /// ⚠️ `lastSeenAt` USED TO MEAN "last launched". It was written when the device registered
    /// (a cold launch) and when a push token changed, and nowhere else — so a phone you had used all
    /// week still read "Last active 3 days ago", and the inactivity sweep on the server reads this
    /// exact field to decide what to sign out. Both of those need it to mean what it says.
    ///
    /// A timer rather than one write per foreground: an app left open for an hour is in use for that
    /// hour, and nothing else was going to say so. Five minutes is the interval the list's "Active
    /// now" is drawn against, so the two agree by construction.
    private var heartbeat: Task<Void, Never>?
    private var lastTouch: Date?
    private static let heartbeatInterval: TimeInterval = 300

    /// Start marking this device active. Call when the app comes to the front; safe to call twice.
    func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.touch()
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
            }
        }
    }

    /// Stop when the app goes to the back. What is already written stands: the device was last
    /// active when it was last in front, which is exactly what the list should say.
    func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func touch() async {
        guard let uid, !Self.thisDeviceId.isEmpty, registered else { return }
        // A foreground and a timer tick can land together; one write is enough.
        if let lastTouch, Date().timeIntervalSince(lastTouch) < 60 { return }
        lastTouch = Date()
        try? await devices(uid).document(Self.thisDeviceId)
            .setData(["lastSeenAt": FieldValue.serverTimestamp()], merge: true)
    }

    // MARK: - Automatic sign-out of devices nobody uses

    /// How long a device may sit unopened before the server signs it out, in days. 0 = never.
    /// Stored on the account, not on the phone, because the sweep that acts on it runs on the
    /// server and because the answer should follow you to a new phone.
    /// `nonisolated` like `thisDeviceId` above and for the same reason: the Devices screen reads
    /// them where a main-actor hop would be noise, and they are constants.
    nonisolated static let autoSignOutOptions = [0, 30, 90, 180, 365]
    nonisolated static let autoSignOutDefaultDays = 180

    func autoSignOutDays() async -> Int {
        guard let uid else { return Self.autoSignOutDefaultDays }
        let snap = try? await db.collection("users").document(uid).getDocument()
        return snap?.get("deviceAutoSignOutDays") as? Int ?? Self.autoSignOutDefaultDays
    }

    func setAutoSignOutDays(_ days: Int) async throws {
        guard let uid else { throw AuthFlowError.notSignedIn }
        try await db.collection("users").document(uid)
            .setData(["deviceAutoSignOutDays": days], merge: true)
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
        if let uid { UserDefaults.standard.removeObject(forKey: Self.registeredKey(uid)) }
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
        // The marker goes with the record. Leaving it behind would make the next sign-in on this
        // phone look like a device that had been thrown off.
        UserDefaults.standard.removeObject(forKey: Self.registeredKey(uid))
        try? await devices(uid).document(Self.thisDeviceId).delete()
    }

    func stopWatching() {
        watcher?.remove()
        watcher = nil
        registered = false
        stopHeartbeat()
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
            let user = db.collection("users").document(uid)
            // Both token homes: the old user-doc fields (the signed-out device may be on a
            // pre-move build) and users/{uid}/push/tokens (a post-move build). setData(merge:)
            // on the push doc so a missing doc can't NOT_FOUND the whole batch.
            batch.updateData(tokenRemovals, forDocument: user)
            batch.setData(tokenRemovals, forDocument: user.collection("push").document("tokens"), merge: true)
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
