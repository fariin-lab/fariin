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

/// The LIVE waveform of a locked recording (owner 2026-10-15, with a picture: "X · waveform · 1 ·
/// send" in one 44pt bar). Fed `AudioRecorder.levels` (0…1, 30Hz, the last 80) every display-link
/// tick. The newest level stands at the right edge and older ones walk left; a quiet moment is a dot
/// (a bar as tall as it is wide), sound rises into a bar. Nothing to tap: scrubbing is the review's.
final class LiveLevelsView: UIView {
    var levels: [Float] = [] { didSet { setNeedsDisplay() } }
    var color: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }

    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let step = Self.barWidth + Self.spacing
        let fit = Int((w + Self.spacing) / step)
        guard fit > 0 else { return }
        let shown = Array(levels.suffix(fit))
        let path = UIBezierPath()
        // Right-aligned: the newest sample's bar ends at the right edge.
        for (i, level) in shown.reversed().enumerated() {
            let x = w - Self.barWidth - CGFloat(i) * step
            let bh = max(Self.barWidth, h * CGFloat(max(0, min(1, level))))
            let bar = CGRect(x: x, y: (h - bh) / 2, width: Self.barWidth, height: bh)
            path.append(UIBezierPath(roundedRect: bar, cornerRadius: Self.barWidth / 2))
        }
        color.setFill()
        path.fill()
    }
}

/// A soft shape whose outline keeps morphing, for the halo around the recording mic (owner
/// 2026-10-15: "the recording animation looks ugly, use the reference's"). The reference draws its
/// halo as blobs, not circles: eight points around a circle, each pulled in by a random amount, joined
/// by a smooth closed curve, and the outline animates from one random shape to the next without
/// stopping. Louder speaks faster: each morph takes 1 / speed seconds, speed rising from 0.9 to 4
/// with the level (the reference's range). Size is NOT this view's business: the composer scales it
/// by the level exactly as it scaled the old circles, so nothing about the halo's size changes.
final class BlobView: UIView {
    var color: UIColor = .clear { didSet { shape.fillColor = color.cgColor } }
    /// 0…1, the recorder's smoothed level; read at the start of every morph.
    var level: CGFloat = 0

    private let shape = CAShapeLayer()
    private var running = false
    private static let points = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        if !running { shape.path = Self.path(in: bounds.size, wobble: 0) }
    }

    func start() {
        guard !running else { return }
        running = true
        morph()
    }

    func stop() {
        running = false
        shape.removeAllAnimations()
        shape.path = Self.path(in: bounds.size, wobble: 0)
    }

    private func morph() {
        guard running, bounds.width > 0 else { return }
        let next = Self.path(in: bounds.size, wobble: 1)
        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = shape.presentation()?.path ?? shape.path
        anim.toValue = next
        let speed = 0.9 + (4 - 0.9) * max(0, min(1, level))
        anim.duration = 1 / Double(speed)
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shape.path = next
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.morph() }
        shape.add(anim, forKey: "morph")
        CATransaction.commit()
    }

    /// A closed smooth curve through `points` points on a circle filling `size`, each pulled in by
    /// up to 14% of the radius × `wobble` (0 = a circle). Always the same number of curve segments,
    /// so any two shapes can be animated between.
    private static func path(in size: CGSize, wobble: CGFloat) -> CGPath {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        guard r > 0 else { return CGMutablePath() }
        let n = points
        let pts: [CGPoint] = (0..<n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let rr = r * (1 - 0.14 * wobble * CGFloat.random(in: 0...1))
            return CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        }
        // Catmull-Rom through the points, as cubic Béziers (tension 1/6).
        let p = CGMutablePath()
        p.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        p.closeSubpath()
        return p
    }
}
