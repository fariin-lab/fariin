import CoreGraphics
import Foundation

/// Mosaic layout for a media group (2...10 photos/videos in one message).
///
/// OUR OWN SOLVER. Telegram-iOS is GPLv2 and the standing rule on this project is that we never port
/// their code — the reference here is the BEHAVIOUR, captured from ten screenshots of Telegram's output
/// at square aspect (user, 2026-07-27), which pin the arrangement for every count from 1 to 10:
///
///      1 full          2 |            3 ▔▔▔        4 ▌▔▔       5 ▔ ▔        6 ▔ ▔
///                      2 columns        ▁ ▁          ▌▁▁         ▁ ▁ ▁        ▔ ▔
///                                                    ▌▁▁                      ▔ ▔
///      7 ▔ ▔          8 ▔ ▔          9 ▔ ▔ ▔       10 ▔ ▔
///        ▔ ▔            ▔ ▔ ▔          ▔ ▔ ▔          ▔ ▔
///        ▔ ▔ ▔          ▔ ▔ ▔          ▔ ▔ ▔          ▔ ▔ ▔
///                                                     ▔ ▔ ▔
///
/// Two rules do most of the work, and both are visible in those images:
///   * A row holds two or three items. Never one (except a deliberate full-width hero) and never four.
///   * Aspect decides orientation for the small counts: WIDE media stacks into full-width rows, TALL
///     media sits side by side in columns. At square, the counts below are the tie-break.
///
/// Everything is computed in a UNIT box (width 1, height = whatever the rows need) so the caller can
/// scale it to any bubble width and get exact, non-distorting frames.
enum MediaGroupLayout {

    /// One tile's placement, in unit coordinates: x/y/width/height are fractions of the group's width.
    struct Tile {
        let index: Int          // index into the original media array
        let rect: CGRect        // unit rect; multiply by the rendered width
    }

    struct Result {
        let tiles: [Tile]
        /// Total height as a multiple of the width. Height in points = width * heightRatio.
        let heightRatio: CGFloat
    }

    /// Spacing between tiles, in points. Telegram's is hairline; ours matches at 2pt.
    static let spacing: CGFloat = 2

    // MARK: - Entry point

    /// - Parameter aspects: width/height for each item, in order. Unknown → pass 1 (square).
    static func solve(aspects rawAspects: [CGFloat]) -> Result {
        let n = rawAspects.count
        guard n > 0 else { return Result(tiles: [], heightRatio: 0) }
        // Clamp: a panorama or a very tall shot must not be allowed to dictate a whole row's height.
        let a = rawAspects.map { min(max($0.isFinite && $0 > 0 ? $0 : 1, 0.55), 1.8) }

        switch n {
        case 1:
            return Result(tiles: [Tile(index: 0, rect: CGRect(x: 0, y: 0, width: 1, height: 1))],
                          heightRatio: 1 / a[0])
        case 2:  return two(a)
        case 3:  return three(a)
        case 4:  return four(a)
        default: return rows(a, pattern: rowPattern(for: n))
        }
    }

    // MARK: - The small counts, where aspect changes the shape

    /// Two side by side, unless BOTH are wide — then stacked, because two letterboxes in columns leaves
    /// two slivers. This is the one case where Telegram visibly switches on aspect and it reads correctly.
    private static func two(_ a: [CGFloat]) -> Result {
        let bothWide = a[0] > 1.2 && a[1] > 1.2
        if bothWide {
            // Two full-width rows, each keeping its own aspect.
            let h0 = 1 / a[0], h1 = 1 / a[1]
            let gap = spacingRatio()
            return Result(tiles: [
                Tile(index: 0, rect: CGRect(x: 0, y: 0, width: 1, height: h0)),
                Tile(index: 1, rect: CGRect(x: 0, y: h0 + gap, width: 1, height: h1)),
            ], heightRatio: h0 + gap + h1)
        }
        // Columns: both share one height, widths split in proportion to their aspects so neither is
        // squeezed more than the other.
        let gap = spacingRatio()
        let usable = 1 - gap
        let w0 = usable * (a[0] / (a[0] + a[1]))
        let w1 = usable - w0
        let h = min(w0 / a[0], w1 / a[1])
        return Result(tiles: [
            Tile(index: 0, rect: CGRect(x: 0, y: 0, width: w0, height: h)),
            Tile(index: 1, rect: CGRect(x: w0 + gap, y: 0, width: w1, height: h)),
        ], heightRatio: h)
    }

    /// A hero plus two. Wide hero → it takes a full-width top row and the pair sits under it (screenshot 3).
    /// Otherwise the hero is a tall left column with the pair stacked beside it.
    private static func three(_ a: [CGFloat]) -> Result {
        let gap = spacingRatio()
        if a[0] >= 1.0 {
            let heroH = 1 / a[0]
            let usable = 1 - gap
            let w1 = usable * (a[1] / (a[1] + a[2]))
            let w2 = usable - w1
            let rowH = min(w1 / a[1], w2 / a[2])
            return Result(tiles: [
                Tile(index: 0, rect: CGRect(x: 0, y: 0, width: 1, height: heroH)),
                Tile(index: 1, rect: CGRect(x: 0, y: heroH + gap, width: w1, height: rowH)),
                Tile(index: 2, rect: CGRect(x: w1 + gap, y: heroH + gap, width: w2, height: rowH)),
            ], heightRatio: heroH + gap + rowH)
        }
        // Tall hero on the left; the other two stack on the right and together match its height.
        let heroW: CGFloat = 0.62
        let sideW = 1 - heroW - gap
        let heroH = heroW / a[0]
        let sideH = (heroH - gap) / 2
        return Result(tiles: [
            Tile(index: 0, rect: CGRect(x: 0, y: 0, width: heroW, height: heroH)),
            Tile(index: 1, rect: CGRect(x: heroW + gap, y: 0, width: sideW, height: sideH)),
            Tile(index: 2, rect: CGRect(x: heroW + gap, y: sideH + gap, width: sideW, height: sideH)),
        ], heightRatio: heroH)
    }

    /// Screenshot 4: one tall hero on the left, three stacked down the right. A wide first item flips it
    /// to a full-width hero over a row of three, which is the same idea rotated.
    private static func four(_ a: [CGFloat]) -> Result {
        let gap = spacingRatio()
        if a[0] > 1.2 {
            let heroH = 1 / a[0]
            let usable = 1 - 2 * gap
            let total = a[1] + a[2] + a[3]
            var x: CGFloat = 0
            var tiles = [Tile(index: 0, rect: CGRect(x: 0, y: 0, width: 1, height: heroH))]
            var rowH: CGFloat = .greatestFiniteMagnitude
            var widths: [CGFloat] = []
            for i in 1...3 {
                let w = usable * (a[i] / total)
                widths.append(w)
                rowH = min(rowH, w / a[i])
            }
            for (k, w) in widths.enumerated() {
                tiles.append(Tile(index: k + 1, rect: CGRect(x: x, y: heroH + gap, width: w, height: rowH)))
                x += w + gap
            }
            return Result(tiles: tiles, heightRatio: heroH + gap + rowH)
        }
        let heroW: CGFloat = 0.60
        let sideW = 1 - heroW - gap
        let heroH = heroW / a[0]
        let sideH = (heroH - 2 * gap) / 3
        var tiles = [Tile(index: 0, rect: CGRect(x: 0, y: 0, width: heroW, height: heroH))]
        for k in 0..<3 {
            tiles.append(Tile(index: k + 1,
                              rect: CGRect(x: heroW + gap, y: CGFloat(k) * (sideH + gap),
                                           width: sideW, height: sideH)))
        }
        return Result(tiles: tiles, heightRatio: heroH)
    }

    // MARK: - Five and up

    /// Row sizes for each count, read straight off the reference screenshots. Note that 6 is 2+2+2 and
    /// NOT 3+3: a two-column six reads as a block, a three-column six reads as a strip. Counts past 10
    /// never reach here (the sender splits into groups of ten) but the fallback stays sane anyway.
    static func rowPattern(for n: Int) -> [Int] {
        switch n {
        case 5:  return [2, 3]
        case 6:  return [2, 2, 2]
        case 7:  return [2, 2, 3]
        case 8:  return [2, 3, 3]
        case 9:  return [3, 3, 3]
        case 10: return [2, 2, 3, 3]
        default:
            var left = n, out: [Int] = []
            while left > 0 { let take = min(3, left); out.append(take); left -= take }
            return out
        }
    }

    /// Lay out fixed-size rows. Within a row, widths are proportional to aspect so nothing is squashed
    /// more than its neighbour, and the row's height is whatever lets every tile fill its width.
    private static func rows(_ a: [CGFloat], pattern: [Int]) -> Result {
        let gap = spacingRatio()
        var tiles: [Tile] = []
        var y: CGFloat = 0
        var idx = 0
        for (r, count) in pattern.enumerated() {
            let usable = 1 - gap * CGFloat(count - 1)
            let slice = Array(a[idx..<min(idx + count, a.count)])
            guard !slice.isEmpty else { break }
            let total = slice.reduce(0, +)
            var widths = slice.map { usable * ($0 / total) }
            // Guard against a rounding drift accumulating across the row.
            let drift = usable - widths.reduce(0, +)
            if let last = widths.indices.last { widths[last] += drift }
            var rowH = CGFloat.greatestFiniteMagnitude
            for (k, w) in widths.enumerated() { rowH = min(rowH, w / slice[k]) }
            var x: CGFloat = 0
            for (k, w) in widths.enumerated() {
                tiles.append(Tile(index: idx + k, rect: CGRect(x: x, y: y, width: w, height: rowH)))
                x += w + gap
            }
            y += rowH
            if r < pattern.count - 1 { y += gap }
            idx += count
        }
        return Result(tiles: tiles, heightRatio: y)
    }

    /// The gap expressed in unit width. The solver works at width 1 and the caller scales, so the gap has
    /// to be converted at a representative bubble width or it would grow with the bubble.
    private static func spacingRatio(referenceWidth: CGFloat = 260) -> CGFloat {
        spacing / referenceWidth
    }
}
