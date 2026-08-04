import Foundation

// Jittered exponential backoff (the standard retry-interval formula):
// min(cap, 2^attempt × base/2) × random(0.75…1.25). The jitter prevents synchronized
// "thundering herd" retries across clients when a backend hiccups.
enum Backoff {
    static func delay(attempt: Int, base: TimeInterval = 2, cap: TimeInterval = 60) -> TimeInterval {
        let avg = min(cap, pow(2, Double(max(0, attempt))) * base / 2)
        return avg * Double.random(in: 0.75...1.25)
    }
    /// Async sleep for the attempt's backoff interval.
    static func sleep(attempt: Int, base: TimeInterval = 2, cap: TimeInterval = 60) async {
        try? await Task.sleep(nanoseconds: UInt64(delay(attempt: attempt, base: base, cap: cap) * 1_000_000_000))
    }
}

// Terminal "this media is gone" registry (the standard approach: mark unrecoverable attachments as a final state
// instead of retrying forever). In Fariin's mailman model a delivered 1:1 video is DELETED from the
// server — a 404 on it is permanent, so remember that and never re-fetch. Persisted like HiddenMessages.
enum DeadMedia {
    private static var cache = Set<String>((UserDefaults.standard.string(forKey: "deadMedia") ?? "")
        .split(separator: " ").map(String.init))
    static func contains(_ id: String) -> Bool { cache.contains(id) }
    static func mark(_ id: String) {
        guard !id.isEmpty, !cache.contains(id) else { return }
        cache.insert(id)
        // Bound the persisted set — old ids are worthless once their chats are gone.
        if cache.count > 500 { cache = Set(cache.suffix(400)) }
        UserDefaults.standard.set(cache.joined(separator: " "), forKey: "deadMedia")
    }
}
