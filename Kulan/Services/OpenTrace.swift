import UIKit

/// ⛔ MEASUREMENT ONLY, NO BEHAVIOUR — owner 2026-10-15: "the centre column of the attach grid opens with
/// a pop, left and right open well; find the real cause with logs before changing anything". Every
/// open from an attach tile is written to `DiagLog` (never on screen, his 2026-09-28 rule), from the
/// tap to the landing, and the file is sent up after each open so the numbers can be read from
/// `users/{uid}/diag`. Remove once the cause is confirmed and fixed.
///
/// Lines read `OPEN#<n> +<ms since tap>ms <what>`, rects as `x,y,w,h` in window points.
@MainActor enum OpenTrace {
    private(set) static var active = false
    static var sampler: FrameSampler?
    private static var n = 0
    private static var tapAt: CFTimeInterval = 0

    static func begin(_ what: String) {
        n += 1
        tapAt = CACurrentMediaTime()
        active = true
        DiagLog.add("OPEN#\(n) +0ms TAP \(what)")
    }

    static func note(_ what: String) {
        guard active else { return }
        let ms = Int((CACurrentMediaTime() - tapAt) * 1000)
        DiagLog.add("OPEN#\(n) +\(ms)ms \(what)")
    }

    /// The flight landed and the copy is gone: close this open's record and send the file soon.
    static func end(_ what: String) {
        guard active else { return }
        note(what)
        active = false
        DiagLog.flagForUpload(after: 4)
    }

    static func r(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }
    static func s(_ size: CGSize?) -> String {
        guard let size else { return "nil" }
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    /// Samples the flying copy's DRAWN rect (presentation layers, window points) on the first frames
    /// of the flight, so the log shows exactly where it was on screen frame by frame.
    final class FrameSampler: NSObject {
        private weak var container: UIView?
        private weak var clip: UIView?
        private var link: CADisplayLink?
        private var left: Int

        init(container: UIView, clip: UIView, frames: Int = 12) {
            self.container = container
            self.clip = clip
            self.left = frames
            super.init()
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func tick() {
            MainActor.assumeIsolated {
                guard let container, let clip, left > 0,
                      let cp = clip.layer.presentation(), let kp = container.layer.presentation() else {
                    link?.invalidate(); link = nil; return
                }
                left -= 1
                // The copy sits in the clip view; both move during the flight.
                let drawn = kp.frame.offsetBy(dx: cp.frame.minX, dy: cp.frame.minY)
                OpenTrace.note("frame copy=\(OpenTrace.r(drawn)) clip=\(OpenTrace.r(cp.frame)) radius=\(Int(kp.cornerRadius))")
                if left == 0 { link?.invalidate(); link = nil }
            }
        }
    }
}
