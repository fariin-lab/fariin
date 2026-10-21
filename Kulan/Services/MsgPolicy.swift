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
    /// 2026-10-21 (owner: with Message Requests OFF in the panel, a first message still went to
    /// Requests and flickered on the sender's side): until the config listener answered, every
    /// phone ran on the built-in `requests = true`, so a cold launch filed a stranger's chat under
    /// Requests and gave the sender the one-short-text request composer. The last answer is kept on
    /// the phone and used from the first frame; the listener still corrects it within a second.
    @ObservationIgnored private var global = MsgPolicy.savedGlobal()
    private static let savedKey = "msgPolicy.global.v1"
    private static func savedGlobal() -> Global {
        guard let d = UserDefaults.standard.dictionary(forKey: savedKey) else { return Global() }
        return Global(requests: d["requests"] as? Bool ?? true,
                      chatKeyRequired: d["chatKeyRequired"] as? Bool ?? true,
                      chatKeyVisible: d["chatKeyVisible"] as? Bool ?? true)
    }
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

    // MARK: - Asking the server now (owner 2026-10-21)

    /// Has `uid`'s user document (and with it their override, or the lack of one) been seen yet?
    func hasRecord(_ uid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return overrides[uid] != nil
    }

    /// ⛔ THE LIVE ANSWER BEFORE A FIRST MESSAGE — owner 2026-10-21. The listener and the saved copy
    /// can both be minutes behind a flip in the panel (a phone that was asleep, a listener on the
    /// old client), and a first message sent on a stale switch is refused by the rules, which read
    /// the live one. So the send path asks once: `config/msgPolicy` from the server, and the
    /// recipient's user document when it has never been seen (or always, with `forceUser`, after a
    /// refusal). Each read waits at most `timeout` seconds and then takes the cache; nothing here
    /// throws, and an unanswered read keeps the last answer.
    func confirm(for other: String?, forceUser: Bool = false, timeout: TimeInterval = 2) async {
        let db = FirestoreHub.db
        async let g = Self.readNow(db.collection("config").document("msgPolicy"), timeout: timeout)
        var userSnap: DocumentSnapshot?
        if let other, !other.isEmpty, forceUser || !hasRecord(other) {
            userSnap = await Self.readNow(db.collection("users").document(other), timeout: timeout)
        }
        if let snap = await g {
            let d = snap.data() ?? [:]
            setGlobal(Global(requests: d["requests"] as? Bool ?? true,
                             chatKeyRequired: d["chatKeyRequired"] as? Bool ?? true,
                             chatKeyVisible: d["chatKeyVisible"] as? Bool ?? true))
        }
        // A user document the cache has never held says nothing; only a real answer is recorded.
        if let other, let userSnap, userSnap.exists || !userSnap.metadata.isFromCache {
            record(uid: other, data: userSnap.data())
        }
    }

    /// After a send the rules refused: read the switch and the recipient once more, so the next
    /// attempt, the composer and the bars all use what the database used. Once per chat per few
    /// seconds; a second caller for the same chat waits on the same reads (the send path and the
    /// chat screen both report a refusal).
    func refreshAfterRefusal(cid: String) async {
        let parts = cid.split(separator: "_").map(String.init)
        let other = parts.count == 2 ? parts.first(where: { $0 != ChatService.uid }) : nil
        await refusalRead(cid: cid, other: other).value
    }
    private func refusalRead(cid: String, other: String?) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        if let last = refusalReads[cid], Date().timeIntervalSince(last.at) < 5 { return last.task }
        let task = Task { await self.confirm(for: other, forceUser: true) }
        refusalReads[cid] = (task, Date())
        return task
    }
    @ObservationIgnored private var refusalReads: [String: (task: Task<Void, Never>, at: Date)] = [:]

    /// One read that prefers the server but never waits longer than `timeout`, then the cache.
    private static func readNow(_ ref: DocumentReference, timeout: TimeInterval) async -> DocumentSnapshot? {
        let once = ReadOnce()
        let server: DocumentSnapshot? = await withCheckedContinuation { cont in
            ref.getDocument(source: .server) { snap, _ in
                if once.claim() { cont.resume(returning: snap) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
        if let server { return server }
        return try? await ref.getDocument(source: .cache)
    }
    private final class ReadOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func setGlobal(_ g: Global) {
        lock.lock()
        let changed = global != g
        global = g
        lock.unlock()
        if changed {
            UserDefaults.standard.set(["requests": g.requests, "chatKeyRequired": g.chatKeyRequired,
                                       "chatKeyVisible": g.chatKeyVisible], forKey: Self.savedKey)
            bump()
        }
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
