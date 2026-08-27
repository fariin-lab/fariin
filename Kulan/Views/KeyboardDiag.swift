import UIKit

/// ⚠️ TEMPORARY DIAGNOSTIC — 2026-08-27, the keyboard-open investigation on the owner's iOS 26
/// phone. Two mechanism rebuilds behaved identically there, so the next build stops deducing and
/// records: a tiny on-screen event log, drawn over the chat for a few seconds around every
/// keyboard transition, that a screenshot can carry back. Lines are timestamped from the first
/// event of the gesture; a quiet gap starts a fresh page.
///
/// Remove this file and its call sites once the open is settled.
@MainActor
enum KeyboardDiag {
    static var enabled = true
    private static let label = UILabel()
    private static var lines: [String] = []
    private static var t0 = CACurrentMediaTime()
    private static var lastT = CACurrentMediaTime()
    private static var hideWork: DispatchWorkItem?

    static func attach(to view: UIView) {
        guard enabled, label.superview !== view else { return }
        label.removeFromSuperview()
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.alpha = 0
        label.isUserInteractionEnabled = false
        view.addSubview(label)
    }

    static func log(_ s: String) {
        guard enabled, let host = label.superview else { return }
        let t = CACurrentMediaTime()
        if t - lastT > 3 { lines.removeAll(); t0 = t }
        lastT = t
        lines.append(String(format: "%5.0f %@", (t - t0) * 1000, s))
        if lines.count > 18 { lines.removeFirst(lines.count - 18) }
        UIView.performWithoutAnimation {
            label.text = lines.joined(separator: "\n")
            let size = label.sizeThatFits(CGSize(width: host.bounds.width - 16, height: 500))
            label.frame = CGRect(x: 8, y: host.safeAreaInsets.top + 44,
                                 width: size.width + 10, height: size.height + 8)
            host.bringSubviewToFront(label)
            label.alpha = 1
        }
        hideWork?.cancel()
        let w = DispatchWorkItem { UIView.animate(withDuration: 0.3) { label.alpha = 0 } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }
}
