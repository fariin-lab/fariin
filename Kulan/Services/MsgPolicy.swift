import Foundation
import Observation
import FirebaseFirestore

/// ⛔ MESSAGE POLICY FROM THE ADMIN PANEL — owner 2026-10-18: Message Requests and the Chat Key,
/// switched on or off for everybody or for one person, at any time, with no app release.
///
///   config/msgPolicy       { requests, chatKeyRequired, chatKeyVisible }   everybody
///   users/{uid}.msgPolicy  { requests?, chatKeyRequired? }                 one person
///
/// Both are written only by the admin panel's server function (adminApi); the rules refuse them from
/// every phone. A person's own setting beats the everybody setting, which beats the shipped default,
/// and the shipped default is TODAY'S behaviour: requests on, Chat Key required, Chat Key shown.
/// Anything missing or not a true/false reads as that default.
///
/// THE RECIPIENT'S SETTING DECIDES: whether a stranger's first message to them is a request, and
/// whether the stranger needs their key. The same reading is in `firestore.rules`
/// (`requestsOnFor`, `chatKeyRequiredFor`), in `functions/msgPolicy.js` (the push wording) and in the
/// panel's backend. The rules are the enforcement; this only decides what the screen offers, so the
/// two must agree or the composer opens onto a send the database refuses.
///
/// HIDING THE CHAT KEY TURNS ITS REQUIREMENT OFF TOO. A key nobody can see, type or set must never be
/// the reason somebody cannot be reached; the panel says so beside the switch.
///
/// LIVE, NOT ONCE PER LAUNCH (unlike `RemoteFeatures`): one snapshot listener on the config document,
/// one on my own user document (my override), and other people's overrides arrive on the user
/// document listener the chat screen already holds for them (`ThreadRepository` calls `record`).
/// A flip in the panel reaches an open chat within seconds.
@Observable
final class MsgPolicy: @unchecked Sendable {
    static let shared = MsgPolicy()
    private init() {}

    struct Global: Equatable {
        var requests = true
        var chatKeyRequired = true
        var chatKeyVisible = true
    }
    struct Override: Equatable {
        var requests: Bool?
        var chatKeyRequired: Bool?
        init(_ any: Any?) {
            let d = any as? [String: Any] ?? [:]
            requests = d["requests"] as? Bool
            chatKeyRequired = d["chatKeyRequired"] as? Bool
        }
        init() {}
    }

    /// Bumped on every change. Every reader touches it, so SwiftUI views (and anything computed
    /// inside their body, such as `MessageRequests.stance`) redraw when a switch flips. The values
    /// themselves sit behind a lock: `stance` is also called from send paths off the main thread.
    private(set) var revision = 0
    private let lock = NSLock()
    @ObservationIgnored private var global = Global()
    @ObservationIgnored private var overrides: [String: Override] = [:]
    @ObservationIgnored private var configListener: ListenerRegistration?
    @ObservationIgnored private var meListener: ListenerRegistration?

    // MARK: - Listening

    func start(uid: String) {
        stop()
        attach(uid: uid)
    }

    /// 2026-10-20 (owner): after `FirestoreHub.swap` both listeners belong to the stuck client. Let
    /// go of them off-main and attach again on the fresh one, for the same account. The overrides
    /// stay (not a sign-out). Added once, on the first `attach`.
    @ObservationIgnored private var attachedUid: String?
    @ObservationIgnored private var swapObserver: NSObjectProtocol?
    private func watchSwaps() {
        guard swapObserver == nil else { return }
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.configListener != nil, let uid = self.attachedUid else { return }
            FirestoreHub.drop([self.configListener, self.meListener])
            self.configListener = nil
            self.meListener = nil
            self.attach(uid: uid)
        }
    }

    private func attach(uid: String) {
        watchSwaps()
        attachedUid = uid
        configListener = FirestoreHub.db.collection("config").document("msgPolicy")
            .addSnapshotListener { [weak self] snap, _ in
                // An error keeps the last good answer; a missing document is today's behaviour.
                guard let snap else { return }
                let d = snap.data() ?? [:]
                self?.setGlobal(Global(requests: d["requests"] as? Bool ?? true,
                                       chatKeyRequired: d["chatKeyRequired"] as? Bool ?? true,
                                       chatKeyVisible: d["chatKeyVisible"] as? Bool ?? true))
            }
        guard !uid.isEmpty else { return }
        meListener = FirestoreHub.db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                self?.record(uid: uid, data: snap.data())
            }
    }

    /// Stopped on sign-out. The overrides go with the account; the global stays (it describes the app).
    func stop() {
        configListener?.remove(); configListener = nil
        meListener?.remove(); meListener = nil
        attachedUid = nil
        lock.lock(); overrides = [:]; lock.unlock()
    }

    /// Somebody's user document arrived (a chat screen's listener, or my own above).
    func record(uid: String, data: [String: Any]?) {
        guard !uid.isEmpty else { return }
        let o = Override(data?["msgPolicy"])
        lock.lock()
        let changed = overrides[uid] != o
        overrides[uid] = o
        lock.unlock()
        if changed { bump() }
    }

    private func setGlobal(_ g: Global) {
        lock.lock()
        let changed = global != g
        global = g
        lock.unlock()
        if changed { bump() }
    }

    private func bump() {
        if Thread.isMainThread { revision &+= 1 } else { DispatchQueue.main.async { self.revision &+= 1 } }
    }

    // MARK: - Reading

    /// Does a stranger's first message to `uid` arrive as a request (one short text, then wait)?
    /// An unknown person (no listener has delivered their document yet) follows the global, which
    /// is also what the rules do for a person with no override.
    func requestsOn(for uid: String) -> Bool {
        _ = revision
        lock.lock(); defer { lock.unlock() }
        return overrides[uid]?.requests ?? global.requests
    }

    /// Is `uid`'s "People Who Know My Chat Key" choice enforced? Off whenever the Chat Key is hidden.
    func chatKeyRequired(for uid: String) -> Bool {
        _ = revision
        lock.lock(); defer { lock.unlock() }
        guard global.chatKeyVisible else { return false }
        return overrides[uid]?.chatKeyRequired ?? global.chatKeyRequired
    }

    /// Are the Chat Key's rows, buttons and prompts shown anywhere in the app?
    var chatKeyVisible: Bool {
        _ = revision
        lock.lock(); defer { lock.unlock() }
        return global.chatKeyVisible
    }
}
