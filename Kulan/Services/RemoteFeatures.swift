import Foundation
import FirebaseFirestore

/// FEATURE SWITCHES THE OWNER FLIPS FROM THE ADMIN PANEL (admin.fariin.com → Feature controls),
/// 2026-10-12. One document, `config/features`, written only by the adminApi function (the rules let
/// signed-in phones read it and nobody write it). Each key is a Bool.
///
/// How a switch resolves: the value from the server if it has one, otherwise the default this build
/// ships with (the old `static let`). Two kinds of switch, the owner's rule:
///   • finished features may go ON or OFF from the panel;
///   • unfinished ones (groups, group calls, call links, two-step) may only be turned OFF. A remote
///     `true` is ignored for them, so a half-built feature can never be switched on by accident; a
///     future build that ships one ON can still be killed from the panel.
///
/// WHEN IT APPLIES: the next time the app opens. The listener saves what the server says; the switches
/// read a snapshot taken once per launch. Changing a feature's doors under a screen that is already
/// drawn (a tab disappearing mid-scroll) is worse than waiting for the next open, and a snapshot is
/// also what lets these be read from any thread without a lock.
final class RemoteFeatures {
    static let shared = RemoteFeatures()
    private init() {}

    private static let storeKey = "remoteFeatures.v1"

    /// What the server said, as of the last launch. Read once; never changes while the app runs.
    private static let snapshot: [String: Bool] = {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Bool]) ?? [:]
    }()

    /// A finished feature: the server's value wins either way.
    static func value(_ key: String, default shipped: Bool) -> Bool {
        snapshot[key] ?? shipped
    }

    /// An unfinished feature: the server can only take it away.
    static func offOnly(_ key: String, default shipped: Bool) -> Bool {
        shipped && snapshot[key] != false
    }

    private var listener: ListenerRegistration?

    /// Started with AppLimits. An error or a missing document leaves the saved values alone, the same
    /// rule AppLimits follows: a dropped listener is not a reason to undo the owner's last choice.
    func start() {
        stop()
        listener = Firestore.firestore().collection("config").document("features")
            .addSnapshotListener { snap, _ in
                guard let snap, snap.exists else { return }
                var out: [String: Bool] = [:]
                for (k, v) in snap.data() ?? [:] { if let b = v as? Bool { out[k] = b } }
                UserDefaults.standard.set(out, forKey: Self.storeKey)
            }
    }

    func stop() { listener?.remove(); listener = nil }
}
