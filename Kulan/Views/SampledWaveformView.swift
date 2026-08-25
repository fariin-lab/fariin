import SwiftUI

/// The reference app's `AudioWaveformProgressView.redrawSamples`, as a SwiftUI canvas. Fed decibel
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
/// Scrubbing rides the same `WaveformGestureArea` the bubble uses, so a tap lands and a horizontal
/// drag scrubs while a vertical touch is refused before it can begin.
struct SampledWaveformView: View {
    let decibels: [Float]
    var progress: Double
    var played: Color
    var unplayed: Color
    var onSeek: (Double) -> Void
    var onScrub: (Bool) -> Void = { _ in }

    private static let sampleWidth: CGFloat = 2
    private static let minSampleSpacing: CGFloat = 2
    private static let minSampleHeight: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            let width = size.width, height = size.height
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

            var playedPath = Path(), unplayedPath = Path()
            for (x, sample) in amplitudes.prefix(count).enumerated() {
                // Their rule, verbatim: `(x > playedLines) || (progress == 0)` → unplayed.
                let isUnplayed = x > playedLines || p == 0
                let h = max(Self.minSampleHeight, height * CGFloat(sample))
                let rect = CGRect(x: CGFloat(x) * (Self.sampleWidth + spacing),
                                  y: height / 2 - h / 2,
                                  width: Self.sampleWidth, height: h)
                let bar = Path(roundedRect: rect, cornerRadius: Self.sampleWidth / 2)
                if isUnplayed { unplayedPath.addPath(bar) } else { playedPath.addPath(bar) }
            }
            ctx.fill(playedPath, with: .color(played))
            ctx.fill(unplayedPath, with: .color(unplayed))

            // Their `thumbView`: sample-wide, full height, at width × progress.
            let thumb = CGRect(x: width * p, y: 0, width: Self.sampleWidth, height: height)
            ctx.fill(Path(roundedRect: thumb, cornerRadius: Self.sampleWidth / 2), with: .color(played))
        }
        .contentShape(Rectangle())
        .overlay { WaveformGestureArea(progress: progress, onSeek: onSeek, onScrub: onScrub) }
    }
}
