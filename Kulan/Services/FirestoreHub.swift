import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// ⛔ THE ONE DOOR TO FIRESTORE. Never call `Firestore.firestore()` anywhere else (owner,
/// 2026-10-20, 9th "dead until refresh" report: "fix it so I never have to refresh").
///
/// Why: Firestore 11.15 (and every later release, 13.0.1 included) can stop its own worker for good
/// while closing a gRPC stream (grpc_stream.cc FastFinishCompletionsBlocking / WaitUntilOffQueue,
/// firebase-ios-sdk #12522, still open). After that every send, listener, lookup and call ring waits
/// for ever, and `terminate()` waits behind the same worker. His phone did it three times on
/// 2026-10-20 alone. The stuck client cannot be restarted, but a SECOND FirebaseApp with the same
/// options gets a brand new client with its own worker. So when SessionRecovery proves the client
/// stuck, `swap()` builds that fresh client, signs it in as the same person, and every service
/// re-attaches its listeners to it on `swapped`. The old client is left alone, never touched again
/// (calls into it can wait on its stuck worker), and the process ends the next time he leaves the
/// app, as before, so the next open is back on the default app.
///
/// What the fresh client does NOT have: the old one's disk cache (its files are locked by the stuck
/// client), so lists fill from the server, and writes the old client had queued go out on the next
/// launch, from the old cache.
enum FirestoreHub {
    /// Posted on the main queue after a swap. Every holder of a listener removes nothing (the old
    /// registration belongs to the stuck client) and attaches again through `FirestoreHub.db`.
    static let swapped = Notification.Name("FirestoreHub.swapped")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Firestore?
    nonisolated(unsafe) private static var freshApp: FirebaseApp?
    @MainActor private(set) static var generation = 0
    @MainActor private static var swapping = false
    /// Every attempt gets its own app name: a failed attempt's app may still be deleting.
    @MainActor private static var attempts = 0
    @MainActor private static var authMirror: AuthStateDidChangeListenerHandle?
    /// A fresh client that also gets stuck is swapped again, at most this many times in one process.
    private static let maxSwaps = 3

    /// The Firestore client to use right now. Read it at the moment of use; never keep it in a
    /// stored property (a kept one stays on the stuck client after a swap).
    static var db: Firestore {
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        let first = Firestore.firestore()
        current = first
        return first
    }

    /// Let go of listeners that belong to the stuck client, on `swapped`. `remove()` mutes the
    /// listener at once, then queues the removal on the client's worker, so it runs off the main
    /// thread: on a stuck client nothing on screen must wait for it.
    static func drop(_ registrations: [ListenerRegistration?]) {
        let regs = registrations.compactMap { $0 }
        guard !regs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { regs.forEach { $0.remove() } }
    }

    /// The settings every client is given: real on-disk offline persistence.
    static func configure(_ db: Firestore) {
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        db.settings = settings
    }

    /// Has the app moved off the default client? (The fresh client's Auth must follow sign-in and
    /// sign-out; see `mirrorAuth`.)
    static var isSwapped: Bool {
        lock.lock(); defer { lock.unlock() }
        return freshApp != nil
    }

    /// Build a fresh client, sign it in as the current user, and hand it out. Returns true only when
    /// the fresh client answered a server read; false when there is nobody signed in, the swap limit
    /// is spent, the sign-in did not answer in time, or the fresh client is silent too.
    @MainActor @discardableResult
    static func swap(_ why: String) async -> Bool {
        guard !swapping, generation < maxSwaps,
              let user = Auth.auth().currentUser,
              let base = FirebaseApp.app()?.options.copy() as? FirebaseOptions else { return false }
        swapping = true
        defer { swapping = false }
        let next = generation + 1
        DiagLog.add("SWAP \(next) (\(why)): building a fresh Firestore client")
        attempts += 1
        let name = "kulan-fresh-\(attempts)"
        FirebaseApp.configure(name: name, options: base)
        guard let app = FirebaseApp.app(name: name) else {
            DiagLog.add("  swap: app \(name) was not created")
            return false
        }
        // The fresh client asks ITS OWN app's Auth for tokens, so that Auth has to hold the same
        // person. Same project, same API key: updateCurrentUser takes the user across.
        let signedIn = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do { try await Auth.auth(app: app).updateCurrentUser(user); return true }
                catch { print("[FirestoreHub] updateCurrentUser failed:", error); return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        // Signed out (or someone else signed in) while that ran: nothing to swap for.
        guard signedIn, Auth.auth().currentUser?.uid == user.uid else {
            DiagLog.add("  swap: sign-in on the fresh app did not answer, staying put")
            _ = await app.delete()
            return false
        }
        let fresh = Firestore.firestore(app: app)
        configure(fresh)
        lock.lock()
        current = fresh
        freshApp = app
        lock.unlock()
        generation = next
        mirrorAuth()
        DiagLog.add("  swap \(next) done: listeners attach again on the fresh client")
        NotificationCenter.default.post(name: swapped, object: nil)
        // Proof, not hope: the fresh client must reach the server. If whatever stopped the old one
        // is shared by the whole process, this read stays silent too, and the caller keeps the old
        // net (a fresh process when he leaves the app). The fresh client stays in use either way:
        // it can still come back, the old one never will.
        let uid = user.uid
        let began = Date()
        let answered = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do { _ = try await fresh.collection("users").document(uid).getDocument(source: .server); return true }
                catch { print("[FirestoreHub] fresh client read failed:", error); return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        DiagLog.add(answered ? "  fresh client answered the server in \(ms)ms"
                             : "  fresh client did NOT answer the server in 10s")
        return answered
    }

    /// The fresh app's Auth follows the default app's: signed out there means signed out here, and
    /// a new sign-in is carried across, so rules see the same person on both.
    @MainActor private static func mirrorAuth() {
        guard authMirror == nil else { return }
        authMirror = Auth.auth().addStateDidChangeListener { _, user in
            lock.lock(); let app = freshApp; lock.unlock()
            guard let app else { return }
            let auth = Auth.auth(app: app)
            if let user {
                guard auth.currentUser?.uid != user.uid else { return }
                auth.updateCurrentUser(user) { error in
                    if let error { print("[FirestoreHub] mirror sign-in failed:", error) }
                }
            } else {
                try? auth.signOut()
            }
        }
    }
}
