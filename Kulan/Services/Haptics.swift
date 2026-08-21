import UIKit

// THE TAPTIC ENGINE HAS TO BE WOKEN UP BEFORE IT CAN BE FELT.
//
// Every haptic in the app was written the same way: build a generator, fire it, drop it.
//
//     UIImpactFeedbackGenerator(style: .light).impactOccurred()
//
// That is the one pattern Apple's own documentation tells you not to use. The Taptic Engine is
// asleep between uses, and a generator that has never had `prepare()` called has to wake it on the
// spot — which costs tens of milliseconds, arrives after the thing it was meant to confirm, and on a
// busy frame is dropped entirely. Then the generator is released immediately, so the next tap starts
// from a cold engine again. Nothing is broken and nothing logs an error; the tap is just weak,
// late, or absent, which is exactly the report: sending a message "doesn't tell you anything".
//
// This keeps one generator per style alive for the life of the app and re-primes it after each use,
// so the next one is instant. Same API shape as before, so call sites read the same.
//
// WHY THIS MATTERS MORE THAN A SOUND. A haptic is the only feedback that survives the ring/silent
// switch. A sent-message sound is correctly silenced with everything else, so on a phone on silent —
// which is most phones, most of the time — this tap IS the confirmation. It has to actually fire.
@MainActor
enum Haptics {
    private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static let notifier = UINotificationFeedbackGenerator()

    private static func generator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let g = impacts[style] { return g }
        let g = UIImpactFeedbackGenerator(style: style)
        impacts[style] = g
        return g
    }

    /// Call when an interaction becomes LIKELY, not when it happens: opening the composer, starting
    /// a drag, pressing and holding. The engine stays warm for a few seconds, which is the whole
    /// point — `prepare()` at the moment of the tap is no better than not calling it at all.
    static func prepare(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        generator(style).prepare()
        notifier.prepare()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = generator(style)
        g.impactOccurred()
        g.prepare()   // re-arm for the next one rather than waiting to be asked
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notifier.notificationOccurred(type)
        notifier.prepare()
    }
}
