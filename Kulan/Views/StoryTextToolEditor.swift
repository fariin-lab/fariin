//
//  StoryTextToolEditor.swift
//  The Aa tool on a story photo or clip.
//
//  ⚠️ THIS IS A PORT, NOT A DESIGN. Every mechanism below was read out of the reference app's
//  image-editor text mode (`ImageEditorViewController+Text`, `MediaTextView`, `ColorPickerBar`) on
//  2026-08-17, and the parts that are ours are marked as ours with the reason.
//
//  THE FOUR MECHANISMS, and what each one answers:
//
//  1. THE BAR IS THE KEYBOARD'S OWN `inputAccessoryView`.
//
//         textView.inputAccessoryView = textViewAccessoryToolbar
//
//     Not a view timed against the keyboard, not a SwiftUI keyboard toolbar — the accessory view IS
//     part of the keyboard, so it cannot lead it, lag it, or fail to appear. Everything a caption
//     needs (the font, the alignment, the badge, the colours, Done) lives on it.
//
//  2. THE EDITING AREA IS BOUNDED BY THE KEYBOARD, AND THE WORDS ARE CENTRED IN WHAT IS LEFT.
//
//         textViewContainer.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
//         textViewWrapperView.autoVCenterInSuperview()
//
//     That is the whole of "centre the text": the container is the screen above the keyboard and the
//     block sits in the middle of it. Nothing measures a keyboard height by hand.
//
//  3. THE DIM RUNS 300pt PAST THE BOTTOM. Their comment says why, and it is the honest reason:
//     "animations of textViewContainer.frame don't match animations of the keyboard and non-dimmed
//     area was showing in between the bottom edge of textViewContainer and the top of keyboard."
//     They do not chase the keyboard with a curve. They make the gap impossible to see.
//
//  4. DONE MEANS `resignFirstResponder`, AND THE POSITION IS TAKEN OFF THE END OF EDITING.
//
//         let locationInView = view.convert(textView.bounds.center, from: textView).clamp(view.bounds)
//         textItem = textItem.with(unitCenter: textCenterImageUnit)
//
//     Their comment: "Ensure continuity of the new text item's location with its apparent location in
//     this text editor." The canvas is told where the words WERE, so there is nothing left to travel
//     and nothing to animate. Only for a text that was never placed — one that has been dragged
//     somewhere has a position its owner chose.
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - A colour picked off a spectrum

/// A colour AND where it sits on the bar. Theirs is the same pair for the same stated reason: "so
/// that we can consistently restore palette view state" — two points on the spectrum can resolve to
/// nearly the same colour, and only the phase can put the thumb back where the finger left it.
struct StoryTextColorValue: Equatable {
    var color: UIColor
    var phase: CGFloat

    static let white = StoryTextColorValue(color: .white, phase: 1)

    /// Their nine stops, in their order. ⚠️ BLACK IS THE LEFT END AND WHITE IS THE RIGHT END, which
    /// is what makes a spectrum usable for a caption: the two colours a photograph needs most are
    /// the two easiest to hit, at the ends of the travel.
    static let gradient: [UIColor] = [
        rgb(0x000000), rgb(0xff5500), rgb(0xffff00),
        rgb(0x00ff00), rgb(0x00ffff), rgb(0x0000ff),
        rgb(0xff00ff), rgb(0xff0000), rgb(0xffffff),
    ]

    static func value(atPhase phase: CGFloat) -> StoryTextColorValue {
        let stops = gradient
        let segments = stops.count - 1
        let p = min(1, max(0, phase))
        let scaled = p * CGFloat(segments)
        var i = Int(scaled)
        if i >= segments { i = segments - 1 }
        if i < 0 { i = 0 }
        return StoryTextColorValue(color: blend(stops[i], stops[i + 1], scaled - CGFloat(i)), phase: p)
    }

    /// Naive RGB interpolation, which is what the bar's own gradient draws — theirs carries a comment
    /// worrying about exactly this ("if CAGradientLayer doesn't do naive RGB color interpolation,
    /// this won't be WYSIWYG"). Ours draws the bar with a device-RGB `CGGradient`, so the colour under
    /// the finger and the colour this returns are computed the same way.
    private static func blend(_ c0: UIColor, _ c1: UIColor, _ t: CGFloat) -> UIColor {
        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        c0.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        return UIColor(red: r0 + (r1 - r0) * t, green: g0 + (g1 - g0) * t,
                       blue: b0 + (b1 - b0) * t, alpha: a0 + (a1 - a0) * t)
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// MARK: - The most permissive recogniser possible

/// Theirs, verbatim in behaviour: accepts any number of touches anywhere, is blocked by nothing and
/// blocks everything. It is what lets the colour bar be grabbed anywhere along its length and
/// dragged, rather than tapped stop by stop.
private final class StoryPermissiveGestureRecognizer: UIGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { handle(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { handle(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { handle(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { handle(event) }

    private func handle(_ event: UIEvent) {
        var hasValidTouch = false
        for touch in event.allTouches ?? [] {
            switch touch.phase {
            case .began, .moved, .stationary: hasValidTouch = true
            default: break
            }
        }
        if hasValidTouch {
            switch state {
            case .possible: state = .began
            case .began, .changed: state = .changed
            default: state = .failed
            }
        } else {
            switch state {
            case .began, .changed: state = .ended
            default: state = .failed
            }
        }
    }
}

// MARK: - The teardrop that shows the colour under the finger

/// Theirs, including the arithmetic: two circles joined by their tangents, solved with one `atan2`.
/// It exists because the thumb is under the thumb — the only way to see the colour you are choosing
/// is to draw it somewhere the hand is not.
private final class StoryColorPreviewView: UIView {
    private static let innerRadius: CGFloat = 32
    private static let circleMargin: CGFloat = 3
    private static let teardropTipRadius: CGFloat = 4
    private static let teardropPointiness: CGFloat = 12
    static let boxSize: CGFloat = innerRadius * 4

    var selectedColor: UIColor = .white {
        didSet { circleLayer.fillColor = selectedColor.cgColor }
    }

    private let circleLayer = CAShapeLayer()
    private let teardropLayer = CAShapeLayer()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.boxSize, height: Self.boxSize))
        isUserInteractionEnabled = false
        circleLayer.strokeColor = nil
        teardropLayer.strokeColor = nil
        teardropLayer.fillColor = UIColor.white.cgColor
        circleLayer.fillColor = selectedColor.cgColor
        // Layer order matters — theirs says so, and it does: the white teardrop is the outline the
        // coloured circle sits inside.
        layer.addSublayer(teardropLayer)
        layer.addSublayer(circleLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()

        let outerRadius = Self.innerRadius + Self.circleMargin
        let tipCenter = CGPoint(x: bounds.midX, y: bounds.maxY - Self.teardropTipRadius)
        let circleCenter = CGPoint(x: tipCenter.x,
                                   y: tipCenter.y - (Self.teardropPointiness + Self.innerRadius))

        // The tangent between two circles of known distance and radius: solve the right triangle,
        // then atan2 it.
        let centerDistance = hypot(tipCenter.x - circleCenter.x, tipCenter.y - circleCenter.y)
        let radiusDiff = outerRadius - Self.teardropTipRadius
        let tangentLength = max(0, centerDistance * centerDistance - radiusDiff * radiusDiff).squareRoot()
        let angle = atan2(tangentLength, radiusDiff)
        let startAngle = angle + .pi / 2
        let endAngle = -angle + .pi / 2

        let path = UIBezierPath()
        path.addArc(withCenter: circleCenter, radius: outerRadius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: true)
        path.addArc(withCenter: tipCenter, radius: Self.teardropTipRadius,
                    startAngle: endAngle, endAngle: startAngle, clockwise: true)
        teardropLayer.frame = bounds
        teardropLayer.path = path.cgPath

        let side = Self.innerRadius * 2
        let circleFrame = CGRect(x: circleCenter.x - Self.innerRadius,
                                 y: circleCenter.y - Self.innerRadius,
                                 width: side, height: side)
        circleLayer.frame = bounds
        circleLayer.path = UIBezierPath(ovalIn: circleFrame).cgPath
    }
}

// MARK: - The colour bar

/// Theirs: a 16pt capsule of spectrum with a 24pt thumb on it, driven by the permissive recogniser so
/// one touch can slide the whole way. Laid out by frame rather than by constraints — the thumb's
/// position is a fraction of the bar's own width, which is a number that does not exist until the bar
/// has been laid out, and a constraint constant written from inside `layoutSubviews` is a loop
/// waiting to happen.
final class StoryTextColorPickerBar: UIControl {

    /// ⚠️ VERTICAL IS HIS 2026-08-17 REDESIGN, and it is a deliberate move away from the reference
    /// app, whose bar is horizontal in the keyboard's accessory row. He drew it standing at the left
    /// edge of the picture instead, which is where the story editors he compares us against put it:
    /// the words own the middle of the screen and the colours own the margin.
    ///
    /// White is at the TOP in that drawing, which is phase 1 — so the spectrum is drawn from the
    /// bottom up and the thumb's travel is inverted. Nothing else about the control changes.
    enum Axis { case horizontal, vertical }
    private let axis: Axis

    private enum Metrics {
        static let thumbSize: CGFloat = 24
        static let barHeight: CGFloat = 16
        static let colorCircleSize: CGFloat = 10
        /// Theirs — the preview floats this far above the bar.
        static let previewGap: CGFloat = 24
    }

    var value: StoryTextColorValue {
        didSet {
            thumb.color = value.color
            preview.selectedColor = value.color
            setNeedsLayout()
        }
    }

    var uiColor: UIColor { value.color }

    private let barImageView = UIImageView()
    private let thumb = ThumbView(frame: .zero)
    private let preview = StoryColorPreviewView()

    init(value: StoryTextColorValue, axis: Axis = .horizontal) {
        self.value = value
        self.axis = axis
        super.init(frame: .zero)

        // The teardrop is drawn outside this control's own bounds.
        clipsToBounds = false

        barImageView.image = Self.gradientImage(for: axis)
        barImageView.clipsToBounds = true
        barImageView.contentMode = .scaleToFill
        addSubview(barImageView)

        thumb.color = value.color
        addSubview(thumb)

        preview.selectedColor = value.color
        preview.isHidden = true
        addSubview(preview)

        addGestureRecognizer(StoryPermissiveGestureRecognizer(target: self, action: #selector(didTouch)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        switch axis {
        case .horizontal: CGSize(width: UIView.noIntrinsicMetric, height: Metrics.thumbSize)
        case .vertical:   CGSize(width: Metrics.thumbSize, height: UIView.noIntrinsicMetric)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let p = min(1, max(0, value.phase))
        thumb.bounds = CGRect(x: 0, y: 0, width: Metrics.thumbSize, height: Metrics.thumbSize)
        preview.bounds = CGRect(x: 0, y: 0,
                                width: StoryColorPreviewView.boxSize, height: StoryColorPreviewView.boxSize)
        switch axis {
        case .horizontal:
            barImageView.frame = CGRect(x: 0, y: (bounds.height - Metrics.barHeight) / 2,
                                        width: bounds.width, height: Metrics.barHeight)
            barImageView.layer.cornerRadius = Metrics.barHeight / 2
            let x = barImageView.frame.minX + barImageView.frame.width * p
            thumb.center = CGPoint(x: x, y: bounds.midY)
            preview.transform = .identity
            preview.center = CGPoint(x: x,
                                     y: barImageView.frame.minY - Metrics.previewGap - StoryColorPreviewView.boxSize / 2)
        case .vertical:
            barImageView.frame = CGRect(x: (bounds.width - Metrics.barHeight) / 2, y: 0,
                                        width: Metrics.barHeight, height: bounds.height)
            barImageView.layer.cornerRadius = Metrics.barHeight / 2
            // Phase 1 is WHITE and white is at the top, so the travel runs the other way.
            let y = barImageView.frame.minY + barImageView.frame.height * (1 - p)
            thumb.center = CGPoint(x: bounds.midX, y: y)
            // The teardrop's tip points down as drawn; a quarter turn clockwise points it left, at
            // the bar it belongs to, and the preview floats out to the right where the hand is not.
            preview.transform = CGAffineTransform(rotationAngle: .pi / 2)
            preview.center = CGPoint(x: barImageView.frame.maxX + Metrics.previewGap + StoryColorPreviewView.boxSize / 2,
                                     y: y)
        }
    }

    @objc private func didTouch(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            preview.isHidden = false
        case .ended:
            preview.isHidden = true
        default:
            preview.isHidden = true
            return
        }

        // Only the axis the bar runs along matters — theirs says the same, and for the same reason:
        // the bar is 16pt across and a finger is not.
        let point = gesture.location(in: barImageView)
        let phase: CGFloat
        switch axis {
        case .horizontal:
            guard barImageView.bounds.width > 0 else { return }
            phase = point.x / barImageView.bounds.width
        case .vertical:
            guard barImageView.bounds.height > 0 else { return }
            phase = 1 - point.y / barImageView.bounds.height
        }
        value = StoryTextColorValue.value(atPhase: min(1, max(0, phase)))
        sendActions(for: .valueChanged)
    }

    private static func gradientImage(for axis: Axis) -> UIImage {
        let long: CGFloat = 512
        let size = axis == .horizontal ? CGSize(width: long, height: Metrics.barHeight)
                                       : CGSize(width: Metrics.barHeight, height: long)
        let colors = StoryTextColorValue.gradient.map { $0.cgColor }
        return UIGraphicsImageRenderer(size: size).image { ctx in
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors as CFArray, locations: nil) else { return }
            // Vertical runs bottom to top, so stop 0 (black) is at the foot and stop 8 (white) at the
            // head — which is the way round he drew it.
            let start = axis == .horizontal ? CGPoint.zero : CGPoint(x: 0, y: size.height)
            let end = axis == .horizontal ? CGPoint(x: size.width, y: 0) : CGPoint.zero
            ctx.cgContext.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
    }

    /// Theirs: a glass capsule with the chosen colour as a 10pt dot inside it.
    private final class ThumbView: UIView {
        var color: UIColor = .white {
            didSet { dot.backgroundColor = color }
        }

        private let dot = UIView()
        private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            glass.clipsToBounds = true
            addSubview(glass)
            dot.backgroundColor = color
            dot.clipsToBounds = true
            glass.contentView.addSubview(dot)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            glass.frame = bounds
            glass.layer.cornerRadius = min(bounds.width, bounds.height) / 2
            dot.bounds = CGRect(x: 0, y: 0, width: Metrics.colorCircleSize, height: Metrics.colorCircleSize)
            dot.center = CGPoint(x: glass.bounds.midX, y: glass.bounds.midY)
            dot.layer.cornerRadius = Metrics.colorCircleSize / 2
        }
    }
}

// MARK: - The bar that rides the keyboard

/// The reference app's `TextStylingToolbar`. One horizontal stack — the two style buttons on a glass
/// panel at the leading edge, Done at the trailing one — installed as the text view's
/// `inputAccessoryView`. (The colour bar left this row for the picture's left margin, and the
/// alignment button was removed outright; both are his 2026-08-17 calls.)
final class StoryTextToolbar: UIControl {

    /// Theirs: 44pt round controls, and on iOS 26 the leading buttons share ONE glass panel instead of
    /// wearing a glass background each.
    private enum Metrics {
        static let buttonSize: CGFloat = 44
        static let stackSpacing: CGFloat = 20
        static let panelSpacing: CGFloat = 8
        static let hMargin: CGFloat = 16
    }

    var fontStyle: TextOverlay.FontStyle { didSet { updateFontButton() } }
    /// ⚠️ NO LONGER A CONTROL — HIS 2026-08-17 CALL, "remove Text Alignment Button". It stays as a
    /// value because the editor and the canvas both lay the words out against it; it is simply the
    /// one the caption was created with (centre) for the whole session now, so nothing downstream
    /// changes. A `let`, so it cannot be quietly turned back into a control by an assignment.
    let alignment: TextAlignment
    var background: TextOverlay.BgStyle { didSet { updateBackgroundButton() } }

    /// One callback per thing that can change, rather than a delegate: this bar has exactly one owner
    /// and it lives ten lines away.
    var onStyleChange: (() -> Void)?
    var onDone: (() -> Void)?

    private let fontButton = UIButton(configuration: .plain())
    private let backgroundButton = UIButton(configuration: .plain())
    private let doneButton = UIButton(configuration: .glass())
    private let glassPanel = UIVisualEffectView(effect: {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
    }())
    private let stack = UIStackView()

    /// ⚠️ NO COLOUR BAR IN HERE ANY MORE — his 2026-08-17 redesign moved it to the left edge of the
    /// picture, standing up, where the story editors he compares us against put it. The reference app
    /// keeps it in this row; he does not want it here. See `StoryTextColorPickerBar.Axis`.
    init(fontStyle: TextOverlay.FontStyle,
         alignment: TextAlignment,
         background: TextOverlay.BgStyle) {
        self.fontStyle = fontStyle
        self.alignment = alignment
        self.background = background

        super.init(frame: .zero)

        // ⚠️ `flexibleHeight` + an overridden `intrinsicContentSize` is what an accessory view needs to
        // be measured at all; without it UIKit gives it whatever height it was created with.
        autoresizingMask = [.flexibleHeight]
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: Metrics.hMargin,
                                                           bottom: 0, trailing: Metrics.hMargin)

        for button in [fontButton, backgroundButton, doneButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.configuration?.cornerStyle = .capsule
            button.configuration?.baseForegroundColor = .white
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
                button.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),
            ])
        }

        let panelStack = UIStackView(arrangedSubviews: [fontButton, backgroundButton])
        panelStack.spacing = Metrics.panelSpacing
        panelStack.alignment = .center
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        glassPanel.clipsToBounds = true
        glassPanel.translatesAutoresizingMaskIntoConstraints = false
        glassPanel.contentView.addSubview(panelStack)
        NSLayoutConstraint.activate([
            panelStack.topAnchor.constraint(equalTo: glassPanel.topAnchor),
            panelStack.leadingAnchor.constraint(equalTo: glassPanel.leadingAnchor),
            panelStack.trailingAnchor.constraint(equalTo: glassPanel.trailingAnchor),
            panelStack.bottomAnchor.constraint(equalTo: glassPanel.bottomAnchor),
        ])

        fontButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.fontStyle = self.fontStyle.next()
            self.onStyleChange?()
        }, for: .primaryActionTriggered)

        backgroundButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.background = self.background.next()
            self.onStyleChange?()
        }, for: .primaryActionTriggered)

        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() },
                             for: .primaryActionTriggered)

        // The tools sit at the leading edge and Done at the trailing one, with nothing but air
        // between them — the shape he drew once the colours left this row.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(glassPanel)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(doneButton)
        stack.alignment = .center
        stack.spacing = Metrics.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        doneButton.configuration?.image = UIImage(systemName: "checkmark",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        updateFontButton()
        updateBackgroundButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// ⚠️ COMPUTED FROM THE NUMBERS, NOT FROM A LAID-OUT FRAME. Theirs reads `stackView.frame.height`,
    /// which is zero the first time UIKit asks — and the first time UIKit asks is when it decides how
    /// tall the accessory view is. A bar measured at two points high is a bar that is not there.
    /// The constraints above say the same thing this arithmetic says: top margin, one 44pt row, 8pt,
    /// and whatever the home indicator needs when there is no keyboard under us.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: directionalLayoutMargins.top + Metrics.buttonSize + 8 + safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassPanel.layer.cornerRadius = min(glassPanel.bounds.height, glassPanel.bounds.width) / 2
    }

    // MARK: The three style buttons

    /// The Aa wears the font it would give you — theirs does the same with a per-style glyph, which is
    /// what makes a cycling button readable: the control IS the preview.
    ///
    /// ⚠️ ONE LINE, AND IT HAD BROKEN INTO TWO — his report, with the button circled: "in story Aa
    /// icon now is like 2 line, fix plz, one line like Aa, not A / a".
    ///
    /// The button is a fixed 44pt square, and a `.plain()` configuration keeps its own content insets
    /// (8pt each side on this metric). That leaves about 28pt for the title, which "Aa" fits at the
    /// system font and does NOT fit in the wider of the cycling styles — so UIKit did what it is
    /// supposed to do with a title that will not fit on one line and wrapped it. The glyph the control
    /// exists to preview was the thing that made it wrap, which is why it looked like a rendering bug
    /// rather than a layout one.
    ///
    /// Both halves are said explicitly: the insets go, so the title has the whole 44pt, and the line
    /// break mode is clipping, so a style wider even than that is trimmed at the edges instead of
    /// folding in half. Nothing about the size, the spacing or the font changes.
    private func updateFontButton() {
        // Built through `NSAttributedString` rather than an `AttributeContainer`: with both SwiftUI
        // and UIKit in scope, `container.font` is ambiguous between `Font` and `UIFont`.
        let attributed = NSAttributedString(string: "Aa", attributes: [
            .font: StoryTextToolFonts.font(for: fontStyle, size: 17),
            .foregroundColor: UIColor.white,
        ])
        fontButton.configuration?.attributedTitle = AttributedString(attributed)
        fontButton.configuration?.contentInsets = .zero
        fontButton.configuration?.titleLineBreakMode = .byClipping
        // ⚠️ THE LABEL IS TOLD AS WELL AS THE CONFIGURATION. A configuration-based button rebuilds its
        // label whenever the configuration is updated, and this is re-run on every style change — so
        // the belt is re-applied each time rather than set once at init and lost.
        fontButton.titleLabel?.numberOfLines = 1
    }

    private func updateBackgroundButton() {
        let name = background == .plain ? "a.square" : "a.square.fill"
        backgroundButton.configuration?.image = UIImage(systemName: name,
                                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
    }

}

// MARK: - Fonts

/// One place turns a `TextOverlay.FontStyle` into a `UIFont`, because the editor and the bar's own Aa
/// have to agree and a second copy of this would drift.
enum StoryTextToolFonts {
    static func font(for style: TextOverlay.FontStyle, size: CGFloat) -> UIFont {
        let design: UIFontDescriptor.SystemDesign = switch style {
        case .rounded: .rounded
        case .classic: .default
        case .serif: .serif
        case .mono: .monospaced
        }
        var descriptor = UIFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        if let designed = descriptor.withDesign(design) { descriptor = designed }
        // ⚠️ `withDesign` can drop the weight, and a rounded regular next to a rounded semibold is a
        // visible difference from what `storyStyledText` draws. Ask for it back.
        descriptor = descriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold.rawValue],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension TextOverlay.FontStyle {
    func next() -> TextOverlay.FontStyle {
        let all = TextOverlay.FontStyle.allCases
        guard let i = all.firstIndex(of: self) else { return all[0] }
        return all[(i + 1) % all.count]
    }
}

extension TextOverlay.BgStyle {
    func next() -> TextOverlay.BgStyle {
        switch self {
        case .plain: .semi
        case .semi: .solid
        case .solid: .plain
        }
    }
}

extension TextAlignment {
    /// (`storyNext()` lived here to cycle the alignment button. The button is gone — his call — and a
    /// cycle with nothing to cycle it is a control's stump, so it went with it.)
    var storyNSAlignment: NSTextAlignment {
        switch self {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}

// MARK: - The text view

/// Their `MediaTextView`, minus the parts that only make sense against their renderer.
///
/// ⚠️ `textContainerInset = .zero` IS OURS AND IT REPLACES TWO OF THEIR MAGIC NUMBERS. They leave
/// UIKit's default 8pt vertical inset in place and then pull the badge back over it with
/// `UIEdgeInsets(top: -6, left: 6, bottom: -7, right: 6)`, which their own comment explains as "the
/// best visual match with CATextLayer's bounds". Our canvas draws with a SwiftUI `Text`, which has no
/// such inset — so zeroing it and using `storyStyledText`'s own paddings is what makes the editing
/// badge and the posted badge the same shape. Copying their numbers would mismatch OUR renderer.
private final class StoryToolTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        writingToolsBehavior = .none          // theirs: `disableAiWritingTools()`
        backgroundColor = .clear
        isOpaque = false
        isScrollEnabled = false
        scrollsToTop = false
        textAlignment = .center
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Theirs, and the two lines are the whole of it: nudging the input delegate is what commits a
    /// pending autocorrect suggestion before the field gives up first responder. Without it, tapping
    /// Done with a suggestion in flight posts the word the person did not choose.
    func acceptAutocorrectSuggestion() {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.selectionDidChange(self)
    }
}

// MARK: - The editor

final class StoryTextToolViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {

    /// The working copy. Nothing is written back to the canvas until editing ends — theirs keeps its
    /// edits on the text view and applies them once, in `applyTextEdits`, and doing the same here
    /// keeps a keystroke out of SwiftUI's update path entirely.
    private var overlay: TextOverlay

    /// What `storyStyledText` will be offered on the canvas, in canvas points, BEFORE the overlay's
    /// own scale. See `layoutBlock` for why every metric below is multiplied by that scale.
    private let wrapWidth: CGFloat

    /// The edited overlay, and where its words sat on screen at the instant editing ended.
    var onFinish: ((TextOverlay, CGPoint) -> Void)?

    /// Theirs: `pointSize.clamp(12, 64)` on the pinch.
    private static let minPointSize: CGFloat = 12
    private static let maxPointSize: CGFloat = 64

    private let container = UIView()
    private let dimBackground = UIView()
    private let badge = UIView()
    /// The explicit designated initialiser rather than `StoryToolTextView()` — a `UITextView` subclass
    /// that overrides one designated init has subtle rules about which of the others it still inherits,
    /// and this is not the file to find out in.
    private let textView = StoryToolTextView(frame: .zero, textContainer: nil)
    /// The font the words are currently drawn in, kept because an empty `UITextView` reports a nil
    /// `font` and the empty badge still has to be a line tall.
    private var currentFont: UIFont = .systemFont(ofSize: 34, weight: .semibold)
    private lazy var toolbar = StoryTextToolbar(fontStyle: overlay.font,
                                                alignment: overlay.alignment,
                                                background: overlay.background)
    /// THE COLOURS, STANDING AT THE LEFT EDGE OF THE PICTURE — his 2026-08-17 redesign. It used to be
    /// a horizontal bar inside the keyboard's accessory row, which is where the reference app keeps
    /// it; he drew it here instead, and it belongs to this screen rather than to the keyboard now.
    private lazy var colorBar = StoryTextColorPickerBar(
        value: StoryTextColorValue(color: UIColor(overlay.color), phase: overlay.colorPhase),
        axis: .vertical)

    private var toolbarInstalled = false
    private var didBeginEditing = false
    private var finished = false
    private var pinchStartPointSize: CGFloat = 0

    /// THE SIZE THE WORDS ARE ACTUALLY DRAWN AT ON SCREEN, which is the overlay's base size times its
    /// scale. The canvas draws `storyStyledText` at `baseSize` and then applies `.scaleEffect(scale)`
    /// to the finished block, so the two only agree if the editor multiplies everything — the font,
    /// both paddings, the corner and the wrap width — by that same scale. Anything less and the badge
    /// changes shape the moment Done is pressed.
    private var pointSize: CGFloat
    private var scale: CGFloat { max(0.05, overlay.scale) }

    init(overlay: TextOverlay, wrapWidth: CGFloat) {
        self.overlay = overlay
        self.wrapWidth = max(40, wrapWidth)
        // ⚠️ NOT CLAMPED HERE, ONLY ON THE PINCH — theirs clamps inside `handleTextPinchGesture` and
        // nowhere else. A caption already pinched past 64 on the canvas would otherwise be SHRUNK by
        // the act of opening it for editing, which is the editor taking away a size its owner chose.
        self.pointSize = max(1, overlay.baseSize * max(0.05, overlay.scale))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        // MECHANISM 2. The editing area is the screen above the keyboard, and it is bounded by the
        // keyboard's own layout guide rather than by a height anybody measured.
        container.alpha = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        // MECHANISM 3. The dim runs 300pt past the container's bottom edge, theirs verbatim, because
        // the container's frame animation and the keyboard's are two different animations and the
        // undimmed sliver between them is what you would otherwise see.
        dimBackground.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimBackground.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dimBackground)
        NSLayoutConstraint.activate([
            dimBackground.topAnchor.constraint(equalTo: container.topAnchor),
            dimBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dimBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 300),
        ])

        badge.layer.cornerCurve = .continuous
        container.addSubview(badge)
        badge.addSubview(textView)
        textView.delegate = self
        textView.text = overlay.text
        textView.textAlignment = overlay.alignment.storyNSAlignment

        // Theirs: pinch anywhere in the editing area resizes the words; a tap on the dim finishes.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        container.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapDimmer))
        tap.delegate = self
        container.addGestureRecognizer(tap)

        toolbar.onStyleChange = { [weak self] in self?.styleDidChange() }
        toolbar.onDone = { [weak self] in self?.finishTextEditing() }

        // Above the dim and above the words, because it is the only control on this screen that is
        // not on the keyboard and it has to be reachable while the words are being typed.
        container.addSubview(colorBar)
        colorBar.addAction(UIAction { [weak self] _ in self?.styleDidChange() }, for: .valueChanged)

        applyTextViewAttributes()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // ⚠️ ALSO TRIED HERE, NOT ONLY BEFORE THE FIELD TAKES THE KEYBOARD. The install needs a real
        // width to measure the bar against, and a view hosted by SwiftUI can reach `viewDidAppear`
        // before it has one — in which case the one chance to attach the bar would be spent on a
        // zero-width measurement and the keyboard would come up bare.
        installToolbarIfNeeded()
        layoutBlock()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginTextEditing()
    }

    /// Theirs, in `initializeTextUIIfNecessary`: the bar is measured once and handed to the text view
    /// as its accessory. ⚠️ It has to be installed BEFORE the field becomes first responder — an
    /// accessory view attached to a field that is already up does not appear until the keyboard is
    /// dismissed and raised again.
    private func installToolbarIfNeeded() {
        guard !toolbarInstalled, view.bounds.width > 0 else { return }
        let size = toolbar.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        toolbar.bounds.size = size
        textView.inputAccessoryView = toolbar
        toolbarInstalled = true
        // If the field somehow took the keyboard first, the accessory view is not picked up until it
        // is asked for again. Cheap, and it is the difference between a bar and no bar.
        if textView.isFirstResponder { textView.reloadInputViews() }
    }

    /// Theirs: fade the editing layer in over 0.2s and take the keyboard.
    private func beginTextEditing() {
        guard !didBeginEditing else { return }
        didBeginEditing = true
        installToolbarIfNeeded()
        UIView.animate(withDuration: 0.2) { self.container.alpha = 1 }
        // ⚠️ AND IT IS ASKED TWICE IF THE FIRST ANSWER IS NO. `becomeFirstResponder` RETURNS a Bool
        // and the honest reasons it can be false are all timing — the window not key yet, another
        // responder still resigning, a presentation still settling. One more turn is the standard
        // remedy and costs nothing when the first ask succeeded, which is nearly always. The exit in
        // `finishTextEditing` is what makes a second `false` survivable rather than fatal; this is
        // what makes it rare.
        if !textView.becomeFirstResponder() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished else { return }
                _ = self.textView.becomeFirstResponder()
            }
        }
    }

    /// THE BLOCK, DRAWN THE WAY `storyStyledText` DRAWS IT.
    ///
    /// Theirs does this with constraints — the wrapper vertically centred in the container, the badge
    /// centred in the wrapper, the text view pinned to the badge. Ours does it by frame for one
    /// reason: our badge has to HUG the words the way a SwiftUI `Text` does, and a `UITextView` does
    /// not hug anything. `sizeThatFits` is the same TextKit measurement SwiftUI makes, so the box this
    /// produces is the box the canvas will produce.
    private func layoutBlock() {
        guard container.bounds.width > 1 else { return }

        let s = scale
        let hPad = (overlay.background == .plain ? 6 : 14) * s
        let vPad = (overlay.background == .plain ? 2 : 8) * s
        // The canvas's own wrap width, and never wider than this screen — theirs bounds the wrapper at
        // the container's margins for the same reason. At the sizes a caption is normally written at
        // the canvas figure is the smaller one, so the line breaks here are already the canvas's; only
        // a caption pinched larger than the screen falls back to the screen, and it has nowhere else
        // to go.
        let containerMax = container.bounds.width - 32
        let maxTextWidth = max(8, min(wrapWidth * s, containerMax) - 2 * hPad)

        let fit = textView.sizeThatFits(CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
        // A caret needs somewhere to stand while the field is empty.
        let textWidth = max(6, min(maxTextWidth, ceil(fit.width)))
        var textHeight = max(ceil(fit.height), ceil(currentFont.lineHeight))

        // A caption you cannot see while you are typing it is worse than one that scrolls. Theirs caps
        // the wrapper at the container's margins and leaves the overflow alone; ours hands it to the
        // scroll view the text view already is.
        let availableHeight = max(60, container.bounds.height - 32)
        let shouldScroll = textHeight + 2 * vPad > availableHeight
        if textView.isScrollEnabled != shouldScroll { textView.isScrollEnabled = shouldScroll }
        if shouldScroll { textHeight = availableHeight - 2 * vPad }

        var badgeWidth = textWidth + 2 * hPad
        var badgeHeight = textHeight + 2 * vPad
        if overlay.background != .plain {
            // Theirs: the badge never goes below 36x36, so a one-character caption is still a badge.
            badgeWidth = max(badgeWidth, 36 * s)
            badgeHeight = max(badgeHeight, 36 * s)
        }

        // THE ALIGNMENT MOVES THE BLOCK. The badge HUGS its words, so on a single line there is no
        // slack inside it and aligning the lines to each other shows nothing at all; the band below is
        // the widest the block could ever be — the same wrap width the canvas uses — and leading parks
        // the block against its left edge, trailing against its right, centre where it has always been.
        //
        // ⚠️ NOTHING SETS IT TO ANYTHING BUT CENTRE TODAY: the button that cycled it was removed on his
        // instruction (see `StoryTextToolbar.alignment`). This is kept whole rather than folded away
        // because it is what makes a caption's alignment mean something the day it comes back, and
        // because the value still travels out to the canvas and the post.
        //
        // AND IT SURVIVES DONE WITHOUT TOUCHING THE RENDERER: the editor hands back the BADGE's centre
        // on screen and the canvas draws the badge at that centre, so a block parked left is reported
        // left. `storyStyledText` is byte for byte what it was.
        let blockWidth = maxTextWidth + 2 * hPad
        let bandMinX = container.bounds.midX - blockWidth / 2
        let centreX: CGFloat = switch toolbar.alignment {
        case .leading:  bandMinX + badgeWidth / 2
        case .trailing: bandMinX + blockWidth - badgeWidth / 2
        default:        container.bounds.midX
        }
        badge.bounds = CGRect(x: 0, y: 0, width: badgeWidth, height: badgeHeight)
        badge.center = CGPoint(x: centreX, y: container.bounds.midY)
        badge.layer.cornerRadius = overlay.background == .plain ? 0 : 10 * s

        // ⚠️ `frame`, NOT `bounds` + `center`, AND THE DIFFERENCE IS NOT STYLE. A `UITextView` is a
        // scroll view, and a scroll view's `bounds.origin` IS its `contentOffset` — writing a
        // zero-origin bounds on every layout pass would scroll a long caption back to the top under
        // the person's own finger.
        textView.frame = CGRect(x: (badgeWidth - textWidth) / 2,
                                y: (badgeHeight - textHeight) / 2,
                                width: textWidth, height: textHeight)

        // THE COLOURS, DOWN THE LEFT MARGIN. Vertically centred on the editing area like the words,
        // so the two never argue about the middle of the screen — one owns the centre, one owns the
        // edge. Its length is a share of the area rather than a constant, or it would run off a short
        // screen once the keyboard is up.
        //
        // ⚠️ HIS 2026-08-17 SIZING: SHORTER, AND HARD AGAINST THE EDGE. At 0.34 of the editing area it
        // stood over 200pt tall on his phone and its gutter was 16pt, which is a strip of the picture
        // the width of a thumb spent on a control that is touched for a second at a time. 0.24 and a
        // 4pt gutter keep the same shape at the size he drew — the whole 44pt control is the grab
        // area, so moving it out to the margin costs nothing a finger can feel.
        let barLength = min(180, max(110, container.bounds.height * 0.24))
        colorBar.bounds = CGRect(x: 0, y: 0, width: 44, height: barLength)
        colorBar.center = CGPoint(x: 4 + 22, y: container.bounds.midY)
    }

    // MARK: Styling

    /// Their `updateTextViewAttributes(using:)`, reading from the same three rules `storyStyledText`
    /// reads from so the editor and the canvas cannot disagree about ink, badge or shadow.
    private func applyTextViewAttributes() {
        let color = colorBar.value.color
        let ink: UIColor = overlay.background == .solid
            ? UIColor(storyBadgeInk(on: Color(uiColor: color)))
            : color

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = toolbar.alignment.storyNSAlignment

        currentFont = StoryTextToolFonts.font(for: toolbar.fontStyle, size: pointSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: currentFont,
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ]
        if overlay.background == .plain {
            // `storyStyledText` shadows the plain style and only the plain style.
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 3 * scale
            shadow.shadowOffset = CGSize(width: 0, height: 1 * scale)
            attributes[.shadow] = shadow
        }

        let selection = textView.selectedRange
        let current = textView.text ?? ""
        textView.attributedText = NSAttributedString(string: current, attributes: attributes)
        // ⚠️ Setting `attributedText` moves the caret to the end. Put it back, or changing a colour
        // mid-sentence sends the next character somewhere else.
        if selection.location + selection.length <= current.utf16.count {
            textView.selectedRange = selection
        }
        // This is what makes the NEXT character wear the style too — theirs carries the same line and
        // the same reason.
        textView.typingAttributes = attributes
        textView.tintColor = .white

        let badgeColor: UIColor = switch overlay.background {
        case .plain: .clear
        case .semi: UIColor.black.withAlphaComponent(0.38)
        case .solid: color
        }
        badge.backgroundColor = badgeColor
    }

    private func styleDidChange() {
        overlay.background = toolbar.background
        overlay.alignment = toolbar.alignment
        overlay.font = toolbar.fontStyle
        textView.textAlignment = toolbar.alignment.storyNSAlignment
        applyTextViewAttributes()
        layoutBlock()
    }

    // MARK: Gestures

    /// Theirs: the pinch sets the point size directly, clamped to 12...64. Their custom recogniser
    /// computes `pinchStateLast.distance / pinchStateStart.distance`, which is what
    /// `UIPinchGestureRecognizer.scale` already is.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartPointSize = pointSize
        case .changed, .ended:
            let size = pinchStartPointSize * gesture.scale
            pointSize = min(Self.maxPointSize, max(Self.minPointSize, size))
            applyTextViewAttributes()
            layoutBlock()
        default:
            break
        }
    }

    @objc private func didTapDimmer() {
        finishTextEditing()
    }

    /// ⚠️ ONLY THE DIM ENDS EDITING. Their recogniser sits on the whole container and their handler is
    /// named `didTapDimmerView`, which is the intent; a tap that lands on the words has to reach the
    /// text view and move the caret instead.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        guard let touched = touch.view else { return true }
        if touched === colorBar || touched.isDescendant(of: colorBar) { return false }
        return !(touched === badge || touched.isDescendant(of: badge))
    }

    // MARK: Finishing

    /// MECHANISM 4. Done is `resignFirstResponder` and nothing else — the work happens off the end of
    /// editing, in `textViewDidEndEditing`, which is the one moment when the editing layout is still
    /// the layout and the keyboard has not yet begun taking the words with it.
    /// ⚠️ `textView.isFirstResponder` USED TO BE A GUARD ON THIS AND IT COULD LOCK HIM IN THE APP.
    ///
    /// Theirs carries that guard, and theirs can afford it: their text mode is one state of a screen
    /// that still has its own bottom bar, its ✕ and its ✓ underneath. Ours is a full-screen editor
    /// whose ONLY two exits — the Done button and the tap on the dim — both ran through this function,
    /// and the composer's own ✕ is hidden for as long as `editingID` is set. So a field that never
    /// took the keyboard (a first responder refused, a race with another responder, anything at all)
    /// left every door locked and killing the app as the only way out.
    ///
    /// Ending editing and BEING first responder are two different questions. If the keyboard is up,
    /// hand back through it exactly as before — `resignFirstResponder` is what carries the autocorrect
    /// commit and the keyboard's own dismissal. If it is not, there is nothing to resign and no
    /// `textViewDidEndEditing` will ever arrive, so finish directly. The work is the same either way.
    private func finishTextEditing() {
        guard !finished else { return }
        guard textView.isFirstResponder else {
            completeEditing()
            return
        }
        textView.acceptAutocorrectSuggestion()
        textView.resignFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        layoutBlock()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        completeEditing()
    }

    /// The hand-back, in one place because it has two callers now: the keyboard giving up first
    /// responder, and `finishTextEditing` finding there was no keyboard to give up. See the note
    /// there — an editor with no exit is worse than any of the six bugs this screen was built to fix.
    private func completeEditing() {
        guard !finished else { return }
        finished = true

        // Theirs, in order: read the position, then apply the edits.
        let center = badge.superview.map { $0.convert(badge.center, to: nil) }
            ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)

        applyTextEdits()
        onFinish?(overlay, center)
    }

    /// Their `applyTextEdits`. Everything the bar and the pinch changed is written onto the overlay
    /// here, once.
    private func applyTextEdits() {
        overlay.text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        overlay.font = toolbar.fontStyle
        overlay.alignment = toolbar.alignment
        overlay.background = toolbar.background
        overlay.color = Color(uiColor: colorBar.value.color)
        overlay.colorPhase = colorBar.value.phase
        // The editor owns the size the words are drawn at on screen; the canvas multiplies by the
        // overlay's own scale, so the base size is that screen size divided back out. Their editor
        // writes `textView.font.pointSize` straight onto the item for the same reason — the size you
        // finished with is the size you get.
        overlay.baseSize = pointSize / scale
    }
}

// MARK: - The SwiftUI door

/// ⚠️ `StoryTextEditor` is TAKEN — it is the text-only story composer's field, in
/// `StoryTextComposer.swift`. Two text editors one word apart is the trap this app already has twice
/// (`StoriesRowUIKit` / `StoryRowUIKit`), so this one is named for the tool it belongs to.
struct StoryTextToolEditor: UIViewControllerRepresentable {
    let overlay: TextOverlay
    /// `canvasSize.width * 0.9` — what `TextOverlayView` offers `storyStyledText`.
    let wrapWidth: CGFloat
    var onFinish: (TextOverlay, CGPoint) -> Void

    func makeUIViewController(context: Context) -> StoryTextToolViewController {
        let controller = StoryTextToolViewController(overlay: overlay, wrapWidth: wrapWidth)
        controller.onFinish = onFinish
        return controller
    }

    /// ⚠️ RE-HANDED EVERY UPDATE. A closure installed once captures the View STRUCT COPY it was made
    /// from, which goes stale the moment the parent's state moves — the trap in
    /// [[kulan-preview-row-live-card]].
    func updateUIViewController(_ controller: StoryTextToolViewController, context: Context) {
        controller.onFinish = onFinish
    }
}
