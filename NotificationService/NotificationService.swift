import CryptoKit
import Foundation
import Intents
import Sodium
import UIKit
import UserNotifications

/// Runs on this phone for every message notification (the push carries `mutable-content`), even
/// when Fariin is closed. Two jobs:
/// 1. Tell the server "this phone has it", which turns the sender's single tick into two (owner,
///    2026-09-25, delivered ticks). 1:1 pushes only: they carry the signed token.
/// 2. ⛔ READABLE BANNERS — owner 2026-10-18: "look like the big messengers". The push carries the
///    message's CIPHERTEXT (`ct`, never plaintext; functions `pushPayload.js`). This extension opens
///    it with this account's key copy from the App Group (Shared/NotifShared.swift) and the sender's
///    cached public key, puts the real text in the body, and turns the banner into an Apple
///    Communication Notification (INSendMessageIntent): the sender's photo on the left with the
///    small app badge, the group's name and photo for a group. The reference apps do the same.
///
/// ⚠️ THE NOTIFICATION IS NEVER HELD HOSTAGE. Any miss (no key copy yet, sender key not cached,
/// phone not unlocked since boot, avatar download slow, intent refused) shows the banner as it
/// arrived from the server ("New message", "📷 Photo"). It is handed to iOS once both jobs end, or
/// when iOS says time is up, whichever comes first.
///
/// No Firebase here on purpose: the ack token is signed by the server (`deliveryToken`), and
/// everything else is read from the App Group the app keeps current (Kulan/Services/NotifShare.swift).
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?
    /// Jobs still running (ack, enrich). The banner goes when this reaches zero.
    private var pending = 0

    private static let endpoint = URL(string: "https://me-central1-kulan-2ef85.cloudfunctions.net/ackDelivered")!
    private static let work = DispatchQueue(label: "fariin.nse.enrich", qos: .userInitiated)

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let sharing = Self.screenShareLive()
        lock.lock()
        handler = contentHandler
        content = sharing ? Self.hidingText(request.content) : request.content
        pending = 2
        lock.unlock()

        sendAck(request.content.userInfo)

        // While the screen is shared nothing personal is added: the banner stays hidden as above.
        if sharing { jobDone(); return }
        let original = request.content
        Self.work.async { [weak self] in
            Self.enrich(original) { updated in
                guard let self else { return }
                if let updated {
                    self.lock.lock()
                    if self.handler != nil { self.content = updated }
                    self.lock.unlock()
                }
                self.jobDone()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func sendAck(_ info: [AnyHashable: Any]) {
        guard let cid = info["cid"] as? String,
              let uid = info["ackUid"] as? String,
              let ack = info["ack"] as? String,
              let body = try? JSONSerialization.data(withJSONObject: ["cid": cid, "uid": uid, "ack": ack])
        else { jobDone(); return }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in self?.jobDone() }.resume()
    }

    private func jobDone() {
        lock.lock()
        pending -= 1
        let last = pending <= 0
        lock.unlock()
        if last { finish() }
    }

    /// Hands the notification to iOS exactly once.
    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }

    // MARK: Readable banners (owner 2026-10-18)

    /// Data keys the server sends (functions/pushPayload.js): `cid`, `aid` (sender uid), `sn` (sender
    /// name, only when the recipient's Message Preview is on), `g` ("1" for a group), `kind` (the
    /// message type) and `ct` (the ciphertext, when it fits in the push), or `tx` (the text itself, for
    /// a group that is no longer end-to-end encrypted, 2026-10-19). No `sn` = preview is off,
    /// and the banner is left exactly as the server sent it: no name, no text, no photo.
    private static func enrich(_ original: UNNotificationContent,
                               completion: @escaping (UNNotificationContent?) -> Void) {
        let info = original.userInfo
        guard let cid = info["cid"] as? String, !cid.isEmpty,
              let aid = info["aid"] as? String, !aid.isEmpty,
              let senderName = info["sn"] as? String, !senderName.isEmpty,
              let copy = original.mutableCopy() as? UNMutableNotificationContent
        else { completion(nil); return }

        let isGroup = (info["g"] as? String) == "1"
        let kind = (info["kind"] as? String) ?? "text"
        let defaults = NotifShared.defaults
        let me = defaults?.string(forKey: NotifShared.uidKey) ?? ""
        let chats = defaults?.dictionary(forKey: NotifShared.chatsKey) as? [String: [String: Any]] ?? [:]
        let chat: [String: Any] = chats[cid] ?? [:]
        // The sender's 1:1 chat with me, if there is one: a saved contact name and their photo.
        let direct: [String: Any] = me.isEmpty ? [:] : (chats["\(me)_\(aid)"] ?? chats["\(aid)_\(me)"] ?? [:])

        // A 1:1 push names its recipient (`ackUid`); one for another account is not opened.
        let forMe = !me.isEmpty && ((info["ackUid"] as? String).map { $0 == me } ?? true)

        // 1. The text.
        var text: String?
        if forMe, let ct = info["ct"] as? String, !ct.isEmpty {
            text = Opener.open(ct, me: me, sender: aid)
        }
        // 2026-10-19 groups v2: a group that is no longer end-to-end encrypted sends its words as
        // they are (`tx`, only with Message Preview on), so there is nothing to open.
        if text == nil, isGroup, let tx = info["tx"] as? String, !tx.isEmpty { text = tx }
        // 1:1: the name this phone shows (a saved contact name wins). Group: the server's sender name,
        // unless I have them saved under another.
        let shownSender = (direct[NotifShared.Chat.name] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? senderName
        if let text, !text.isEmpty {
            let line = prefix(for: kind) + text
            copy.body = isGroup ? "\(shownSender): \(line)" : line
        }
        let groupName = (chat[NotifShared.Chat.name] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? original.title
        copy.title = isGroup ? groupName : shownSender

        // 2. The photos, downloaded with a short limit or taken from the App Group cache.
        let senderPhoto = isGroup
            ? ((chat[NotifShared.Chat.members] as? [String: String])?[aid] ?? direct[NotifShared.Chat.photo] as? String)
            : chat[NotifShared.Chat.photo] as? String
        let groupPhoto = isGroup ? chat[NotifShared.Chat.photo] as? String : nil
        let photos = Avatars.load([senderPhoto, groupPhoto], timeout: 4)

        // 3. The Communication Notification. If iOS refuses, the readable text above still shows.
        let sender = INPerson(personHandle: INPersonHandle(value: aid, type: .unknown),
                              nameComponents: nil, displayName: shownSender,
                              // No photo: a grey person circle, so the banner still has a face with
                              // the small app badge (owner 2026-10-31, as the reference app does).
                              image: INImage(imageData: photos[0] ?? Avatars.placeholder(group: false)),
                              contactIdentifier: nil, customIdentifier: aid)
        let mePerson = INPerson(personHandle: INPersonHandle(value: me.isEmpty ? "me" : me, type: .unknown),
                                nameComponents: nil, displayName: nil, image: nil,
                                contactIdentifier: nil, customIdentifier: me.isEmpty ? nil : me,
                                isMe: true, suggestionType: .none)
        // A group needs more than one recipient for iOS to draw it as a group conversation.
        let recipients: [INPerson] = isGroup
            ? [mePerson, INPerson(personHandle: INPersonHandle(value: cid, type: .unknown),
                                  nameComponents: nil, displayName: groupName, image: nil,
                                  contactIdentifier: nil, customIdentifier: cid)]
            : [mePerson]
        let intent = INSendMessageIntent(recipients: recipients,
                                         outgoingMessageType: .outgoingMessageText,
                                         content: copy.body,
                                         speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: groupName) : nil,
                                         conversationIdentifier: cid,
                                         serviceName: nil,
                                         sender: sender,
                                         attachments: nil)
        if isGroup {
            intent.setImage(INImage(imageData: photos[1] ?? Avatars.placeholder(group: true)),
                            forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { _ in
            let updated = try? copy.updating(from: intent)
            completion(updated ?? copy)
        }
    }

    /// Captions travel in the message's text; the kind keeps its sign in front of them.
    private static func prefix(for kind: String) -> String {
        switch kind {
        case "image", "album": return "📷 "
        case "video": return "📹 "
        case "file": return "📎 "
        default: return ""
        }
    }

    /// Opens "enc1:" (1:1) and "encg1:" (group) the way Kulan/Services/Crypto.swift does, with the
    /// shared key copy and the sender's cached public keys (current first, then the earlier ring).
    /// nil on any miss, never a lock glyph or a placeholder: the caller then keeps the server's hint.
    private enum Opener {
        static func open(_ raw: String, me: String, sender: String) -> String? {
            let sodium = Sodium()
            guard let skB64 = NotifShared.readSecretKey(uid: me),
                  let skData = Data(base64Encoded: skB64),
                  skData.count == sodium.box.SecretKeyBytes else { return nil }
            let sk = Bytes(skData)
            let keys = senderKeys(sender)
            guard !keys.isEmpty else { return nil }

            func openBox(_ box: Bytes, _ nonce: Bytes) -> Bytes? {
                for k in keys {
                    if let o = sodium.box.open(authenticatedCipherText: box, senderPublicKey: k,
                                               recipientSecretKey: sk, nonce: nonce) { return o }
                }
                return nil
            }

            if raw.hasPrefix("enc1:") {
                let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3,
                      let nonce = Data(base64Encoded: parts[1]),
                      let box = Data(base64Encoded: parts[2]),
                      let opened = openBox(Bytes(box), Bytes(nonce)) else { return nil }
                return String(bytes: opened, encoding: .utf8)
            }
            if raw.hasPrefix("encg1:") {
                guard let json = Data(base64Encoded: String(raw.dropFirst("encg1:".count))),
                      let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                      let nB64 = obj["n"] as? String, let cB64 = obj["c"] as? String,
                      let wraps = obj["w"] as? [String: String], let mine = wraps[me],
                      let dataNonce = Data(base64Encoded: nB64), let ct = Data(base64Encoded: cB64)
                else { return nil }
                let wp = mine.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard wp.count == 2,
                      let wrapped = Data(base64Encoded: wp[0]), let keyNonce = Data(base64Encoded: wp[1]),
                      let msgKey = openBox(Bytes(wrapped), Bytes(keyNonce)),
                      let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(ct),
                                                         secretKey: msgKey, nonce: Bytes(dataNonce))
                else { return nil }
                return String(bytes: opened, encoding: .utf8)
            }
            return nil
        }

        private static func senderKeys(_ uid: String) -> [Bytes] {
            let d = NotifShared.defaults
            var out: [Bytes] = []
            if let cur = (d?.dictionary(forKey: NotifShared.pubKeysKey) as? [String: String])?[uid],
               let k = Data(base64Encoded: cur) { out.append(Bytes(k)) }
            for b in (d?.dictionary(forKey: NotifShared.pubRingKey) as? [String: [String]])?[uid] ?? [] {
                if let k = Data(base64Encoded: b), !out.contains(Bytes(k)) { out.append(Bytes(k)) }
            }
            return out
        }
    }

    /// Avatar files in the App Group container (`NotifShared.avatarFolder`), named by a hash of the
    /// URL. A changed photo has a new URL, so a cached file is never stale; the app deletes the
    /// folder on sign-out. Downloads run together and give up after `timeout`.
    private enum Avatars {
        static let maxBytes = 2_000_000

        /// The face for someone (or a group) with no photo: a soft grey circle with the person or
        /// people glyph, the way the app's own avatar draws it. PNG, drawn once per banner.
        static func placeholder(group: Bool) -> Data {
            let size = CGSize(width: 180, height: 180)
            let img = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor(red: 0.86, green: 0.86, blue: 0.88, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
                let cfg = UIImage.SymbolConfiguration(pointSize: group ? 70 : 84, weight: .regular)
                if let glyph = UIImage(systemName: group ? "person.2.fill" : "person.fill", withConfiguration: cfg)?
                    .withTintColor(UIColor(red: 0.62, green: 0.62, blue: 0.65, alpha: 1), renderingMode: .alwaysOriginal) {
                    let g = glyph.size
                    glyph.draw(in: CGRect(x: (size.width - g.width) / 2, y: (size.height - g.height) / 2 + 6,
                                          width: g.width, height: g.height))
                }
            }
            return img.pngData() ?? Data()
        }

        /// Results land here from the download callbacks (a class, so a late callback after the
        /// wait gave up writes into it harmlessly instead of into a captured local).
        private final class Slots: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Data?]
            init(_ n: Int) { items = [Data?](repeating: nil, count: n) }
            func set(_ i: Int, _ d: Data) { lock.lock(); items[i] = d; lock.unlock() }
            var all: [Data?] { lock.lock(); defer { lock.unlock() }; return items }
        }

        static func load(_ urls: [String?], timeout: TimeInterval) -> [Data?] {
            let slots = Slots(urls.count)
            let group = DispatchGroup()
            for (i, s) in urls.enumerated() {
                guard let s, s.hasPrefix("https://"), let url = URL(string: s) else { continue }
                let file = cacheFile(s)
                if let file, let d = try? Data(contentsOf: file), !d.isEmpty { slots.set(i, d); continue }
                group.enter()
                var req = URLRequest(url: url)
                req.timeoutInterval = timeout
                URLSession.shared.dataTask(with: req) { data, resp, _ in
                    defer { group.leave() }
                    guard let data, !data.isEmpty, data.count <= Avatars.maxBytes,
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                    slots.set(i, data)
                    if let file {
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                                 withIntermediateDirectories: true)
                        try? data.write(to: file, options: .atomic)
                    }
                }.resume()
            }
            _ = group.wait(timeout: .now() + timeout + 0.5)
            return slots.all
        }

        private static func cacheFile(_ url: String) -> URL? {
            guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NotifShared.appGroup)
            else { return nil }
            let name = SHA256.hash(data: Data(url.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            return dir.appendingPathComponent(NotifShared.avatarFolder, isDirectory: true)
                .appendingPathComponent(name + ".img")
        }
    }

    // MARK: Screen share privacy (1:1 audit #16, owner, 2026-10-08)
    //
    // While this phone shares its screen, a system banner with the message text would be in the
    // shared video. The broadcast extension stamps a keepalive in the App Group's `ss_video.bin`
    // every 0.5 s while it runs and zeroes it when it ends (Shared/ScreenShareIPC.swift, `Video`).
    // Fresh stamp = a share is live: show the banner without its text. The values below mirror
    // ScreenShareIPC (this target does not compile that file); keep them in step.
    // Needs the App Group on this extension (NotificationService.entitlements + the App ID). Without
    // it the container is nil and the banner is shown as it arrived, as before.
    private static let videoFileName = "ss_video.bin"
    private static let keepaliveOffset: off_t = 48             // ScreenShareIPC.Video.oKeepaliveNs
    private static let keepaliveTimeoutNs: UInt64 = 2_000_000_000 // ScreenShareIPC.keepaliveTimeoutNs

    private static func screenShareLive() -> Bool {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NotifShared.appGroup) else {
            return false
        }
        let fd = open(dir.appendingPathComponent(videoFileName).path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var stamp: UInt64 = 0
        guard pread(fd, &stamp, MemoryLayout<UInt64>.size, keepaliveOffset) == MemoryLayout<UInt64>.size,
              stamp != 0 else { return false }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)   // the same clock the extension stamps with
        // 1:1 audit check, 2026-10-08: a stamp from before a reboot (clock restarted below it) is stale.
        return now >= stamp && now - stamp <= keepaliveTimeoutNs
    }

    private static func hidingText(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        copy.title = "Kulan"   // 1:1 audit check, 2026-10-08: the sender's name is hidden too
        copy.subtitle = ""
        copy.body = "New message"
        return copy
    }
}
