import UIKit

/// The reference app's `AudioWaveformProgressView.redrawSamples`, drawn by a UIView. Fed decibel
/// samples from `SampledWaveform`, it draws them their way and nothing else:
///
///   · bar width 2, at least 2 between bars, at least 2 tall           (`sampleWidth` etc.)
///   · as many bars as fit: (width + 2) / 4, the rest of the width shared evenly between them
///   · height = the view's height × the 0…1 level, the loudest value drawn being full height
///   · a 2pt full-height thumb at width × progress, corner radius 1
///   · played on the left of the thumb, unplayed on the right; at progress 0 everything is unplayed
///
/// ⚠️ NO KNEE, NO CEILING, NO PERCEPTUAL CURVE. `WaveformBars.display` carries three of those,
/// each earned against a different report about the sent bubble; this view is for the review strip
/// he compared to the reference, and the comparison is only honest if the maths is theirs.
///
/// Scrubbing rides the same `AxisLockedScrubRecognizer` the bubble uses, so a tap lands and a
/// horizontal drag scrubs while a vertical touch is refused before it can begin.
final class ComposerWaveformView: UIView {
    var decibels: [Float] = [] { didSet { setNeedsDisplay() } }
    var progress: Double = 0 { didSet { setNeedsDisplay() } }
    var played: UIColor = .label { didSet { setNeedsDisplay() } }
    var unplayed: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }
    var onSeek: (Double) -> Void = { _ in }

    private static let sampleWidth: CGFloat = 2
    private static let minSampleSpacing: CGFloat = 2
    private static let minSampleHeight: CGFloat = 2

    private var startPct: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        let pan = AxisLockedScrubRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let width = bounds.width, height = bounds.height
        guard width > 0 else { return }
        // Their `targetSamplesCount`, then "we might not have enough samples".
        let target = Int((width + Self.minSampleSpacing) / (Self.sampleWidth + Self.minSampleSpacing))
        let amplitudes = SampledWaveform.levels(for: decibels, count: target)
        guard !amplitudes.isEmpty else { return }
        let count = min(target, amplitudes.count)
        let gaps = max(0, count - 1)
        let spacing: CGFloat = gaps > 0
            ? max(0, width - Self.sampleWidth * CGFloat(count)) / CGFloat(gaps)
            : 0
        let p = CGFloat(max(0, min(1, progress)))
        let playedLines = Int(CGFloat(amplitudes.count) * p)

        let playedPath = UIBezierPath(), unplayedPath = UIBezierPath()
        for (x, sample) in amplitudes.prefix(count).enumerated() {
            // Their rule, verbatim: `(x > playedLines) || (progress == 0)` → unplayed.
            let isUnplayed = x > playedLines || p == 0
            let h = max(Self.minSampleHeight, height * CGFloat(sample))
            let bar = CGRect(x: CGFloat(x) * (Self.sampleWidth + spacing),
                             y: height / 2 - h / 2,
                             width: Self.sampleWidth, height: h)
            let path = UIBezierPath(roundedRect: bar, cornerRadius: Self.sampleWidth / 2)
            if isUnplayed { unplayedPath.append(path) } else { playedPath.append(path) }
        }
        played.setFill(); playedPath.fill()
        unplayed.setFill(); unplayedPath.fill()

        // Their `thumbView`: sample-wide, full height, at width × progress.
        let thumb = CGRect(x: width * p, y: 0, width: Self.sampleWidth, height: height)
        played.setFill()
        UIBezierPath(roundedRect: thumb, cornerRadius: Self.sampleWidth / 2).fill()
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let w = max(1, bounds.width)
        onSeek(max(0, min(1, Double(g.location(in: self).x / w))))
    }

    @objc private func handlePan(_ g: AxisLockedScrubRecognizer) {
        let w = max(1, bounds.width)
        switch g.state {
        case .began:
            startPct = max(0, min(1, progress))
            VoiceScrubState.active = true
            fallthrough
        case .changed:
            let pct = startPct + Double(g.translation(in: self).x / w)
            onSeek(max(0, min(1, pct)))
        case .ended, .cancelled, .failed:
            VoiceScrubState.touchOnWaveform = false
            VoiceScrubState.active = false
        default:
            break
        }
    }
}

extension ComposerWaveformView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
