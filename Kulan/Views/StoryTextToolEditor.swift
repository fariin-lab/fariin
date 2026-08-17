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

    init(value: StoryTextColorValue) {
        self.value = value
        super.init(frame: .zero)

        // The teardrop is drawn outside this control's own bounds.
        clipsToBounds = false

        barImageView.image = Self.gradientImage()
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
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.thumbSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        barImageView.frame = CGRect(x: 0, y: (bounds.height - Metrics.barHeight) / 2,
                                    width: bounds.width, height: Metrics.barHeight)
        barImageView.layer.cornerRadius = Metrics.barHeight / 2

        let x = barImageView.frame.minX + barImageView.frame.width * min(1, max(0, value.phase))
        thumb.bounds = CGRect(x: 0, y: 0, width: Metrics.thumbSize, height: Metrics.thumbSize)
        thumb.center = CGPoint(x: x, y: bounds.midY)

        preview.bounds = CGRect(x: 0, y: 0,
                                width: StoryColorPreviewView.boxSize, height: StoryColorPreviewView.boxSize)
        preview.center = CGPoint(x: x,
                                 y: barImageView.frame.minY - Metrics.previewGap - StoryColorPreviewView.boxSize / 2)
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

        // Only `x` matters — theirs says the same, and for the same reason: the bar is 16pt tall and
        // a finger is not.
        let width = barImageView.bounds.width
        guard width > 0 else { return }
        let x = gesture.location(in: barImageView).x
        value = StoryTextColorValue.value(atPhase: min(1, max(0, x / width)))
        sendActions(for: .valueChanged)
    }

    private static func gradientImage() -> UIImage {
        let size = CGSize(width: 512, height: Metrics.barHeight)
        let colors = StoryTextColorValue.gradient.map { $0.cgColor }
        return UIGraphicsImageRenderer(size: size).image { ctx in
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors as CFArray, locations: nil) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: size.width, y: 0), options: [])
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

/// Their `TextStylingToolbar`, with our three style controls in place of their two. One horizontal
/// stack — style buttons on a glass panel, the colour bar, Done — installed as the text view's
/// `inputAccessoryView`.
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
    var alignment: TextAlignment { didSet { updateAlignButton() } }
    var background: TextOverlay.BgStyle { didSet { updateBackgroundButton() } }

    var colorValue: StoryTextColorValue {
        get { colorPickerBar.value }
        set { colorPickerBar.value = newValue }
    }

    /// One callback per thing that can change, rather than a delegate: this bar has exactly one owner
    /// and it lives ten lines away.
    var onStyleChange: (() -> Void)?
    var onColorChange: (() -> Void)?
    var onDone: (() -> Void)?

    private let fontButton = UIButton(configuration: .plain())
    private let alignButton = UIButton(configuration: .plain())
    private let backgroundButton = UIButton(configuration: .plain())
    private let doneButton = UIButton(configuration: .glass())
    private let colorPickerBar: StoryTextColorPickerBar
    private let glassPanel = UIVisualEffectView(effect: {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
    }())
    private let stack = UIStackView()

    init(fontStyle: TextOverlay.FontStyle,
         alignment: TextAlignment,
         background: TextOverlay.BgStyle,
         color: StoryTextColorValue) {
        self.fontStyle = fontStyle
        self.alignment = alignment
        self.background = background
        self.colorPickerBar = StoryTextColorPickerBar(value: color)

        super.init(frame: .zero)

        // ⚠️ `flexibleHeight` + an overridden `intrinsicContentSize` is what an accessory view needs to
        // be measured at all; without it UIKit gives it whatever height it was created with.
        autoresizingMask = [.flexibleHeight]
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: Metrics.hMargin,
                                                           bottom: 0, trailing: Metrics.hMargin)

        for button in [fontButton, alignButton, backgroundButton, doneButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.configuration?.cornerStyle = .capsule
            button.configuration?.baseForegroundColor = .white
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
                button.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),
            ])
        }

        let panelStack = UIStackView(arrangedSubviews: [fontButton, alignButton, backgroundButton])
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

        colorPickerBar.translatesAutoresizingMaskIntoConstraints = false
        // The bar is the one thing in the row that gives: the four controls beside it are fixed 44pt
        // squares, so it takes whatever width is left.
        colorPickerBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        colorPickerBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        colorPickerBar.addAction(UIAction { [weak self] _ in self?.onColorChange?() }, for: .valueChanged)

        fontButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.fontStyle = self.fontStyle.next()
            self.onStyleChange?()
        }, for: .primaryActionTriggered)

        alignButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.alignment = self.alignment.storyNext()
            self.onStyleChange?()
        }, for: .primaryActionTriggered)

        backgroundButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.background = self.background.next()
            self.onStyleChange?()
        }, for: .primaryActionTriggered)

        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() },
                             for: .primaryActionTriggered)

        stack.addArrangedSubview(glassPanel)
        stack.addArrangedSubview(colorPickerBar)
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
        updateAlignButton()
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
    private func updateFontButton() {
        // Built through `NSAttributedString` rather than an `AttributeContainer`: with both SwiftUI
        // and UIKit in scope, `container.font` is ambiguous between `Font` and `UIFont`.
        let attributed = NSAttributedString(string: "Aa", attributes: [
            .font: StoryTextToolFonts.font(for: fontStyle, size: 17),
            .foregroundColor: UIColor.white,
        ])
        fontButton.configuration?.attributedTitle = AttributedString(attributed)
    }

    private func updateAlignButton() {
        let name = switch alignment {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        default: "text.alignright"
        }
        alignButton.configuration?.image = UIImage(systemName: name,
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
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
    func storyNext() -> TextAlignment {
        switch self {
        case .leading: .center
        case .center: .trailing
        case .trailing: .leading
        }
    }

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
                                                background: overlay.background,
                                                color: StoryTextColorValue(color: UIColor(overlay.color),
                                                                           phase: overlay.colorPhase))

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
        toolbar.onColorChange = { [weak self] in self?.styleDidChange() }
        toolbar.onDone = { [weak self] in self?.finishTextEditing() }

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
        textView.becomeFirstResponder()
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

        badge.bounds = CGRect(x: 0, y: 0, width: badgeWidth, height: badgeHeight)
        badge.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        badge.layer.cornerRadius = overlay.background == .plain ? 0 : 10 * s

        // ⚠️ `frame`, NOT `bounds` + `center`, AND THE DIFFERENCE IS NOT STYLE. A `UITextView` is a
        // scroll view, and a scroll view's `bounds.origin` IS its `contentOffset` — writing a
        // zero-origin bounds on every layout pass would scroll a long caption back to the top under
        // the person's own finger.
        textView.frame = CGRect(x: (badgeWidth - textWidth) / 2,
                                y: (badgeHeight - textHeight) / 2,
                                width: textWidth, height: textHeight)
    }

    // MARK: Styling

    /// Their `updateTextViewAttributes(using:)`, reading from the same three rules `storyStyledText`
    /// reads from so the editor and the canvas cannot disagree about ink, badge or shadow.
    private func applyTextViewAttributes() {
        let color = toolbar.colorValue.color
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
        return !(touched === badge || touched.isDescendant(of: badge))
    }

    // MARK: Finishing

    /// MECHANISM 4. Done is `resignFirstResponder` and nothing else — the work happens off the end of
    /// editing, in `textViewDidEndEditing`, which is the one moment when the editing layout is still
    /// the layout and the keyboard has not yet begun taking the words with it.
    private func finishTextEditing() {
        guard !finished, textView.isFirstResponder else { return }
        textView.acceptAutocorrectSuggestion()
        textView.resignFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        layoutBlock()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
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
        overlay.color = Color(uiColor: toolbar.colorValue.color)
        overlay.colorPhase = toolbar.colorValue.phase
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
