import Foundation
import FirebaseAuth
import FirebaseFirestore

/// The two exports, split the way large messengers split them — owner asked 2026-09-25 whether
/// "Your Account Data" was real, and handed the call to me.
///
///  • `accountReport()` — what the account IS: profile, sign-in, devices, privacy, blocked people,
///    counts. No message content. This is "Your Account Data" in Account.
///  • `chatExport(...)` — one conversation's messages, from that chat's own info page.
///
/// ⚠️ WHAT THE OLD EXPORT DID WRONG, so nobody rebuilds it: it was one file of every message in every
/// chat with only name and handle for the account; a chat that failed to load came out empty and
/// looked complete (`try?`); and the decrypted text was left in the temp folder forever. Here a
/// failure is an error the screen shows, the file is written with complete file protection in a
/// folder of its own, and `cleanup()` deletes it when the share sheet closes.
enum DataExport {
    enum Failure: LocalizedError {
        case signedOut, unreadable
        var errorDescription: String? {
            switch self {
            case .signedOut: return "You are signed out."
            case .unreadable: return "Could not load everything. Check your connection and try again."
            }
        }
    }

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FariinExport", isDirectory: true)
    }

    /// Deletes every export file. Called when the share sheet closes, and safe to call any time.
    static func cleanup() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Account report

    @MainActor
    static func accountReport() async throws -> URL {
        guard let user = Auth.auth().currentUser else { throw Failure.signedOut }
        let uid = user.uid
        let me = ProfileStore.shared.me
        let df = Date.FormatStyle(date: .abbreviated, time: .shortened)

        var out = "Fariin, account information\n"
        out += "Created \(Date().formatted(df))\n\n"

        out += "ACCOUNT\n"
        out += "Name: \(me?.name ?? "")\n"
        out += "Username: @\(me?.handle ?? "")\n"
        if let about = me?.about, !about.isEmpty { out += "Bio: \(about)\n" }
        out += "Account ID: \(uid)\n"
        if let email = user.email, !email.isEmpty { out += "Email: \(email)\n" }
        if let joined = me?.joinedAt ?? user.metadata.creationDate { out += "Joined: \(joined.formatted(df))\n" }
        out += "Profile photo: \((me?.photoUrl ?? "").isEmpty ? "No" : "Yes")\n"
        let links = me?.links ?? []
        if !links.isEmpty {
            out += "Links:\n"
            for l in links { out += "  \(l.title): \(l.url)\n" }
        }
        out += "\n"

        out += "SIGN-IN METHODS\n"
        let providers = user.providerData.map(\.providerID)
        if providers.isEmpty { out += "  None\n" }
        for p in providers { out += "  \(providerName(p))\n" }
        out += "\n"

        out += "PRIVACY\n"
        let privacy = me?.privacy ?? [:]
        if privacy.isEmpty { out += "  Defaults\n" }
        for (k, v) in privacy.sorted(by: { $0.key < $1.key }) { out += "  \(k): \(v)\n" }
        out += "\n"

        // Devices: one read of the account's own device records, which the rules let it read.
        out += "DEVICES\n"
        do {
            let snap = try await Firestore.firestore().collection("users").document(uid)
                .collection("devices").getDocuments()
            let devices = snap.documents.compactMap(DeviceSession.init)
            if devices.isEmpty { out += "  None\n" }
            for d in devices.sorted(by: { $0.lastSeenAt > $1.lastSeenAt }) {
                out += "  \(d.model), \(d.os), app \(d.appVersion), last active \(d.lastSeenAt.formatted(df))"
                out += d.isThisDevice ? " (this phone)\n" : "\n"
            }
        } catch {
            throw Failure.unreadable
        }
        out += "\n"

        out += "BLOCKED ACCOUNTS\n"
        let blocked = BlockList.shared.entries.keys.sorted()
        if blocked.isEmpty { out += "  None\n" }
        for b in blocked {
            let p = await ProfileStore.shared.cachedPeer(b)
            out += "  " + (p.map { "@\($0.handle)" } ?? b) + "\n"
        }
        out += "\n"

        out += "ACTIVITY\n"
        let convs = ConversationsRepository.shared.conversations
            .filter { !$0.isCleared(uid) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
        out += "Chats: \(convs.count)\n"
        out += "Glowers: \(me?.glowerCount ?? 0)\n"
        out += "Glowing: \(me?.glowingCount ?? 0)\n\n"

        out += "Messages are not in this file. Messages are end-to-end encrypted and only your phones "
        out += "can read them. To save a conversation, open the chat, tap the name at the top, and "
        out += "choose Export Chat.\n"

        return try write(out, name: "Fariin-Account-Information.txt")
    }

    private static func providerName(_ id: String) -> String {
        switch id {
        case "password": return "Email and password"
        case "apple.com": return "Apple"
        case "google.com": return "Google"
        default: return id
        }
    }

    // MARK: - One chat

    /// Every message in one 1:1 chat that this account can still see: nothing before a Clear, nothing
    /// deleted for me, nothing deleted for everyone. A failed read throws; it never writes a
    /// half-empty file that looks whole.
    @MainActor
    static func chatExport(cid: String, otherUid: String, otherName: String) async throws -> URL {
        guard let uid = Auth.auth().currentUser?.uid else { throw Failure.signedOut }
        _ = await Crypto.shared.preloadKey(otherUid)
        let conv = ConversationsRepository.shared.conversations.first { $0.id == cid }
        let clearedMs = conv?.clearedAt[uid] ?? 0

        let snap: QuerySnapshot
        do {
            snap = try await Firestore.firestore().collection("conversations").document(cid)
                .collection("messages").order(by: "createdAt").getDocuments()
        } catch {
            throw Failure.unreadable
        }

        let df = Date.FormatStyle(date: .abbreviated, time: .shortened)
        var out = "Fariin, chat with \(otherName)\n"
        out += "Exported \(Date().formatted(df))\n\n"
        for d in snap.documents {
            let m = Message(id: d.documentID, data: d.data(), cid: cid, crypto: Crypto.shared)
            if m.createdAt.timeIntervalSince1970 * 1000 <= clearedMs { continue }
            if m.deleted || HiddenMessages.isHidden(m.id) { continue }
            let who = m.authorId == uid ? "You" : otherName
            out += "[\(m.createdAt.formatted(df))] \(who): \(describe(m))\n"
        }
        let safe = otherName.filter { $0.isLetter || $0.isNumber || $0 == " " }
        return try write(out, name: "Fariin-Chat-\(safe.isEmpty ? "Export" : safe).txt")
    }

    private static func describe(_ m: Message) -> String {
        if m.isCall { return m.callVideo ? "[Video call]" : "[Voice call]" }
        if m.isAudio { return "[Voice message]" }
        if m.isVideo { return captioned("[Video]", m.text) }
        if m.isImage || !m.album.isEmpty { return captioned("[Photo]", m.text) }
        if m.isFile { return "[File: \(m.fileName ?? "document")]" }
        if m.isGif { return "[GIF]" }
        return m.text
    }

    private static func captioned(_ tag: String, _ text: String) -> String {
        text.isEmpty ? tag : "\(tag) \(text)"
    }

    // MARK: - Writing

    private static func write(_ text: String, name: String) throws -> URL {
        let fm = FileManager.default
        cleanup()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
