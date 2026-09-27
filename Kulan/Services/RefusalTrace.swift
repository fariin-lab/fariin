import UIKit
import FirebaseAuth
import FirebaseFirestore

/// ⛔ TEMPORARY, REMOVE WITH `OpenTrace` — owner, 2026-09-27: "sometimes the whole app breaks: I
/// can't react, archive or unarchive, my picture, name and bio are gone, every account looks
/// deleted, messages don't send. With the internet OFF everything works; restarting fixes it."
///
/// Online-only means the server is refusing this phone, and a refused snapshot listener is closed
/// by Firestore for good, which is why only a restart heals it. What is not known is WHY the phone's
/// requests are refused, and the rules turn a request away for three different reasons: no
/// signed-in user, an anonymous one, or a two-step claim that does not list this session
/// (`twoStepSatisfied`). The first time the server says permission-denied or unauthenticated, this
/// puts the phone's sign-in state at that moment on screen, red, for him to photograph, and then
/// asks for a fresh token to see whether that alone would have let it back in.
@MainActor enum RefusalTrace {
    private static var lastShown = Date.distantPast

    static func note(_ error: Error, _ from: String) {
        let ns = error as NSError
        // 7 = permission denied, 16 = unauthenticated (the numbers SendQueue and PushManager test too).
        guard ns.domain == FirestoreErrorDomain, ns.code == 7 || ns.code == 16 else { return }
        guard Date().timeIntervalSince(lastShown) > 60 else { return }
        lastShown = Date()
        let what = ns.code == 7 ? "permission denied" : "unauthenticated"
        Task { @MainActor in
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss"
            var lines = ["SERVER REFUSED THIS PHONE (\(what))", "first seen at: \(from), \(clock.string(from: Date()))"]
            let user = Auth.auth().currentUser
            lines.append("server sign-in: " + (user.map { "\($0.uid.prefix(6))" + ($0.isAnonymous ? " ANONYMOUS" : "") } ?? "NONE"))
            lines.append("app thinks: \(AuthService.shared.uid.map { String($0.prefix(6)) } ?? "NONE"), sends as: \(ChatService.uid.prefix(6))")
            if let user {
                lines.append(describe(try? await user.getIDTokenResult(forcingRefresh: false), "token", clock))
                lines.append(describe(try? await user.getIDTokenResult(forcingRefresh: true), "fresh token", clock))
            }
            show(lines.joined(separator: "\n"))
        }
    }

    private static func describe(_ r: AuthTokenResult?, _ name: String, _ clock: DateFormatter) -> String {
        guard let r else { return "\(name): could not get one" }
        var s = "\(name): signed in \(clock.string(from: r.authDate)), expires \(clock.string(from: r.expirationDate))"
        if let c = r.claims["twoStep"] as? [String: Any] {
            s += "\n  two-step: required=\(c["required"] ?? "-") ok=\(c["ok"] ?? "-") this session passes=\(TwoStepGate.sessionPassed(r))"
        } else {
            s += "\n  two-step: none"
        }
        return s
    }

    private static func show(_ text: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.9)
        label.text = text
        let width = window.bounds.width - 24
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: 12, y: window.safeAreaInsets.top + 60, width: width, height: size.height + 8)
        label.isUserInteractionEnabled = false
        window.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { label.removeFromSuperview() }
    }
}
