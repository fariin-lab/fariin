import Foundation
import UIKit

// Last-decrypted messages per chat, kept in memory ONLY (wiped when the app is killed).
//
// This is what lets a reopened chat render its conversation SYNCHRONOUSLY at ThreadRepository.init
// — fully painted and frozen BEFORE the push transition — instead of fading in a beat late while
// the E2EE decrypt runs off the main thread. It's Kulan's local decrypted render-state / local DB:
// the messages are already unlocked and ready, so the screen isn't empty when the push starts.
//
// First-ever open of a chat this session is still a cold async load (nothing cached yet); every
// reopen after is instant. Main-actor only (written from ThreadRepository on the main thread).
final class ThreadMessageCache {
    static let shared = ThreadMessageCache()
    private init() {
        // Background shrink (cache-evacuation idea, softened): keep the cache so reopening a
        // chat after backgrounding is still instant, but trim each chat to ~2 screens of messages so a
        // backgrounded app isn't holding thousands of decrypted Message structs under memory/thermal
        // pressure (the SwiftUI-layout watchdog kill happened exactly there).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for (cid, msgs) in self.byCid where msgs.count > self.backgroundCap {
                self.byCid[cid] = Array(msgs.suffix(self.backgroundCap))
            }
        }
    }

    private var byCid: [String: [Message]] = [:]
    private let cap = 200            // bound memory — the recent window is all the first screen needs
    private let backgroundCap = 60   // ~2 screens; enough for an instant reopen after backgrounding

    func store(_ cid: String, _ messages: [Message]) {
        byCid[cid] = messages.suffix(cap).map { $0 }
    }
    func messages(for cid: String) -> [Message]? { byCid[cid] }

    /// Sign-out/delete: these are DECRYPTED messages — never let them survive into
    /// another account's session on this device.
    func removeAll() { byCid = [:] }
}
