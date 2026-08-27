import Combine
import UIKit

// ===== A voice note, in UIKit =====
//
// ⛔ THIS IS THE SECOND ATTEMPT. The first (2026-08-25) shipped and was reverted the same night,
// and the reason is the most important thing in this file:
//
//   THE PLAY DISC MUST TAKE ITS TOUCH WITH A GESTURE RECOGNISER, NEVER AS A `UIControl`.
//
// A `UIControl` answers touch DELIVERY, and inside this list that is not the same thing as a tap.
// `UIScrollView.delaysContentTouches` holds `touchesBegan` back from subviews by design, and the
// list runs its own 0.2s long press with `cancelsTouchesInView` at the default — so a touch that
// did reach the control can still be taken away before it becomes `.touchUpInside`. The first tap
// on a settling list is exactly the one that loses, which is what he reported: "first play voice
// note won't play at all".
//
// `VoicePlayDiscControl` (recovered from `813b87fe`) already takes its tap with a recogniser, and
// the waveform always did — which is why the waveform never had the bug. Nothing here may go back
// to a control.
//
// ⚠️ PLAYBACK STATE IS NOT IN THE MODEL. It changes many times a second; a model carrying it would
// re-plan the row on every tick. This view subscribes to `VoiceNotePlayer` and repaints in place —
// no rect it draws depends on progress.

final class VoiceBubbleView: UIView {
    private let disc = VoicePlayDiscControl()
    private let wave = VoiceWaveformView()
    private let speedPill = UILabel()
    private let duration = UILabel()
    private let unreadDot = UIView()
    private let micGlyph = UIImageView()

    /// The disc's tap routes UP, like every other tap in this directory. `VoiceNotePlayer.toggle`
    /// takes a whole `Message`, and a view that reached for one would be a view holding app state.
    /// Seeking, scrubbing and the speed pill need only an id or a cid, so those are called directly.
    var onPlayToggle: () -> Void = {}

    private var bag = Set<AnyCancellable>()
    private var body: BubbleBody.VoiceBody?
    private var cid = ""
    private var tint: UIColor = .label

    override init(frame: CGRect) {
        super.init(frame: frame)
        // ⚠️ The view itself passes touches through — the DISC and the WAVEFORM have their own
        // recognisers and must receive them, but everything else is paint.
        addSubview(disc)
        addSubview(wave)
        speedPill.textAlignment = .center
        speedPill.layer.cornerRadius = 11
        speedPill.clipsToBounds = true
        addSubview(speedPill)
        duration.isUserInteractionEnabled = false
        addSubview(duration)
        unreadDot.layer.cornerRadius = 3.5
        unreadDot.isUserInteractionEnabled = false
        addSubview(unreadDot)
        micGlyph.contentMode = .scaleAspectFit
        micGlyph.isUserInteractionEnabled = false
        addSubview(micGlyph)

        // Nothing to play while the bytes are still going up; the disc is already spinning.
        disc.onTap = { [weak self] in
            guard let self, self.body?.loading != true else { return }
            self.onPlayToggle()
        }
        wave.onSeek = { [weak self] fraction in
            guard let b = self?.body else { return }
            VoiceNotePlayer.shared.seek(fraction, id: b.messageId)
        }
        wave.onScrub = { active in
            // The list's reply-swipe yields to a scrub — the waveform is a no-reply zone while a
            // finger is on it.
            VoiceNotePlayer.shared.setScrubbing(active)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedSpeed))
        speedPill.isUserInteractionEnabled = true
        speedPill.addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ v: BubbleBody.VoiceBody, plan: VoicePlan, tint: UIColor, cid: String) {
        self.body = v
        self.cid = cid
        self.tint = tint

        disc.frame = plan.disc
        disc.discTint = tint
        wave.frame = plan.wave
        wave.bars = v.bars
        wave.playedColor = tint
        wave.unplayedColor = tint.withAlphaComponent(0.35)
        speedPill.frame = plan.speedPill
        duration.frame = plan.duration
        duration.attributedText = plan.durationAttr
        unreadDot.frame = plan.unreadDot
        unreadDot.backgroundColor = BubblePalette.accent
        micGlyph.frame = plan.micGlyph
        micGlyph.image = UIImage(systemName: "mic.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        micGlyph.tintColor = tint.withAlphaComponent(0.8)

        subscribe()
        paint()
    }

    /// One subscription for the whole view, rebuilt on every configure so a recycled cell never
    /// keeps the previous note's.
    private func subscribe() {
        bag.removeAll()
        let player = VoiceNotePlayer.shared
        // ⚠️ `receive(on:)` IS LOAD-BEARING. `objectWillChange` fires BEFORE the value changes, so
        // painting synchronously would read the state we are being told is about to be replaced.
        // Hopping to the next runloop turn means `paint` reads the new one.
        player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.paint() }
            .store(in: &bag)
    }

    /// Playback → the disc's glyph, the waveform's progress, the speed label. No geometry.
    private func paint() {
        guard let b = body else { return }
        let player = VoiceNotePlayer.shared
        disc.showsPause = player.isPlaying(b.messageId) && !b.loading
        // The upload's spinner and the player's are the same spinner: there is nothing to play
        // until the bytes land, and the disc is the one place that says so.
        disc.isBusy = b.loading || player.isLoading(b.messageId)
        wave.progress = player.progress(for: b.messageId)
        // The dot is live, not planned: its slot is reserved either way, so hiding it the moment
        // this note is heard costs no layout. Playing it at all counts as hearing it.
        unreadDot.isHidden = !b.unplayed || player.isPlaying(b.messageId)
            || player.progress(for: b.messageId) > 0

        let rate = player.rate(for: cid)
        speedPill.attributedText = NSAttributedString(
            string: rate == 1 ? "1x" : String(format: "%.1fx", rate),
            attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .bold),
                         .foregroundColor: tint])
        speedPill.backgroundColor = tint.withAlphaComponent(0.12)
    }

    @objc private func tappedSpeed() {
        VoiceNotePlayer.shared.cycleRate(cid: cid)
        paint()
    }

    /// ⛔ WHEN ONE OF THESE THREE LAST TOOK A TOUCH — his report: keyboard up, tap Play (or the 1×
    /// pill), and the keyboard closes.
    ///
    /// THE CAUSE IS NOT THE AUDIO STACK, which is where the two previous attempts looked. The proof
    /// is the speed pill: `cycleRate` sets a number and repaints, it never opens a session, never
    /// changes the category and never touches proximity monitoring — and it closes the keyboard just
    /// the same. What Play and 1× actually have in common is that they are both TAPS ON THE
    /// CONVERSATION, and the conversation has a tap-to-dismiss gesture across the whole of it.
    ///
    /// That gesture is simultaneous, so it fires for a tap that was meant for something inside a
    /// bubble as readily as for one on the wallpaper, and it cannot see what the tap was for. The
    /// composer bar hit the identical problem when the UIKit bar replaced the SwiftUI one — tapping
    /// the field for Paste closed the keyboard — and the answer there is the one used here: the view
    /// that RECEIVES the touch leaves a timestamp, and the deferred dismissal declines when it finds
    /// a fresh one.
    ///
    /// ⚠️ STAMPED IN `hitTest` RATHER THAN IN THE TAP HANDLER, and that is what makes it sound. A
    /// hit test happens while the touch is being delivered, which is strictly before any gesture on
    /// any view can recognise it, so the stamp is always there to be read. A handler fires from
    /// gesture recognition, and two recognisers on one touch have no guaranteed order between them.
    static let controlTouch = TouchClock()

    /// The disc and the waveform own their touches; everything else lets them through so the
    /// bubble's own long press and reply swipe still work over the rest of the note.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for v in [disc, wave, speedPill] where !v.isHidden {
            let local = convert(point, to: v)
            if v.bounds.contains(local) {
                // A nil event is a layout-time query, not a finger; only a real touch is stamped.
                if event != nil { VoiceBubbleView.controlTouch.last = Date() }
                return v.hitTest(local, with: event) ?? v
            }
        }
        return nil
    }

    func prepareForReuse() {
        bag.removeAll()
        body = nil
        wave.progress = 0
        disc.showsPause = false
        disc.isBusy = false
    }
}
