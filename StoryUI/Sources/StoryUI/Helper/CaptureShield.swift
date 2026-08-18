//
//  CaptureShield.swift
//  StoryUI
//

import UIKit

/// ⛔ WHAT iOS ACTUALLY OFFERS AGAINST A SCREENSHOT, WHICH IS NOT AN API THAT REFUSES ONE.
///
/// Read before changing anything here, and do not let a later session "simplify" it into a
/// `userDidTakeScreenshotNotification` handler. There is no public API on any version of iOS that
/// stops a screenshot being taken. Apple gives three things and no more:
///
///   1. `UIApplication.userDidTakeScreenshotNotification` — fires AFTER the picture is in the
///      camera roll. It can tell the author; it cannot stop anything.
///   2. `UIScreen.isCaptured` + `capturedDidChangeNotification` — true while the screen is being
///      RECORDED or mirrored. Official, documented, reliable, and the only guarantee in this file.
///      It says nothing about a still screenshot.
///   3. `AVSampleBufferDisplayLayer.preventsCapture` — documented since iOS 13, and the only
///      published "leave this out of a capture" switch in the system. It exists ONLY on that layer,
///      which means owning the decode and feeding sample buffers yourself. `AVPlayerLayer`, which
///      this app's story player uses, has no equivalent.
///
/// Everything else is the trick below.
///
/// ## The trick, and whose it is
///
/// A `UITextField` with `isSecureTextEntry` on renders through a canvas layer the system composits
/// separately, and that canvas is left OUT of screenshots and screen recordings — it is how a
/// password field, and Netflix, come out black. Put your own layer inside that canvas and it
/// inherits the exclusion: visible on the glass, absent from the capture.
///
/// This is not invented here. It is the reference messenger's own story implementation, read from
/// its source (`StoryItemImageView.updateImage`), four lines long:
///
///     captureProtectedView = UITextField(frame: contentView.frame)
///     captureProtectedView.isSecureTextEntry = true
///     layer.addSublayer(captureProtectedView.layer)
///     captureProtectedView.layer.sublayers?.first?.addSublayer(contentView.layer)
///
/// ⚠️ IT IS AN IMPLEMENTATION DETAIL OF UIKit, NOT A CONTRACT. `sublayers.first` being the secure
/// canvas is undocumented. It has held for many years and ships in apps with hundreds of millions of
/// users, but an iOS release could end it silently — which is exactly why the `isCaptured` half
/// below is not optional garnish. If the canvas ever stops being there, `isShielded` goes false and
/// a recording is still defeated by blanking.
///
/// ## What this class does not claim
///
/// A photograph of the screen taken with another phone defeats every one of these, and always will.
/// This raises the cost of copying a story; it does not make it impossible, and the UI must never
/// tell the person otherwise.
final class CaptureShield {

    /// EVERY PROTECTED THING HANGS OFF THIS ONE VIEW, and it is the only thing that ever moves.
    ///
    /// ⚠️ IT IS DELIBERATELY NOT A SUBVIEW. Its LAYER is parented — either straight onto the host's
    /// layer, or into the secure canvas — so switching protection on and off is one `addSublayer`
    /// with nothing else to keep in step. The media inside it keeps its own view hierarchy, so image
    /// views, player layers and content modes all behave exactly as they did; the host lays it out
    /// to its own bounds in `layoutSubviews`, so nothing inside ever learns which home it is in.
    let content = UIView()

    /// True when the media is currently inside the system's secure canvas. False either because this
    /// story is not protected, or because UIKit did not hand us the canvas — see the class note. The
    /// second case must never be reported to anyone as protection.
    private(set) var isShielded = false

    /// True while the screen is being recorded or mirrored, from `UIScreen.isCaptured`. The host
    /// hides its media while this is on. This is the half that is guaranteed.
    private(set) var isCapturing = false

    private weak var host: UIView?
    private var field: UITextField?
    private var wantsShield = false
    private var captureObserver: NSObjectProtocol?
    /// Called when `isCapturing` flips, so the host can hide or show its media. Never called for a
    /// story that is not protected.
    var onCaptureStateChanged: ((Bool) -> Void)?

    init(host: UIView) {
        self.host = host
        content.isUserInteractionEnabled = false
        host.layer.addSublayer(content.layer)
    }

    deinit {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
    }

    /// Protect this story, or stop protecting it. Idempotent, and safe to call on every update —
    /// which is how it stays on through a pause, a swipe to the next story, a swipe back, and an
    /// automatic advance: the page re-applies it every time it re-renders, and a re-used view (the
    /// viewers-sheet keeps video views alive) is told again when it is re-attached.
    func setProtected(_ on: Bool) {
        // The retry: if a previous attempt could not find the canvas there is no field to reuse, so
        // "already on" must not short-circuit an attempt that never actually shielded anything.
        if on == wantsShield, on == isShielded { return }
        wantsShield = on
        on ? shield() : unshield()
        on ? startWatchingCapture() : stopWatchingCapture()
    }

    /// Called from the host's `layoutSubviews`. Keeps the secure field, its canvas and the content
    /// all exactly the host's bounds, so a layer inside `content` is in the host's own coordinates
    /// whether it is shielded or not.
    func layout(in bounds: CGRect) {
        // No implicit animation: this runs inside every sheet-pull frame and a fading corner or a
        // sliding canvas would be visible as a smear behind the picture.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer.frame = bounds
        if let field {
            field.layer.frame = bounds
            field.layer.sublayers?.first?.frame = CGRect(origin: .zero, size: bounds.size)
        }
        CATransaction.commit()
    }

    // MARK: - The secure canvas

    private func shield() {
        guard let host else { return }
        let f = field ?? {
            let f = UITextField()
            f.isSecureTextEntry = true
            f.isUserInteractionEnabled = false
            field = f
            return f
        }()
        if f.layer.superlayer !== host.layer { host.layer.addSublayer(f.layer) }
        // ⚠️ THE CANVAS IS THE FIRST SUBLAYER AND NOTHING PROMISES IT IS THERE. On the pass where it
        // is not, the media stays where it was — visible, unshielded, and honestly reported as such
        // — and the next layout pass tries again rather than leaving a story that looks protected
        // and is not.
        guard let canvas = f.layer.sublayers?.first else {
            isShielded = false
            return
        }
        if content.layer.superlayer !== canvas { canvas.addSublayer(content.layer) }
        isShielded = true
    }

    private func unshield() {
        guard let host else { return }
        if content.layer.superlayer !== host.layer { host.layer.addSublayer(content.layer) }
        field?.layer.removeFromSuperlayer()
        field = nil
        isShielded = false
    }

    /// Re-tried from the host's layout pass, for the case above. Costs nothing once shielded.
    func retryIfNeeded() {
        guard wantsShield, !isShielded else { return }
        shield()
    }

    // MARK: - Screen recording and mirroring

    /// ⚠️ THE ONLY GUARANTEED HALF. `UIScreen.isCaptured` is documented and behaves: it is true while
    /// the screen is being recorded, AirPlayed or shared, and it changes before the recording starts
    /// carrying frames. The host blanks its media on it, so a recording gets a dark card whatever the
    /// secure canvas did or did not do.
    private func startWatchingCapture() {
        guard captureObserver == nil else { return }
        applyCaptureState(UIScreen.main.isCaptured)
        captureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyCaptureState(UIScreen.main.isCaptured)
        }
    }

    private func stopWatchingCapture() {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        captureObserver = nil
        applyCaptureState(false)
    }

    private func applyCaptureState(_ capturing: Bool) {
        guard capturing != isCapturing else { return }
        isCapturing = capturing
        onCaptureStateChanged?(capturing)
    }
}
