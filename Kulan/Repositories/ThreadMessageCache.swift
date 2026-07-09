import Foundation

// Last-decrypted messages per chat, kept in memory ONLY (wiped when the app is killed).
//
// This is what lets a reopened chat render its conversation SYNCHRONOUSLY at ThreadRepository.init
// — fully painted and frozen BEFORE the push transition — instead of fading in a beat late while
// the E2EE decrypt runs off the main thread. It's Kulan's equivalent of Signal's local decrypted
// render-state (GRDB) / WhatsApp's local DB: the messages are already unlocked and ready, so the
// screen isn't empty when the push starts.
//
// First-ever open of a chat this session is still a cold async load (nothing cached yet); every
// reopen after is instant. Main-actor only (written from ThreadRepository on the main thread).
final class ThreadMessageCache {
    static let shared = ThreadMessageCache()
    private init() {}

    private var byCid: [String: [Message]] = [:]
    private let cap = 200   // bound memory — the recent window is all the first screen needs

    func store(_ cid: String, _ messages: [Message]) {
        byCid[cid] = messages.suffix(cap).map { $0 }
    }
    func messages(for cid: String) -> [Message]? { byCid[cid] }
}
