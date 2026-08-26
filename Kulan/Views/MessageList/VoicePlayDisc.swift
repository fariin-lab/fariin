import UIKit
import SwiftUI

/// ⛔ STEP ONE OF MOVING THE VOICE BUBBLE OFF SwiftUI (his order, 2026-08-25: "yes please, we
/// replace step by step carefully").
///
/// The disc is first because every symptom he has reported about voice notes is here:
///
///   · it could not be a `Button` at all. The note in `VoiceMessageView.playButton` says why — inside
///     a hosted cell a Button's press gesture claims the touch, so a drag that starts on the disc was
///     swallowed and the chat would not scroll. It has been a bare `onTapGesture` ever since, which
///     means no press state, no touch-down feel, nothing UIKit gives a control for free.
///   · every progress tick re-rendered it, because it lives inside a view that redraws on each one.
///   · and its icon arrived a frame late, which is the flicker he screen-recorded and slowed down.
///
/// ⛔ AND IT IS A RECOGNISER, NOT A `UIControl` — his report, 2026-08-25: "first play voice note
/// won't play at all". THIS IS THE TRAP, AND IT IS WORTH READING BEFORE MOVING ANYTHING ELSE ACROSS.
///
/// A `UIControl` answers TOUCH DELIVERY. Inside a scroll view that is not the same thing as a tap:
/// `delaysContentTouches` holds touchesBegan back from subviews on purpose, and the list runs its
/// own 0.2s long press with `cancelsTouchesInView` left at the default — so a touch that reaches the
/// control can still be taken away before it becomes `.touchUpInside`, and the first tap on a
/// settling list is exactly the one that loses.
///
/// A UIGestureRecognizer is not delayed and is not cancelled that way; it negotiates with the list's
/// recognisers as a peer. The SwiftUI `onTapGesture` this replaced was one, which is why it worked,
/// and the waveform beside it is one, which is why the waveform never had this bug.
///
/// So the disc keeps its own drawing and its own touch, and takes them the way the rest of this
/// screen does.
///
/// ⚠️ THE PLAY STATE IS STILL PASSED IN, NOT OWNED HERE. That is deliberate and it is step two.
/// `VoiceMessageView` already resolves `playing` and `loading` correctly, including the half-second
/// hold that stops the engine's settling publishes flicking the icon; moving state ownership AND the
/// drawing in one go would leave nothing to bisect if the feel is wrong. This step changes who owns
/// the TOUCH and the PIXELS, nothing else.
final class VoicePlayDiscControl: UIView {

    var discTint: UIColor = .label {
        didSet { if discTint != oldValue { setNeedsDisplay() } }
    }

    /// Pause glyph when true, play glyph when false.
    var showsPause: Bool = false {
        didSet { if showsPause != oldValue { setNeedsDisplay() } }
    }

    var isBusy: Bool = false {
        didSet {
            guard isBusy != oldValue else { return }
            if isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
            spinner.isHidden = !isBusy
            setNeedsDisplay()
        }
    }

    var onTap: () -> Void = {}

    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // ⚠️ CLEAR AND NON-OPAQUE, OR THE GLYPH CANNOT BE CUT OUT. `draw` punches the play/pause
        // shape THROUGH the disc so the bubble behind shows in it — the same trick the SwiftUI
        // version used with `destinationOut` inside a compositing group, and the reason neither
        // version needs to be told what colour the bubble is (it can be a gradient).
        backgroundColor = .clear
        isOpaque = false
        spinner.hidesWhenStopped = true
        spinner.isHidden = true
        addSubview(spinner)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    @objc private func tapped() { onTap() }

    /// Black on a light disc, white on a dark one. Resolved against the view's own traits so it
    /// answers correctly in both appearances.
    private static func contrasting(with colour: UIColor) -> UIColor {
        var white: CGFloat = 0, alpha: CGFloat = 0
        guard colour.getWhite(&white, alpha: &alpha) else { return .black }
        return white > 0.6 ? .black : .white
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let side = min(rect.width, rect.height)
        let circle = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)

        // Loading: the faint disc the spinner sits on, and no glyph — the same two states the
        // SwiftUI version drew.
        guard !isBusy else {
            ctx.setFillColor(discTint.withAlphaComponent(0.22).cgColor)
            ctx.fillEllipse(in: circle)
            return
        }

        ctx.setFillColor(discTint.cgColor)
        ctx.fillEllipse(in: circle)

        // ⚠️ NO ANIMATION ON THE SWAP, and that is a decision with history: a symbol-effect bounce
        // was tried in the SwiftUI version and he read the travelling icon as LAG. The glyph changes
        // between frames or not at all.
        // ⛔ THE GLYPH IS PAINTED, NOT PUNCHED — his report, 2026-08-26: in light mode the play
        // icon cannot be seen at all, the disc is a solid black circle.
        //
        // This used to draw with `.destinationOut` so the bubble showed through the play shape, on
        // the theory that a hole needs to know nothing about the bubble's colour and therefore
        // survives gradients and wallpaper. In this hierarchy the erase does not reveal the bubble;
        // it comes out black. On a WHITE disc (dark mode, or any bubble I sent) a black triangle is
        // exactly right, which is why this shipped and looked correct — and on a BLACK disc (an
        // incoming bubble in light mode, where the tint is `.label`) it is black on black.
        //
        // Painted in the disc's own opposite instead: the contrast is guaranteed for any tint, on
        // any bubble, with no knowledge of what is behind it.
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        guard let glyph = UIImage(systemName: showsPause ? "pause.fill" : "play.fill",
                                  withConfiguration: config)?
            .withTintColor(Self.contrasting(with: discTint), renderingMode: .alwaysOriginal) else { return }

        glyph.draw(in: CGRect(x: circle.midX - glyph.size.width / 2,
                              y: circle.midY - glyph.size.height / 2,
                              width: glyph.size.width, height: glyph.size.height))
    }
}

extension VoicePlayDiscControl: UIGestureRecognizerDelegate {
    /// Coexist with the list's long press and its scroll pan, exactly as the waveform does. Refusing
    /// simultaneity here would put this tap back in a fight it does not need to win.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The seam. Kept deliberately thin: the bubble's layout, its bubble chrome, its context menu and its
/// reply swipe all stay exactly where they are, and only the disc inside them changes hands.
struct VoicePlayDisc: UIViewRepresentable {
    let playing: Bool
    let loading: Bool
    let tint: Color
    let onTap: () -> Void

    func makeUIView(context: Context) -> VoicePlayDiscControl {
        let v = VoicePlayDiscControl()
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateUIView(_ v: VoicePlayDiscControl, context: Context) {
        v.discTint = UIColor(tint)
        v.showsPause = playing
        v.isBusy = loading
        // Re-set every pass on purpose: the closure captures the current view's state, and a stale
        // one would toggle the wrong note after a cell is recycled.
        v.onTap = onTap
    }
}
