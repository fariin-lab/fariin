import UIKit
import SwiftUI
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth
import FirebaseMessaging
import UserNotifications
import PushKit

// App delegate: configures Firebase, owns the APNs/FCM token handshake, and saves
// the device's FCM token to users/{uid}.fcmTokens so the Cloud Function can push
// to it. (Firebase config lives here so it runs before any messaging setup.)
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

        FirebaseApp.configure()

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
        let name = d["callerName"] as? String ?? "Call"
        let uid = d["callerUid"] as? String ?? ""
        let photo = d["photo"] as? String
        let video = (d["type"] as? String) == "video"   // M1: show the right CallKit UI for a video call
        // iOS 13+: MUST report to CallKit before completion or the app is terminated.
        CallService.shared.prepareIncoming(callId: callId, name: name, uid: uid, photo: photo, video: video)
        CallKitManager.shared.reportIncoming(callId: callId, name: name, video: video) { completion() }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push: APNs registration failed:", error)
    }

    // FCM rotation token → save it so the Cloud Function can target this device.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid)
            .setData(["fcmTokens": FieldValue.arrayUnion([token])], merge: true)
    }

    // Foreground banner — but NOT for the chat you're already looking at.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let cid = notification.request.content.userInfo["cid"] as? String
        if let cid, cid == AppRouter.shared.activeChatId { return [] }
        // Play the chat's CHOSEN message sound (real, foreground) and suppress the system push
        // sound. Background pushes still use the server payload's sound (per-chat sound there is
        // a follow-up). "None" → silent banner.
        if let cid {
            let sound = SoundStore.sound(cid, .message)
            guard sound.id != "none" else { return [.banner, .badge] }
            await MainActor.run { SoundPlayer.shared.play(sound) }
            return [.banner, .badge]
        }
        return [.banner, .sound, .badge]
    }

    // Tapping a push opens the right chat (works from background AND cold launch —
    // MainShell consumes the pending route once the conversation list is loaded).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let cid = response.notification.request.content.userInfo["cid"] as? String {
            await MainActor.run { AppRouter.shared.pendingChatId = cid }
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
    var activeChatId: String?     // the chat currently on screen (suppresses its own banners)
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
        // Badge = total unread across the OTHER chats (this one is now read).
        let me = Auth.auth().currentUser?.uid ?? ""
        let total = ConversationsRepository.shared.conversations
            .filter { $0.id != cid }
            .reduce(0) { $0 + $1.unread(me) }
        center.setBadgeCount(max(0, total))
    }
}

enum Push {
    static var latestVoipToken: String?

    /// Persist the VoIP token once we're signed in (PushKit can fire before login).
    static func saveVoipToken() {
        guard let token = latestVoipToken, let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid)
            .setData(["voipTokens": FieldValue.arrayUnion([token])], merge: true)
    }

    /// Ask for permission, then register with APNs (FCM token follows via the delegate).
    /// Safe to call on every launch once signed in — iOS only prompts once.
    static func register() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Stop push to this device: drop its FCM token so the Cloud Function skips it,
    /// AND its VoIP token — otherwise a logged-out phone keeps getting CallKit ring
    /// pushes for an account that isn't signed in here anymore (ghost rings).
    // Async so sign-out can AWAIT the removals — fire-and-forget writes raced signOut
    // and lost auth mid-flight, leaving stale tokens (ghost pushes after logout).
    static func unregister() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let doc = Firestore.firestore().collection("users").document(uid)
        var updates: [String: Any] = [:]
        if let token = Messaging.messaging().fcmToken { updates["fcmTokens"] = FieldValue.arrayRemove([token]) }
        if let voip = latestVoipToken { updates["voipTokens"] = FieldValue.arrayRemove([voip]) }
        guard !updates.isEmpty else { return }
        // ONE atomic write, RETRIED. The old code swallowed failures (try?), so a transient blip at sign-out
        // left this phone's tokens under the signed-out account → calls to it kept ringing this phone after
        // switching accounts (ghost calls). Retry so the removal actually lands. (CallService.watchRingingCancel
        // is the belt: it ends any call whose callee isn't the account signed in here.)
        for attempt in 0..<3 {
            do { try await doc.updateData(updates); return }
            catch {
                if attempt == 2 { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}
