import UIKit
import FirebaseAuth
import FirebaseFirestore

/// ⛔ THE SERVER REFUSED THIS PHONE, SO GET BACK IN AND RECONNECT — owner, 2026-09-27 and 09-28:
/// "every account looks deleted, I can't send, can't archive, can't react". Fine with the internet
/// off, healed only by a restart.
///
/// Firestore ends a snapshot listener for good the first time the server refuses it, and nothing in
/// the app ever attached one again. No screen watched the ID token, so one refused moment (a sign-in
/// whose two-step answer had not reached the token yet, a token that failed to refresh) left the chat
/// list, the open chat, my own profile sync, the block list and the device watcher dead until the
/// process died. The refusal itself could be over in seconds; the damage lasted until a restart
/// because the restart was the only thing that attached them again.
///
/// This is the one place that decides what a refusal means:
///  - it asks Firebase for a FRESH token, because a refusal is either a stale token or a real change;
///  - a fresh token that passes the same two-step test as the rules posts `recovered`, and every
///    owner of a listener that must not stay dead attaches its own again;
///  - a fresh token that does not pass posts `needsTwoStep`: the screen a new sign-in gets;
///  - a refresh Firebase refuses because the session is over (revoked, the account disabled or
///    deleted) posts `sessionEnded`: the teardown of a sign-out from another device.
///
/// Retries back off (1s, 3s, 10s, 30s, 60s, 60s) and then stop; coming back to the app starts them
/// again. The back-off only resets after five quiet minutes, so a refusal that survives a fresh
/// token cannot turn into a loop that re-attaches every second.
///
/// ⚠️ ONLY READS A SIGNED-IN MEMBER IS ALWAYS ALLOWED REPORT HERE: my chat list, my own documents, an
/// open chat's messages, anyone's profile document (`allow get: if signedIn()`). Presence and the
/// other audience-gated reads are refused ON PURPOSE for some people; reporting those would treat a
/// privacy setting as a broken session.
///
/// The TYPE is not main-actor, only its state and its functions are: the notification names are
/// read by repositories that are not main-actor types, and a constant needs no actor.
enum SessionRecovery {
    static let recovered = Notification.Name("SessionRecovery.recovered")
    static let needsTwoStep = Notification.Name("SessionRecovery.needsTwoStep")
    static let sessionEnded = Notification.Name("SessionRecovery.sessionEnded")

    private static let delays: [Double] = [1, 3, 10, 30, 60, 60]
    @MainActor private static var attempt = 0
    @MainActor private static var scheduled = false
    @MainActor private static var unrecovered = false
    @MainActor private static var lastRecoveredAt = Date.distantPast
    @MainActor private static var foregroundObserver: NSObjectProtocol?

    @MainActor static func noteRefusal(_ error: Error?, _ from: String) {
        guard let error else { return }
        let ns = error as NSError
        // 7 = permission denied, 16 = unauthenticated (the numbers SendQueue and PushManager test too).
        guard ns.domain == FirestoreErrorDomain, ns.code == 7 || ns.code == 16 else { return }
        RefusalTrace.note(error, from)   // TEMPORARY, remove with RefusalTrace
        // Signed out: there is no session to get back into, and sign-out tears the listeners down.
        guard Auth.auth().currentUser != nil else { return }
        if Date().timeIntervalSince(lastRecoveredAt) > 300 { attempt = 0 }
        unrecovered = true
        watchForeground()
        schedule()
    }

    @MainActor private static func schedule() {
        guard !scheduled, attempt < delays.count else { return }
        scheduled = true
        let delay = delays[attempt]
        attempt += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await recover()
        }
    }

    @MainActor private static func recover() async {
        scheduled = false
        guard unrecovered, let user = Auth.auth().currentUser else { return }
        let uid = user.uid
        do {
            let token = try await user.getIDTokenResult(forcingRefresh: true)
            // Another account signed in during the refresh: its own sign-in starts its own listeners.
            guard Auth.auth().currentUser?.uid == uid else { return }
            unrecovered = false
            lastRecoveredAt = Date()
            NotificationCenter.default.post(
                name: TwoStepGate.sessionPassed(token) ? recovered : needsTwoStep, object: nil)
        } catch {
            // ⚠️ FIREBASE'S OWN WORD THAT THE SESSION IS OVER (revoked, disabled, deleted), not
            // merely "no user". A Sign Out tapped while this refresh was in flight also leaves no
            // user, and that sign-out has already run its own teardown, keeping the media it chose
            // to keep; a second, keep-nothing wipe on top would delete it.
            let code = (error as NSError).code
            let over = [AuthErrorCode.userTokenExpired, .userDisabled, .userNotFound, .invalidUserToken]
                .map(\.rawValue).contains(code)
            if over {
                unrecovered = false
                attempt = 0
                NotificationCenter.default.post(name: sessionEnded, object: nil)
            } else {
                schedule()   // offline, or a passing failure: again, later
            }
        }
    }

    @MainActor private static func watchForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard unrecovered else { return }
                    attempt = 0
                    schedule()
                }
            }
    }
}
