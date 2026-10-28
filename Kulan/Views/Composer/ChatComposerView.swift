import UIKit
import SwiftUI

/// The chat's input bar, in UIKit. See `ChatComposerState` for why and for what SwiftUI still owns.
///
/// LAYOUT IS A PURE FUNCTION OF (bounds, `shown`). `layoutSubviews` computes every frame from the
/// state last applied; a state change runs `refreshAppearance` + `layoutIfNeeded` inside ONE
/// animation block chosen for that moment (the reference app's one-animator-per-moment rule), and
/// a change that alters the bar's height tells the host so SwiftUI can animate the frame on the
/// same clock. Because frames are never set outside `layoutSubviews`, SwiftUI animating the host's
/// frame (keyboard insets, banner growth) and UIKit animating the contents cannot fight: each
/// intermediate bounds is simply laid out.
///
/// EVERY CONTROL IS RESIDENT. Nothing is added or removed for a state change — alpha, transform and
/// frame are the only things that move. The mic's hold gesture therefore always has its view, the
/// text view is never taken out of the tree (which is a resign), and a cross-fade is one alpha
/// going down while another goes up on one clock.
final class ChatComposerView: UIView {

    // MARK: - The SwiftUI numbers, unchanged

    private enum M {
        static let button: CGFloat = 40          // every round button, and the pill's resting height
        static let gap: CGFloat = 8              // "+" → pill and pill → send
        static let pillRadius: CGFloat = 20
        static let fieldInsets = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 0)
        static let fieldFont = UIFont.systemFont(ofSize: 17)
        static let maxLines = 6
        static let inPillSpacing: CGFloat = 3    // field · GIF · mic (owner 2026-08-22: 3, down from 4)
        /// Camera to GIF, centre to centre (owner 2026-10-15: "too much space; use the reference's").
        /// The reference gives each field icon a 32pt slot with no gap between them, so its two icons
        /// stand 32pt apart. Our slots stay 40pt for the finger and simply overlap by the difference.
        static let fieldIconPitch: CGFloat = 32
        static let micTrailing: CGFloat = 4      // the pill's last icon (the GIF) 4pt from its edge
        static let strip: CGFloat = 14           // the locked strip's and hold row's side padding
        static let stripSpacing: CGFloat = 8
        static let holdSpacing: CGFloat = 10
        static let lockLift: CGFloat = 86        // the lock target floats this far above the mic
        static let halo: CGFloat = 78
        static let disc: CGFloat = 56
        static let overlayTrailing: CGFloat = 12 // the old `.padding(.trailing, 12)` on the overlay
        static let toastLift: CGFloat = 8        // the old `.offset(y: -8)` on both toasts
        static let onceBlue = UIColor(red: 0x3D / 255, green: 0xA1 / 255, blue: 0xFD / 255, alpha: 1)
        /// ⛔ THE RECORDING BAR IS 44 — owner 2026-10-15, three pictures: holding, locked and paused
        /// are one 44pt pill each, with the X, the ① and the send INSIDE it (they were round buttons
        /// outside a 40pt strip, and the locked bar said "Cancel" in words).
        static let recordBar: CGFloat = 44
        /// The X and the send inside the recording bar.
        static let stripCircle: CGFloat = 36
        /// The X is smaller than the send (owner 2026-10-15: "make the X 32pt"), on the same centre.
        static let stripX: CGFloat = 32
        static let stripInset: CGFloat = 4
    }

    /// The reference app's own clocks, read from its source (see `refControlSpring` in ThreadView
    /// for the provenance). ONE per moment; which one is used says what is moving.
    private enum Clock {
        case control      // 0.25 / damping 0.645 — the lock, and every control that changes with it
        case recordStart  // 0.14 / 0.9 — the bar flipping into a recording on touch-down
        case review       // 0.28 / 0.85 — pause landing on the review
        case text         // 0.2 ease-in-out — the send button coming as text arrives; banners
        case micExit      // 0.2 ease-out — the big mic leaving (their `lockVoiceMemoUI`)
        case armed        // 0.12 — the lock target hiding when the cancel threshold is crossed

        func run(_ body: @escaping () -> Void, done: ((Bool) -> Void)? = nil) {
            let opts: UIView.AnimationOptions = [.allowUserInteraction, .beginFromCurrentState]
            switch self {
            case .control:
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.645, initialSpringVelocity: 0,
                               options: opts, animations: body, completion: done)
            case .recordStart:
                UIView.animate(withDuration: 0.14, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                               options: opts, animations: body, completion: done)
            case .review:
                UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: opts, animations: body, completion: done)
            case .text:
                UIView.animate(withDuration: 0.2, delay: 0, options: opts.union(.curveEaseInOut), animations: body, completion: done)
            case .micExit:
                UIView.animate(withDuration: 0.2, delay: 0, options: opts.union(.curveEaseOut), animations: body, completion: done)
            case .armed:
                UIView.animate(withDuration: 0.12, delay: 0, options: opts.union(.curveEaseInOut), animations: body, completion: done)
            }
        }

        /// The same curve for SwiftUI, so the host animates the bar's frame on the clock its
        /// contents are moving on.
        var swiftUI: Animation {
            switch self {
            case .control:     return .spring(response: 0.25, dampingFraction: 0.645)
            case .recordStart: return .spring(response: 0.14, dampingFraction: 0.9)
            case .review:      return .spring(response: 0.28, dampingFraction: 0.85)
            case .text:        return .easeInOut(duration: 0.2)
            case .micExit:     return .easeOut(duration: 0.2)
            case .armed:       return .easeInOut(duration: 0.12)
            }
        }
    }

    // MARK: - Wiring

    var actions = ChatComposerActions()
    /// The bar's preferred height changed. The host re-lays out, on `animation` when there is one.
    var onHeightChange: ((Animation?) -> Void)?
    /// The paddings around the bar, written by the controller that places it (`positionBottomBar`)
    /// from the keyboard band — the pad above the pill, the side insets, the gap below. The
    /// overlays (big mic, toasts) are placed against this padded box, where the old SwiftUI
    /// `.overlay`s were aligned.
    var outerInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20) {
        didSet { if outerInsets != oldValue { setNeedsLayout() } }
    }
    private(set) var shown = ChatComposerState()
    /// A focus request that could not be honoured yet (no window, or UIKit refused mid-transition).
    /// Retried on the next `apply` and when the view lands in a window. See `requestFocus`.
    private var pendingFocus: Bool?
    private let recorder: AudioRecorder
    private var lastHeight: CGFloat = M.button
    private var lastMeasuredWidth: CGFloat = 0

    // MARK: - Views

    /// The reference model: the bar paints NOTHING; only the pill controls are glass, merged as one
    /// system by the container so "+" and the pill read as Apple's own bars do.
    private let container: UIVisualEffectView = {
        let e = UIGlassContainerEffect()
        e.spacing = M.gap
        return UIVisualEffectView(effect: e)
    }()
    /// ⛔ 17, NOT 20 — his screenshot, 2026-08-27, with the "+" circled. A plus is a wide thin cross
    /// that reaches its full point size in both directions, so 20 inside a 40pt button crossed half
    /// the circle and read as the heaviest thing at that end of the bar. 17 leaves it room to sit in.
    /// Same correction as the review bar's play glyph, and for the same reason: what a symbol weighs
    /// is not the number you set, it is how much of the box the shape actually reaches.
    // ⛔ ONE GLYPH SIZE FOR EVERY ROUND BUTTON: 17. His screenshot, 2026-08-27, listing send, record
    // again, pause, delete and play as all wrong — the strip was carrying 17, 18, 19 and 20 side by
    // side, and mismatched by a point or two is exactly what reads as "not quite right" without being
    // nameable.
    //
    // ⚠️ 17 IS THEIR RATIO, NOT THEIR NUMBER, AND THE DIFFERENCE IS DELIBERATE. Their controls are
    // 24pt glyphs in a 40pt box (`animationSize = CGSize(square: 24)` for the voice draft's
    // play/pause, `LayoutMetrics.initialTextBoxHeight = 40` for the button) — a ratio of 0.6. Our box
    // is 40 too, so the literal copy is 24. But theirs are drawn OUTLINE assets and ours are FILLED
    // SF Symbols, which carry far more ink at the same point size: he rejected this bar's play glyph
    // at 22 and again at 17 for being too big, and 24 would be heavier than either. 17 is where a
    // filled symbol sits at the weight their 24pt outline does.
    private let plusButton = ChatComposerView.glassButton(symbol: "plus", size: 17, weight: .regular, color: .label)
    private let trashButton = ChatComposerView.glassButton(symbol: "trash.fill", size: 17, weight: .regular, color: .systemRed, bakeColor: true)
    private let sendButton = ChatComposerView.glassButton(symbol: "arrow.up", size: 17, weight: .bold, color: .white, prominent: true)
    // ⛔ NO PAUSE BUTTON HERE — it floats above the bar, and the hosting view never delivers touches
    // to a platform view outside the frame SwiftUI gave it (proven on device, build 682). It lives
    // in `MessageListController.setVoiceControl`, whose view owns that region of the screen.
    private let pill: UIVisualEffectView = {
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = true
        let v = UIVisualEffectView(effect: g)
        v.cornerConfiguration = .uniformCorners(radius: .fixed(M.pillRadius))
        return v
    }()

    // Inside the pill: the banners, then the three resident rows.
    private var bannerViews: [String: ComposerBannerView] = [:]
    private let fieldRow = UIView()
    private let textView = ComposerTextView()
    private let gifButton = IconButton(image: UIImage(named: "ic_gif"), size: CGSize(width: 24, height: 24))
    /// Stickers are off for me here: the sticker slot is empty and the camera takes it.
    private var stickerSlotEmpty = false
    /// ⛔ THE CAMERA LIVES IN THE FIELD — owner 2026-10-15: "remove Camera from the attach sheet,
    /// show the camera in the input bar". Beside the GIF, the same dimmed ink, shown when the GIF is.
    /// His own camera drawing (owner 2026-10-15, SVG), drawn like the GIF icon beside it.
    private let cameraButton = IconButton(image: UIImage(named: "ic_camera_field"), size: CGSize(width: 24, height: 24))
    private let micButton = AccessibleActivationView()
    /// Drag on the bar grows / shrinks the sticker panel while it is up (see `barPanShouldBegin`).
    private let stickerBarPan = UIPanGestureRecognizer()
    private let stickerBarPanDelegate = StickerBarPanDelegate()
    /// ⛔ THE REFERENCE APP'S OWN MIC AND PLUS — owner, 2026-09-27, both ringed: "use their recording
    /// icon and + icon". Their `mic` and `plus` vectors (`ic_composer_mic`, `ic_composer_plus`), drawn
    /// at their own 24pt, as their composer draws them. The recording disc keeps `ic_mic`.
    private let micGlyph = UIImageView(image: UIImage(named: "ic_composer_mic")?.withRenderingMode(.alwaysTemplate))
    /// ⛔ THE MIC IS ITS OWN BUTTON, NOT SOMETHING INSIDE THE FIELD — owner, 2026-09-11: "make the
    /// voice recording button a separate standalone button, not part of the text input field. Make
    /// it work and look like the + button — as an independent button next to the input field."
    ///
    /// The same glass capsule the "+" is built from, in the trailing slot opposite it. It shares
    /// that slot with `sendButton`: no text, the mic stands there; type, and the mic fades as the
    /// arrow grows into the same centre.
    ///
    /// ⚠️ THE CAPSULE TAKES NO TOUCHES. `micButton` is still the invisible sibling that owns the
    /// hold gesture, for the reason it always was: the recogniser needs a view that is never hidden
    /// or faded mid-hold, and this capsule is hidden the moment the big disc takes over. Moving the
    /// picture does not move the gesture.
    private let micGlass = ChatComposerView.glassPlate()

    private let holdRow = UIView()
    private let holdMic = ChatComposerView.redMic()
    private let holdTimer = ChatComposerView.timerLabel()
    private let holdHint = UIView()
    private let holdChevron = UIImageView(image: UIImage(systemName: "chevron.left",
                                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    private let holdHintLabel = UILabel()

    private let strip = UIView()
    private let stripRecording = UIView()
    private let stripMic = ChatComposerView.redMic()
    private let stripTimer = ChatComposerView.timerLabel()
    private let cancelButton = UIButton(type: .custom)
    private let stripReview = UIView()
    /// 18pt glyph in its 26pt slot (owner 2026-10-15: "make that icon small"); the slot and the 44pt
    /// tap area are unchanged, so nothing else on the bar moves.
    private let playButton = IconButton(image: nil, size: CGSize(width: 18, height: 18))
    private let waveform = ComposerWaveformView()
    private let totalLabel = UILabel()
    private let onceButton = IconButton(image: nil, size: CGSize(width: 24, height: 24))
    /// Inside the locked/paused bar (2026-10-15): the X (cancels, as the bin and "Cancel" did), the
    /// live waveform while recording, and the send.
    private let stripX: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        cfg.baseBackgroundColor = .tertiarySystemFill
        // Owner 2026-10-28: a red trash, not an X (an X read as "cancel" or "close"; this deletes).
        cfg.baseForegroundColor = .systemRed
        cfg.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        // ⛔ TAPS AROUND IT COUNT — owner 2026-10-15: "the X works only when I hit the icon, the touch
        // area is too small". The 32pt circle stays as drawn; its tap area reaches the bar's left
        // end and its full height, and 6pt to the right (the play button starts just after).
        let b = OutsetHitButton(configuration: cfg)
        b.hitOutset = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 6)
        b.accessibilityLabel = "Delete recording"
        return b
    }()
    private let stripSend: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        cfg.baseForegroundColor = .white
        cfg.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        let b = UIButton(configuration: cfg)
        b.accessibilityLabel = "Send voice message"
        return b
    }()
    private let liveWave = LiveLevelsView()
    /// ⛔ PAUSE LIVES IN THE BAR — owner 2026-10-28: the pause / keep-recording control floated over
    /// the chat (`MessageListController.setVoiceControl`, the reference app's stop button where the
    /// lock was). It is a button inside the bar now, just before the send: pause while recording,
    /// the mic to keep recording while paused. Inside the bar, its touches arrive like any other.
    private let stripControl: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        cfg.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.14)
        cfg.baseForegroundColor = .systemBlue
        let b = OutsetHitButton(configuration: cfg)
        b.hitOutset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return b
    }()
    /// A red dot before the timer while recording: the bar is listening.
    private let recDot = UIView()

    // Over the bar, outside its bounds: the big mic and the lock target, and the two toasts.
    private let overlayGroup = UIView()
    private let discGroup = UIView()
    private let pulseWrap = UIView()
    /// ⛔ BLOBS, NOT CIRCLES — owner 2026-10-15: "the recording animation looks ugly, use the
    /// reference's; don't change my size". Same two layers, same sizes and the same level-driven
    /// scale as before; their outline now morphs the way the reference's halo does (`BlobView`).
    private let haloOuter = BlobView()
    private let haloInner = BlobView()
    /// The level the halo shows, eased toward the recorder's (the raw 30Hz level made it jump).
    private var shownLevel: CGFloat = 0
    private let disc = UIView()
    private let discGlyph = UIImageView(image: UIImage(named: "ic_mic")?.withRenderingMode(.alwaysTemplate))
    private let lockTarget: UIVisualEffectView = {
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = true
        let v = UIVisualEffectView(effect: g)
        v.cornerConfiguration = .capsule()
        return v
    }()
    private let lockIcon = UIImageView()
    private let lockChevron = UIImageView(image: UIImage(systemName: "chevron.up",
                                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
    private let holdHintPill = UIView()
    private let holdHintPillLabel = UILabel()
    private let onceToast = NoticePillView()
    // Slow mode: the ring on the send button, the countdown's clock, the tip above send.
    private let slowRing = CAShapeLayer()
    private var slowTimer: Timer?
    private let slowTip = UIView()
    private let slowTipLabel = UILabel()
    private let slowTipArrow = CAShapeLayer()

    private var holdStart: CGPoint?
    private var pillIsCapsule = false
    /// Where a text send left from, in window coordinates: the pill, and the x of its first letter.
    struct TextSendSource { let pill: CGRect; let textX: CGFloat }
    /// The last text send's source and when. The list takes it once (`takeTextSendSource`) to fly
    /// the new bubble out of the field.
    private var lastTextSend: (source: TextSendSource, at: CFTimeInterval)?
    /// The last text send's source, if it was sent within the last second. One use only.
    func takeTextSendSource() -> TextSendSource? {
        defer { lastTextSend = nil }
        guard let s = lastTextSend, CACurrentMediaTime() - s.at < 1.0 else { return nil }
        return s.source
    }
    private var displayLink: CADisplayLink?

    // MARK: - Init

    init(recorder: AudioRecorder) {
        self.recorder = recorder
        super.init(frame: .zero)
        clipsToBounds = false
        backgroundColor = .clear
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(stickerCreated(_:)),
                                               name: StickerCreatorDoor.created, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stickerCreatorClosedWithoutSending),
                                               name: StickerCreatorDoor.closedWithoutSending, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stickerCreatorWillReturn),
                                               name: StickerCreatorDoor.willReturn, object: nil)
        // ⛔ LIGHT ↔ DARK AT ONCE (owner 2026-10-18: "the composer needs a refresh after I change the
        // theme"). The glass views kept the look they were made with until the chat was reopened; a
        // fresh effect is set on every appearance change, and the colours this bar bakes are redone.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: ChatComposerView, _: UITraitCollection) in
            v.reapplyGlassForTheme()
        }
    }

    /// The pill's glass with or without its touch response, keeping its tint.
    private func setPillInteractive(_ on: Bool) {
        let old = pill.effect as? UIGlassEffect
        guard old?.isInteractive != on else { return }
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = on
        g.tintColor = old?.tintColor
        // ⚠️ NIL FIRST (owner 2026-10-27, third report: the paused review bar still glowed under the
        // finger). A glass effect laid over a glass effect kept the old one's touch response; it is
        // only dropped when the effect is cleared, as the theme change already does
        // (`reapplyGlassForTheme`). No animation, so the bar never shows without its glass.
        UIView.performWithoutAnimation {
            pill.effect = nil
            pill.effect = g
        }
    }

    private func reapplyGlassForTheme() {
        for v in [pill, lockTarget] {
            let old = v.effect as? UIGlassEffect
            let g = UIGlassEffect(style: .regular)
            g.isInteractive = old?.isInteractive ?? true
            g.tintColor = old?.tintColor
            v.effect = nil
            v.effect = g
        }
        // The round glass buttons draw their material from their configuration: setting it again
        // makes them resolve it for the new appearance.
        for b in [plusButton, trashButton, sendButton] { b.configuration = b.configuration }
        refreshStatic()
        refreshAppearance()
        setNeedsLayout()
    }

    /// The creator is about to close on a saved sticker: the panel goes on the field now, so the
    /// focus iOS gives back during the close comes up as stickers, never as the text keys.
    @objc private func stickerCreatorWillReturn() {
        guard window != nil, !stickerPanelUp else { return }
        setStickerPanel(true, reload: textView.isFirstResponder)
    }

    /// A sticker was just made from this chat's panel with Send (owner 2026-10-19): it goes into
    /// this chat, and the keys stay down.
    @objc private func stickerCreated(_ n: Notification) {
        guard window != nil, let s = n.object as? Sticker else { return }
        actions.sendSticker(s)
        // iOS can hand the field its focus back during the creator's close; the keys stay down.
        if textView.isFirstResponder { requestFocus(false) }
    }

    /// The creator closed without a send: the panel it was opened from comes back.
    @objc private func stickerCreatorClosedWithoutSending() {
        guard window != nil else { return }
        if !stickerPanelUp { setStickerPanel(true, reload: textView.isFirstResponder) }
        if !textView.isFirstResponder { requestFocus(true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// ⛔ WHERE THE "+" IS, for the attach sheet to grow out of and shrink back into — owner,
    /// 2026-09-28: "I want the attach sheet coming out of that button, and going back into it when I
    /// close, Apple's native iOS 26 animation, not custom". The sheet's zoom is SwiftUI's
    /// (`navigationTransition(.zoom)` in ThreadView), and its source has to be a SwiftUI view; this
    /// bar is UIKit, so ThreadView places an invisible source over the button, at the rect this
    /// answers. Asked at the moment of presenting, not at the tap: with the keyboard up the button
    /// moves down before the sheet opens. Weak, so a closed chat's bar is not kept alive by it.
    @MainActor enum AttachSource {
        fileprivate static weak var button: UIView?
        /// The "+" in window coordinates, or `.zero` when there is no bar on screen.
        static var windowRect: CGRect {
            guard let b = button, b.window != nil else { return .zero }
            return b.convert(b.bounds, to: nil)
        }
        /// Hides the real "+" while the sheet's copy of it is the thing that grows and shrinks
        /// (`AttachSheetController`). ⚠️ A MASK, NOT `alpha`: this bar animates the button's alpha,
        /// transform and `isHidden` for its own states (recording, text-only), and a second writer
        /// of the same property is how the "+" once stayed invisible. Nothing here touches `mask`.
        static func setLifted(_ on: Bool) { button?.mask = on ? UIView() : nil }
    }

    private func build() {
        addSubview(container)
        container.contentView.addSubview(plusButton)
        AttachSource.button = plusButton
        container.contentView.addSubview(trashButton)
        container.contentView.addSubview(pill)
        container.contentView.addSubview(sendButton)
        // ⛔ THE ATTACH BUTTON TAPS BACK — his report, 2026-09-16: "when i click attach button there's
        // not haptic". It had none, and neither does anything else on this bar.
        //
        // ⚠️ PRIMED ON TOUCH-DOWN, FIRED ON THE TAP, which is the rule `Haptics` was written to
        // enforce: the Taptic Engine sleeps between uses, and a generator woken at the moment of the
        // tap costs tens of milliseconds and arrives after the thing it is confirming — or is dropped
        // on a busy frame. Touch-down is the moment the interaction becomes likely, so by touch-up
        // the engine is already awake. `Haptics.impact` re-arms itself afterwards.
        //
        // `.light` because this opens a sheet rather than committing anything. The heavier styles in
        // this app are for things that cannot be taken back.
        plusButton.addAction(UIAction { _ in Haptics.prepare(.light) }, for: .touchDown)
        plusButton.addAction(UIAction { [weak self] _ in
            Haptics.impact(.light)
            self?.actions.attach()
        }, for: .touchUpInside)
        trashButton.addAction(UIAction { [weak self] _ in self?.actions.cancelRecording() }, for: .touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.shown.recordLocked { self.actions.sendRecording() } else {
                // Where the text left from, for the list's send transition — measured before the
                // send clears the field and shrinks the pill. Not for an edit, which moves no bubble.
                if !self.shown.editing, !self.textView.text.isEmpty {
                    let tv = self.textView
                    let lead = tv.textContainerInset.left + tv.textContainer.lineFragmentPadding
                    let source = TextSendSource(pill: self.pill.convert(self.pill.bounds, to: nil),
                                                textX: tv.convert(CGPoint(x: lead, y: 0), to: nil).x)
                    self.lastTextSend = (source, CACurrentMediaTime())
                }
                self.actions.send()
            }
        }, for: .touchUpInside)
        // The field row: text and GIF. ⛔ THE MIC IS NOT INSIDE THE PILL'S GLASS — owner, 2026-08-25,
        // build 681: sliding up to lock, "the blur is following me". Interactive Liquid Glass tracks
        // a touch that begins inside it and follows the finger; the mic lived in the pill's
        // `contentView`, so a hold-and-drag was a touch on the pill as far as its glass was
        // concerned, and the pill lifted and chased the finger up the screen. The mic is a sibling of
        // the pill now, drawn over its slot — the touch never belongs to the glass.
        pill.contentView.addSubview(fieldRow)
        fieldRow.addSubview(textView)
        fieldRow.addSubview(gifButton)
        fieldRow.addSubview(cameraButton)
        // ⛔ THE GLYPH IS IN THE GLASS, THE TOUCH IS NOT — his screenshot, 2026-08-27: "the recording
        // icon is not part of the composer, but the GIF icon is." He is reading it exactly right. The
        // mic was a bare sibling drawn OVER the pill, so it never sat on the pill's material: the
        // chat behind showed through around it while the GIF icon a few points away rode the glass.
        //
        // ⚠️ SUPERSEDED 2026-09-11, AND THE SPLIT IS WHY THE MOVE WAS CHEAP. The note above was
        // about making the mic read as part of the pill; his decision since is the opposite — the
        // mic is a standalone button beside the field, so belonging to the pill is no longer the
        // goal and the material comes from its own capsule instead. Both halves survive unchanged in
        // shape: the GLYPH is parented to `micGlass` rather than to the pill, and the BUTTON is
        // still the empty, invisible sibling over the same slot that owns the hold gesture, so the
        // touch never belongs to the glass and no glass can chase the finger. What is recorded above
        // still holds for anything that tries to put a live control inside the pill.
        container.contentView.addSubview(micGlass)
        micGlass.addSubview(micGlyph)
        container.contentView.addSubview(micButton)
        textView.delegate = self
        // 2026-09-24 decision D-composer-5: pasted pictures, not on a text-only request.
        textView.onPasteImages = { [weak self] imgs in
            guard let self, !self.shown.textOnly else { return false }
            self.actions.pasteImages(imgs)
            return true
        }
        // ⛔ DIMMER THAN THE MIC, AND ONLY THIS ONE (owner 2026-08-22: "GIF icon make it low
        // brightness but don't touch the voice recording icon"). The mic is the button people
        // reach for without looking; the stickers are a browse.
        gifButton.icon.tintColor = UIColor.label.withAlphaComponent(0.55)
        gifButton.accessibilityLabel = "GIF"
        // 2026-10-17: the GIF button opens the sticker panel in the keyboard's place (and, while it
        // is up, shows a keyboard and puts the keys back). The panel's GIFs tab reaches `actions.gif`.
        gifButton.addAction(UIAction { [weak self] _ in self?.toggleStickerPanel() }, for: .touchUpInside)
        StickerPanelHeight.start()
        stickerBarPan.maximumNumberOfTouches = 1
        stickerBarPan.addTarget(self, action: #selector(stickerBarPanned(_:)))
        stickerBarPanDelegate.owner = self
        stickerBarPan.delegate = stickerBarPanDelegate
        addGestureRecognizer(stickerBarPan)
        // A tap in the field while the panel is up brings the keys back, as in the reference app.
        let fieldTap = UITapGestureRecognizer(target: self, action: #selector(fieldTappedForKeys))
        fieldTap.cancelsTouchesInView = false
        fieldTap.delegate = self
        textView.addGestureRecognizer(fieldTap)
        cameraButton.icon.tintColor = UIColor.label.withAlphaComponent(0.55)
        cameraButton.accessibilityLabel = "Camera"
        cameraButton.addAction(UIAction { [weak self] _ in self?.actions.camera() }, for: .touchUpInside)
        micGlyph.contentMode = .scaleAspectFit
        micGlyph.tintColor = .label
        // The glyph draws only — every touch on this slot is the sibling button's. Without this the
        // image view would swallow the hit test before the invisible button above it ever saw it.
        micGlyph.isUserInteractionEnabled = false
        // Instant UIKit hold gesture (minimumPressDuration 0) — fires on touch-down. The view it is
        // on is never hidden or removed while a hold runs, only its glyph fades, so it keeps
        // tracking the drag for the whole gesture.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0
        hold.allowableMovement = .greatestFiniteMagnitude   // never fail on movement — the drag IS the gesture
        hold.cancelsTouchesInView = false
        hold.delegate = self
        micButton.addGestureRecognizer(hold)
        // VoiceOver cannot hold a finger down, so its double-tap goes straight to the locked,
        // hands-free mode rather than the ordinary hold: `holdBegan()` immediately followed by
        // `holdEnded(.zero, false)` is indistinguishable from the quick, unmoved tap that
        // `endHoldRecording` already reads as "lock hands-free" — the same `lockRecording()` a
        // slide onto the lock target reaches, just with no drag involved.
        micButton.accessibilityLabel = "Record voice message"
        micButton.accessibilityTraits = .button
        micButton.onActivate = { [weak self] in
            guard let self else { return false }
            self.actions.holdBegan()
            self.actions.holdEnded(.zero, false)
            return true
        }

        // The hold row: red dot + timer + "‹ slide to cancel".
        pill.contentView.addSubview(holdRow)
        holdRow.isUserInteractionEnabled = false   // becomes true only while a finger is holding
        holdRow.addSubview(holdMic)
        holdRow.addSubview(holdTimer)
        holdRow.addSubview(holdHint)
        holdHint.addSubview(holdChevron)
        // `.center`, or the 12pt chevron is stretched to the row's 40 (owner, build 681: "the arrow
        // icon looks big height").
        holdChevron.contentMode = .center
        holdHint.addSubview(holdHintLabel)
        holdHintLabel.font = .systemFont(ofSize: 15)
        holdHintLabel.text = "Slide to cancel"

        // The locked strip: recording (mic · timer · Cancel · 1) or review (play · wave · time · 1).
        pill.contentView.addSubview(strip)
        strip.addSubview(stripRecording)
        strip.addSubview(stripReview)
        strip.addSubview(onceButton)
        stripRecording.addSubview(stripMic)
        stripRecording.addSubview(stripTimer)
        stripRecording.addSubview(cancelButton)
        // Headline, i.e. 17 semibold — the reference app's locked-state Cancel.
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelButton.setTitleColor(.systemRed, for: .normal)
        cancelButton.setTitleColor(UIColor.systemRed.withAlphaComponent(0.5), for: .highlighted)
        cancelButton.addAction(UIAction { [weak self] _ in self?.actions.cancelRecording() }, for: .touchUpInside)
        stripReview.addSubview(playButton)
        stripReview.addSubview(waveform)
        stripReview.addSubview(totalLabel)
        playButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // The icon answers the finger now; the state that confirms it arrives a beat later.
            let willPlay = !self.shown.previewPlaying
            self.playButton.icon.image = UIImage(systemName: willPlay ? "pause.fill" : "play.fill",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
            self.actions.togglePreview()
        }, for: .touchUpInside)
        waveform.onSeek = { [weak self] pct in self?.actions.seekPreview(pct) }
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        totalLabel.textColor = .secondaryLabel
        onceButton.addAction(UIAction { [weak self] _ in self?.actions.toggleVoiceOnce() }, for: .touchUpInside)
        // 2026-10-15 redesign: X · live waveform · ① · send while recording; X · play · waveform ·
        // time · ① · send while paused. The mic and "Cancel" words of the old locked bar go.
        // ⛔ THE TIMER STAYS — owner 2026-10-16: locked recording showed no minutes. It sits between
        // the X and the live wave, in the paused bar's time style.
        strip.addSubview(stripX)
        strip.addSubview(stripSend)
        strip.addSubview(stripControl)
        stripRecording.addSubview(recDot)
        recDot.backgroundColor = .systemRed
        recDot.layer.cornerRadius = 4
        stripControl.addAction(UIAction { [weak self] _ in self?.actions.pauseOrResumeRecording() }, for: .touchUpInside)
        stripRecording.addSubview(liveWave)
        for v in [stripMic, cancelButton] as [UIView] { v.isHidden = true }
        stripTimer.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        stripTimer.textColor = .secondaryLabel
        stripX.addAction(UIAction { [weak self] _ in self?.actions.cancelRecording() }, for: .touchUpInside)
        stripSend.addAction(UIAction { [weak self] _ in self?.actions.sendRecording() }, for: .touchUpInside)

        // The big mic + lock, drawn over everything and never hit-tested.
        addSubview(overlayGroup)
        overlayGroup.isUserInteractionEnabled = false
        overlayGroup.clipsToBounds = false
        overlayGroup.alpha = 0
        overlayGroup.addSubview(lockTarget)
        lockTarget.contentView.addSubview(lockIcon)
        lockTarget.contentView.addSubview(lockChevron)
        lockIcon.contentMode = .center
        lockChevron.contentMode = .center
        overlayGroup.addSubview(discGroup)
        discGroup.addSubview(pulseWrap)
        pulseWrap.addSubview(haloOuter)
        discGroup.addSubview(haloInner)
        discGroup.addSubview(disc)
        disc.addSubview(discGlyph)
        discGlyph.contentMode = .scaleAspectFit

        // The two toasts above the bar.
        addSubview(holdHintPill)
        holdHintPill.isUserInteractionEnabled = false
        holdHintPill.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        holdHintPill.addSubview(holdHintPillLabel)
        holdHintPillLabel.font = .systemFont(ofSize: 13, weight: .medium)
        holdHintPillLabel.textColor = .white
        holdHintPillLabel.text = "Hold to record, release to send"
        holdHintPill.alpha = 0
        holdHintPill.isHidden = true
        addSubview(onceToast)
        onceToast.isUserInteractionEnabled = false
        onceToast.alpha = 0
        onceToast.isHidden = true
        // Slow mode. The ring rides the send button's own layer, so it comes and goes with it.
        slowRing.fillColor = UIColor.clear.cgColor
        slowRing.lineWidth = 2
        slowRing.lineCap = .round
        slowRing.strokeEnd = 0
        sendButton.layer.addSublayer(slowRing)
        addSubview(slowTip)
        slowTip.isUserInteractionEnabled = false
        let tipColor = UIColor(white: 0.12, alpha: 0.94)
        slowTip.backgroundColor = tipColor
        slowTip.layer.cornerRadius = 12
        slowTip.layer.cornerCurve = .continuous
        slowTipArrow.fillColor = tipColor.cgColor
        slowTip.layer.addSublayer(slowTipArrow)
        slowTip.addSubview(slowTipLabel)
        slowTipLabel.font = .systemFont(ofSize: 14, weight: .medium)
        slowTipLabel.textColor = .white
        slowTipLabel.numberOfLines = 0
        slowTip.alpha = 0
        slowTip.isHidden = true

        refreshStatic()
        refreshAppearance()
    }

    // MARK: - Factories

    /// A 40pt round Liquid Glass button — the "+", the bin and the send. `prominent` is the tinted
    /// glass the send button wears in the chat's own colour.
    private static func glassButton(symbol: String, size: CGFloat, weight: UIImage.SymbolWeight,
                                    color: UIColor, prominent: Bool = false,
                                    bakeColor: Bool = false) -> UIButton {
        var cfg: UIButton.Configuration = prominent ? .prominentGlass() : .glass()
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
        cfg.baseForegroundColor = color
        // ⛔ `bakeColor` TINTS THE GLYPH INTO THE IMAGE instead of leaving it to
        // `baseForegroundColor` — owner, 2026-08-26: "Delete icon make it red", and it was already
        // `.systemRed` here.
        //
        // A glass `UIButton.Configuration` resolves its own foreground style, and on the glass
        // material it wins over the base colour we asked for: the trash came out the same near-black
        // as the "+" beside it. An `.alwaysOriginal` image carries its colour in the bitmap, so
        // there is nothing left for the style to override.
        //
        // ⚠️ OPT-IN, NOT THE DEFAULT. `sendButton.tintColor` is written every state update, and a
        // baked bitmap would ignore it — the send arrow would freeze at whatever colour it was
        // built with. Only a button whose colour never changes may bake it.
        cfg.image = bakeColor ? UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
                              : UIImage(systemName: symbol)
        let b = UIButton(configuration: cfg)
        return b
    }

    /// The "+" button's material with no content of its own, for a control that draws its own glyph.
    /// Used by the mic, whose picture is one of his assets rather than an SF Symbol — handing it to
    /// the configuration would mean scaling a vector to a point size the factory above expresses in
    /// symbol terms, so the glyph stays the image view it has always been and this just puts the
    /// same glass behind it.
    private static func glassPlate() -> UIButton {
        var cfg: UIButton.Configuration = .glass()
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        let b = UIButton(configuration: cfg)
        b.isUserInteractionEnabled = false   // the hold gesture lives on `micButton` above it
        return b
    }

    /// ⛔ 24pt BOX — the reference app draws this mic as a 24×24 image, not a text-sized glyph, so
    /// it reads bigger than the timer beside it. An SF Symbol at 20 fills a 24pt box to about the
    /// same height. Same view in the hold row and the locked strip, so it cannot change size when
    /// the recording locks.
    private static func redMic() -> UIImageView {
        let v = UIImageView(image: UIImage(systemName: "mic.fill",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)))
        v.tintColor = .systemRed
        v.contentMode = .center
        v.addSymbolEffect(.pulse, options: .repeating)   // gentle live pulse
        return v
    }

    /// ⛔ 17 SEMIBOLD, NOT SUBHEADLINE — the reference app's duration label is body-size at semibold
    /// with monospaced digits, and the same label serves both the hold and the locked bar.
    private static func timerLabel() -> UILabel {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        l.textColor = .label
        l.text = "0:00"
        return l
    }

    // MARK: - State in

    /// The whole state, every render. Diffed against `shown`; only what changed moves.
    func apply(_ new: ChatComposerState) {
        let old = shown
        guard new != old else { return }
        shown = new

        // Content that never animates: text, focus, glyphs, tints, the review's data.
        syncText(new, wasFocused: old.focused)
        refreshStatic()
        syncBanners(from: old.banners, to: new.banners)
        // The paused voice review: no liquid response to touch on its bar (owner 2026-10-26, "only
        // this bar"). Interactive glass comes back as the review ends; nothing else changes.
        // 2026-10-27 (owner: "still the liquid effect when I tap play"): every pass, not only on the
        // change. A bar that came up already reviewing (a parked draft adopted on return) never saw
        // the change, so its glass kept the touch response. `setPillInteractive` is a no-op when
        // nothing differs.
        setPillInteractive(!new.reviewing)

        // The one clock for this moment. Ordered by what is structurally largest: the lock owns the
        // bar; a recording starting owns the row; the review owns the strip; text owns the send.
        var clock: Clock?
        if old.recordLocked != new.recordLocked { clock = .control }
        else if old.recordingActive != new.recordingActive { clock = .recordStart }
        else if old.reviewing != new.reviewing { clock = .review }
        else if old.hasText != new.hasText { clock = .text }
        else if old.banners.map(\.id) != new.banners.map(\.id) { clock = .text }

        // A glass view scaled to a dot is still a glass view: unhide before any entrance, hide
        // after any exit, so nothing invisible is left rendering.
        for b in [plusButton, trashButton, sendButton] where targetAlpha(for: b) > 0 { b.isHidden = false }
        // Height: decided up front, told to the host INSIDE the animation block below. The
        // reference app animates its toolbar's height change in one animator and its list follows
        // from within it; ours used to report after the block, and the host then ran a second
        // spring of its own, so a banner faded in on one curve while the frame grew on another
        // (the 2026-08-26 audit). Now the host's constraint, inset and layout writes ride this
        // block, whichever clock it is.
        let h = preferredHeight(forWidth: bounds.width)
        let heightChanged = h != lastHeight
        if heightChanged { lastHeight = h }
        let changes = { [self] in
            refreshAppearance()
            if heightChanged {
                invalidateIntrinsicContentSize()
                onHeightChange?(clock?.swiftUI)
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            for b in [self.plusButton, self.trashButton, self.sendButton] where b.alpha == 0 { b.isHidden = true }
        }
        if let clock { clock.run(changes, done: finish) } else { changes(); finish(true) }

        // Side channels — disjoint views, their own clocks.
        if old.recordingHeld != new.recordingHeld { setOverlay(shown: new.recordingHeld) }
        if old.recordDrag != new.recordDrag || old.recordLocked != new.recordLocked {
            // On lock the drag springs home on the control clock, like the call site's
            // `withAnimation(refControlSpring) { recordDrag = .zero }`; a live finger is 1:1.
            if old.recordLocked != new.recordLocked { Clock.control.run { [self] in applyDrag() } } else { applyDrag() }
        }
        if old.cancelArmed != new.cancelArmed { Clock.armed.run { [self] in refreshArmed() } }
        if old.holdHint != new.holdHint { toast(holdHintPill, on: new.holdHint) }
        if old.voiceOnceToast != new.voiceOnceToast { toast(onceToast, on: new.voiceOnceToast) }
        if old.slowUntil != new.slowUntil || old.slowTotal != new.slowTotal { startSlow() }
        if old.sendTint != new.sendTint { slowRing.strokeColor = new.sendTint.cgColor }
        if old.slowTip != new.slowTip { showSlowTip(new.slowTip) }
        setLive(new.recordingActive)
    }

    // MARK: - Slow mode

    // ⛔ SLOW MODE IN THE BAR, NOT IN AN ALERT (owner 2026-10-27, from the reference app): while a
    // member waits, a ring round the send button runs down to nothing (full at the send, empty when
    // they may send again), and the empty field shows a stopwatch and the time left. A send too soon
    // brings up a small tip pointing at the send button (`slowTip`, set by the chat for 3 s); the
    // text stays in the field. One clock: `slowUntil`, from the chat.

    private func slowLeft() -> Double { shown.slowUntil?.timeIntervalSinceNow ?? 0 }

    private func startSlow() {
        slowTimer?.invalidate(); slowTimer = nil
        slowRing.removeAnimation(forKey: "slow")
        guard slowLeft() > 0, shown.slowTotal > 0 else { endSlow(); return }
        slowRing.strokeColor = shown.sendTint.cgColor
        runSlowRing()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSlow() }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps counting while the list scrolls
        slowTimer = t
        tickSlow()
    }

    /// The ring from what is left now down to nothing, in step with the clock.
    private func runSlowRing() {
        let left = slowLeft()
        guard left > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slowRing.strokeEnd = 0
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = min(1, left / shown.slowTotal)
        a.toValue = 0
        a.duration = left
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        slowRing.add(a, forKey: "slow")
    }

    private func tickSlow() {
        let left = slowLeft()
        guard left > 0 else { endSlow(); return }
        // Back from the background, Core Animation has dropped the run: start it again from now.
        if slowRing.animation(forKey: "slow") == nil { runSlowRing() }
        let n = Int(left.rounded(.up))
        textView.placeholderIcon = "stopwatch"
        textView.placeholder = String(format: "%d:%02d", n / 60, n % 60)
    }

    private func endSlow() {
        slowTimer?.invalidate(); slowTimer = nil
        slowRing.removeAnimation(forKey: "slow")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slowRing.strokeEnd = 0
        CATransaction.commit()
        textView.placeholderIcon = nil
        textView.placeholder = shown.placeholder
    }

    private func showSlowTip(_ text: String?) {
        let v = slowTip
        if let text {
            slowTipLabel.text = text
            setNeedsLayout(); layoutIfNeeded()
            v.isHidden = false
            v.layer.removeAllAnimations()
            v.alpha = 0
            v.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState]) {
                v.alpha = 1
                v.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
                v.alpha = 0
            }, completion: { _ in
                if v.alpha == 0 { v.isHidden = true }
            })
        }
    }

    /// The tip sits above the send button, its arrow pointing down at the button's middle.
    private func layoutSlowTip(width W: CGFloat) {
        let maxW = min(W - 16, 290)
        let ls = slowTipLabel.sizeThatFits(CGSize(width: maxW - 24, height: .greatestFiniteMagnitude))
        let tipW = ceil(ls.width) + 24, tipH = ceil(ls.height) + 16
        let target = convert(sendButton.center, from: sendButton.superview)
        let top = target.y - M.button / 2 - 10 - tipH
        let x = max(8, min(W - 8 - tipW, target.x - tipW / 2))
        // `bounds` and `center`, not `frame`: the tip may be mid-pop with a scale on it.
        slowTip.bounds = CGRect(x: 0, y: 0, width: tipW, height: tipH)
        slowTip.center = CGPoint(x: x + tipW / 2, y: top + tipH / 2)
        slowTipLabel.frame = CGRect(x: 12, y: 8, width: tipW - 24, height: tipH - 16)
        let ax = min(tipW - 16, max(16, target.x - x))
        let p = UIBezierPath()
        p.move(to: CGPoint(x: ax - 7, y: tipH))
        p.addLine(to: CGPoint(x: ax, y: tipH + 7))
        p.addLine(to: CGPoint(x: ax + 7, y: tipH))
        p.close()
        slowTipArrow.path = p.cgPath
    }

    private func syncText(_ s: ChatComposerState, wasFocused: Bool) {
        if textView.text != s.text {
            textView.text = s.text
            // 2026-09-24 decision D-composer-5: a mention inserted mid-text keeps the caret after it.
            if let c = s.caret, c <= (s.text as NSString).length {
                textView.selectedRange = NSRange(location: c, length: 0)
            }
            textView.refreshPlaceholder()
        }
        // The slow-mode countdown owns the placeholder while it runs (`tickSlow`).
        if slowTimer == nil { textView.placeholder = s.placeholder }
        textView.textOnly = s.textOnly
        // ⛔ THE FOCUS FLAG IS A REQUEST, HONOURED WHEN IT CHANGES — NOT A TRUTH TO BE ENFORCED.
        // Owner, builds 693-695: "tap the composer, the keyboard often does not open; several taps
        // before it appears." The field took the tap and became first responder on its own; the
        // delegate reports that a turn later (`textViewDidBeginEditing` → main.async, see there).
        // Inside that same turn the keyboard's willChangeFrame changes `KeyboardWatcher.height`,
        // ThreadView re-renders (the bar's `outerInsets` read it), and `apply` arrived here with
        // the STALE `focused == false`. This used to read the stale flag as an order and resign the
        // field it had just been handed — will-show and will-hide in one run-loop turn, so no
        // keyboard at all. The same shape ran the other way: an interactive dismiss with a stale
        // `true` put the keyboard straight back.
        //
        // So only a CHANGE in the request acts. A flag that merely lags UIKit's truth is left
        // alone; the delegate's report brings the two together a turn later, as designed.
        if s.focused != wasFocused { requestFocus(s.focused) }
        else if let p = pendingFocus { requestFocus(p) }
    }

    /// Honours a focus request now, or keeps it for the next chance: the view has no window yet
    /// (chat opening on a reply), or UIKit refused the responder mid-transition (context menu still
    /// dismissing). A kept request is cleared by the next CHANGE of the flag, so a person who has
    /// since put the keyboard away is never overruled by an old request.
    private func requestFocus(_ on: Bool) {
        pendingFocus = nil
        guard window != nil else { pendingFocus = on; return }
        if on {
            textView.resignRequested = false
            // GIF search holds the keys in its own field; the field comes back when it closes.
            if !textView.isFirstResponder, !gifSearchActive, !textView.becomeFirstResponder() { pendingFocus = true }
        } else {
            if gifSearchActive { endGifSearchNow() }
            if textView.isFirstResponder {
                // OUR resign announces itself, so the guard lets it through — see ComposerTextView.
                textView.resignRequested = true
                textView.resignFirstResponder()
            }
        }
    }

    // ⛔ GIF SEARCH IN THE PANEL — owner 2026-10-18 (5775aae8 restored): the sticker panel grows to full
    // screen and its search field takes the keys. The field lets go on purpose (`onBeginGifSearch`
    // arms the resign), its end-editing is not a close, and the list keeps the keyboard guide where
    // it is (`holdsKeyboardForGifSearch`) until the panel is back at its own height.
    private var gifSearchActive = false
    /// True while GIF search is growing, open, or shrinking back to the panel, so
    /// `MessageListController` keeps the keyboard guide pinned and never drops the composer.
    private(set) var holdsKeyboardForGifSearch = false
    /// The search page is open (its field has the keys), as against growing back down to the panel.
    var gifSearchOpen: Bool { gifSearchActive }

    /// Search closed with no animation (chat leaving, focus taken away): the panel goes with it, so
    /// the next tap in the field brings the keyboard, as after any other close of the panel.
    private func endGifSearchNow() {
        gifSearchActive = false
        holdsKeyboardForGifSearch = false
        (textView.inputView as? StickerKeyboardView)?.tearDownSearchOverlay()
        if stickerPanelUp, !textView.isFirstResponder { setStickerPanel(false, reload: false) }
    }

    /// Everything that is a plain assignment: glyphs, colours, the review's data.
    private func refreshStatic() {
        let s = shown
        let accent = UIColor(Theme.accent(s.dark))
        let onAccent = UIColor(Theme.onAccent(s.dark))

        plusButton.configuration?.image = s.attachBusy ? UIImage(systemName: "ellipsis")
                                                       : UIImage(named: "ic_composer_plus")
        sendButton.configuration?.image = UIImage(systemName: s.editing && !s.recordLocked ? "checkmark" : "arrow.up")
        // ⛔ THE CHAT'S OWN COLOUR, NOT A FIXED BLUE — both sends (text and voice) resolve the same
        // tint, so a chat colour cannot reach one and miss the other.
        sendButton.configuration?.baseBackgroundColor = s.sendTint
        sendButton.tintColor = s.sendTint
        stripSend.configuration?.baseBackgroundColor = s.sendTint

        // ⛔ 14. THE TRAIL IS 22 → 17 → 14, AND HE HAS ASKED TWICE. 22 filled a 26pt box almost edge
        // to edge; 17 was the first cut and he circled it again on 2026-08-27 — still too big.
        //
        // ⚠️ POINT SIZE IS NOT OPTICAL SIZE, WHICH IS WHY 17 STILL READ LARGE. Its neighbours in this
        // strip are the trash at 18, the one-time circle at 20 and the time label at 15 — but every
        // one of those is an OUTLINE or text, and `play.fill` is a solid triangle. A filled glyph
        // carries far more ink at the same point size, so matching the numbers was never going to
        // match the weight. 14 puts it under the text beside it, which is where the eye stops
        // reading it as the loudest thing in a strip whose subject is the waveform.
        playButton.icon.image = UIImage(systemName: s.previewPlaying ? "pause.fill" : "play.fill",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
        // 2026-10-15 picture: a black play and a grey wave, like the rest of the bar's glyphs.
        playButton.icon.tintColor = .label
        playButton.accessibilityLabel = s.previewPlaying ? "Pause preview" : "Play preview"
        var ctl = stripControl.configuration ?? .filled()
        ctl.image = UIImage(systemName: s.reviewing ? "mic.fill" : "pause.fill",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        stripControl.configuration = ctl
        stripControl.accessibilityLabel = s.reviewing ? "Keep recording" : "Pause and listen back"
        waveform.decibels = s.previewDecibels
        waveform.progress = s.previewProgress
        waveform.played = .label
        waveform.unplayed = .secondaryLabel
        onceButton.icon.image = UIImage(systemName: s.voiceOnce ? "1.circle.fill" : "1.circle",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        onceButton.icon.tintColor = s.voiceOnce ? M.onceBlue : .label
        onceButton.accessibilityLabel = s.voiceOnce ? "One-time listen on" : "One-time listen off"

        // The disc is the ACCENT, which is white at night — so the glyph on it is `onAccent`, or
        // it draws nothing on the one control you are watching.
        // The reference's two glass rings: outer 35% and middle 55% strength, each half tint (its
        // `alpha` × `fill`), the rest is the frosted glass itself (`BlobView`).
        haloOuter.color = accent.withAlphaComponent(0.35 * 0.5)
        haloInner.color = accent.withAlphaComponent(0.55 * 0.5)
        disc.backgroundColor = accent
        discGlyph.tintColor = onAccent
        lockIcon.tintColor = .label
        lockChevron.tintColor = .label

        onceToast.configure(symbol: "checkmark.circle.fill", text: "Set to one-time listen",
                            surface: s.noticeSurface, onWallpaper: s.onWallpaper, dark: s.dark)
        refreshArmed()
        refreshTimers()
    }

    /// Alphas and transforms for the current state. Frames are `layoutSubviews`'s.
    private func refreshAppearance() {
        let s = shown
        for b in [plusButton, trashButton, sendButton] {
            let a = targetAlpha(for: b)
            b.alpha = a
            b.transform = a > 0 ? .identity : CGAffineTransform(scaleX: b === trashButton ? 0.6 : 0.1,
                                                                y: b === trashButton ? 0.6 : 0.1)
        }
        fieldRow.alpha = s.recordingActive ? 0 : 1
        // ⛔ NEVER DISABLE THE ANCESTOR OF THE FIRST RESPONDER — owner, 2026-08-25, build 683: "when
        // the keyboard is open and I start recording, the keyboard automatically closes". Nothing
        // asked it to: this line did, by turning off interaction on the view the text view lives in
        // the instant a recording began. The field then resigned, our own delegate reported the
        // resignation as the user's intent, and the flag went false — so it stayed closed. The row
        // is covered by `holdRow` (held) or `strip` (locked) either way, so making the COVER take
        // the taps is all that was ever needed, and it cannot touch focus.
        holdRow.alpha = s.recordingHeld ? 1 : 0
        holdRow.isUserInteractionEnabled = s.recordingHeld
        strip.alpha = s.recordLocked ? 1 : 0
        strip.isUserInteractionEnabled = s.recordLocked
        stripRecording.alpha = s.reviewing ? 0 : 1
        // The red dot breathes while recording (Core Animation, not a SwiftUI repeatForever).
        if s.recordLocked && !s.reviewing && !UIAccessibility.isReduceMotionEnabled {
            if recDot.layer.animation(forKey: "blink") == nil {
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1; blink.toValue = 0.25
                blink.duration = 0.6; blink.autoreverses = true; blink.repeatCount = .infinity
                blink.isRemovedOnCompletion = false
                recDot.layer.add(blink, forKey: "blink")
            }
        } else {
            recDot.layer.removeAnimation(forKey: "blink")
        }
        stripRecording.isUserInteractionEnabled = !s.reviewing
        stripReview.alpha = s.reviewing ? 1 : 0
        stripReview.isUserInteractionEnabled = s.reviewing
        let fieldIcons: CGFloat = (!s.recordingActive && !s.hasText && !s.textOnly) ? 1 : 0
        gifButton.alpha = s.stickersOff ? 0 : fieldIcons
        gifButton.isUserInteractionEnabled = !s.stickersOff
        // Owner 2026-10-23: with stickers off the camera moves into the sticker's slot instead of
        // leaving a hole at the end of the field. Laid out again only when that changes.
        if stickerSlotEmpty != s.stickersOff { stickerSlotEmpty = s.stickersOff; setNeedsLayout() }
        // Gone while the sticker panel is up (owner 2026-10-18), back when it closes.
        cameraButton.alpha = stickerPanelUp ? 0 : fieldIcons
        // The mic sits ABOVE the pill now, so it must go when the locked strip takes the pill (the "1"
        // lives in its slot then). While a finger holds it only the glyph fades — the view stays, so
        // the gesture keeps tracking; a lock ends the gesture, and then the whole button can leave.
        // ⚠️ THE HIDE HAS TO REACH THE GLYPH ITSELF. It used to be a child of the button, so fading
        // the button took the picture with it; it is the pill's child now and would have stayed on
        // screen with text typed or a recording locked. The button keeps its own alpha because that
        // is also what takes it out of the hit test, and the glyph carries both reasons to be gone:
        // the slot is not offered (text / locked), or the hold is running and the red bubble has
        // taken over.
        // ⛔ AND NEVER WHILE AN INLINE EDIT IS OPEN. The slot belongs to the checkmark then, and the
        // mic was appearing in it the moment the field went empty — which is exactly what you do to
        // replace a message: select all, delete, then speak.
        //
        // What that produced: a brand-new voice message appended to the thread, while the edit
        // banner was hidden (it is suppressed during a recording, so nothing was on screen to say an
        // edit was open), and the edit itself then silently abandoned by the empty-text branch of
        // save. Two wrong outcomes and no warning, from one reasonable intention. Nothing on the
        // voice path consults `editingMessage`; the honest fix is not to offer the mic at all.
        // ...and never on a text-only request (`textOnly`): a voice note is not text.
        micButton.alpha = (s.hasText || s.recordLocked || s.editing || s.textOnly) ? 0 : 1
        // VoiceOver should only land on this when it is actually offered — otherwise a double-tap
        // while typing or already locked would start a second recording nothing on screen shows.
        micButton.isAccessibilityElement = micButton.alpha > 0
        // The capsule and its glyph fade as one — the glyph is its subview now.
        // 2026-09-24 decision D-composer-5: `editing` too, as on the button above; the capsule
        // was left drawn as a dead mic when an edit's text was emptied.
        micGlass.alpha = (s.hasText || s.recordLocked || s.recordingHeld || s.textOnly || s.editing) ? 0 : 1
        for (_, v) in bannerViews { v.alpha = s.recordingActive ? 0 : 1 }
    }

    private func targetAlpha(for b: UIButton) -> CGFloat {
        let s = shown
        // No "+" on a text-only request either — see `ChatComposerState.textOnly`.
        if b === plusButton { return (s.recordingActive || s.textOnly) ? 0 : 1 }
        // The bin and the send of a locked recording live INSIDE the bar now (`stripX`, `stripSend`).
        if b === trashButton { return 0 }
        return (s.hasText && !s.recordLocked) ? 1 : 0
    }

    // MARK: - Banners

    private func syncBanners(from old: [ChatComposerBanner], to new: [ChatComposerBanner]) {
        let accent = UIColor.label
        let newIds = Set(new.map(\.id))
        for (id, v) in bannerViews where !newIds.contains(id) {
            bannerViews[id] = nil
            Clock.text.run({ v.alpha = 0 }, done: { _ in v.removeFromSuperview() })
        }
        for b in new {
            if let v = bannerViews[b.id] {
                v.configure(b, accent: accent)
            } else {
                let v = ComposerBannerView()
                v.configure(b, accent: accent)
                v.onClose = { [weak self] in self?.actions.dismissBanner(b.style) }
                v.alpha = 0
                pill.contentView.insertSubview(v, belowSubview: fieldRow)
                bannerViews[b.id] = v
                Clock.text.run { v.alpha = 1 }
            }
        }
    }

    // MARK: - Recording visuals

    private func setOverlay(shown on: Bool) {
        if on {
            // Enters as it was: no entrance of its own ("keep everything else unchanged").
            overlayGroup.layer.removeAllAnimations()
            overlayGroup.alpha = 1
            overlayGroup.transform = .identity
            lockTarget.isHidden = false
            startPulse()
        } else {
            // ⛔ ITS EXIT IS THE ONE THING IN THE LOCK THAT IS NOT ON THE CONTROL SPRING — the
            // reference hands the big circle and the lock chevron to a plain 0.2 that takes them to
            // alpha 0 and scale 0.9. A spring on something disappearing can overshoot, and an
            // overshoot nobody can see the end of just reads as slack.
            Clock.micExit.run({ [self] in
                overlayGroup.alpha = 0
                overlayGroup.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            }, done: { [weak self] _ in
                guard let self, !self.shown.recordingHeld else { return }
                self.stopPulse()
                self.overlayGroup.transform = .identity
            })
        }
    }

    // The fixed 1s "breathing" scale is gone (2026-10-15): the blobs' own morph is the idle motion,
    // as in the reference, and two motions on one halo read as a wobble fighting a pulse.
    private func startPulse() {
        pulseWrap.layer.removeAllAnimations()
        pulseWrap.transform = .identity
        shownLevel = 0
        haloOuter.start()
        haloInner.start()
    }

    private func stopPulse() {
        pulseWrap.layer.removeAllAnimations()
        pulseWrap.transform = .identity
        haloOuter.stop()
        haloInner.stop()
    }

    /// Rubber-band the visual mic offset: 1:1 up to the lock/cancel limit, then diminishing
    /// resistance past it (the UIScrollView overscroll curve) so it feels physical, not hard-clamped.
    /// ThreadView's thresholds read the same function, so what you see is what is measured.
    static func rubberband(_ x: CGFloat, limit: CGFloat, dim: CGFloat = 220, c: CGFloat = 0.55) -> CGFloat {
        guard x < 0 else { return 0 }          // only up/left drags move the mic
        let d = -x
        if d <= limit { return x }
        let over = d - limit
        return -(limit + (1 - 1 / (over * c / dim + 1)) * dim)
    }

    private var clampedDrag: CGSize {
        CGSize(width: Self.rubberband(shown.recordDrag.width, limit: 90),
               height: Self.rubberband(shown.recordDrag.height, limit: 100))
    }

    private var lockProgress: CGFloat { min(1, max(0, -clampedDrag.height / 88)) }

    private func applyDrag() {
        let d = clampedDrag
        discGroup.transform = CGAffineTransform(translationX: d.width, y: d.height)
        let p = lockProgress
        lockIcon.image = UIImage(systemName: p > 0.7 ? "lock.fill" : "lock.open.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        lockChevron.alpha = 1 - p
        lockTarget.transform = CGAffineTransform(scaleX: 0.92 + p * 0.12, y: 0.92 + p * 0.12)
        // Fade the hint as the finger slides toward the cancel threshold.
        holdHint.alpha = 1.0 - min(1.0, -d.width / 90.0) * 0.6
    }

    private func refreshArmed() {
        let armed = shown.cancelArmed
        lockTarget.alpha = armed ? 0 : 1
        let c: UIColor = armed ? .systemRed : .secondaryLabel
        holdChevron.tintColor = c
        holdHintLabel.textColor = c
    }

    // The timer and the halo follow the recorder at 30Hz while a recording exists. A display link
    // rather than observation: the recorder's clock ticks on its own timer and the halo wants a
    // frame-paced read of the metered level, not a re-render per change.
    private func setLive(_ on: Bool) {
        if on, displayLink == nil {
            let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
            refreshTimers()
        } else if !on {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    fileprivate func tick() {
        refreshTimers()
        if shown.recordLocked && !shown.reviewing { liveWave.levels = recorder.levels }
        // Eased toward the recorder's level: up quickly, down slowly, as a VU meter falls.
        let raw = CGFloat(recorder.levels.last ?? 0)
        shownLevel += (raw - shownLevel) * (raw > shownLevel ? 0.45 : 0.15)
        let lvl = shownLevel
        haloOuter.level = lvl
        haloInner.level = lvl
        haloOuter.transform = CGAffineTransform(scaleX: 1.10 + 0.85 * lvl, y: 1.10 + 0.85 * lvl)
        haloInner.transform = CGAffineTransform(scaleX: 1 + 0.40 * lvl, y: 1 + 0.40 * lvl)
    }

    private func refreshTimers() {
        let t = Int(recorder.elapsed)
        let s = String(format: "%d:%02d", t / 60, t % 60)
        if holdTimer.text != s {
            holdTimer.text = s
            stripTimer.text = s
            totalLabel.text = s
            setNeedsLayout()
        }
    }

    private func toast(_ v: UIView, on: Bool) {
        if on {
            v.isHidden = false
            v.layer.removeAllAnimations()
            v.alpha = 0
            v.transform = CGAffineTransform(translationX: 0, y: v.bounds.height)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                v.alpha = 1
                v.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
                v.alpha = 0
                v.transform = CGAffineTransform(translationX: 0, y: v.bounds.height)
            }, completion: { _ in
                if v.alpha == 0 { v.isHidden = true }
            })
        }
    }

    // MARK: - Gesture

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let loc = g.location(in: self)
        let start = holdStart ?? loc
        let t = CGSize(width: loc.x - start.x, height: loc.y - start.y)
        switch g.state {
        case .began:
            holdStart = loc
            actions.holdBegan()
        case .changed:
            actions.holdChanged(t)
        case .ended:
            actions.holdEnded(t, false)
            holdStart = nil
        case .cancelled, .failed:
            actions.holdEnded(t, true)
            holdStart = nil
        default:
            break
        }
    }

    // MARK: - Measurement

    /// The pill's horizontal extent for a bar `width` wide: after "+" (or the bin) and before send.
    private func pillSpan(width: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let s = shown
        let slot = M.button + M.gap
        // A text-only request has no "+", so the pill starts at the edge — the same left the bar
        // already takes while a recording holds the row.
        // A recording takes the whole width, locked or paused too: its X and send are inside it.
        let left: CGFloat = s.textOnly ? 0 : (s.recordingActive ? 0 : slot)
        // ⛔ THE TRAILING SLOT IS NOW ALWAYS RESERVED, not only when there is something to send.
        // The mic moved out of the pill and stands in that slot, so the pill stops at the same place
        // whether the mic or the send arrow is showing — which is also why typing no longer resizes
        // the field: the two swap inside one slot that was already there.
        //
        // The two exceptions are the ones with nothing in that slot: a text-only request has no mic
        // at all, and a hold in flight gives the whole pill to the "slide to cancel" row with the
        // mic invisible over its end.
        //
        // ⚠️ A TEXT-ONLY REQUEST STILL HAS A SEND BUTTON. It took the whole width, and the moment
        // there was text the send arrow appeared in the trailing slot ON TOP of the pill's end (owner
        // screenshot, 2026-09-25, first message to somebody). The slot is kept free whenever send
        // can show; with nothing typed there is nothing in it, so the pill may use it.
        let right: CGFloat
        if s.textOnly { right = s.hasText ? width - slot : width }   // exactly `targetAlpha`'s send rule
        else if s.recordingActive { right = width }
        else { right = width - slot }
        return (left, max(left, right))
    }

    /// The text's own width inside the pill: the whole pill once there is text (or when there is no
    /// GIF and no mic to make room for), else what the GIF and mic leave.
    private func textWidth(pillWidth: CGFloat) -> CGFloat {
        (shown.hasText || shown.textOnly) ? pillWidth
                      // ONE button inside the pill now, not two: the GIF. The mic left.
                      // Two now: the camera beside the GIF (2026-10-15).
                      : pillWidth - M.micTrailing - M.button - M.fieldIconPitch - M.inPillSpacing
    }

    private var maxTextHeight: CGFloat {
        ceil(CGFloat(M.maxLines) * M.fieldFont.lineHeight + M.fieldInsets.top + M.fieldInsets.bottom)
    }

    private func fieldHeight(textWidth: CGFloat) -> CGFloat {
        guard textWidth > 0 else { return M.button }
        let fit = ceil(textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        return max(M.button, min(fit, maxTextHeight))
    }

    /// What the bar wants to be, for the host. Recording is exactly one row; otherwise the banners
    /// over the field, the field growing to six lines.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        if shown.recordingActive { return M.recordBar }
        let span = pillSpan(width: width)
        var h: CGFloat = 0
        for b in shown.banners { h += ComposerBannerView.height(for: b) }
        h += fieldHeight(textWidth: textWidth(pillWidth: span.right - span.left))
        return max(M.button, ceil(h))
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: lastHeight)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = shown
        let W = bounds.width, H = bounds.height
        container.frame = bounds

        // The three round buttons and the pill between them, all bottom-aligned.
        //
        // ⛔ BOUNDS + CENTER, NEVER FRAME — owner, 2026-08-25, build 683: "the send button appears
        // too large first and then shrinks", and grows again on send. These buttons carry a
        // scale(0.1) transform while hidden, and setting `frame` back-computes bounds THROUGH the
        // transform: a 0.1-scaled button asked to occupy 40pt is given 400pt of bounds, which is
        // the giant circle he photographed. `bounds` and `center` are transform-independent, which
        // is exactly why UIKit documents `frame` as undefined when a transform is set.
        let rowY = H - M.button
        let buttonBounds = CGRect(x: 0, y: 0, width: M.button, height: M.button)
        let buttonMidY = rowY + M.button / 2
        plusButton.bounds = buttonBounds
        plusButton.center = CGPoint(x: M.button / 2, y: buttonMidY)
        trashButton.bounds = buttonBounds
        trashButton.center = plusButton.center
        sendButton.bounds = buttonBounds
        sendButton.center = CGPoint(x: W - M.button / 2, y: buttonMidY)
        let span = pillSpan(width: W)
        let pw = span.right - span.left
        pill.frame = CGRect(x: span.left, y: 0, width: pw, height: H)
        // ⛔ ROUND ENDS ON THE 44pt RECORDING BAR — owner 2026-10-15: "you forgot the corners, make
        // them round like the text field". The fixed 20 is a full round end on the 40pt field and
        // not on 44; a recording bar is one row, so it is a true capsule (Apple's own rounding).
        if pillIsCapsule != s.recordingActive {
            pillIsCapsule = s.recordingActive
            pill.cornerConfiguration = s.recordingActive ? .capsule() : .uniformCorners(radius: .fixed(M.pillRadius))
        }

        // Banners pinned to the top of the pill, the field row to its bottom.
        var y: CGFloat = 0
        for b in s.banners {
            guard let v = bannerViews[b.id] else { continue }
            let h = ComposerBannerView.height(for: b)
            v.frame = CGRect(x: 0, y: y, width: pw, height: h)
            y += h
        }
        let tw = textWidth(pillWidth: pw)
        let fh = min(H, fieldHeight(textWidth: tw))
        fieldRow.frame = CGRect(x: 0, y: H - fh, width: pw, height: fh)
        // The mic: the trailing slot, the "+" button's mirror, sharing its centre with send. Bounds
        // and centre rather than frame, for the reason written above the buttons — this one is
        // scaled while the big disc grows out of it.
        micGlass.bounds = buttonBounds
        micGlass.center = CGPoint(x: W - M.button / 2, y: buttonMidY)
        // Inside the capsule now, so its slot is the capsule's own bounds.
        micGlyph.frame = CGRect(x: (M.button - 24) / 2, y: (M.button - 24) / 2, width: 24, height: 24)
        // The invisible gesture view over the same slot, in the container's space.
        micButton.frame = CGRect(x: W - M.button, y: rowY, width: M.button, height: M.button)
        // The GIF is the pill's last slot now that the mic has left it.
        gifButton.frame = CGRect(x: pw - M.micTrailing - M.button, y: fh - M.button,
                                 width: M.button, height: M.button)
        cameraButton.frame = CGRect(x: stickerSlotEmpty ? gifButton.frame.minX : gifButton.frame.minX - M.fieldIconPitch,
                                    y: fh - M.button, width: M.button, height: M.button)
        textView.frame = CGRect(x: 0, y: 0, width: max(0, tw), height: fh)
        let fit = ceil(textView.sizeThatFits(CGSize(width: max(1, tw), height: .greatestFiniteMagnitude)).height)
        // ⛔ A PASTE PAST THE LAST LINE — owner 2026-10-15: pasting a long link, the text ran off the
        // bottom of the field, last line cut in half. The field only becomes scrollable here, during
        // layout, and nothing then scrolled it: it stayed at the top of the text while the caret sat
        // at the end, below the field. When it turns scrollable, bring the caret into view, a turn
        // later so the new frame and content size are in place first. Typing past the last line
        // already worked because UIKit follows the caret of a field that is scrollable while typing.
        let scrolls = fit > maxTextHeight
        if textView.isScrollEnabled != scrolls {
            textView.isScrollEnabled = scrolls
            if scrolls {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    textView.scrollRangeToVisible(textView.selectedRange)
                }
            }
        }

        // The hold row and the strip are the whole 44pt recording pill (`M.recordBar`).
        let rh = s.recordingActive ? H : fh
        holdRow.frame = s.recordingActive ? CGRect(x: 0, y: 0, width: pw, height: H) : fieldRow.frame
        let hx = M.strip
        holdMic.frame = CGRect(x: hx, y: (rh - 24) / 2, width: 24, height: 24)
        let holdTimerW = ceil(holdTimer.intrinsicContentSize.width)
        holdTimer.frame = CGRect(x: holdMic.frame.maxX + M.holdSpacing, y: 0, width: holdTimerW, height: rh)
        // The hint sits CENTRED in what the timer leaves, the way the reference draws it.
        let chevW: CGFloat = 12, hintGap: CGFloat = 3
        let hintLabelW = ceil(holdHintLabel.intrinsicContentSize.width)
        let hintW = chevW + hintGap + hintLabelW
        let hintRoom = CGRect(x: holdTimer.frame.maxX + M.stripSpacing, y: 0,
                              width: pw - M.strip - M.stripSpacing - (holdTimer.frame.maxX + M.stripSpacing), height: rh)
        holdHint.frame = CGRect(x: hintRoom.midX - hintW / 2, y: 0, width: hintW, height: rh)
        holdChevron.frame = CGRect(x: 0, y: 0, width: chevW, height: rh)
        holdHintLabel.frame = CGRect(x: chevW + hintGap, y: 0, width: hintLabelW, height: rh)

        // The locked / paused bar: X · (live wave | play · wave · time) · ① · send, all inside.
        let sh = M.recordBar, c = M.stripCircle, cy = (sh - c) / 2
        strip.frame = CGRect(x: 0, y: H - sh, width: pw, height: sh)
        stripRecording.frame = strip.bounds
        stripReview.frame = strip.bounds
        // 32pt on the old 36pt circle's centre (22pt in): 6pt from the bar's edge all round.
        let xc = M.stripX
        stripX.frame = CGRect(x: M.stripInset + (c - xc) / 2, y: (sh - xc) / 2, width: xc, height: xc)
        stripSend.frame = CGRect(x: pw - M.stripInset - c, y: cy, width: c, height: c)
        let ctlW: CGFloat = 32
        stripControl.frame = CGRect(x: stripSend.frame.minX - 8 - ctlW, y: (sh - ctlW) / 2, width: ctlW, height: ctlW)
        let onceW: CGFloat = 24
        onceButton.frame = CGRect(x: stripControl.frame.minX - 10 - onceW, y: 0, width: onceW, height: sh)
        recDot.frame = CGRect(x: stripX.frame.maxX + 12, y: (sh - 8) / 2, width: 8, height: 8)
        let timerW = ceil(stripTimer.intrinsicContentSize.width)
        stripTimer.frame = CGRect(x: recDot.frame.maxX + 6, y: 0, width: timerW, height: sh)
        liveWave.frame = CGRect(x: stripTimer.frame.maxX + 12, y: (sh - 22) / 2,
                                width: max(0, onceButton.frame.minX - 12 - (stripTimer.frame.maxX + 12)), height: 22)
        // ⛔ A 44pt TARGET — owner 2026-10-15: "play / pause lags, the button doesn't work well". The
        // control was the 26pt icon box, so a tap a little off it went to nothing. The icon stays
        // 26pt where it was; the control around it is 44 (Apple's minimum), centred on it.
        let playIcon = CGRect(x: stripX.frame.maxX + 8, y: (sh - 26) / 2, width: 26, height: 26)
        playButton.frame = CGRect(x: playIcon.midX - 22, y: 0, width: 44, height: sh)
        let totalW = ceil(totalLabel.intrinsicContentSize.width)
        totalLabel.frame = CGRect(x: onceButton.frame.minX - 12 - totalW, y: 0, width: totalW, height: sh)
        waveform.frame = CGRect(x: playIcon.maxX + M.stripSpacing, y: (sh - 22) / 2,
                                width: max(0, totalLabel.frame.minX - M.stripSpacing - (playIcon.maxX + M.stripSpacing)),
                                height: 22)

        // The overlays are placed against the PADDED box, where the old `.overlay`s were aligned.
        let ins = outerInsets
        let padded = CGRect(x: -ins.left, y: -ins.top, width: W + ins.left + ins.right, height: H + ins.top + ins.bottom)
        // ⛔ THE PUCK GROWS OUT OF THE MIC, SO IT IS CENTRED ON THE MIC — his screenshot, 2026-08-27:
        // hold to record and the big black disc floats above the composer, overlapping the message
        // above it, instead of sitting on the bar.
        //
        // It used to hang off the PADDED BOX'S BOTTOM EDGE: `padded.maxY - halo/2`. The halo is 78
        // and the mic's slot is a 40pt button, so that puts the disc's centre 39pt above the bottom
        // where the mic's is only 20 — and the resting box reaches 5pt BELOW the bar (the composer's
        // rest dip is a negative inset), which buys another 5. About 24pt too high at rest, less with
        // the keyboard up, which is why it looked wrong by a different amount in different states.
        //
        // ⛔ THE MIC'S RESTING SLOT, WRITTEN OUT — NOT `micButton.center`. Reading the live button was
        // the first attempt at this and it made the puck JUMP on lock, which he photographed straight
        // away: `pillSpan` pulls the pill's right edge in by a whole button-and-gap the moment
        // `recordLocked` goes true (the send arrow appears outside it), so the mic slot slides ~48pt
        // left and the puck, anchored to it, went with it — mid-recording, under the finger.
        //
        // ⚠️ 2026-09-11: THE MIC IS A STANDALONE BUTTON NOW AND ITS SLOT MOVED — it no longer lives
        // at the pill's trailing end but in the trailing slot itself, the "+" button's mirror, so
        // the centre is `W - button/2`. The jump this paragraph was written to prevent cannot happen
        // any more for a second reason on top of the first: that slot is fixed, and `pillSpan` no
        // longer moves the pill's right edge when the recording locks.
        //
        // The Y is still the mic's line rather than the padded box's bottom, which is the part that
        // was actually wrong: the halo is 78 against a 40pt button, so hanging it off the box floated
        // it ~24pt high over the message above.
        // On the 44pt recording bar the disc centres on the bar (it is the bar's height then).
        let discCenter = CGPoint(x: W - M.button / 2, y: s.recordingActive ? H / 2 : H - M.button / 2)
        overlayGroup.bounds = CGRect(x: 0, y: 0, width: M.halo, height: M.halo)
        overlayGroup.center = discCenter
        discGroup.bounds = overlayGroup.bounds
        discGroup.center = CGPoint(x: M.halo / 2, y: M.halo / 2)
        // Same rule as the buttons: the pulse wrapper and both halo rings are scaled live (the
        // breathing pulse, the voice level), so they take bounds + center, never frame.
        let haloBounds = discGroup.bounds
        let haloCenter = CGPoint(x: M.halo / 2, y: M.halo / 2)
        pulseWrap.bounds = haloBounds
        pulseWrap.center = haloCenter
        haloOuter.bounds = haloBounds
        haloOuter.center = haloCenter
        haloInner.bounds = haloBounds
        haloInner.center = haloCenter
        disc.bounds = CGRect(x: 0, y: 0, width: M.disc, height: M.disc)
        disc.center = CGPoint(x: M.halo / 2, y: M.halo / 2)
        disc.layer.cornerRadius = M.disc / 2
        discGlyph.frame = CGRect(x: (M.disc - 24) / 2, y: (M.disc - 28) / 2, width: 24, height: 28)
        // Lock target: 48 wide, 14 of vertical padding around the lock and the chevron, 7 apart.
        let lockH: CGFloat = 14 + 20 + 7 + 16 + 14
        lockTarget.bounds = CGRect(x: 0, y: 0, width: 48, height: lockH)
        lockTarget.center = CGPoint(x: M.halo / 2, y: M.halo / 2 - M.lockLift)
        lockIcon.frame = CGRect(x: 0, y: 14, width: 48, height: 20)
        lockChevron.frame = CGRect(x: 0, y: 14 + 20 + 7, width: 48, height: 16)

        // Toasts: centred on the padded box, their top 8 above its top.
        let hintSize = holdHintPillLabel.intrinsicContentSize
        holdHintPill.bounds = CGRect(x: 0, y: 0, width: ceil(hintSize.width) + 28, height: ceil(hintSize.height) + 16)
        holdHintPill.layer.cornerRadius = holdHintPill.bounds.height / 2
        holdHintPill.center = CGPoint(x: padded.midX, y: padded.minY - M.toastLift + holdHintPill.bounds.height / 2)
        holdHintPillLabel.frame = holdHintPill.bounds.insetBy(dx: 14, dy: 8)
        let toastSize = onceToast.sizeThatFits(.zero)
        onceToast.bounds = CGRect(origin: .zero, size: toastSize)
        onceToast.center = CGPoint(x: padded.midX, y: padded.minY - M.toastLift + toastSize.height / 2)
        // Slow mode's ring just outside the send button, starting at the top and running clockwise.
        let ringRect = buttonBounds.insetBy(dx: -3, dy: -3)
        slowRing.frame = ringRect
        slowRing.path = UIBezierPath(arcCenter: CGPoint(x: ringRect.width / 2, y: ringRect.height / 2),
                                     radius: ringRect.width / 2 - 1, startAngle: -.pi / 2,
                                     endAngle: 1.5 * .pi, clockwise: true).cgPath
        layoutSlowTip(width: W)

        // A width change can re-wrap the text; the host is told off the layout pass, not inside it.
        if W != lastMeasuredWidth {
            lastMeasuredWidth = W
            let h = preferredHeight(forWidth: W)
            if h != lastHeight {
                lastHeight = h
                DispatchQueue.main.async { [weak self] in
                    self?.invalidateIntrinsicContentSize()
                    self?.onHeightChange?(nil)
                }
            }
        }
    }

    /// Every touch that lands on the bar stamps the clock the tap-to-dismiss guard reads — see
    /// `ChatComposerActions.barTouched`. `hitTest` fires at routing time, before any gesture
    /// resolves, so the stamp is always fresher than the dismissal it must cancel.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        // ⛔ THE WHOLE BAR IS THE COMPOSER, NOT JUST ITS CONTROLS — his screenshot, 2026-08-27:
        // tapping the empty band beside the "+" or the Send button closes the keyboard.
        //
        // The stamp used to be `v != nil`, i.e. only when some control actually claimed the touch.
        // A point inside this bar that lands on no subview returns nil from `super.hitTest`, so the
        // gap around the round buttons never stamped, and the conversation's deferred dismissal —
        // which hears the whole screen — went ahead and closed the keyboard.
        //
        // ⚠️ THE REFERENCE HAS NO SUCH GAP TO GET WRONG, and that is the behaviour being copied.
        // Their tap-to-dismiss is not on the screen at all, it is on the LIST:
        //
        //     collectionView.addGestureRecognizer(collectionViewTapGestureRecognizer)
        //
        // so their input toolbar is simply outside the recogniser's view and no part of it can ever
        // dismiss anything. Ours cannot move the gesture there — that was tried and he rejected the
        // FEEL of it on an A/B (builds 408-411, see `listBody`) — so the same boundary is drawn the
        // other way round: anything inside this bar's bounds is the composer being touched, control
        // or bare padding, and the conversation was not tapped.
        if bounds.contains(point) { actions.barTouched() }
        return v
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            setLive(false)
            stopPulse()
            // Leaving the chat mid GIF search: no full-screen card or extra window left behind.
            if gifSearchActive || holdsKeyboardForGifSearch { endGifSearchNow() }
            // Leaving mid grow: no window left over the next screen, the bar's container back home.
            (textView.inputView as? StickerKeyboardView)?.tearDownSearchOverlay()
            liftForStickerPanel(0)
        } else if shown.recordingActive {
            setLive(true)
        }
        // Focus asked for before the view had a window is honoured now that it has one.
        if window != nil, let p = pendingFocus { requestFocus(p) }
    }
}

// MARK: - Text delegate

extension ChatComposerView: UITextViewDelegate {

    /// The message length cap, `Limits.messageMaxChars`. Typing simply stops at the ceiling; a
    /// PASTE that would overflow is trimmed to what fits rather than refused whole, because
    /// dropping somebody's entire clipboard on the floor with no explanation is worse than keeping
    /// the part there was room for.
    ///
    /// ⚠️ TRIMMED ON A CHARACTER BOUNDARY, NOT A UNIT ONE. `NSString` counts UTF-16 units, so a cut
    /// at an arbitrary index can land inside an emoji's surrogate pair and produce a broken glyph;
    /// `rangeOfComposedCharacterSequence` backs the cut off to the start of whatever it landed in.
    ///
    /// ⚠️ AND `textViewDidChange` IS CALLED BY HAND. Assigning `.text` programmatically does not
    /// fire the delegate, so without it the placeholder, the send button, the bar's height and
    /// ThreadView's copy of the draft would all keep describing the text from before the paste.
    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !text.isEmpty else { return true }          // a deletion is always allowed
        let ns = tv.text as NSString
        let room = Limits.messageMaxChars - (ns.length - range.length)
        guard room > 0 else { return false }
        let incoming = text as NSString
        if incoming.length <= room { return true }

        var cut = room
        if cut < incoming.length {
            let seq = incoming.rangeOfComposedCharacterSequence(at: cut)
            if seq.location < cut { cut = seq.location }
        }
        guard cut > 0 else { return false }
        tv.text = ns.replacingCharacters(in: range, with: incoming.substring(to: cut))
        tv.selectedRange = NSRange(location: range.location + cut, length: 0)
        textViewDidChange(tv)
        return false
    }

    func textViewDidChange(_ tv: UITextView) {
        textView.refreshPlaceholder()
        actions.textChanged(tv.text)
        let h = preferredHeight(forWidth: bounds.width)
        if h != lastHeight {
            lastHeight = h
            // Their text growth, from the reference toolbar: a 0.25s critically damped spring
            // (`springDamping: 1, springResponse: 0.25`) around the height constraint and the
            // superview's layout, and the list follows from inside it. The host is told inside
            // this block for that reason; ours used to report bare and let the host spring on
            // its own, with overshoot.
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.invalidateIntrinsicContentSize()
                self.onHeightChange?(nil)
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    // Reported a turn later: the delegate fires inside UIKit's responder change, which can itself
    // be running inside a SwiftUI update, and a state write there is the "modifying state during
    // view update" warning. ⚠️ Until this lands, ThreadView's flag LAGS the field — `syncText`
    // therefore acts only on a change of the flag, never on the flag disagreeing with the field.
    // ⛔ `armResignGuard` IS GONE. It held the keyboard for a second after a voice note was tapped,
    // against a resign nobody had located, and the owner declined to keep a block standing in for a
    // diagnosis. The tap never reached this class: the conversation's own tap-to-dismiss gesture was
    // firing on it. See `VoiceBubbleView.controlTouch`. The guard fields below stay — they are the
    // presentation guard `textViewDidBeginEditing` arms, which is a different mechanism.

    /// Whether the field itself holds the first responder. `UIView.isFirstResponder` on the bar
    /// answers for the BAR, which never is one, so a caller outside this file cannot ask the
    /// question without this. Read by the list controller when the app comes back from the
    /// background and it has to decide whether the keys are still up.
    /// GIF search counts: its field holds the keys for this composer.
    var isEditingText: Bool { textView.isFirstResponder || gifSearchActive }

    func textViewDidBeginEditing(_ tv: UITextView) {
        // Arm the resign guard for the presentation — see `ComposerTextView.resignFirstResponder`.
        textView.resignGuardUntil = Date().addingTimeInterval(0.7)
        textView.resignRequested = false
        DispatchQueue.main.async { [weak self] in self?.actions.focusChanged(true) }
    }

    func textViewDidEndEditing(_ tv: UITextView) {
        // The panel's GIF search field took the keys on purpose: the panel and the focus stay.
        if gifSearchActive { return }
        // The keys went away with the panel up (scroll, tap on the chat): the next focus is the
        // keyboard again, not the panel.
        if stickerPanelUp { setStickerPanel(false, reload: false) }
        DispatchQueue.main.async { [weak self] in self?.actions.focusChanged(false) }
    }

    // MARK: Sticker panel (2026-10-17)

    var stickerPanelUp: Bool { textView.inputView != nil }

    func toggleStickerPanel() {
        // Owner 2026-10-17: a light buzz on open and on close.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if stickerPanelUp {
            setStickerPanel(false, reload: true)
            return
        }
        setStickerPanel(true, reload: textView.isFirstResponder)
        if !textView.isFirstResponder { requestFocus(true) }
    }

    @objc private func fieldTappedForKeys() {
        guard stickerPanelUp, textView.isFirstResponder else { return }
        setStickerPanel(false, reload: true)
    }

    /// Swaps the field's inputView. `reload` lets the system animate the swap while the field
    /// already holds the responder; when it does not, `becomeFirstResponder` brings the panel up.
    private func setStickerPanel(_ on: Bool, reload: Bool) {
        if on {
            let panel = StickerKeyboardView(height: StickerPanelHeight.current)
            panel.onSend = { [weak self] s in self?.actions.sendSticker(s) }
            panel.onCreate = { [weak self] in self?.actions.createSticker() }
            panel.onSendGif = { [weak self] g in self?.actions.sendGif(g) }
            // GIF search grows this panel in place (owner 2026-10-18), no more hand-off to the picker.
            panel.hostWindow = { [weak self] in self?.window }
            panel.onTouch = { [weak self] in self?.actions.barTouched() }
            panel.onBeginGifSearch = { [weak self] in
                guard let self else { return }
                self.gifSearchActive = true
                self.holdsKeyboardForGifSearch = true
                self.textView.resignRequested = true
            }
            panel.onWillCollapseGifSearch = { [weak self] in
                self?.holdsKeyboardForGifSearch = true
            }
            panel.onRestorePanelFocus = { [weak self] in
                guard let self else { return }
                self.gifSearchActive = false
                self.textView.resignRequested = false
                // ⛔ NO SYSTEM SLIDE (owner 2026-10-18, build 969: "when it is short, another keyboard
                // sheet comes in from the bottom"). Taking the responder back from the search field
                // played the keyboard's own rise, its rounded backdrop coming up after the card had
                // landed. The card's spring is the only motion; the panel is simply there under it.
                UIView.performWithoutAnimation {
                    _ = self.textView.becomeFirstResponder()
                    self.textView.reloadInputViews()
                }
            }
            panel.onDidCollapseGifSearch = { [weak self] in
                // A beat after the card lands, so the panel's own keyboard notes have all arrived.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, !self.gifSearchActive else { return }
                    self.holdsKeyboardForGifSearch = false
                }
            }
            // Drag to grow / shrink (owner 2026-10-18): the bar rides on top of the grown panel, and
            // the panel stops under the chat's navigation bar.
            panel.onExpansionLift = { [weak self] dy in self?.liftForStickerPanel(dy) }
            panel.composerTopInWindow = { [weak self] in
                guard let c = self?.superview, c.window != nil else { return nil }
                return c.convert(c.bounds, to: nil).minY
            }
            panel.expansionCeilingInWindow = { [weak self] in self?.navigationBarBottomInWindow() }
            textView.inputView = panel
        } else {
            gifSearchActive = false
            holdsKeyboardForGifSearch = false
            // Grown and the keys are leaving with us on screen: the card slides down with them and
            // the bar comes down with it, rather than both snapping (the teardown below then waits).
            if window != nil { (textView.inputView as? StickerKeyboardView)?.slideExpansionAway() }
            (textView.inputView as? StickerKeyboardView)?.tearDownSearchOverlay()
            textView.inputView = nil
        }
        gifButton.icon.image = (on ? UIImage(named: "ic_keyboard") : UIImage(named: "ic_gif"))?
            .withRenderingMode(.alwaysTemplate)
        gifButton.accessibilityLabel = on ? "Keyboard" : "GIF"
        // The camera's own rule, not the sticker button's (which may be hidden for this group).
        let cameraAlpha: CGFloat = on ? 0 : ((!shown.recordingActive && !shown.hasText && !shown.textOnly) ? 1 : 0)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cameraButton.alpha = cameraAlpha
        }
        if reload { textView.reloadInputViews() }
    }

    /// The bar's whole container moves, not the bar: the container only hit-tests inside its own
    /// bounds, so a bar lifted out of it would draw but not take a tap. A transform, so no
    /// constraint, keyboard guide or list inset changes while the panel is grown (the list stays put
    /// under the dim, as the reference app's does). 0 puts it back.
    private func liftForStickerPanel(_ dy: CGFloat) {
        guard let c = superview as? BarTouchView else { return }
        let t: CGAffineTransform = dy > 0.5 ? CGAffineTransform(translationX: 0, y: -dy) : .identity
        if c.transform != t { c.transform = t }
    }

    @objc private func stickerBarPanned(_ pan: UIPanGestureRecognizer) {
        (textView.inputView as? StickerKeyboardView)?.barPanned(pan)
    }

    /// Not from a button or the mic (its hold is a drag of its own), and not from a field whose text
    /// scrolls (the reference app's rule: a field taller than its frame keeps its own drag).
    fileprivate func stickerBarPanShouldReceive(_ touch: UITouch) -> Bool {
        guard stickerPanelUp, var v = touch.view else { return false }
        while v !== self {
            if v is UIControl || v === micButton { return false }
            if v === textView, textView.contentSize.height > textView.bounds.height + 1 { return false }
            guard let s = v.superview else { return false }
            v = s
        }
        return true
    }

    fileprivate func stickerBarPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard stickerPanelUp, let panel = textView.inputView as? StickerKeyboardView else { return false }
        return panel.barPanShouldBegin(pan)
    }

    /// The field's own pan waits for the bar's, so a vertical drag on it moves the panel.
    fileprivate func stickerBarPanOutranks(_ other: UIGestureRecognizer) -> Bool {
        other === textView.panGestureRecognizer
    }

    /// The foot of the navigation bar this chat is shown under, in window space.
    private func navigationBarBottomInWindow() -> CGFloat? {
        var r: UIResponder? = self
        while let n = r {
            if let vc = n as? UIViewController, let nb = vc.navigationController?.navigationBar,
               nb.window != nil, !nb.isHidden {
                return nb.convert(nb.bounds, to: nil).maxY
            }
            r = n.next
        }
        return nil
    }

    // 2026-09-24 decision D-composer-5: the caret, for @mentions typed in the middle of a message.
    // A turn later for the same reason as the focus reports: `syncText` moves the caret from inside
    // a SwiftUI update, and a state write there is the "modifying state during view update" warning.
    func textViewDidChangeSelection(_ tv: UITextView) {
        let at = tv.selectedRange.location
        DispatchQueue.main.async { [weak self] in self?.actions.caretChanged(at) }
    }
}

extension ChatComposerView: UIGestureRecognizerDelegate {
    // Let the hold coexist with the surrounding scroll/tap gestures without stealing or being stolen.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The bar's sticker-panel pan has its own rules; the composer's delegate lets every gesture run
/// together, which this one must not (it would scroll the field and move the panel at once).
@MainActor private final class StickerBarPanDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: ChatComposerView?
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        owner?.stickerBarPanShouldReceive(touch) ?? false
    }
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, let owner else { return false }
        return owner.stickerBarPanShouldBegin(pan)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        owner?.stickerBarPanOutranks(other) ?? false
    }
}

/// A display link retains its target; this breaks the cycle so the bar can be freed.
@MainActor private final class WeakProxy: NSObject {
    weak var target: ChatComposerView?
    init(_ t: ChatComposerView) { target = t }
    @objc func tick() { target?.tick() }
}

/// `micButton` is an invisible gesture host, not a real control (see the comment above it), so
/// VoiceOver has nothing to double-tap unless a plain view says otherwise. This gives it exactly
/// that: an activation action, without turning it into a `UIButton` and disturbing the hold
/// gesture that already owns its touches.
private final class AccessibleActivationView: UIView {
    var onActivate: () -> Bool = { false }
    override func accessibilityActivate() -> Bool { onActivate() }
}

// MARK: - The text view

/// The field: 17pt, a placeholder, grows to six lines then scrolls. Insets are the old
/// `.padding(.leading, 14).padding(.vertical, 9)`, which put a single line at 40.
final class ComposerTextView: UITextView {
    /// ⛔ AN UNREQUESTED RESIGN IS REFUSED WHILE THE KEYS PRESENT — the probe build's verdict
    /// (`f000402c`, his diag screenshots): 3ms after a SwiftUI render pass, with every piece of our
    /// keyboard code proven stood-down, SOMETHING resigns this field with animations disabled —
    /// `NOTE chg band=0 d=0.00` → `FOCUS end` → `FOCUS begin` 10ms later. That unrequested resign
    /// is the whole "keyboard opens on the second try". Every resign of OURS announces itself
    /// first (`resignRequested`, set in `requestFocus`); an anonymous one inside the guard window
    /// is turned away. The window is short — armed at `textViewDidBeginEditing`, expired 0.7s
    /// later — so a real dismissal is never blocked for longer than the presentation itself.
    var resignGuardUntil = Date.distantPast
    var resignRequested = false
    override func resignFirstResponder() -> Bool {
        if !resignRequested, Date() < resignGuardUntil {
            return false
        }
        return super.resignFirstResponder()
    }

    private let placeholderLabel = UILabel()
    var placeholder: String = "" {
        didSet { if placeholder != oldValue { renderPlaceholder() } }
    }
    /// A symbol before the placeholder (slow mode's stopwatch); nil for plain text.
    var placeholderIcon: String? = nil {
        didSet { if placeholderIcon != oldValue { renderPlaceholder() } }
    }

    private func renderPlaceholder() {
        guard let name = placeholderIcon,
              let img = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))?
                .withTintColor(.placeholderText, renderingMode: .alwaysOriginal) else {
            placeholderLabel.attributedText = nil
            placeholderLabel.text = placeholder
            return
        }
        let s = NSMutableAttributedString(attachment: NSTextAttachment(image: img))
        s.append(NSAttributedString(string: " " + placeholder,
                                    attributes: [.font: font ?? .systemFont(ofSize: 17),
                                                 .foregroundColor: UIColor.placeholderText]))
        placeholderLabel.attributedText = s
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .systemFont(ofSize: 17)
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 0)
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        showsHorizontalScrollIndicator = false
        tintColor = .label
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshPlaceholder() { placeholderLabel.isHidden = !text.isEmpty }

    /// 2026-09-24 decision D-composer-5: a pasted picture goes to the photo approval flow, as in the
    /// reference app. A stock text view pastes only text, so an image on the clipboard did nothing.
    /// Returns false when pictures are not accepted here (a first message to a stranger is text only).
    var onPasteImages: (([UIImage]) -> Bool)?

    /// A first message to a stranger (`ChatComposerState.textOnly`) — kept in sync by `syncText`.
    /// Paste is hidden rather than offered and silently swallowed when the clipboard has nothing
    /// but a picture: `onPasteImages` already refuses it there, and `super.paste` has no text to
    /// fall back to, so the menu item used to do nothing at all.
    var textOnly = false

    /// Pictures win unless the clipboard also carries real text: an image copied from a web page
    /// comes with its address, which is not what the person meant to paste.
    private var pastedImages: [UIImage]? {
        let pb = UIPasteboard.general
        guard pb.hasImages, let imgs = pb.images, !imgs.isEmpty else { return nil }
        if let s = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
           URL(string: s)?.scheme == nil { return nil }
        return imgs
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            if textOnly, pb.hasImages, !pb.hasStrings { return false }
            if onPasteImages != nil, pb.hasImages { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let imgs = pastedImages, onPasteImages?(imgs) == true { return }
        super.paste(sender)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                                        width: max(0, bounds.width - textContainerInset.left),
                                        height: ceil(font?.lineHeight ?? 20))
        refreshPlaceholder()
    }
}

// MARK: - Small controls

/// A system button whose tap area reaches past its drawn shape by `hitOutset` (see `stripX`).
final class OutsetHitButton: UIButton {
    var hitOutset: UIEdgeInsets = .zero
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: UIEdgeInsets(top: -hitOutset.top, left: -hitOutset.left,
                                      bottom: -hitOutset.bottom, right: -hitOutset.right)).contains(point)
    }
}

/// A 40×40 tap target around a fixed-size glyph. The old `Image(...).frame(w,h).frame(40,40)`.
/// ⛔ ITS TAP IS A GESTURE RECOGNISER, NOT UICONTROL TRACKING — his reports, 2026-08-26: the GIF
/// button does nothing, and the reply banner's X does nothing.
///
/// Those two are the only controls in the composer that live INSIDE the pill. The pill is a
/// `UIVisualEffectView` carrying a `UIGlassEffect` with `isInteractive = true`, which installs its
/// own press handling over the whole effect view; a `UIControl` beneath it never completes a
/// `.touchUpInside`. Everything that does work — "+", trash, send, the mic — is a SIBLING of the
/// pill, outside the glass.
///
/// This is the same lesson `VoicePlayDiscControl` records at the head of its own file: a recogniser
/// is not delayed and is not cancelled the way tracking is, it negotiates as a peer. The control
/// keeps its `.touchUpInside` API, so every call site is unchanged; only the route the touch takes
/// is different.
final class IconButton: UIControl {
    let icon = UIImageView()
    private let iconSize: CGSize

    init(image: UIImage?, size: CGSize) {
        iconSize = size
        super.init(frame: .zero)
        icon.image = image?.withRenderingMode(.alwaysTemplate)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapFired))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapFired() {
        guard isEnabled else { return }
        // The press flash the tracking path used to give, kept by hand so the button still answers.
        isHighlighted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.isHighlighted = false }
        sendActions(for: .touchUpInside)
    }

    override var isHighlighted: Bool {
        didSet { icon.alpha = isHighlighted ? 0.5 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.bounds = CGRect(origin: .zero, size: iconSize)
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

extension IconButton: UIGestureRecognizerDelegate {
    /// Coexist with the glass effect's own press and with anything the pill or the list runs.
    /// Refusing simultaneity here would put this tap back in the fight it just lost.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The "Set to one-time listen" toast: the composer's notice in the chat's own bubble surface — the
/// same slice of blurred wallpaper an incoming bubble wears, with the hairline rim, or the flat
/// received colour. Never a material in the normal case: a material samples live and comes out a
/// different colour from the bubble beside it.
///
/// ⚠️ That paragraph was rewritten to say the opposite for one day (2026-09-02, while bubbles were
/// briefly a live material) and then rewritten back when the slice was restored the same evening.
/// It is correct as written now. The `.material` branch below is only the no-slice fallback.
final class NoticePillView: UIView {
    private var surface: UIView?
    private let icon = UIImageView()
    private let label = UILabel()
    private var sliceView: WallpaperBlurSliceView? { surface as? WallpaperBlurSliceView }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        icon.contentMode = .center
        icon.tintColor = .label
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .label
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var applied: (Theme.ReceivedSurface, Bool, Bool)?

    func configure(symbol: String, text: String, surface s: Theme.ReceivedSurface, onWallpaper: Bool, dark: Bool) {
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
        label.text = text
        // Called on every state change; the surface is only rebuilt when the surface changed.
        if let a = applied, a.0 == s, a.1 == onWallpaper, a.2 == dark { return }
        applied = (s, onWallpaper, dark)
        surface?.removeFromSuperview()
        let v: UIView
        switch s {
        case .flat(let c):
            v = UIView()
            v.backgroundColor = UIColor(c)
        case .slice(let state):
            let sv = WallpaperBlurSliceView()
            sv.state = state
            v = sv
        case .material:
            // The fallback weight pair, restored with the slice on 2026-09-02. This has `dark` in
            // hand so it uses the two-weight version rather than `Theme.receivedBlurStyle`.
            v = UIVisualEffectView(effect: UIBlurEffect(style: dark ? .systemUltraThinMaterial : .systemThinMaterial))
        }
        v.isUserInteractionEnabled = false
        insertSubview(v, at: 0)
        surface = v
        if onWallpaper {
            layer.borderColor = UIColor(Theme.bubbleRim(dark)).cgColor
            layer.borderWidth = Theme.hairline
        } else {
            layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
            layer.borderWidth = 0.5
        }
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let l = label.intrinsicContentSize
        return CGSize(width: ceil(l.width) + 14 + 6 + 24, height: ceil(max(l.height, 18)) + 10)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface?.frame = bounds
        layer.cornerRadius = bounds.height / 2
        icon.frame = CGRect(x: 12, y: 0, width: 14, height: bounds.height)
        label.frame = CGRect(x: 12 + 14 + 6, y: 0, width: max(0, bounds.width - 12 - 14 - 6 - 12), height: bounds.height)
        sliceView?.reposition()
    }
}
