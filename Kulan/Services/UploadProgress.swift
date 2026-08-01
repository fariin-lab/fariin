import Foundation

/// How far along each in-flight upload is, keyed by the optimistic bubble's clientId.
///
/// This exists so a sending bubble can show a ring that FILLS rather than a spinner that only says
/// "busy". The bytes were always there — Firebase's upload task reports them — but the `putFileAsync`
/// wrapper the send paths used throws the task away, and with it the only thing that knows.
///
/// Deliberately tiny and deliberately in memory only. A fraction is meaningless once the app has
/// been relaunched: the upload it described is either finished or gone, and a restored ring would be
/// describing something that is no longer happening.
@MainActor
final class UploadProgress: ObservableObject {
    static let shared = UploadProgress()
    private init() {}

    /// clientId -> 0...1. Absent means "not started yet", which is a different thing from 0 and is
    /// why the ring spins rather than sitting empty until the first byte lands.
    @Published private(set) var fractions: [String: Double] = [:]

    func report(_ id: String, _ fraction: Double) {
        let clamped = min(1, max(0, fraction))
        // Never let it go backwards within one attempt. Firebase can deliver progress events out of
        // order, and a ring that stutters backwards reads as a fault in the upload.
        if let existing = fractions[id], clamped < existing { return }
        guard fractions[id] != clamped else { return }
        fractions[id] = clamped
    }

    /// A retry starts the bytes over, so the ring must start over too.
    func reset(_ id: String) { fractions[id] = 0 }

    func finish(_ id: String) { fractions.removeValue(forKey: id) }

    func fraction(_ id: String?) -> Double? { id.flatMap { fractions[$0] } }
}
