import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import CallKit

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
/// Retries back off (1s, 3s, 10s, 30s, 60s) and then keep going every 60s for as long as the app is
/// on screen; in the background they pause, and coming back to the app starts them again from 1s.
/// The back-off only resets after five quiet minutes, so a refusal that survives a fresh token
/// cannot turn into a loop that re-attaches every second; it settles at one try a minute instead.
///
/// ⛔ IT USED TO STOP FOR GOOD AFTER ABOUT THREE MINUTES — owner, 2026-10-08 investigation, bug 1.
/// Six tries and then nothing until the app went to the background and back, so anyone who stayed
/// in the app stayed broken. It never gives up while the app is active now.
///
/// ⛔ A STALL IS THE OTHER HALF — owner, 2026-10-08. The connection can stop answering without any
/// refusal at all: writes wait forever, reads come only from the phone's copy. Firestore's codes 14
/// (unavailable) and 4 (deadline exceeded), and the connection watchdog in `ConnectionStatus`, come
/// in through `noteStall`. What a mature messenger does when its socket goes quiet is drop it and
/// dial again, so this does the same: a fresh token (10s at most), then Firestore's network switched
/// off and on, which drops the stuck stream and reconnects. Pending writes are kept and sent again.
/// Stall recoveries are spaced 15s, 30s, then every 60s while the stall lasts (2026-10-13: the old
/// 300s cap left a stuck phone dead for five minutes between tries).
///
/// ⛔ A REAL OUTAGE MUST NOT TURN INTO A STORM — owner, 2026-10-08, round 2. With no route there is
/// nothing to reset, so a stall is ignored until the path is back. With a route that answers nothing
/// (a hotel login page), only the FIRST reset of an episode posts `recovered`: Firestore's listeners
/// survive the network switch, so later resets have nothing to re-attach. The episode ends when
/// `ConnectionStatus` hears the server again (`noteServerAnswered`). During a live call the network
/// is never switched: only the token is refreshed. Every wait is jittered (x0.8 to x1.25) so many
/// phones coming back from the same outage do not all knock at the same second.
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
    /// 2026-10-08: the refusal came back after `persistentAfter` fresh tokens in a row. Retries go on
    /// at the steady pace regardless. Nothing on screen listens to this yet.
    static let persistentRefusal = Notification.Name("SessionRecovery.persistentRefusal")

    /// Refusal back-off; after the last one, every `steadyDelay` while the app is active.
    private static let delays: [Double] = [1, 3, 10, 30, 60]
    private static let steadyDelay: Double = 60
    /// Refusals that came back after a fresh token, in a row, before `persistentRefusal` is posted.
    private static let persistentAfter = 5
    /// Stall recoveries: the gap before the 2nd, the 3rd, the 4th, and every later one in the episode.
    private static let stallGaps: [Double] = [15, 30, 60, 60]
    private static let tokenTimeout: Double = 10
    /// The most a stall recovery waits for each half of Firestore's network switch.
    private static let switchTimeout: Double = 15

    @MainActor private static var attempt = 0
    @MainActor private static var scheduled = false
    @MainActor private static var unrecovered = false
    @MainActor private static var lastRecoveredAt = Date.distantPast
    @MainActor private static var foregroundObserver: NSObjectProtocol?
    @MainActor private static var refusalReturns = 0
    @MainActor private static var persistentPosted = false
    @MainActor private static var stallRunning = false
    @MainActor private static var stallStep = 0
    @MainActor private static var nextStallAt = Date.distantPast
    /// Last time a slow key fetch was looked at (`noteStall("key")`), at most once a minute.
    @MainActor private static var lastKeyLook = Date.distantPast
    /// This stall episode already posted `recovered`; later resets in it stay quiet.
    @MainActor private static var stallEpisodeRecovered = false
    /// 1:1 audit #10: a stall was seen during a call; the reset waits for the call to end.
    @MainActor private static var stallDuringCall = false

    @MainActor private static var isActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    private static let callObserver = CXCallObserver()

    /// ⛔ IN A CALL MEANS iOS HAS ONE TOO — owner, 2026-10-13, 7th "dead until relaunch" report. Every
    /// 1:1 call, both directions, is a CallKit call, so a non-idle `CallService.state` with no live
    /// call on the phone is a leftover (the 10-11 screenshots had a green call pill for hours with no
    /// call). That leftover used to skip every network reset for up to 4 hours, which left a stuck
    /// connection stuck until the app was killed.
    @MainActor private static var inLiveCall: Bool {
        let s = CallService.shared.state
        guard s != .idle && s != .ended else { return false }
        // DiagLog.snapshot records both sides (callState / systemCalls), so no log line here: this is
        // asked on every watchdog tick.
        return callObserver.calls.contains(where: { !$0.hasEnded })
    }

    /// Every back-off wait times a random 0.8 to 1.25.
    private static func jittered(_ delay: Double) -> Double {
        delay * Double.random(in: 0.8...1.25)
    }

    /// `ConnectionStatus` heard the server (a server snapshot, or a server read that answered): the
    /// stall episode is over, and the next stall starts from a fresh reset that posts `recovered`.
    /// One answer does not end an episode: a slow line answers now and then. The episode ends after
    /// the server has kept answering for 60s (check, 2026-10-08: ending it on the first snapshot
    /// let a slow but working line start a fresh, un-spaced reset + `recovered` every ~45s).
    @MainActor private static var answeringSince: Date?

    @MainActor static func noteServerAnswered() {
        guard stallStep > 0 || stallEpisodeRecovered || stallDuringCall else { answeringSince = nil; return }
        let now = Date()
        guard let since = answeringSince else { answeringSince = now; return }
        guard now.timeIntervalSince(since) >= 60 else { return }
        print("[Recovery] server kept answering for 60s, stall episode over")
        DiagLog.add("server kept answering 60s, episode over")
        stallDuringCall = false   // 1:1 audit #10: no reset owed after the call
        stallStep = 0
        nextStallAt = .distantPast
        stallEpisodeRecovered = false
        answeringSince = nil
    }

    /// Signed out: nothing carries over to the next account.
    @MainActor static func reset() {
        attempt = 0
        unrecovered = false
        lastRecoveredAt = .distantPast
        refusalReturns = 0
        persistentPosted = false
        stallStep = 0
        nextStallAt = .distantPast
        stallEpisodeRecovered = false
        answeringSince = nil
        stallDuringCall = false
    }

    @MainActor static func noteRefusal(_ error: Error?, _ from: String) {
        guard let error else { return }
        let ns = error as NSError
        // Callable functions use the same code numbers (7 permission denied, 16 unauthenticated,
        // 14 unavailable, 4 deadline exceeded), so a refused or unanswered callable counts too.
        guard ns.domain == FirestoreErrorDomain || ns.domain == FunctionsErrorDomain else { return }
        // 14 = unavailable, 4 = deadline exceeded: the server did not refuse, it did not answer.
        // That is a stall, and a fresh token alone would not unstick it.
        if ns.code == 14 || ns.code == 4 {
            print("[Recovery] no answer (\(from)), code \(ns.code)")   // console only, never on screen
            noteStall(from)
            return
        }
        // 7 = permission denied, 16 = unauthenticated (the numbers SendQueue and PushManager test too).
        guard ns.code == 7 || ns.code == 16 else { return }
        // Signed out: there is no session to get back into, and sign-out tears the listeners down.
        guard Auth.auth().currentUser != nil else { return }
        if Date().timeIntervalSince(lastRecoveredAt) > 300 {
            attempt = 0
            refusalReturns = 0
            persistentPosted = false
        } else if !unrecovered {
            // Refused again within five minutes of a fresh token that passed: the token is not the
            // whole story. Keep trying at the steady pace and say so.
            print("[Recovery] refusal survived a fresh token (\(from)), retrying every \(Int(steadyDelay))s")
            refusalReturns += 1
            if refusalReturns >= persistentAfter && !persistentPosted {
                persistentPosted = true
                print("[Recovery] persistent refusal")
                NotificationCenter.default.post(name: persistentRefusal, object: nil)
            }
        }
        // One line per new episode, not one per caller: many listeners fail at the same moment.
        if !unrecovered {
            print("[Recovery] server refused (\(from)), code \(ns.code), attempt \(attempt + 1):", error)
        }
        unrecovered = true
        watchForeground()
        schedule()
    }

    /// The connection looks stuck without a refusal: no server answer for a long time while the
    /// network path is up, or Firestore's 14 / 4. Safe to call from many places at once: one stall
    /// recovery runs at a time, and they are spaced 20s, 60s, 120s, then 300s apart (jittered).
    @MainActor static func noteStall(_ from: String) {
        guard Auth.auth().currentUser != nil, isActive, !stallRunning else { return }
        // No route off the phone: an outage, not a stuck stream. Nothing to reset until it is back.
        guard ConnectionStatus.shared.routeUp else { return }
        // ⛔ A SLOW KEY FETCH IS NOT A STUCK CONNECTION (owner, 2026-10-20, 9th "dead until refresh"
        // report). Crypto's 10s key read is one server read; slow App Check or a slow line pushes it
        // past 10s on a healthy client. His log at 11:05: STALL key, cache read 4ms, pending writes
        // confirmed 5ms, then OUR network switch never answered and the client was stuck for good.
        // So "key" only looks (the snapshot's cache probe still catches a really stuck client) and
        // never switches the network. Real stalls (watchdog, heartbeat, Firestore 14/4) still reset.
        if from == "key" {
            let now = Date()
            guard now.timeIntervalSince(lastKeyLook) >= 60 else { return }
            lastKeyLook = now
            DiagLog.snapshot(from)
            DiagLog.add("  slow key fetch: checked only, connection left alone")
            return
        }
        answeringSince = nil   // a fresh stall restarts the "kept answering for 60s" clock
        // 1:1 audit #10 (owner, 2026-10-08): IN A CALL, decide here, before the back-off moves. The
        // reset was skipped inside `recoverStall`, but the step and the next-allowed time had already
        // advanced, so after hang-up the stall was still there and the next reset was 60-300s away,
        // and every call error walked the step up further. Now: one token refresh per call (as
        // before, the connection is left alone), no step used, and the reset runs once the call ends
        // if the server has not been answering since.
        if inLiveCall {
            guard !stallDuringCall else { return }
            DiagLog.snapshot(from)
            stallDuringCall = true
            stallRunning = true
            print("[Recovery] stall (\(from)) in a call, token only, reset after the call")
            Task { @MainActor in
                await recoverStall(announce: false)
                stallRunning = false
                let until = Date().addingTimeInterval(4 * 3600)
                while Date() < until {
                    if !inLiveCall { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard stallDuringCall else { return }   // the server kept answering meanwhile
                // 1:1 audit check, 2026-10-08: noteStall drops a call made in the background, so
                // the reset stays owed and runs on the next foreground.
                guard isActive else { runOwedResetOnForeground(); return }
                stallDuringCall = false
                noteStall("after call")
            }
            return
        }
        let now = Date()
        guard now >= nextStallAt else { return }
        DiagLog.snapshot(from)
        // Two resets in this episode already answered and the server is still silent: resetting
        // the same client again has never once helped (see `noteWedged`).
        if stallStep >= 2 && stallEpisodeRecovered { noteWedged("two resets did not heal") }
        stallStep += 1
        let gap = stallGaps[min(stallStep - 1, stallGaps.count - 1)]
        nextStallAt = now.addingTimeInterval(jittered(gap))
        stallRunning = true
        let announce = !stallEpisodeRecovered
        print("[Recovery] stall (\(from)), recovery \(stallStep)")
        DiagLog.add("  recovery \(stallStep) starts")
        Task { @MainActor in
            await recoverStall(announce: announce)
            stallRunning = false
        }
    }

    /// ⛔ A FIRESTORE CLIENT THAT HAS STOPPED CANNOT BE STARTED AGAIN IN THIS PROCESS (owner,
    /// 2026-10-14, 8th "dead until relaunch" report; the first one with the phone's own log).
    ///
    /// The log: a cache-only read, which is disk and nothing else, did not answer; then the network
    /// switch did not answer either. Firestore runs everything on one serial worker, and in 11.15 that
    /// worker waits with no limit for gRPC to hand back a stream it is closing (grpc_stream.cc:246,
    /// grpc_unary_call.cc:103; firebase-ios-sdk issue 12522, open, no fix in any release). Once it
    /// waits for good, every send, listener, lookup and call ring queues behind it. `terminate()`
    /// queues behind it too, and the client is a singleton, so a fresh process is the only cure.
    /// That is why his relaunch always fixed it and nothing in-app ever did.
    ///
    /// So when the client is proven stuck, the app ends its own process the moment he leaves it,
    /// never while it is on screen and never during a live call. The next open, or an incoming
    /// call's push, starts a fresh process with a working client. Unsent messages and posts are on
    /// disk (Firestore's cache, the story outboxes) and go out from the fresh start.
    ///
    /// Proven stuck means one of: a cache read with no answer in 3s (DiagLog.snapshot); the network
    /// switch with no answer; or a third stall in one episode after two resets that both answered
    /// but did not bring the server back (the iOS 27 phone's pattern: cache fine, writes never
    /// confirmed, resets "recovered" and changed nothing).
    @MainActor private static var wedged = false
    @MainActor private static var wedgedObserver: NSObjectProtocol?

    @MainActor static func noteWedged(_ why: String) {
        guard !wedged, Auth.auth().currentUser != nil else { return }
        wedged = true
        // 2026-10-20 (owner: "fix it so I never have to refresh"): first, a fresh Firestore client in
        // this same process (FirestoreHub.swap), so he keeps using the app without noticing. Only if
        // that cannot be done (no user, swap limit spent, sign-in on the fresh app silent) does the
        // old net below stay armed: a fresh process the next time he leaves the app.
        DiagLog.add("WEDGED (\(why)): swapping to a fresh client")
        Task { @MainActor in
            guard await FirestoreHub.swap(why) else {
                DiagLog.add("  no swap: fresh start when the app leaves the screen")
                armEndProcess()
                return
            }
            wedged = false
            stallStep = 0
            stallEpisodeRecovered = false
            nextStallAt = .distantPast
            unrecovered = false
            lastRecoveredAt = Date()
            NotificationCenter.default.post(name: recovered, object: nil)
        }
    }

    @MainActor private static func armEndProcess() {
        guard wedged, wedgedObserver == nil else { return }
        wedgedObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { endProcessWhenFree() }
            }
        if UIApplication.shared.applicationState == .background { endProcessWhenFree() }
    }

    /// In the background: end now, or once a live call is over (the call's audio keeps the process
    /// running in the background, so this loop keeps ticking until then).
    @MainActor private static func endProcessWhenFree() {
        guard wedged else { return }
        Task { @MainActor in
            while inLiveCall {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // Back on screen meanwhile: wait for the next time he leaves.
            guard UIApplication.shared.applicationState == .background else { return }
            DiagLog.add("process ends for a fresh start")
            DiagLog.flush()
            UserDefaults.standard.synchronize()   // the text send queue lives there
            exit(0)
        }
    }

    @MainActor private static func schedule() {
        // In the background nothing is retried; `didBecomeActive` starts it again.
        guard !scheduled, isActive else { return }
        scheduled = true
        let delay = jittered(attempt < delays.count ? delays[attempt] : steadyDelay)
        attempt += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard isActive else { scheduled = false; return }   // paused; foreground resumes it
            await recover()
        }
    }

    @MainActor private static func recover() async {
        scheduled = false
        guard unrecovered, let user = Auth.auth().currentUser else { return }
        let uid = user.uid
        switch await freshToken(user) {
        case .token(let token):
            // Another account signed in during the refresh: its own sign-in starts its own listeners.
            guard Auth.auth().currentUser?.uid == uid else { return }
            unrecovered = false
            lastRecoveredAt = Date()
            let passed = TwoStepGate.sessionPassed(token)
            print("[Recovery] fresh token, \(passed ? "recovered" : "needs two-step")")
            NotificationCenter.default.post(name: passed ? recovered : needsTwoStep, object: nil)
        case .failed(let error):
            if endSessionIfOver(error) { return }
            print("[Recovery] token refresh failed, trying again later:", error)
            schedule()   // offline, or a passing failure: again, later
        case .timedOut:
            print("[Recovery] token refresh timed out, trying again later")
            schedule()
        }
    }

    /// A fresh token, then Firestore's network off and on. Ends in `recovered` (first reset of the
    /// episode only, `announce`), or in `needsTwoStep` / `sessionEnded` exactly as a refusal recovery
    /// would.
    @MainActor private static func recoverStall(announce: Bool) async {
        guard isActive, let user = Auth.auth().currentUser else { return }
        let uid = user.uid
        var passedToken = false
        switch await freshToken(user) {
        case .token(let token):
            guard Auth.auth().currentUser?.uid == uid else { return }
            guard TwoStepGate.sessionPassed(token) else {
                print("[Recovery] stall: fresh token needs two-step")
                unrecovered = false
                lastRecoveredAt = Date()
                NotificationCenter.default.post(name: needsTwoStep, object: nil)
                return
            }
            passedToken = true
        case .failed(let error):
            if endSessionIfOver(error) { return }
            // Offline or a passing failure: the token in hand may still be good, so reset anyway.
            print("[Recovery] stall: token refresh failed, resetting the connection anyway:", error)
        case .timedOut:
            print("[Recovery] stall: token refresh timed out, resetting the connection anyway")
        }
        guard isActive, Auth.auth().currentUser?.uid == uid else { return }
        // ⛔ NEVER DURING A LIVE CALL — owner, 2026-10-08: switching Firestore's network off drops the
        // call's signalling listeners mid-call. The fresh token above is all a call gets.
        if inLiveCall {
            print("[Recovery] stall: in a call, token refreshed, connection left alone")
            DiagLog.add("  in a call: token only")
            return
        }
        // ⚠️ BOTH CALLS, ALWAYS: a network left switched off would be far worse than the stall.
        //
        // ⛔ AND NEITHER IS WAITED ON FOR EVER (owner, 2026-10-11: "the whole app stops until I
        // restart it"). These were plain awaits. A Firestore client that has stopped answering can
        // leave this switch unanswered too, and then this function never returned: `stallRunning`
        // stayed true, `noteStall` refused every later stall at its first guard, and the app never
        // tried to recover again in that process. Only a restart started it over, which is exactly
        // what he saw. Each half now gets `switchTimeout`; an unanswered switch is logged, the
        // enable is still sent (it queues behind the disable, so the network is never left off),
        // and the next stall is free to try again at its spaced time.
        let db = FirestoreHub.db
        let gen = FirestoreHub.generation
        let offAnswered = await answered(within: switchTimeout) {
            do { try await db.disableNetwork() } catch { print("[Recovery] disableNetwork failed:", error) }
        }
        let onAnswered = await answered(within: switchTimeout) {
            do { try await db.enableNetwork() } catch { print("[Recovery] enableNetwork failed:", error) }
        }
        guard offAnswered, onAnswered else {
            print("[Recovery] stall: the network switch did not answer in \(Int(switchTimeout))s, trying again later")
            DiagLog.add("  network switch DID NOT ANSWER (off \(offAnswered), on \(onAnswered))")
            // Already swapped to a fresh client while this switch sat on the stuck one.
            guard FirestoreHub.generation == gen else { return }
            noteWedged("network switch")
            return
        }
        guard Auth.auth().currentUser?.uid == uid else { return }
        if passedToken {
            unrecovered = false
            lastRecoveredAt = Date()
        }
        // Firestore's listeners live through the switch, so only the first reset of an episode has
        // anything to re-attach; posting on every reset of a long outage would re-attach for nothing.
        guard announce else {
            print("[Recovery] stall: connection reset again, same episode")
            DiagLog.add("  connection reset again")
            return
        }
        stallEpisodeRecovered = true
        print("[Recovery] stall: connection reset, posting recovered")
        DiagLog.add("  connection reset, recovered posted")
        NotificationCenter.default.post(name: recovered, object: nil)
    }

    /// ⚠️ FIREBASE'S OWN WORD THAT THE SESSION IS OVER (revoked, disabled, deleted), not merely
    /// "no user". A Sign Out tapped while this refresh was in flight also leaves no user, and that
    /// sign-out has already run its own teardown, keeping the media it chose to keep; a second,
    /// keep-nothing wipe on top would delete it.
    /// Was this `sessionEnded` a disabled account (a suspension), rather than a sign-out elsewhere?
    static func endedBySuspension(_ note: Notification) -> Bool {
        (note.userInfo?["code"] as? Int) == AuthErrorCode.userDisabled.rawValue
    }

    @MainActor private static func endSessionIfOver(_ error: Error) -> Bool {
        let code = (error as NSError).code
        let over = [AuthErrorCode.userTokenExpired, .userDisabled, .userNotFound, .invalidUserToken]
            .map(\.rawValue).contains(code)
        guard over else { return false }
        print("[Recovery] session is over:", error)
        unrecovered = false
        attempt = 0
        // The code rides along so the notice can tell a suspension (account disabled from the admin
        // panel) apart from a sign-out on another device.
        NotificationCenter.default.post(name: sessionEnded, object: nil, userInfo: ["code": code])
        return true
    }

    private enum TokenOutcome {
        case token(AuthTokenResult)
        case failed(Error)
        case timedOut
    }

    /// Resumes its continuation once, whichever of the token and the timer answers first. Both
    /// callers run on the main actor, so the two never race.
    private final class Once {
        private var continuation: CheckedContinuation<TokenOutcome, Never>?
        init(_ c: CheckedContinuation<TokenOutcome, Never>) { continuation = c }
        func finish(_ outcome: TokenOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    /// A forced token refresh that gives up after `tokenTimeout`. A task group would not do here: it
    /// waits for every child on the way out, and Firebase's refresh does not stop when cancelled.
    @MainActor private static func freshToken(_ user: User) async -> TokenOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<TokenOutcome, Never>) in
            let once = Once(continuation)
            Task { @MainActor in
                do { once.finish(.token(try await user.getIDTokenResult(forcingRefresh: true))) }
                catch { once.finish(.failed(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(tokenTimeout * 1_000_000_000))
                once.finish(.timedOut)
            }
        }
    }

    /// Runs `work` and answers true if it finished within `seconds`, false if the timer won. The work
    /// is left running either way (Firestore's switch cannot be cancelled); a late finish is ignored.
    /// Same one-shot shape as `freshToken`, and for the same reason a task group will not do.
    @MainActor private static func answered(within seconds: Double,
                                            _ work: @escaping @MainActor () async -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceBool(continuation)
            Task { @MainActor in
                await work()
                once.finish(true)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.finish(false)
            }
        }
    }

    /// `Once`, for a yes/no answer.
    private final class OnceBool {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { continuation = c }
        func finish(_ done: Bool) {
            continuation?.resume(returning: done)
            continuation = nil
        }
    }

    /// 1:1 audit check, 2026-10-08: the after-call reset owed when the call ended in the background.
    @MainActor private static var owedResetObserver: NSObjectProtocol?

    @MainActor private static func runOwedResetOnForeground() {
        guard owedResetObserver == nil else { return }
        owedResetObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let o = owedResetObserver { NotificationCenter.default.removeObserver(o) }
                    owedResetObserver = nil
                    guard stallDuringCall else { return }   // answered meanwhile, or signed out
                    stallDuringCall = false
                    // A new call already up: its own stalls take the in-call path from here.
                    let s = CallService.shared.state
                    guard s == .idle || s == .ended else { return }
                    noteStall("after call")
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
