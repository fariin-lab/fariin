import Foundation
import FirebaseFirestore

/// THE CHAT LIST, ON DISK, so the first frame of a cold launch is real chats.
///
/// The problem this exists for: our chat list came from a Firestore listener, and even Firestore's
/// own persistent cache answers on a CALLBACK. A callback cannot land in the first frame. So on
/// every cold launch there was a real hole with no data in it, and the splash and the shimmer were
/// not decoration — they were covering that hole. The reference app has no such hole because its
/// store is on the phone and IS the truth; the network only writes into it.
///
/// ⚠️ WHAT IS STORED, stated plainly. This holds the conversation documents as Firestore hands them
/// over: names, photo URLs, unread counts, timestamps — and `lastMessage`, which is CIPHERTEXT. The
/// list decrypts previews at render time, so no decrypted message text is written here. That is a
/// property of the model (`Conversation.lastMessageCipher`) and it should stay that way; if a future
/// change starts caching decrypted previews, this comment is wrong and the decision needs taking
/// again.
///
/// ⚠️ It adds no exposure that did not already exist: Firestore's persistent cache already writes
/// these same documents to disk. This file is protected at least as well — see `protection`.
final class ConversationsDiskCache {
    static let shared = ConversationsDiskCache()
    private init() {}

    /// One screen is ~10 rows; 200 is far past anything a first frame needs and keeps the
    /// synchronous read in the low milliseconds.
    private let cap = 200
    /// In the FILENAME, not inside the file. A format change lands as a different path, so an old
    /// build's file is never parsed by a new one — it is simply not found, and the launch falls back
    /// to the listener exactly as it did before this existed.
    private let version = 1

    /// `.completeUntilFirstUserAuthentication`, deliberately, and not `.complete`.
    ///
    /// `.complete` would make the file unreadable AND UNWRITABLE while the phone is locked, and
    /// conversation snapshots arrive in the background (a push waking the app) — so the cache would
    /// silently stop being written at exactly the times it most needs updating. This level keeps it
    /// sealed until the first unlock after a reboot, which is the standard bar for this kind of data
    /// and is stronger than the default Firestore's own cache uses.
    private let protection = FileProtectionType.completeUntilFirstUserAuthentication

    private let io = DispatchQueue(label: "fariin.chatlist.cache", qos: .utility)

    // MARK: - Where

    /// Application Support, NOT Caches. The system may evict Caches under disk pressure, and this is
    /// on the launch path: losing it costs the user the very thing it is here to provide.
    private func fileURL(uid: String) -> URL? {
        guard !uid.isEmpty,
              let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        else { return nil }
        // Per uid: switching accounts on one phone must never show the previous person's chats,
        // not even for the one frame this class exists to fill.
        return dir.appendingPathComponent("chatlist-v\(version)-\(uid).plist")
    }

    // MARK: - Read

    /// SYNCHRONOUS ON PURPOSE. It is called before the first frame; hopping to another queue here
    /// would reintroduce the exact gap this class removes.
    ///
    /// Returns [] for anything unexpected — a missing file, a half-written one, a format we no
    /// longer understand. Every one of those simply means "no cache", and the listener behaves as it
    /// always did.
    func load(uid: String) -> [Conversation] {
        guard let url = fileURL(uid: uid),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let raw = plist as? [[String: Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["__id"] as? String,
                  let body = entry["__doc"] as? [String: Any],
                  let doc = restore(body) as? [String: Any] else { return nil }
            return Conversation(id: id, data: doc)
        }
    }

    // MARK: - Write

    /// Called with the documents exactly as the listener received them, so the cache and the live
    /// path are rebuilt by the SAME initializer. A hand-written DTO would be a second description of
    /// a 40-field struct, and the two would drift the first time a field was added.
    func store(_ docs: [(id: String, data: [String: Any])], uid: String) {
        guard let url = fileURL(uid: uid) else { return }
        // An EMPTY list is a real answer and has to be recorded, not skipped. The caller has already
        // dropped the one empty snapshot that lies — an offline cold start's empty cached read — so
        // reaching here with nothing means the server says there is nothing. Keeping the old file
        // would show chats the user has just cleared, for a frame, on every launch afterwards.
        guard !docs.isEmpty else {
            io.async { try? FileManager.default.removeItem(at: url) }
            return
        }
        // Newest first, then capped: if we can only keep some, keep the ones a first frame shows.
        let trimmed = docs
            .sorted { millis($0.data) > millis($1.data) }
            .prefix(cap)
            .map { ["__id": $0.id, "__doc": sanitize($0.data)] as [String: Any] }
        io.async {
            guard let blob = try? PropertyListSerialization.data(fromPropertyList: trimmed,
                                                                 format: .binary, options: 0)
            else { return }
            // Atomic: a launch reading this file while it is being replaced must see the whole old
            // one or the whole new one, never half of either.
            try? blob.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.protectionKey: self.protection],
                                                   ofItemAtPath: url.path)
        }
    }

    /// Signing out takes it with everything else — the next person on this phone must not be handed
    /// a stranger's chat list on their first frame. Called from SessionWipe.
    func wipe(uid: String) {
        guard let url = fileURL(uid: uid) else { return }
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Every file this class has ever written, for a sign-out that no longer knows the uid.
    func wipeAll() {
        io.async {
            guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil, create: false),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { return }
            for n in names where n.hasPrefix("chatlist-v") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    // MARK: - Making a Firestore document survive a property list

    private func millis(_ data: [String: Any]) -> Double {
        if let ts = data["updatedAt"] as? Timestamp { return ts.dateValue().timeIntervalSince1970 }
        return 0
    }

    /// A property list understands String, NSNumber, Bool, Date, Data, Array and Dictionary, and
    /// nothing else. A Firestore document also carries `Timestamp`, `NSNull`, and (before a write
    /// resolves) sentinel objects — any one of which makes the whole serialisation fail, taking the
    /// entire cache with it rather than the single field. Everything unrecognised is dropped here,
    /// because a missing field reads as its default and a failed write reads as no cache at all.
    private func sanitize(_ value: Any) -> Any {
        switch value {
        case let ts as Timestamp:       return ts.dateValue()
        case let dict as [String: Any]: return dict.compactMapValues { keep(sanitize($0)) }
        case let arr as [Any]:          return arr.compactMap { keep(sanitize($0)) }
        default:                        return value
        }
    }

    private func keep(_ value: Any) -> Any? {
        switch value {
        case is String, is NSNumber, is Date, is Data: return value
        case let d as [String: Any]:                   return d
        case let a as [Any]:                           return a
        default:                                       return nil   // NSNull, sentinels, anything new
        }
    }

    /// The reverse. `Conversation.init(id:data:)` reads `createdAt`, `updatedAt` and
    /// `lastReactionAt` as `Timestamp`, so every Date has to go back as one before it is handed
    /// over. Converting ALL dates is safe precisely because the initialiser never reads a bare Date.
    private func restore(_ value: Any) -> Any {
        switch value {
        case let date as Date:          return Timestamp(date: date)
        case let dict as [String: Any]: return dict.mapValues { restore($0) }
        case let arr as [Any]:          return arr.map { restore($0) }
        default:                        return value
        }
    }
}
