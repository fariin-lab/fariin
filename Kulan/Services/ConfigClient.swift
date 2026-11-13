import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// THE APP'S FEATURE FLAGS AND LIMITS FROM THE SERVER (owner 2026-11-13, flags design E-design.md 2.5).
///
/// The callable `getAppConfig` (me-central1) resolves every flag for THIS account on the server and
/// sends back plain values: `{values, hash, v}`, `{notModified, v}` when the hash we hold is still
/// right, or `{notReady, v: 0}` before the server side is seeded. The phone never sees the rules.
///
/// Where a value comes from, first hit wins:
///   1. live keys: the newest values for the signed-in account (fresh reply, or that account's cache);
///      nextLaunch keys: the launch snapshot, taken from the cache when the app starts;
///   2. the compiled default below, which is the constant this build shipped with.
/// `RemoteFeatures` / `LiveFeatures` add one more step between the two for the old switches: the
/// legacy `config/features` doc, for an old server or a notReady reply.
///
/// When it asks: at sign-in / cold start, on return to the foreground when the last ask is over 2 h
/// old, and when `config/epoch.v` moves (one small listener; 0 to 3 s random wait first so every
/// phone does not ask in the same second). Nothing waits on it: an error or notReady keeps what is
/// cached, and with no cache the compiled defaults stand.
///
/// Readers may be on any thread: the values sit behind one lock, and each read is one dictionary
/// lookup. Values outside the registry bounds are clamped, a value of the wrong type is ignored.
final class ConfigClient {
    static let shared = ConfigClient()

    // MARK: - Registry (mirror of functions-admin/functions/lib/flagRegistry.js, app keys)

    struct BoolKey { let name: String; let def: Bool }
    struct IntKey { let name: String; let def: Int; let min: Int; let max: Int }
    struct DoubleKey { let name: String; let def: Double; let min: Double; let max: Double }
    struct StringKey { let name: String; let def: String; let allowed: [String] }

    /// The app limits (G-app-keys.md). Every default is the constant the app shipped with, so a phone
    /// that reads them changes nothing until the panel sets one. All apply live.
    enum K {
        // Chats
        static let messageMaxChars = IntKey(name: "messageMaxChars", def: 4096, min: 1000, max: 6400)
        static let messageBubbleChars = IntKey(name: "messageBubbleChars", def: 2500, min: 500, max: 4096)
        static let captionMaxChars = IntKey(name: "captionMaxChars", def: 1024, min: 200, max: 4096)
        static let pinnedMessagesPerChat = IntKey(name: "pinnedMessagesPerChat", def: 3, min: 1, max: 10)
        static let albumMaxItems = IntKey(name: "albumMaxItems", def: 10, min: 1, max: 10)
        static let mediaPerMessage = IntKey(name: "mediaPerMessage", def: 32, min: 1, max: 32)
        static let forwardChatsAtOnce = IntKey(name: "forwardChatsAtOnce", def: 5, min: 1, max: 20)
        static let forwardSelectionMax = IntKey(name: "forwardSelectionMax", def: 32, min: 1, max: 100)
        static let deleteForEveryoneHours = IntKey(name: "deleteForEveryoneHours", def: 48, min: 1, max: 168)
        static let linkPreviews = BoolKey(name: "linkPreviews", def: true)
        static let linkPreviewImageSide = IntKey(name: "linkPreviewImageSide", def: 800, min: 200, max: 1600)
        // Accounts
        static let blockedUsersMax = IntKey(name: "blockedUsersMax", def: 1000, min: 100, max: 10000)
        static let bioChars = IntKey(name: "bioChars", def: 140, min: 70, max: 500)
        static let profilePhotoMB = IntKey(name: "profilePhotoMB", def: 8, min: 1, max: 8)
        // Media (MB = 1024 x 1024 bytes)
        static let fileUploadMB = IntKey(name: "fileUploadMB", def: 25, min: 1, max: 100)
        static let videoMessageMB = IntKey(name: "videoMessageMB", def: 100, min: 1, max: 100)
        static let videoExportTargetMB = IntKey(name: "videoExportTargetMB", def: 62, min: 10, max: 95)
        static let videoSdBytesPerSec = IntKey(name: "videoSdBytesPerSec", def: 250_000, min: 100_000, max: 1_000_000)
        static let videoHdBytesPerSec = IntKey(name: "videoHdBytesPerSec", def: 500_000, min: 200_000, max: 2_000_000)
        static let voiceNoteMinutes = IntKey(name: "voiceNoteMinutes", def: 30, min: 1, max: 120)
        static let photoMaxSideStandard = IntKey(name: "photoMaxSideStandard", def: 1280, min: 640, max: 4096)
        static let photoMaxSideHigh = IntKey(name: "photoMaxSideHigh", def: 2560, min: 1280, max: 4096)
        static let photoJpegQualityPct = IntKey(name: "photoJpegQualityPct", def: 60, min: 30, max: 95)
        static let photoMinSide = IntKey(name: "photoMinSide", def: 640, min: 320, max: 1280)
        static let autoDownloadMaxMB = IntKey(name: "autoDownloadMaxMB", def: 200, min: 1, max: 1000)
        static let autoDownloadPhotoMB = IntKey(name: "autoDownloadPhotoMB", def: 8, min: 1, max: 50)
        static let voiceAutoDownloadMB = IntKey(name: "voiceAutoDownloadMB", def: 2, min: 1, max: 20)
        static let voicePrefetchAhead = IntKey(name: "voicePrefetchAhead", def: 3, min: 0, max: 10)
        // Stories
        static let storyExpiryHours = IntKey(name: "storyExpiryHours", def: 24, min: 1, max: 48)
        static let storyUploadMB = IntKey(name: "storyUploadMB", def: 50, min: 5, max: 50)
        static let storyVideoSeconds = IntKey(name: "storyVideoSeconds", def: 90, min: 10, max: 180)
        static let storyVideoPickSeconds = IntKey(name: "storyVideoPickSeconds", def: 600, min: 60, max: 1800)
        static let storyCaptionChars = IntKey(name: "storyCaptionChars", def: 200, min: 50, max: 2048)
        // Groups and channels
        static let groupAdminsMax = IntKey(name: "groupAdminsMax", def: 20, min: 1, max: 50)
        static let groupNameChars = IntKey(name: "groupNameChars", def: 100, min: 16, max: 255)
        static let channelDescChars = IntKey(name: "channelDescChars", def: 255, min: 50, max: 2000)
        // Calls
        static let groupRingSeconds = IntKey(name: "groupRingSeconds", def: 60, min: 15, max: 60)
    }

    /// The old switches (config/features keys) that apply on the NEXT launch. The rest of the
    /// switches the server sends (groupCreate, groupStats, and every app limit) apply live.
    static let nextLaunchKeys: Set<String> = [
        "glow", "insights", "profileLinks", "myProfileCard", "twoStep", "storyList", "pollRows",
        "stickerEdit", "chatBackup", "chatTransfer", "historyPull", "videoStream", "r2Media",
        "groups", "groupE2EE", "groupCalls", "callLinks",
    ]

    // MARK: - Typed reads (any thread)

    static func bool(_ k: BoolKey) -> Bool { shared.bool(k.name) ?? k.def }

    static func int(_ k: IntKey) -> Int {
        guard let n = shared.number(k.name) else { return k.def }
        let r = n.rounded()
        guard r.isFinite else { return k.def }
        return Int(Swift.min(Double(k.max), Swift.max(Double(k.min), r)))
    }

    static func double(_ k: DoubleKey) -> Double {
        guard let n = shared.number(k.name), n.isFinite else { return k.def }
        return Swift.min(k.max, Swift.max(k.min, n))
    }

    static func string(_ k: StringKey) -> String {
        guard let s = shared.raw(k.name) as? String else { return k.def }
        return k.allowed.isEmpty || k.allowed.contains(s) ? s : k.def
    }

    /// An old switch as the server resolved it for this account, nil when the server said nothing
    /// (old server, notReady, never fetched). nextLaunch keys come from the launch snapshot.
    static func switchValue(_ key: String) -> Bool? { shared.bool(key) }

    // MARK: - State

    private let lock = NSLock()
    /// What the cache held for the account signed in when the app started. Never changes after.
    private var launch: [String: Any] = [:]
    /// True once any nextLaunch switch was read this run; after that `launch` may not be filled.
    private var launchRead = false
    /// The newest values for the signed-in account.
    private var live: [String: Any] = [:]

    // Main-thread only below.
    private var uid: String?
    private var hash: String?
    private var replyV = 0
    private var lastFetchAt: Date?
    private var knownEpoch = 0
    private var fetching = false
    private var again = false
    /// Bumped by each fetch and by stop(): only the newest request may clear `fetching`.
    private var fetchSeq = 0
    private var epochWait: Task<Void, Never>?
    private var listener: ListenerRegistration?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    private func raw(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        if Self.nextLaunchKeys.contains(key) { launchRead = true; return launch[key] }
        return live[key]
    }

    private func bool(_ key: String) -> Bool? {
        guard let n = raw(key) as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private func number(_ key: String) -> Double? {
        guard let n = raw(key) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    // MARK: - Cache (per account)

    private static func cacheKey(_ uid: String) -> String { "configClient.v1.\(uid)" }

    private struct Cached { var values: [String: Any]; var hash: String?; var v: Int; var at: Date? }

    private static func readCache(_ uid: String) -> Cached? {
        guard let d = UserDefaults.standard.dictionary(forKey: cacheKey(uid)),
              let values = d["values"] as? [String: Any] else { return nil }
        return Cached(values: clean(values), hash: d["hash"] as? String, v: (d["v"] as? Int) ?? 0,
                      at: (d["at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

    private static func writeCache(_ uid: String, _ c: Cached) {
        var d: [String: Any] = ["values": c.values, "v": c.v]
        if let h = c.hash { d["hash"] = h }
        if let at = c.at { d["at"] = at.timeIntervalSince1970 }
        UserDefaults.standard.set(d, forKey: cacheKey(uid))
    }

    /// Plain values only (bool, number, string), so nothing odd ever reaches UserDefaults.
    private static func clean(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in raw {
            if let n = v as? NSNumber { out[k] = n } else if let s = v as? String { out[k] = s }
        }
        return out
    }

    // MARK: - Life cycle

    /// Right after `FirebaseApp.configure()`, before any screen: the launch snapshot is taken HERE,
    /// not on the first read, so a reply that lands early cannot change a nextLaunch key mid-launch.
    func takeLaunchSnapshot() {
        guard let uid = Auth.auth().currentUser?.uid, let c = Self.readCache(uid) else { return }
        lock.lock()
        launch = c.values
        live = c.values
        lock.unlock()
    }

    /// With the account's other listeners (RootView). Loads that account's cache as the live values,
    /// asks the server once, and listens to config/epoch.
    @MainActor func start(uid: String) {
        guard !uid.isEmpty else { return }
        if self.uid != uid {
            let c = Self.readCache(uid)
            lock.lock()
            live = c?.values ?? [:]
            // No snapshot yet (signed out at launch, keychain locked before first unlock, or a
            // sign-out cleared it) and no nextLaunch switch read so far: this account's cache is
            // still a launch value, nothing on screen has used the old one.
            if launch.isEmpty, !launchRead { launch = c?.values ?? [:] }
            lock.unlock()
            hash = c?.hash
            replyV = c?.v ?? 0
            lastFetchAt = nil
            knownEpoch = 0
            publishLive()
        }
        self.uid = uid
        watchApp()
        listen()
        fetch(epoch: nil)
    }

    /// Sign-out. The cache stays (it is per account); the live values go back to the defaults so the
    /// next account never runs on this one's values. The launch snapshot stays, like RemoteFeatures.
    @MainActor func stop() {
        listener?.remove(); listener = nil
        epochWait?.cancel(); epochWait = nil
        uid = nil
        hash = nil
        replyV = 0
        knownEpoch = 0
        lastFetchAt = nil
        fetching = false
        again = false
        fetchSeq += 1
        // The launch snapshot belonged to the account that signed out: the nextLaunch switches fall
        // back to the account-free config/features snapshot for the rest of this run.
        lock.lock(); live = [:]; launch = [:]; lock.unlock()
        publishLive()
    }

    @MainActor private func watchApp() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.uid != nil else { return }
                if let at = self.lastFetchAt, Date().timeIntervalSince(at) < 2 * 3600 { return }
                self.fetch(epoch: nil)
            }
        })
        // After `FirestoreHub.swap` the listener belongs to the stuck client: let go and attach again.
        observers.append(NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.listener != nil else { return }
                FirestoreHub.drop([self.listener])
                self.listener = nil
                self.listen()
            }
        })
    }

    /// The one listener: config/epoch {v}. A move past what the last reply carried means a flag changed.
    @MainActor private func listen() {
        guard listener == nil else { return }
        listener = FirestoreHub.db.collection("config").document("epoch")
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap, snap.exists, let v = (snap.data()?["v"] as? NSNumber)?.intValue else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.epochSeen(v) }
                }
            }
    }

    @MainActor private func epochSeen(_ v: Int) {
        guard v > knownEpoch else { return }
        knownEpoch = v
        guard v > replyV, uid != nil else { return }
        epochWait?.cancel()
        epochWait = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...3_000_000_000))
            guard !Task.isCancelled, let self, v > self.replyV else { return }
            self.fetch(epoch: v)
        }
    }

    // MARK: - Fetch

    @MainActor private func fetch(epoch: Int?, retried: Bool = false) {
        guard let uid else { return }
        if fetching { again = true; return }
        fetching = true
        fetchSeq += 1
        let mine = fetchSeq
        var req: [String: Any] = ["build": AppUpdateGate.build, "platform": "ios"]
        if let hash { req["have"] = hash }
        let asked = epoch ?? (knownEpoch > 0 ? knownEpoch : nil)
        if let asked { req["epoch"] = asked }
        Task { @MainActor [weak self] in
            var reply: [String: Any]?
            do {
                let r = try await Functions.functions(region: "me-central1").httpsCallable("getAppConfig").call(req)
                reply = r.data as? [String: Any]
            } catch {
                reply = nil
            }
            guard let self else { return }
            if mine == self.fetchSeq { self.fetching = false }
            // Signed out or another account while it was out: drop the answer, and run an ask that
            // queued behind it for the account signed in now.
            guard self.uid == uid else {
                if !self.fetching, self.again, self.uid != nil { self.again = false; self.fetch(epoch: nil) }
                return
            }
            let v = (reply?["v"] as? NSNumber)?.intValue ?? 0
            if let reply {
                self.apply(reply, uid: uid, v: v)
            }
            // The answer is older than the epoch it was asked for (the server's bundle had not caught
            // up yet): ask once more a little later.
            if let asked, reply != nil, (reply?["notReady"] as? Bool) != true, v < asked, !retried {
                // A queued ask is folded into the retry: it asks for the newest epoch known by then.
                self.again = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard let self else { return }
                    self.fetch(epoch: max(asked, self.knownEpoch), retried: true)
                }
                return
            }
            if self.again {
                self.again = false
                if self.knownEpoch > self.replyV { self.fetch(epoch: self.knownEpoch) }
            }
        }
    }

    @MainActor private func apply(_ reply: [String: Any], uid: String, v: Int) {
        // notReady: the server has no flags yet. Keep the cache; the legacy doc still answers.
        if (reply["notReady"] as? Bool) == true { return }
        let now = Date()
        if (reply["notModified"] as? Bool) == true {
            lastFetchAt = now
            replyV = max(replyV, v)
            if var c = Self.readCache(uid) { c.v = replyV; c.at = now; Self.writeCache(uid, c) }
            return
        }
        guard let values = reply["values"] as? [String: Any] else { return }
        let clean = Self.clean(values)
        lastFetchAt = now
        replyV = max(replyV, v)
        hash = reply["hash"] as? String
        Self.writeCache(uid, Cached(values: clean, hash: hash, v: replyV, at: now))
        lock.lock(); live = clean; lock.unlock()
        publishLive()
    }

    /// The live switches, for views that redraw when one moves (LiveFeatures is @Observable).
    @MainActor private func publishLive() {
        lock.lock()
        var bools: [String: Bool] = [:]
        for (k, v) in live where !Self.nextLaunchKeys.contains(k) {
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { bools[k] = n.boolValue }
        }
        lock.unlock()
        if LiveFeatures.shared.config != bools { LiveFeatures.shared.config = bools }
    }

    /// For LiveFeatures' first value.
    func liveBools() -> [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Bool] = [:]
        for (k, v) in live where !Self.nextLaunchKeys.contains(k) {
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { out[k] = n.boolValue }
        }
        return out
    }
}
