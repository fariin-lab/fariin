import Foundation
import UserNotifications

/// Runs on this phone for every 1:1 message notification (the push carries `mutable-content`), even
/// when Fariin is closed. Its one job: tell the server "this phone has it", which turns the sender's
/// single tick into two (owner, 2026-09-25, delivered ticks).
///
/// ⚠️ THE NOTIFICATION IS NEVER HELD HOSTAGE. It is shown exactly as it arrived, and it is shown when
/// the acknowledgement finishes, fails, or runs out of time, whichever comes first. A delivery tick
/// is worth nothing next to a message that did not appear.
///
/// No Firebase here on purpose: the push carries a token the server signed for this uid and chat
/// (`deliveryToken` in functions), so the extension needs no sign-in and no keychain. The App Group
/// is only read for the screen-share privacy check below.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    private static let endpoint = URL(string: "https://me-central1-kulan-2ef85.cloudfunctions.net/ackDelivered")!

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        handler = contentHandler
        content = Self.hidingTextDuringShare(request.content)
        lock.unlock()

        let info = request.content.userInfo
        guard let cid = info["cid"] as? String,
              let uid = info["ackUid"] as? String,
              let ack = info["ack"] as? String,
              let body = try? JSONSerialization.data(withJSONObject: ["cid": cid, "uid": uid, "ack": ack])
        else { finish(); return }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in self?.finish() }.resume()
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    // MARK: Screen share privacy (1:1 audit #16, owner, 2026-10-08)
    //
    // While this phone shares its screen, a system banner with the message text would be in the
    // shared video. The broadcast extension stamps a keepalive in the App Group's `ss_video.bin`
    // every 0.5 s while it runs and zeroes it when it ends (Shared/ScreenShareIPC.swift, `Video`).
    // Fresh stamp = a share is live: show the banner without its text. The values below mirror
    // ScreenShareIPC (this target does not compile that file); keep them in step.
    // Needs the App Group on this extension (NotificationService.entitlements + the App ID). Without
    // it the container is nil and the banner is shown as it arrived, as before.
    private static let appGroup = "group.com.kulan.messenger.native"
    private static let videoFileName = "ss_video.bin"
    private static let keepaliveOffset: off_t = 48             // ScreenShareIPC.Video.oKeepaliveNs
    private static let keepaliveTimeoutNs: UInt64 = 2_000_000_000 // ScreenShareIPC.keepaliveTimeoutNs

    private static func screenShareLive() -> Bool {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return false
        }
        let fd = open(dir.appendingPathComponent(videoFileName).path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var stamp: UInt64 = 0
        guard pread(fd, &stamp, MemoryLayout<UInt64>.size, keepaliveOffset) == MemoryLayout<UInt64>.size,
              stamp != 0 else { return false }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)   // the same clock the extension stamps with
        return now >= stamp ? now - stamp <= keepaliveTimeoutNs : true
    }

    private static func hidingTextDuringShare(_ content: UNNotificationContent) -> UNNotificationContent {
        guard screenShareLive(),
              let copy = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        copy.subtitle = ""
        copy.body = "New message"
        return copy
    }

    /// Hands the notification to iOS exactly once.
    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }
}
