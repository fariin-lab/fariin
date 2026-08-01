import Foundation
import FirebaseAuth
import FirebaseFirestore

// The chat list, kept on disk in a form we can read WITHOUT waiting.
//
// THE PROBLEM. Every Firestore read is a callback, offline or not. There is no API that hands you
// data on the spot. So the chat list screen is always built first and told its chats afterwards, and
// that first draw with nothing on it is the blink on a cold launch (owner report, three screenshots).
// Firestore's cache is not the slow part; it answers in milliseconds. The shape is the problem: ask,
// then be called back, which can never happen before the frame that asked.
//
// WhatsApp and Signal do not have this because they read a local database file directly and get rows
// back in the same instant, before the first frame exists. This file is the same idea, small enough
// to be worth it: the last known list, written whenever Firestore updates it, read synchronously the
// moment the repository is created.
//
// It stores the RAW Firestore document data rather than some parallel row type, so rebuilding is the
// existing `Conversation.init(id:data:)` and there is no second model to drift out of step. The three
// Timestamp fields are the only things in that dictionary JSON cannot hold, so they are swapped for
// millisecond numbers on the way out and swapped back on the way in.
enum ChatListSnapshot {
    private static let tsMarker = "__ts_millis__"
    private static let timestampKeys = ["createdAt", "updatedAt", "lastReactionAt"]
    /// Enough to fill any screen twice over. The rest arrive with Firestore a moment later, and a
    /// bounded file keeps the read cheap enough to justify doing it before the first frame.
    private static let maxRows = 60

    private static var fileURL: URL? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Per uid: two accounts on one phone must never see each other's chat list, not even for
        // the one frame before Firestore corrects it.
        return base.appendingPathComponent("chatlist-\(uid).json")
    }

    // MARK: Read (synchronous, on purpose)

    /// Called during `start()`, before the listener is attached, so the first frame already has rows.
    /// Returns empty on a first-ever launch, a different account, or anything unreadable. Every
    /// failure path is silent: this is an optimisation, and a broken cache must never block a launch.
    static func load() -> [Conversation] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { row in
            guard let id = row["__id"] as? String else { return nil }
            var d = row
            d.removeValue(forKey: "__id")
            for k in timestampKeys {
                if let millis = (d[k] as? [String: Any])?[tsMarker] as? Double {
                    d[k] = Timestamp(date: Date(timeIntervalSince1970: millis / 1000))
                }
            }
            return Conversation(id: id, data: d)
        }
    }

    // MARK: Write

    /// Called on every snapshot. Off the main thread: the whole point is that the READ is cheap, and
    /// paying for the write on the frame Firestore delivers would just move the stall.
    static func save(_ docs: [(id: String, data: [String: Any])]) {
        guard let url = fileURL else { return }
        let slice = Array(docs.prefix(maxRows))
        DispatchQueue.global(qos: .utility).async {
            var out: [[String: Any]] = []
            out.reserveCapacity(slice.count)
            for doc in slice {
                var d = doc.data
                for k in timestampKeys {
                    if let ts = d[k] as? Timestamp {
                        d[k] = [tsMarker: ts.dateValue().timeIntervalSince1970 * 1000]
                    }
                }
                // Anything else Firestore may hand us that JSON cannot hold (FieldValue sentinels,
                // GeoPoint, Data) is dropped rather than risking a throw that loses the whole file.
                d = d.filter { JSONSerialization.isValidJSONObject([$1]) }
                d["__id"] = doc.id
                out.append(d)
            }
            guard JSONSerialization.isValidJSONObject(out),
                  let data = try? JSONSerialization.data(withJSONObject: out) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Sign-out: this is a decrypted-adjacent list of who the previous account talks to.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
