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
        static let micTrailing: CGFloat = 4      // last icon 4pt from the bar edge
        static let strip: CGFloat = 14           // the locked strip's and hold row's side padding
        static let stripSpacing: CGFloat = 8
        static let holdSpacing: CGFloat = 10
        static let lockLift: CGFloat = 86        // the lock target floats this far above the mic
        static let halo: CGFloat = 78
        static let disc: CGFloat = 56
        static let overlayTrailing: CGFloat = 12 // the old `.padding(.trailing, 12)` on the overlay
        static let toastLift: CGFloat = 8        // the old `.offset(y: -8)` on both toasts
        static let onceBlue = UIColor(red: 0x3D / 255, green: 0xA1 / 255, blue: 0xFD / 255, alpha: 1)
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
    private let plusButton = ChatComposerView.glassButton(symbol: "plus", size: 20, weight: .regular, color: .label)
    private let trashButton = ChatComposerView.glassButton(symbol: "trash.fill", size: 18, weight: .regular, color: .systemRed, bakeColor: true)
    private let sendButton = ChatComposerView.glassButton(symbol: "arrow.up", size: 19, weight: .bold, color: .white, prominent: true)
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
    private let micButton = UIView()
    private let micGlyph = UIImageView(image: UIImage(named: "ic_mic")?.withRenderingMode(.alwaysTemplate))

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
    private let playButton = IconButton(image: nil, size: CGSize(width: 26, height: 26))
    private let waveform = ComposerWaveformView()
    private let totalLabel = UILabel()
    private let onceButton = IconButton(image: nil, size: CGSize(width: 24, height: 24))

    // Over the bar, outside its bounds: the big mic and the lock target, and the two toasts.
    private let overlayGroup = UIView()
    private let discGroup = UIView()
    private let pulseWrap = UIView()
    private let haloOuter = UIView()
    private let haloInner = UIView()
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

    private var holdStart: CGPoint?
    private var displayLink: CADisplayLink?

    // MARK: - Init

    init(recorder: AudioRecorder) {
        self.recorder = recorder
        super.init(frame: .zero)
        clipsToBounds = false
        backgroundColor = .clear
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        addSubview(container)
        container.contentView.addSubview(plusButton)
        container.contentView.addSubview(trashButton)
        container.contentView.addSubview(pill)
        container.contentView.addSubview(sendButton)
        plusButton.addAction(UIAction { [weak self] _ in self?.actions.attach() }, for: .touchUpInside)
        trashButton.addAction(UIAction { [weak self] _ in self?.actions.cancelRecording() }, for: .touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.shown.recordLocked { self.actions.sendRecording() } else { self.actions.send() }
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
        container.contentView.addSubview(micButton)
        textView.delegate = self
        // ⛔ DIMMER THAN THE MIC, AND ONLY THIS ONE (owner 2026-08-22: "GIF icon make it low
        // brightness but don't touch the voice recording icon"). The mic is the button people
        // reach for without looking; the stickers are a browse.
        gifButton.icon.tintColor = UIColor.label.withAlphaComponent(0.55)
        gifButton.addAction(UIAction { [weak self] _ in self?.actions.gif() }, for: .touchUpInside)
        micGlyph.contentMode = .scaleAspectFit
        micGlyph.tintColor = .label
        micButton.addSubview(micGlyph)
        // Instant UIKit hold gesture (minimumPressDuration 0) — fires on touch-down. The view it is
        // on is never hidden or removed while a hold runs, only its glyph fades, so it keeps
        // tracking the drag for the whole gesture.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0
        hold.allowableMovement = .greatestFiniteMagnitude   // never fail on movement — the drag IS the gesture
        hold.cancelsTouchesInView = false
        hold.delegate = self
        micButton.addGestureRecognizer(hold)

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
        playButton.addAction(UIAction { [weak self] _ in self?.actions.togglePreview() }, for: .touchUpInside)
        waveform.onSeek = { [weak self] pct in self?.actions.seekPreview(pct) }
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        totalLabel.textColor = .secondaryLabel
        onceButton.addAction(UIAction { [weak self] _ in self?.actions.toggleVoiceOnce() }, for: .touchUpInside)

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
        setLive(new.recordingActive)
    }

    private func syncText(_ s: ChatComposerState, wasFocused: Bool) {
        if textView.text != s.text {
            textView.text = s.text
            textView.refreshPlaceholder()
        }
        textView.placeholder = s.placeholder
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
            if !textView.isFirstResponder, !textView.becomeFirstResponder() { pendingFocus = true }
        } else if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    /// Everything that is a plain assignment: glyphs, colours, the review's data.
    private func refreshStatic() {
        let s = shown
        let accent = UIColor(Theme.accent(s.dark))
        let onAccent = UIColor(Theme.onAccent(s.dark))

        plusButton.configuration?.image = UIImage(systemName: s.attachBusy ? "ellipsis" : "plus")
        sendButton.configuration?.image = UIImage(systemName: s.editing && !s.recordLocked ? "checkmark" : "arrow.up")
        // ⛔ THE CHAT'S OWN COLOUR, NOT A FIXED BLUE — both sends (text and voice) resolve the same
        // tint, so a chat colour cannot reach one and miss the other.
        sendButton.configuration?.baseBackgroundColor = s.sendTint
        sendButton.tintColor = s.sendTint

        // ⛔ 17, NOT 22 — owner, 2026-08-26: "play voice is too big". It was a 22pt glyph in a 26pt
        // box, so it filled its control almost edge to edge and read as the loudest thing in a strip
        // where it is the least important: the trash beside it is 18 and the waveform is the part
        // you are meant to look at. 17 sits it just under its neighbour, which is where a secondary
        // control belongs.
        playButton.icon.image = UIImage(systemName: s.previewPlaying ? "pause.fill" : "play.fill",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        playButton.icon.tintColor = accent
        waveform.decibels = s.previewDecibels
        waveform.progress = s.previewProgress
        waveform.played = accent
        waveform.unplayed = accent.withAlphaComponent(0.35)
        onceButton.icon.image = UIImage(systemName: s.voiceOnce ? "1.circle.fill" : "1.circle",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        onceButton.icon.tintColor = s.voiceOnce ? M.onceBlue : .label
        onceButton.accessibilityLabel = s.voiceOnce ? "One-time listen on" : "One-time listen off"

        // The disc is the ACCENT, which is white at night — so the glyph on it is `onAccent`, or
        // it draws nothing on the one control you are watching.
        haloOuter.backgroundColor = accent.withAlphaComponent(0.12)
        haloInner.backgroundColor = accent.withAlphaComponent(0.22)
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
        stripRecording.isUserInteractionEnabled = !s.reviewing
        stripReview.alpha = s.reviewing ? 1 : 0
        stripReview.isUserInteractionEnabled = s.reviewing
        gifButton.alpha = (!s.recordingActive && !s.hasText) ? 1 : 0
        // The mic sits ABOVE the pill now, so it must go when the locked strip takes the pill (the "1"
        // lives in its slot then). While a finger holds it only the glyph fades — the view stays, so
        // the gesture keeps tracking; a lock ends the gesture, and then the whole button can leave.
        micButton.alpha = (s.hasText || s.recordLocked) ? 0 : 1
        micGlyph.alpha = s.recordingHeld ? 0 : 1
        for (_, v) in bannerViews { v.alpha = s.recordingActive ? 0 : 1 }
    }

    private func targetAlpha(for b: UIButton) -> CGFloat {
        let s = shown
        if b === plusButton { return s.recordingActive ? 0 : 1 }
        if b === trashButton { return s.recordLocked && s.reviewing ? 1 : 0 }
        return (s.hasText || s.recordLocked) ? 1 : 0
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

    private func startPulse() {
        pulseWrap.layer.removeAllAnimations()
        pulseWrap.transform = .identity
        UIView.animate(withDuration: 1.0, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut, .allowUserInteraction]) {
            self.pulseWrap.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
        }
    }

    private func stopPulse() {
        pulseWrap.layer.removeAllAnimations()
        pulseWrap.transform = .identity
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
        let lvl = CGFloat(recorder.levels.last ?? 0)
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
        let left: CGFloat = s.recordingActive ? (s.reviewing ? slot : 0) : slot
        let right: CGFloat = (s.hasText || s.recordLocked) ? width - slot : width
        return (left, max(left, right))
    }

    /// The text's own width inside the pill: the whole pill once there is text, else what the GIF
    /// and mic leave.
    private func textWidth(pillWidth: CGFloat) -> CGFloat {
        shown.hasText ? pillWidth
                      : pillWidth - M.micTrailing - M.button - M.inPillSpacing - M.button - M.inPillSpacing
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
        if shown.recordingActive { return M.button }
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
        // The mic is the pill's sibling (see `build`), so its frame is in the container's space:
        // over the pill's last slot, bottom-aligned with the row.
        let micX = pw - M.micTrailing - M.button
        micButton.frame = CGRect(x: span.left + micX, y: H - M.button, width: M.button, height: M.button)
        micGlyph.frame = CGRect(x: (M.button - 22) / 2, y: (M.button - 24) / 2, width: 22, height: 24)
        gifButton.frame = CGRect(x: micX - M.inPillSpacing - M.button, y: fh - M.button,
                                 width: M.button, height: M.button)
        textView.frame = CGRect(x: 0, y: 0, width: max(0, tw), height: fh)
        let fit = ceil(textView.sizeThatFits(CGSize(width: max(1, tw), height: .greatestFiniteMagnitude)).height)
        textView.isScrollEnabled = fit > maxTextHeight

        // The hold row sits where the field row is; the strip is the whole (one-row) pill.
        holdRow.frame = fieldRow.frame
        let hx = M.strip
        holdMic.frame = CGRect(x: hx, y: (fh - 24) / 2, width: 24, height: 24)
        let holdTimerW = ceil(holdTimer.intrinsicContentSize.width)
        holdTimer.frame = CGRect(x: holdMic.frame.maxX + M.holdSpacing, y: 0, width: holdTimerW, height: fh)
        // The hint sits CENTRED in what the timer leaves, the way the reference draws it.
        let chevW: CGFloat = 12, hintGap: CGFloat = 3
        let hintLabelW = ceil(holdHintLabel.intrinsicContentSize.width)
        let hintW = chevW + hintGap + hintLabelW
        let hintRoom = CGRect(x: holdTimer.frame.maxX + M.stripSpacing, y: 0,
                              width: pw - M.strip - M.stripSpacing - (holdTimer.frame.maxX + M.stripSpacing), height: fh)
        holdHint.frame = CGRect(x: hintRoom.midX - hintW / 2, y: 0, width: hintW, height: fh)
        holdChevron.frame = CGRect(x: 0, y: 0, width: chevW, height: fh)
        holdHintLabel.frame = CGRect(x: chevW + hintGap, y: 0, width: hintLabelW, height: fh)

        strip.frame = CGRect(x: 0, y: H - M.button, width: pw, height: M.button)
        stripRecording.frame = strip.bounds
        stripReview.frame = strip.bounds
        let onceW: CGFloat = 24
        onceButton.frame = CGRect(x: pw - M.strip - onceW, y: 0, width: onceW, height: M.button)
        stripMic.frame = CGRect(x: hx, y: (M.button - 24) / 2, width: 24, height: 24)
        let stripTimerW = ceil(stripTimer.intrinsicContentSize.width)
        stripTimer.frame = CGRect(x: stripMic.frame.maxX + M.stripSpacing, y: 0, width: stripTimerW, height: M.button)
        cancelButton.frame = CGRect(x: stripTimer.frame.maxX + M.stripSpacing, y: 0,
                                    width: max(0, onceButton.frame.minX - M.stripSpacing - (stripTimer.frame.maxX + M.stripSpacing)),
                                    height: M.button)
        playButton.frame = CGRect(x: hx, y: (M.button - 26) / 2, width: 26, height: 26)
        let totalW = ceil(totalLabel.intrinsicContentSize.width)
        totalLabel.frame = CGRect(x: onceButton.frame.minX - M.stripSpacing - totalW, y: 0, width: totalW, height: M.button)
        waveform.frame = CGRect(x: playButton.frame.maxX + M.stripSpacing, y: (M.button - 22) / 2,
                                width: max(0, totalLabel.frame.minX - M.stripSpacing - (playButton.frame.maxX + M.stripSpacing)),
                                height: 22)

        // The overlays are placed against the PADDED box, where the old `.overlay`s were aligned.
        let ins = outerInsets
        let padded = CGRect(x: -ins.left, y: -ins.top, width: W + ins.left + ins.right, height: H + ins.top + ins.bottom)
        let discCenter = CGPoint(x: padded.maxX - M.overlayTrailing - M.halo / 2, y: padded.maxY - M.halo / 2)
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
        haloOuter.layer.cornerRadius = M.halo / 2
        haloInner.bounds = haloBounds
        haloInner.center = haloCenter
        haloInner.layer.cornerRadius = M.halo / 2
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setLive(false); stopPulse() }
        else if shown.recordingActive { setLive(true) }
        // Focus asked for before the view had a window is honoured now that it has one.
        if window != nil, let p = pendingFocus { requestFocus(p) }
    }
}

// MARK: - Text delegate

extension ChatComposerView: UITextViewDelegate {
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
    func textViewDidBeginEditing(_ tv: UITextView) {
        KeyboardDiag.log("FOCUS begin")   // ⚠️ temporary — does the field keep focus through the cancel?
        DispatchQueue.main.async { [weak self] in self?.actions.focusChanged(true) }
    }

    func textViewDidEndEditing(_ tv: UITextView) {
        KeyboardDiag.log("FOCUS end")   // ⚠️ temporary — a resign here means the cancel took the focus too
        DispatchQueue.main.async { [weak self] in self?.actions.focusChanged(false) }
    }
}

extension ChatComposerView: UIGestureRecognizerDelegate {
    // Let the hold coexist with the surrounding scroll/tap gestures without stealing or being stolen.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// A display link retains its target; this breaks the cycle so the bar can be freed.
@MainActor private final class WeakProxy: NSObject {
    weak var target: ChatComposerView?
    init(_ t: ChatComposerView) { target = t }
    @objc func tick() { target?.tick() }
}

// MARK: - The text view

/// The field: 17pt, a placeholder, grows to six lines then scrolls. Insets are the old
/// `.padding(.leading, 14).padding(.vertical, 9)`, which put a single line at 40.
final class ComposerTextView: UITextView {
    private let placeholderLabel = UILabel()
    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                                        width: max(0, bounds.width - textContainerInset.left),
                                        height: ceil(font?.lineHeight ?? 20))
        refreshPlaceholder()
    }
}

// MARK: - Small controls

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
/// received colour. Never a material: a material samples live and comes out a different colour from
/// the bubble beside it.
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
