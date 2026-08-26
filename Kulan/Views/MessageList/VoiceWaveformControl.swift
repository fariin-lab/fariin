import UIKit
import SwiftUI

/// ⛔ STEP TWO: THE WAVEFORM, DRAWN AND SCRUBBED IN ONE UIKIT VIEW.
///
/// What it replaces was three views stacked on the same 104×22 points, because SwiftUI could not do
/// the job in one:
///
///   1. a `Canvas` drawing the bars, re-run by SwiftUI every time `progress` moved,
///   2. a `WaveformGestureArea` overlaid on top of it — already UIKit, because the one rule that
///      matters here (never take a vertical touch) cannot be written in SwiftUI at all, and
///   3. a second overlay for the playhead, positioned from a `GeometryReader`.
///
/// One `UIView` owns all three now. The bars and the playhead are drawn in the same pass, and the
/// recogniser sits on the view that draws them instead of on a transparent sheet above it. The
/// progress tick moves a `CGFloat` and calls `setNeedsDisplay`; nothing re-runs a view body.
///
/// ⚠️ THE HEIGHT MAPPING STAYS IN `WaveformBars.display`. Every number in it was measured against
/// the reference apps over several rounds — the −20 dB window, the quiet knee, the soft ceiling —
/// and it is deliberately NOT copied here. One place decides what a stored bar looks like, so the
/// recorder strip, the gallery and this bubble cannot drift apart.
final class VoiceWaveformView: UIView {

    var bars: [Int] = [] { didSet { if bars != oldValue { setNeedsDisplay() } } }
    var progress: Double = 0 { didSet { if progress != oldValue { setNeedsDisplay() } } }
    var playedColor: UIColor = .label { didSet { setNeedsDisplay() } }
    var unplayedColor: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }

    var onSeek: (Double) -> Void = { _ in }
    var onScrub: (Bool) -> Void = { _ in }

    private var startPct: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)

        // The same recogniser the overlay used, on the view that draws the bars now. It decides the
        // axis at touch-down and fails instantly on a vertical movement, which is what leaves the
        // chat's scrolling completely alone — see its own notes.
        let pan = AxisLockedScrubRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), rect.width > 0, rect.height > 0 else { return }

        // AIR BETWEEN THE BARS. All 40 stored bars in a slim bubble gave a 2.75pt slot — a picket
        // fence pressed into a plank. Downsampled at DRAW time so a slot is never under 4pt, taking
        // each bucket's LOUDEST bar so peaks survive the merge, which also re-shapes every note ever
        // sent with no migration.
        let maxBars = max(8, Int(rect.width / 4))
        let step = max(1, Int((Double(bars.count) / Double(maxBars)).rounded(.up)))
        var drawn: [Int] = []
        var b = 0
        while b < bars.count {
            drawn.append(bars[b..<min(b + step, bars.count)].max() ?? 0)
            b += step
        }
        guard !drawn.isEmpty else { return }

        let slot = rect.width / CGFloat(drawn.count)
        let barW = max(2, slot * 0.5)
        let playedTo = Int(Double(drawn.count) * progress)

        for (i, v) in drawn.enumerated() {
            let h = max(2, WaveformBars.display(v) * rect.height)
            let x = CGFloat(i) * slot + (slot - barW) / 2
            let bar = CGRect(x: x, y: (rect.height - h) / 2, width: barW, height: h)
            ctx.setFillColor((i <= playedTo ? playedColor : unplayedColor).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: bar, cornerRadius: barW / 2).cgPath)
            ctx.fillPath()
        }

        // THE PLAYHEAD: a flat capped rule the height of the wave, not a round knob sitting proud of
        // it (owner, 2026-08-24). It marks the spot and reads as part of the waveform.
        let x = rect.width * CGFloat(max(0, min(1, progress)))
        let head = CGRect(x: x - 1.25, y: 0, width: 2.5, height: rect.height)
        ctx.setFillColor(playedColor.cgColor)
        ctx.addPath(UIBezierPath(roundedRect: head, cornerRadius: 1.25).cgPath)
        ctx.fillPath()
    }

    // MARK: - Touch

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let w = max(1, bounds.width)
        onSeek(max(0, min(1, Double(g.location(in: self).x / w))))
    }

    @objc private func handlePan(_ g: AxisLockedScrubRecognizer) {
        let w = max(1, bounds.width)
        switch g.state {
        case .began:
            startPct = max(0, min(1, progress))
            // `touchOnWaveform` is claimed at touch-down inside the recogniser, not here — see its
            // note. `active` means "a scrub is really under way", which is a different fact and is
            // what stops the reply swipe FIRING at the end.
            VoiceScrubState.active = true
            onScrub(true)
            fallthrough
        case .changed:
            onSeek(max(0, min(1, startPct + Double(g.translation(in: self).x / w))))
        case .ended, .cancelled, .failed:
            VoiceScrubState.touchOnWaveform = false
            VoiceScrubState.active = false
            onScrub(false)
        default:
            break
        }
    }
}

extension VoiceWaveformView: UIGestureRecognizerDelegate {
    /// Co-exist with everything. The bubble's long-press-for-menu lives on an ancestor and must keep
    /// receiving these touches; the scroll view's pan is vertical-only, so it can never fight us.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The seam, kept as thin as the disc's. Everything around the wave — the row, the pill, the meta
/// line, the bubble — is untouched.
struct VoiceWaveform: UIViewRepresentable {
    let bars: [Int]
    let progress: Double
    let played: Color
    let unplayed: Color
    let onSeek: (Double) -> Void
    let onScrub: (Bool) -> Void

    func makeUIView(context: Context) -> VoiceWaveformView { VoiceWaveformView() }

    func updateUIView(_ v: VoiceWaveformView, context: Context) {
        v.bars = bars
        v.progress = progress
        v.playedColor = UIColor(played)
        v.unplayedColor = UIColor(unplayed)
        // Re-set every pass: a recycled cell must never seek the note it used to hold.
        v.onSeek = onSeek
        v.onScrub = onScrub
    }
}
