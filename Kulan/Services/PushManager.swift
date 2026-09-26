import UIKit
import SwiftUI
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth
import FirebaseMessaging
import FirebaseStorage
import UserNotifications
import PushKit

// App delegate: configures Firebase, owns the APNs/FCM token handshake, and saves
// the device's FCM token to users/{uid}/push/tokens so the Cloud Function can push
// to it. (Firebase config lives here so it runs before any messaging setup.)
//
// STAGE 3 OF THE PUSH-TOKEN MOVE. Tokens used to live on the user doc itself
// (users/{uid}.fcmTokens / .voipTokens) — a document ANY signed-in account can
// read if it knows the uid. Read a token there, write it onto your own profile,
// and the server's reconcile hands you the victim's messages and calls. So this
// build writes tokens ONLY to users/{uid}/push/tokens (owner-only readable, see
// firestore.rules) and strips its own token from the old fields. The server reads
// BOTH places until every phone has this build (stage 4 removes the old fields).
final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {

    private var voipRegistry: PKPushRegistry?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Large PERSISTENT URLCache — this is the story viewer's cache tier (StoryUI's image loader +
        // its AVPlayer both read URLCache.shared first). It was left at the tiny iOS default, so warmed
        // story images/videos were evicted between launches and re-downloaded. A 100 MB memory / 1 GB
        // disk store keeps story media on disk across relaunches. Set FIRST, before any URLSession runs.
        let storyCache = URLCache(memoryCapacity: 100 * 1024 * 1024,
                                  diskCapacity: 1024 * 1024 * 1024,
                                  directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                      .appendingPathComponent("URLCache", isDirectory: true))
        URLCache.shared = storyCache

        // 2026-09-24 fix-all #161: App Check provider, installed before configure (see AppCheckSetup).
        AppCheckSetup.install()
        FirebaseApp.configure()

        // ⚠️ A DEAD UPLOAD MUST FAIL, NOT HANG. Firebase Storage's default `maxUploadRetryTime` is
        // 600 SECONDS: on a bad connection `putDataAsync` retries quietly for ten minutes before it
        // ever throws. Nothing is wrong with that as a network policy and everything is wrong with
        // it as a user-facing one — the story card sits on "Uploading…" the whole time, because the
        // code that clears it is in the catch that never runs. That is his "it never finishes".
        //
        // 120s is well past any upload that is genuinely going to succeed and well short of a wait
        // anybody will sit through. When it does expire, `postStory`'s catch already deletes both
        // halves and `uploadError` already carries the reason to the UI.
        //
        // Set once here rather than per call site, because chat photos, voice notes and profile
        // pictures all had the same ten-minute silence waiting for them.
        Storage.storage().maxUploadRetryTime = 120
        Storage.storage().maxOperationRetryTime = 60   // downloadURL, delete, metadata

        // Transfers the SYSTEM was still carrying for a process that no longer exists. Nobody is
        // waiting on them and nothing will attach their result to a message, so they are cancelled
        // rather than left to finish into storage we pay for. See `BackgroundUploader.adopt`.
        if UploadEngine.backgroundEnabled {
            BackgroundUploader.shared.adopt()
            // ⚠️ AND `adopt` CANCELLING THOSE TASKS LOSES NOTHING, which is only true because of the
            // line below. The SERVER still holds every byte it received; the resume asks it how many
            // and sends the rest. Cancelling the orphaned task just stops us paying to finish a
            // transfer whose result nobody in this process is waiting for.
            Task { await ChatService.resumePendingUploads() }
        }

        // REAL on-disk offline persistence (the win the JS SDK couldn't do in Hermes).
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings

        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self

        // Init CallKit early (sets WebRTC manual-audio) + register for VoIP push so
        // calls ring natively even when the app is killed.
        _ = CallKitManager.shared
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
        return true
    }

    // MARK: - VoIP (PushKit)

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Push.latestVoipToken = token
        Push.saveVoipToken()   // saves if signed in; re-saved on login otherwise
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let d = payload.dictionaryPayload
        let callId = d["callId"] as? String ?? ""
        // 2026-09-24 audit: no call id means no call document to ring for (an empty id is not a
        // valid Firestore path). Still reported to CallKit, as iOS requires, then ended at once.
        guard !callId.isEmpty else { CallKitManager.shared.reportAndDiscard(completion: completion); return }
        let name = d["callerName"] as? String ?? "Call"
        let uid = d["callerUid"] as? String ?? ""
        let photo = d["photo"] as? String
        let video = (d["type"] as? String) == "video"   // M1: show the right CallKit UI for a video call
        // iOS 13+: MUST report to CallKit before completion or the app is terminated.
        CallService.shared.prepareIncoming(callId: callId, name: name, uid: uid, photo: photo, video: video)
        CallKitManager.shared.reportIncoming(callId: callId, name: name, video: video,
                                            callerUid: uid) { completion() }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push: APNs registration failed:", error)
    }

    /// iOS finished carrying an upload while the app was not running and has woken it only to say
    /// so. The handler MUST be called once the session has delivered its events, or the watchdog
    /// kills the app — `BackgroundUploader` calls it from `urlSessionDidFinishEvents`.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.sessionIdentifier else { completionHandler(); return }
        BackgroundUploader.shared.systemCompletionHandler = completionHandler
        BackgroundUploader.shared.adopt()   // recreating the session is what delivers those events
    }

    // FCM rotation token → save it so the Cloud Function can target this device.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, let uid = Auth.auth().currentUser?.uid else { return }
        // HONOR THE TOGGLE (audit): turning Show Notifications off unregisters the tokens, but this
        // delegate fires on every launch and token rotation and put them straight back, so pushes
        // resumed at the next cold start while the switch still read OFF.
        guard UserDefaults.standard.object(forKey: "notif.push") as? Bool ?? true else { return }
        Push.saveToken(field: "fcmTokens", token: token, uid: uid)
        // Also on this device's own row, so signing it out from another phone can strip
        // exactly this token and leave the other devices' tokens alone.
        Task { @MainActor in DeviceRegistry.shared.recordFCMToken(token) }
    }

    // Foreground banner — but NOT for the chat you're already looking at.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let cid = content.userInfo["cid"] as? String
        if let cid, cid == AppRouter.shared.activeChatId { return [] }
        // A CHAT notification gets OUR banner, not the system one. The iOS drop-down reads as
        // "something outside the app happened" while you are looking at the app; every messenger
        // draws its own instead. Anything that is not a chat keeps the system banner — there is
        // nothing for ours to route to.
        guard let cid else { return [.banner, .sound, .badge] }
        // THE THREE IN-APP TOGGLES ARE READ HERE (audit). They were only ever read by
        // InAppNotify.process, whose feed was removed, so Settings > Notifications > In-App Sounds /
        // Vibrate / Preview did nothing at all: the banner appeared and the tone played regardless,
        // and vibrate could never fire. This is the surviving foreground path, so it owns them.
        let d = UserDefaults.standard
        let wantPreview = d.object(forKey: "notif.inAppPreview") as? Bool ?? true
        let wantSound = d.object(forKey: "notif.inAppSound") as? Bool ?? true
        let wantVibrate = d.object(forKey: "notif.inAppVibrate") as? Bool ?? true
        if wantPreview {
            let body = await InAppBannerCenter.previewBody(cid: cid) ?? content.body
            await MainActor.run {
                InAppBannerCenter.shared.show(cid: cid, title: content.title, body: body)
            }
        }
        if wantVibrate {
            await MainActor.run { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
        // Play the chat's CHOSEN message sound (real, foreground) and suppress the system push
        // sound. Background pushes still use the server payload's sound (per-chat sound there is
        // a follow-up). "None" → silent banner.
        let sound = SoundStore.sound(cid, .message)
        guard wantSound, sound.id != "none" else { return [.badge] }
        await MainActor.run { SoundPlayer.shared.play(sound) }
        return [.badge]
    }

    // Tapping a push opens the right chat (works from background AND cold launch —
    // MainShell consumes the pending route once the conversation list is loaded).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // A cid becomes a Firestore document id in ThreadView, where an empty or slashed one raises
        // an uncatchable exception (audit, 2026-09-24). Our own pushes never carry one; refuse it anyway.
        if let cid = response.notification.request.content.userInfo["cid"] as? String,
           !cid.isEmpty, !cid.contains("/"),
           await Self.mayOpenFromPush(cid) {
            await MainActor.run { AppRouter.shared.pendingChatId = cid }
        }
    }

    /// 2026-09-24 audit: a notification can outlive its account. Sign out of A, sign in as B, tap A's
    /// banner, and B was pushed onto a chat it is not in (a blank screen the rules refuse to fill).
    /// A chat already in this account's list is fine; otherwise ask the server, and drop the tap
    /// only when it says no (refused, missing, or not a member). Offline or any other error still
    /// opens, because a real chat the list has not loaded yet must not become a dead tap.
    private static func mayOpenFromPush(_ cid: String) async -> Bool {
        guard let me = Auth.auth().currentUser?.uid else { return false }
        let known = await MainActor.run { ConversationsRepository.shared.conversations.contains { $0.id == cid } }
        if known { return true }
        do {
            let snap = try await Firestore.firestore().collection("conversations").document(cid).getDocument()
            guard snap.exists, let users = snap.data()?["users"] as? [String] else { return false }
            return users.contains(me)
        } catch {
            // 7 = permissionDenied, by wire number (see StoriesService on why not the SDK enum).
            let ns = error as NSError
            return !(ns.domain == FirestoreErrorDomain && ns.code == 7)
        }
    }
}

// App-wide navigation intents (deep links) + which chat is on screen.
@Observable final class AppRouter {
    static let shared = AppRouter()
    private init() {}
    var pendingChatId: String?    // a chat to open from a notification tap
    var pendingChatName: String?  // fallback header name when the conv isn't in the cache yet
    var pendingChatPhoto: String? // fallback header photo
    var pendingInviteCode: String? // a kulan://g/<code> invite link to resolve into a Join sheet
    /// 2026-09-24 decision D4: a kulan://u/<handle> link, kept like the invite code above until the
    /// app is signed in and on its main screen (RootView opens it then). A link tapped while signed
    /// out used to be dropped, because the lookup needs a session.
    var pendingUserHandle: String?
    var activeChatId: String?     // the chat currently on screen (suppresses its own banners)
    /// A specific message to land on once that chat is open, rather than opening wherever the chat
    /// normally opens. Set beside `pendingChatId`, consumed once by ThreadView.
    ///
    /// Added for the floating voice-note bar: it could say WHICH CHAT the note was in and nothing more,
    /// so tapping it dropped you at the bottom to hunt for the one bubble that was moving. Everything
    /// else was already there — the player knows the message id, and the thread already knows how to
    /// page back to a message and flash it, because that is what a tap on a reply quote does. This is
    /// the wire between them. Nothing else sets it, so every other caller behaves exactly as before.
    var pendingMessageId: String?
}

// Clear a chat's delivered notifications + fix the app badge when you read it.
enum NotificationCleaner {
    static func clear(cid: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes
                .filter { ($0.request.content.userInfo["cid"] as? String) == cid }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        // Badge = total unread across the OTHER chats (this one is now read), counted with the SAME
        // filter the in-app badges use (audit): a silently blocked contact's messages still increment
        // unread, but every surface in the app shows 0 for that chat, so the springboard badge landed
        // on a number the user could neither see nor clear — and it leaked that their messages arrive.
        // Hidden legacy groups are excluded for the same reason.
        let total = badgeTotal(excluding: cid)
        lastSetBadge = total
        center.setBadgeCount(total)
    }

    /// The springboard badge as the chat list sees it. One filter for both callers, so the number a
    /// read sets and the number a snapshot sets cannot disagree.
    private static func badgeTotal(excluding cid: String?) -> Int {
        let me = Auth.auth().currentUser?.uid ?? ""
        guard !me.isEmpty else { return 0 }
        let total = ConversationsRepository.shared.conversations
            .filter { $0.id != cid && !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                      && (Flags.groupsEnabled || !$0.isGroup) }
            .reduce(0) { $0 + $1.unread(me) }
        return max(0, total)
    }

    /// 2026-09-24 fix-all #166: reading a chat on another device lowers `unreadCount` there, and that
    /// lands here through the chat-list listener, but only a read ON THIS device used to reset the
    /// badge, so it overstated until the next push. The list now calls this on every published
    /// snapshot. Skipped while nothing changed, so a typing flag does not touch the badge at all.
    nonisolated(unsafe) private static var lastSetBadge: Int?
    @MainActor static func syncBadgeFromList() {
        guard ConversationsRepository.shared.hasLoaded else { return }
        let total = badgeTotal(excluding: nil)
        guard total != lastSetBadge else { return }
        lastSetBadge = total
        UNUserNotificationCenter.current().setBadgeCount(total)
    }
}

enum Push {
    static var latestVoipToken: String?

    /// The one place tokens are WRITTEN now: users/{uid}/push/tokens, which only its
    /// owner can read — a stolen uid no longer surrenders the account's push tokens.
    /// The second write scrubs this device's token off the old world-readable fields
    /// (harmless no-op once stage 4 deletes them). Two separate writes on purpose:
    /// registering in the new home must never be hostage to the old home's cleanup.
    static func saveToken(field: String, token: String, uid: String) {
        let user = Firestore.firestore().collection("users").document(uid)
        user.collection("push").document("tokens")
            .setData([field: FieldValue.arrayUnion([token])], merge: true)
        // Only OUR token comes off — this account's other, not-yet-updated devices keep
        // their old-field tokens (the server still reads those) until they update too.
        user.updateData([field: FieldValue.arrayRemove([token])])
    }

    /// Persist the VoIP token once we're signed in (PushKit can fire before login).
    static func saveVoipToken() {
        guard let token = latestVoipToken, let uid = Auth.auth().currentUser?.uid else { return }
        saveToken(field: "voipTokens", token: token, uid: uid)
        // And on this device's row, so a remote sign-out can pull this device's ring token.
        Task { @MainActor in DeviceRegistry.shared.recordVoipToken(token) }
    }

    /// Ask for permission, then register with APNs (FCM token follows via the delegate).
    /// Safe to call on every launch once signed in — iOS only prompts once.
    /// Respects the user's own Show Notifications switch: boot calls this unconditionally, so
    /// without the check a launch re-registered a device the user had deliberately turned off.
    ///
    /// NEVER A COLD POPUP (first-run rebuild, 2026-09-24). On a phone that has not been asked yet,
    /// this does NOT ask: the first-run explainer screen (`NotificationsExplainerView`) does, after
    /// saying why. `askIfUndecided` is for the two places a person has just asked for notifications
    /// themselves: that screen's Continue, and the Show Notifications switch in Settings. A phone
    /// that already answered is unaffected either way: iOS answers without showing anything.
    static func register(askIfUndecided: Bool = false) {
        guard UserDefaults.standard.object(forKey: "notif.push") as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined && !askIfUndecided { return }
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
        // SAVE THE TOKEN WE ALREADY HOLD, for whoever is signed in NOW (audit, 2026-09-24). The FCM
        // delegate only fires when the token is minted or rotates, and it drops it when nobody is
        // signed in. Sign out (which strips the token) and sign in again, or into another account,
        // in the same run, and the token is unchanged, so the delegate never fires and the new
        // account got no pushes until the next cold launch. Same write as the delegate's.
        if let token = Messaging.messaging().fcmToken, let uid = Auth.auth().currentUser?.uid {
            saveToken(field: "fcmTokens", token: token, uid: uid)
            Task { @MainActor in DeviceRegistry.shared.recordFCMToken(token) }
        }
        // The official channel's topics read the same switch, and nothing else would put this phone
        // back in them: they are a Firebase-side subscription, not a token, so turning Show
        // Notifications off and on again leaves the announcement side silent forever unless it is
        // re-derived here.
        //
        // Boot calls this before anybody is signed in, hence the explicit check: a phone sitting on
        // the sign-in screen must not be in a topic. Once signed in, the channel's own state
        // listener takes over and syncs on every launch anyway.
        OfficialPushTopics.sync(muted: OfficialChannelStore.shared.state.muted,
                                signedIn: Auth.auth().currentUser != nil)
    }

    /// Set once the first-run notifications screen has been answered, Continue or Not now, so it
    /// is shown once per install. Deleting the app clears it along with every other default.
    private static let explainerSeenKey = "firstRun.notificationsExplainerSeen"

    /// Should the first-run notifications screen show? Only on a phone iOS has never asked, with
    /// the Show Notifications switch on, and only until the screen has been answered once. A person
    /// who already allowed or refused goes straight past it. A local check, no network.
    static func needsExplainer() async -> Bool {
        guard !DemoMode.active else { return false }
        guard UserDefaults.standard.object(forKey: "notif.push") as? Bool ?? true else { return false }
        guard !UserDefaults.standard.bool(forKey: explainerSeenKey) else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .notDetermined
    }

    /// The explainer's answer. Continue shows the system popup and waits for it, so the screen
    /// stays put underneath until the person has chosen; Not now asks nothing.
    static func finishExplainer(allow: Bool) async {
        UserDefaults.standard.set(true, forKey: explainerSeenKey)
        guard allow else { return }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        guard granted else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Stop push to this device: drop its FCM token so the Cloud Function skips it,
    /// AND its VoIP token — otherwise a logged-out phone keeps getting CallKit ring
    /// pushes for an account that isn't signed in here anymore (ghost rings).
    // Async so sign-out can AWAIT the removals — fire-and-forget writes raced signOut
    // and lost auth mid-flight, leaving stale tokens (ghost pushes after logout).
    static func unregister() async {
        // BEFORE the uid guard. Dropping the tokens is an account-scoped job and rightly gives up
        // without one, but a topic subscription belongs to the handset: it would survive the
        // sign-out and keep announcing to whoever picks the phone up next.
        OfficialPushTopics.leaveAll()
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let doc = db.collection("users").document(uid)
        var updates: [String: Any] = [:]
        if let token = Messaging.messaging().fcmToken { updates["fcmTokens"] = FieldValue.arrayRemove([token]) }
        if let voip = latestVoipToken { updates["voipTokens"] = FieldValue.arrayRemove([voip]) }
        guard !updates.isEmpty else { return }
        // ONE atomic batch, RETRIED. The old code swallowed failures (try?), so a transient blip at sign-out
        // left this phone's tokens under the signed-out account → calls to it kept ringing this phone after
        // switching accounts (ghost calls). Retry so the removal actually lands. (CallService.watchRingingCancel
        // is the belt: it ends any call whose callee isn't the account signed in here.)
        // BOTH homes in the batch: old fields (pre-move builds wrote there) and push/tokens
        // (this build writes there). setData(merge:) on the push doc, not updateData — on an
        // account that never saw this build the doc doesn't exist, and a NOT_FOUND would sink
        // the whole batch, old-field removals included.
        for attempt in 0..<3 {
            let batch = db.batch()
            batch.updateData(updates, forDocument: doc)
            batch.setData(updates, forDocument: doc.collection("push").document("tokens"), merge: true)
            do { try await batch.commit(); return }
            catch {
                if attempt == 2 { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}
