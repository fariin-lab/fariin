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

    /// In SOLID mode this is the disc's fill and the glyph is drawn in its opposite. In BLUR mode
    /// the blur is the fill and this is the GLYPH's colour — see `usesBlur`.
    var discTint: UIColor = .label {
        didSet {
            guard discTint != oldValue else { return }
            updateGlyph()
            setNeedsDisplay()
        }
    }

    /// ⛔ THE DISC IS THE BUBBLE'S BLUR, NOT A COLOUR — owner, 2026-09-02: "play button inside the
    /// voice bubble now is only fixed color… make it every time using blur of the bubble".
    ///
    /// A flat fill cannot answer a bubble that is itself a blur. The incoming bubble stopped being
    /// a colour earlier the same day, so a disc painted at `.label` was the one part of the note
    /// that still had a hardcoded surface, and it read as a sticker on glass.
    ///
    /// ⚠️ THIS IS A BLUR ON A BLUR AND THAT IS THE EFFECT, NOT A BUG. The bubble under it is
    /// already a material; a second one over the same wallpaper lands lighter than the first, which
    /// is exactly the pale disc in his screenshot. It is also why the disc needs no knowledge of
    /// the wallpaper, the chat colour or the theme — a lighter version of whatever it sits on.
    ///
    /// ⚠️ ONLY WHERE THE BUBBLE IS A MATERIAL. On a flat bubble — no wallpaper, or Reduce
    /// Transparency, or any note I sent, which is a solid chat colour — a blur samples a flat
    /// colour and resolves to very nearly that colour, so the disc would disappear into the bubble.
    /// Those keep the solid fill, which is what `MessageRowView` decides from the row's own fill.
    var usesBlur: Bool = false {
        didSet {
            guard usesBlur != oldValue else { return }
            blur.isHidden = !usesBlur
            updateGlyph()
            setNeedsDisplay()
        }
    }

    private let blur: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: Theme.receivedBlurStyle))
        v.isUserInteractionEnabled = false
        v.clipsToBounds = true
        v.isHidden = true
        return v
    }()

    /// Pause glyph when true, play glyph when false.
    var showsPause: Bool = false {
        didSet { if showsPause != oldValue { updateGlyph() } }
    }

    var isBusy: Bool = false {
        didSet {
            guard isBusy != oldValue else { return }
            if isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
            spinner.isHidden = !isBusy
            updateGlyph()
            setNeedsDisplay()
        }
    }

    var onTap: () -> Void = {}

    private let spinner = UIActivityIndicatorView(style: .medium)
    /// ⛔ THE GLYPH IS A SUBVIEW NOW, AND IT HAD TO BECOME ONE. It was painted inside `draw`, which
    /// renders into the view's OWN LAYER — and a layer's contents sit BEHIND its sublayers. The
    /// moment the disc grew a blur subview, a glyph painted in `draw` would have been covered by
    /// it. A sibling above the blur is the only order that works.
    private let glyph = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Clear and non-opaque: in blur mode this view paints nothing at all and the blur subview
        // is the whole disc, so anything opaque here would be a square behind a circle.
        backgroundColor = .clear
        isOpaque = false
        // Order is the whole design: blur at the bottom, glyph over it, spinner over both.
        addSubview(blur)
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        spinner.hidesWhenStopped = true
        spinner.isHidden = true
        addSubview(spinner)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        // ⚠️ SEED IT HERE OR THE FIRST DISC IS BLANK. Every input above is a `didSet` that guards on
        // the value actually changing, and a property's default value never fires its own `didSet` —
        // so a disc configured with exactly the defaults (`discTint` is `.label`, which is what an
        // incoming bubble's tint resolves to) would be asked to change nothing and would draw no
        // mark at all. `draw` used to cover this by rebuilding the glyph on every pass.
        updateGlyph()
        // ⚠️ AND REDO IT ON A THEME FLIP. The tint arriving here is a DYNAMIC colour (the incoming
        // bubble's text colour is white at night and black by day), and a `tintColor` set once is a
        // resolved value that will not follow the phone. UIKit re-runs `draw` by itself for a view
        // that implements it, which is what covered the glyph while it lived in there; a subview's
        // `tintColor` gets no such help.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: VoicePlayDiscControl, _) in
            self.updateGlyph()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The same circle `draw` fills, so the two modes are the same shape in the same place.
        let side = min(bounds.width, bounds.height)
        let circle = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        blur.frame = circle
        blur.layer.cornerRadius = side / 2
        glyph.frame = circle
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The play/pause mark, and the one decision that differs between the two modes.
    ///
    /// ⚠️ SOLID mode draws it in the disc's OPPOSITE, because the disc is a known flat colour and
    /// the mark has to survive it (see the note in `draw`). BLUR mode draws it in `discTint` — the
    /// bubble's own text colour — because the disc is a lighter version of the bubble and whatever
    /// is readable on the bubble is readable on it. Neither mode has to know what the wallpaper is.
    private func updateGlyph() {
        glyph.isHidden = isBusy
        guard !isBusy else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        glyph.image = UIImage(systemName: showsPause ? "pause.fill" : "play.fill",
                              withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
        // ⚠️ RESOLVED AGAINST THIS VIEW'S TRAITS BEFORE IT IS WEIGHED. `contrasting` reads the
        // colour's brightness, and a dynamic colour asked for its brightness outside a drawing pass
        // answers against `UITraitCollection.current`, which during a `didSet` or an initialiser is
        // not reliably this view's. It used to be weighed inside `draw`, where the view's traits are
        // current for free — that free-ness is gone with the glyph, so ask explicitly.
        let resolved = discTint.resolvedColor(with: traitCollection)
        glyph.tintColor = usesBlur ? discTint : Self.contrasting(with: resolved)
    }

    @objc private func tapped() { onTap() }

    /// Black on a light disc, white on a dark one. Resolved against the view's own traits so it
    /// answers correctly in both appearances.
    private static func contrasting(with colour: UIColor) -> UIColor {
        var white: CGFloat = 0, alpha: CGFloat = 0
        guard colour.getWhite(&white, alpha: &alpha) else { return .black }
        return white > 0.6 ? .black : .white
    }

    /// THE DISC'S SURFACE, and only in solid mode. In blur mode the `blur` subview is the surface
    /// and this paints nothing — filling here as well would put a flat colour under a material and
    /// the material would resolve to it, which is the whole thing he asked to be rid of.
    ///
    /// ⚠️ NO ANIMATION ON THE GLYPH SWAP, and that is a decision with history: a symbol-effect
    /// bounce was tried in the SwiftUI version and he read the travelling icon as LAG. The glyph
    /// changes between frames or not at all.
    ///
    /// ⛔ THE GLYPH IS PAINTED, NOT PUNCHED — his report, 2026-08-26: in light mode the play icon
    /// cannot be seen at all, the disc is a solid black circle. It used to draw with
    /// `.destinationOut` so the bubble showed through the play shape, on the theory that a hole
    /// needs to know nothing about the bubble's colour. In this hierarchy the erase does not reveal
    /// the bubble; it comes out black — right on a white disc, black-on-black on a dark one. The
    /// mark is drawn in a real colour instead, which `updateGlyph` chooses.
    override func draw(_ rect: CGRect) {
        guard !usesBlur, let ctx = UIGraphicsGetCurrentContext() else { return }
        let side = min(rect.width, rect.height)
        let circle = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        // Loading: the faint disc the spinner sits on. The glyph hides itself for this state.
        ctx.setFillColor(discTint.withAlphaComponent(isBusy ? 0.22 : 1).cgColor)
        ctx.fillEllipse(in: circle)
    }
}

extension VoicePlayDiscControl: UIGestureRecognizerDelegate {
    /// Coexist with the list's long press and its scroll pan, exactly as the waveform does. Refusing
    /// simultaneity here would put this tap back in a fight it does not need to win.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

