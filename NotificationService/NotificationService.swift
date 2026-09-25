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
/// (`deliveryToken` in functions), so the extension needs no sign-in, no keychain and no App Group.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    private static let endpoint = URL(string: "https://me-central1-kulan-2ef85.cloudfunctions.net/ackDelivered")!

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        handler = contentHandler
        content = request.content
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

    /// Hands the notification to iOS exactly once.
    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }
}
