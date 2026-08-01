import CoreGraphics
import Foundation

/// Mosaic layout for a media group (2...10 photos or videos sent as one message).
///
/// OUR OWN CODE, THEIR ALGORITHM. Telegram-iOS reports no licence, so shipping their source would
/// oblige publishing Kulan's — reading it to extract the algorithm is fine, pasting it is not (the
/// standing rule on this project). Everything below is written from
/// `submodules/MosaicLayout/Sources/ChatMessageBubbleMosaicLayout.swift`, read 2026-07-28, and each rule
/// cites where it comes from.
///
/// THE POINT OF THE REWRITE (user, 2026-07-28: "Dont use always square, it must use the size of the
/// picture"): the previous version picked a fixed arrangement per count, derived from screenshots that
/// happened to be square photos. That is only correct for square photos. Telegram does not choose by
/// count — it chooses by SHAPE. Three wide landscape shots stack into full-width strips; three tall
/// portrait shots sit side by side as columns; the count only breaks ties.
///
/// The shape of the algorithm:
///
///   1. Classify every item by aspect ratio (w/h): wide `> 1.2`, tall `< 0.8`, otherwise square-ish.
///   2. For 2, 3 and 4 items there are hand-tuned arrangements that read better than anything a
///      general solver produces, chosen by that classification.
///   3. For 5 or more — or whenever any single item is extreme (ratio > 2) — a general solver tries
///      every way of splitting the items into 2, 3 or 4 rows of at most 3, and scores each.
///
/// Row heights are never guessed: a row of items with ratios r₁…rₙ filling width W has exactly one
/// height, `(W - gaps) / Σr`, because each item's width is `ratio × height`. That is what makes the
/// tiles keep their real proportions instead of being cropped to squares.
enum MediaGroupLayout {

    /// Which outer edges of the whole group a tile touches, so the album can round only the corners
    /// that are actually on the outside (Telegram's `MosaicItemPosition`).
    struct Edges: OptionSet {
        let rawValue: Int
        static let top = Edges(rawValue: 1)
        static let bottom = Edges(rawValue: 2)
        static let left = Edges(rawValue: 4)
        static let right = Edges(rawValue: 8)
    }

    /// One tile's placement, in POINTS, relative to the group's top-left.
    struct Tile {
        let index: Int          // index into the original media array
        let rect: CGRect
        let edges: Edges
    }

    struct Result {
        let tiles: [Tile]
        let size: CGSize
    }

    /// Telegram's hairline is 1pt; ours is 2 so the seams read on a wallpaper.
    static let spacing: CGFloat = 2

    // Their constants, unchanged: a tile narrower or shorter than these reads as a sliver.
    private static let minWidth: CGFloat = 68
    private static let minHeight: CGFloat = 81

    // MARK: - Entry point

    /// - Parameters:
    ///   - itemSizes: each item's natural pixel size, in order. Unknown → pass a square.
    ///   - maxSize: the box the group must fit. Width is the bubble's content width; height bounds the
    ///     hand-tuned 2/3/4 arrangements. A square box matches what Telegram passes for grouped media.
    static func solve(itemSizes: [CGSize], maxSize: CGSize, spacing: CGFloat = spacing) -> Result {
        guard !itemSizes.isEmpty else { return Result(tiles: [], size: .zero) }

        let ratios = itemSizes.map { $0.height > 0 ? $0.width / $0.height : 1 }
        // Their classification string: one letter per item, in order.
        let shapes = ratios.map { r -> Character in
            if r > 1.2 { return "w" }        // wide
            if r < 0.8 { return "n" }        // narrow (tall)
            return "q"                        // square-ish
        }
        // A single extreme item (a panorama) makes the hand-tuned arrangements look wrong, so it falls
        // through to the general solver, which crops ratios into a sane band first.
        let forceGeneral = ratios.contains { $0 > 2.0 }
        // Their average seeds at 1.0 before summing, so it is (1 + Σr) / n, not the plain mean. Kept as
        // they have it: it is a threshold input in three places and changing it changes the output.
        let averageRatio = (1.0 + ratios.reduce(0, +)) / CGFloat(ratios.count)

        if !forceGeneral {
            switch itemSizes.count {
            case 1:
                let h = min(maxSize.height, maxSize.width / max(ratios[0], 0.01))
                return finish([placed(0, CGRect(x: 0, y: 0, width: maxSize.width, height: h),
                                      [.top, .bottom, .left, .right])])
            case 2:
                return two(ratios, shapes, maxSize, spacing, averageRatio)
            case 3:
                return three(ratios, shapes, maxSize, spacing)
            case 4:
                return four(ratios, shapes, maxSize, spacing)
            default:
                break
            }
        }
        return general(ratios, maxSize: maxSize, spacing: spacing, averageRatio: averageRatio)
    }

    // MARK: - Two

    private static func two(_ r: [CGFloat], _ shapes: [Character], _ maxSize: CGSize,
                            _ spacing: CGFloat, _ averageRatio: CGFloat) -> Result {
        let maxRatio = maxSize.width / maxSize.height
        let both = String(shapes)

        // Two similar landscapes, wider than the box allows side by side: stack them full width. Side by
        // side they would each be half-width letterboxes, which is two slivers.
        if both == "ww", averageRatio > 1.4 * maxRatio, r[1] - r[0] < 0.2 {
            let w = maxSize.width
            let h = floor(min(w / r[0], min(w / r[1], (maxSize.height - spacing) / 2)))
            return finish([
                placed(0, CGRect(x: 0, y: 0, width: w, height: h), [.top, .left, .right]),
                placed(1, CGRect(x: 0, y: h + spacing, width: w, height: h), [.bottom, .left, .right]),
            ])
        }
        // Two of a kind: equal halves, the shorter one setting the height.
        if both == "ww" || both == "qq" {
            let w = (maxSize.width - spacing) / 2
            let h = floor(min(w / r[0], min(w / r[1], maxSize.height)))
            return finish([
                placed(0, CGRect(x: 0, y: 0, width: w, height: h), [.top, .left, .bottom]),
                placed(1, CGRect(x: w + spacing, y: 0, width: w, height: h), [.top, .right, .bottom]),
            ])
        }
        // Mixed shapes: split the width in proportion to how much each one needs at a shared height.
        let avail = maxSize.width - spacing
        let second = floor(min(0.5 * avail, (avail / r[0] / (1 / r[0] + 1 / r[1])).rounded()))
        let first = maxSize.width - second - spacing
        let h = floor(min(maxSize.height, min(first / r[0], second / r[1]).rounded()))
        return finish([
            placed(0, CGRect(x: 0, y: 0, width: first, height: h), [.top, .left, .bottom]),
            placed(1, CGRect(x: first + spacing, y: 0, width: second, height: h), [.top, .right, .bottom]),
        ])
    }

    // MARK: - Three

    private static func three(_ r: [CGFloat], _ shapes: [Character], _ maxSize: CGSize,
                              _ spacing: CGFloat) -> Result {
        // A TALL first item takes the full height on the left, the other two stack beside it. This is the
        // case the old square-only solver could never produce, and the one the user's photos will hit.
        if shapes[0] == "n" {
            let fullHeight = maxSize.height
            let thirdHeight = min((maxSize.height - spacing) * 0.5,
                                  (r[1] * (maxSize.width - spacing) / (r[2] + r[1])).rounded())
            let secondHeight = maxSize.height - thirdHeight - spacing
            let rightWidth = max(minWidth, min((maxSize.width - spacing) * 0.5,
                                               min(thirdHeight * r[2], secondHeight * r[1]).rounded()))
            let leftWidth = min(fullHeight * r[0], maxSize.width - spacing - rightWidth).rounded()
            return finish([
                placed(0, CGRect(x: 0, y: 0, width: leftWidth, height: fullHeight), [.top, .left, .bottom]),
                placed(1, CGRect(x: leftWidth + spacing, y: 0, width: rightWidth, height: secondHeight), [.right, .top]),
                placed(2, CGRect(x: leftWidth + spacing, y: secondHeight + spacing, width: rightWidth, height: thirdHeight), [.right, .bottom]),
            ])
        }
        // Otherwise: a wide hero across the top, two halves underneath.
        let full = maxSize.width
        let firstHeight = floor(min(full / r[0], (maxSize.height - spacing) * 0.66))
        let half = (maxSize.width - spacing) / 2
        let secondHeight = min(maxSize.height - firstHeight - spacing,
                               min(half / r[1], half / r[2]).rounded())
        return finish([
            placed(0, CGRect(x: 0, y: 0, width: full, height: firstHeight), [.top, .left, .right]),
            placed(1, CGRect(x: 0, y: firstHeight + spacing, width: half, height: secondHeight), [.left, .bottom]),
            placed(2, CGRect(x: half + spacing, y: firstHeight + spacing, width: half, height: secondHeight), [.right, .bottom]),
        ])
    }

    // MARK: - Four

    private static func four(_ r: [CGFloat], _ shapes: [Character], _ maxSize: CGSize,
                             _ spacing: CGFloat) -> Result {
        // A WIDE first item: hero across the top, the other three in a row beneath, each keeping its own
        // width share.
        if shapes[0] == "w" {
            let w = maxSize.width
            let heroHeight = min(w / r[0], (maxSize.height - spacing) * 0.66).rounded()
            let avail = maxSize.width - 2 * spacing
            var rowHeight = (avail / (r[1] + r[2] + r[3])).rounded()
            let w0 = max(minWidth, min(avail * 0.4, rowHeight * r[1]))
            let w2 = max(max(minWidth, avail * 0.33), rowHeight * r[3])
            let w1 = w - w0 - w2 - 2 * spacing
            rowHeight = max(minHeight, min(maxSize.height - heroHeight - spacing, rowHeight))
            let y = heroHeight + spacing
            return finish([
                placed(0, CGRect(x: 0, y: 0, width: w, height: heroHeight), [.top, .left, .right]),
                placed(1, CGRect(x: 0, y: y, width: w0, height: rowHeight), [.left, .bottom]),
                placed(2, CGRect(x: w0 + spacing, y: y, width: w1, height: rowHeight), [.bottom]),
                placed(3, CGRect(x: w0 + w1 + 2 * spacing, y: y, width: w2, height: rowHeight), [.right, .bottom]),
            ])
        }
        // Otherwise: a full-height hero on the LEFT, three stacked down the right side.
        let h = maxSize.height
        let heroWidth = min(h * r[0], (maxSize.width - spacing) * 0.6).rounded()
        var colWidth = ((maxSize.height - 2 * spacing) / (1 / r[1] + 1 / r[2] + 1 / r[3])).rounded()
        let h0 = floor(colWidth / r[1])
        let h1 = floor(colWidth / r[2])
        let h2 = h - h0 - h1 - 2 * spacing
        colWidth = max(minWidth, min(maxSize.width - heroWidth - spacing, colWidth))
        let x = heroWidth + spacing
        return finish([
            placed(0, CGRect(x: 0, y: 0, width: heroWidth, height: h), [.top, .left, .bottom]),
            placed(1, CGRect(x: x, y: 0, width: colWidth, height: h0), [.right, .top]),
            placed(2, CGRect(x: x, y: h0 + spacing, width: colWidth, height: h1), [.right]),
            placed(3, CGRect(x: x, y: h0 + h1 + 2 * spacing, width: colWidth, height: h2), [.right, .bottom]),
        ])
    }

    // MARK: - Five and up, and anything extreme

    private struct Attempt {
        let lineCounts: [Int]
        let heights: [CGFloat]
    }

    private static func general(_ ratios: [CGFloat], maxSize: CGSize, spacing: CGFloat,
                                averageRatio: CGFloat) -> Result {
        // Crop each ratio toward the group's overall orientation, then clamp hard. Without this one
        // panorama would flatten an entire row to a letterbox strip.
        let cropped = ratios.map { r -> CGFloat in
            let pulled = averageRatio > 1.1 ? max(1, r) : min(1, r)
            return max(0.66667, min(1.7, pulled))
        }
        let count = cropped.count

        // A row of these ratios filling the width has exactly this height — that identity is the whole
        // solver.
        func rowHeight(_ slice: ArraySlice<CGFloat>) -> CGFloat {
            let sum = slice.reduce(0, +)
            guard sum > 0 else { return 0 }
            return (maxSize.width - CGFloat(slice.count - 1) * spacing) / sum
        }

        var attempts: [Attempt] = []
        func add(_ counts: [Int]) {
            guard counts.allSatisfy({ $0 > 0 }) else { return }
            var heights: [CGFloat] = []
            var start = 0
            for c in counts {
                heights.append(rowHeight(cropped[start ..< start + c]))
                start += c
            }
            attempts.append(Attempt(lineCounts: counts, heights: heights))
        }

        // Two rows.
        for first in 1 ..< count where first <= 3 && count - first <= 3 {
            add([first, count - first])
        }
        // Three rows. The middle row may hold four when the group is distinctly tall.
        let middleCap = averageRatio < 0.85 ? 4 : 3
        if count >= 3 {
            for first in 1 ..< count - 1 {
                for second in 1 ..< count - first {
                    let third = count - first - second
                    guard first <= 3, second <= middleCap, third <= 3 else { continue }
                    add([first, second, third])
                }
            }
        }
        // Four rows.
        if count >= 4 {
            for first in 1 ..< count - 2 {
                for second in 1 ..< count - first - 1 {
                    for third in 1 ..< count - first - second {
                        let fourth = count - first - second - third
                        guard first <= 3, second <= 3, third <= 3, fourth <= 3 else { continue }
                        add([first, second, third, fourth])
                    }
                }
            }
        }

        // Score: closest to a 3:4 block wins. Two penalties, both theirs — a row wider than the one below
        // it (they want counts flat or growing downward), and a block that ends up too small.
        let target = floor(maxSize.width / 3 * 4)
        var best: Attempt?
        var bestDiff: CGFloat = 0
        for attempt in attempts {
            var total = spacing * CGFloat(attempt.heights.count - 1)
            var runningMin: CGFloat = .greatestFiniteMagnitude
            for h in attempt.heights {
                total += floor(h)
                // NOTE: this compares the RUNNING total, not the individual row height. That is what
                // their code does, and since it only feeds a 1.5x tie-break penalty, reproducing it is
                // how our output matches theirs. Do not "fix" it.
                runningMin = min(runningMin, total)
            }
            var diff = abs(total - target)
            let counts = attempt.lineCounts
            if counts.count > 1, zip(counts, counts.dropFirst()).contains(where: { $0 > $1 }) {
                diff *= 1.5
            }
            if runningMin < minWidth { diff *= 1.5 }
            if best == nil || diff < bestDiff {
                best = attempt
                bestDiff = diff
            }
        }
        guard let optimal = best else { return Result(tiles: [], size: .zero) }

        var tiles: [Tile] = []
        var index = 0
        var y: CGFloat = 0
        for (row, lineCount) in optimal.lineCounts.enumerated() {
            let h = ceil(optimal.heights[row])
            var x: CGFloat = 0
            for k in 0 ..< lineCount {
                var edges: Edges = []
                if row == 0 { edges.insert(.top) }
                if row == optimal.lineCounts.count - 1 { edges.insert(.bottom) }
                if k == 0 { edges.insert(.left) }
                if k == lineCount - 1 { edges.insert(.right) }
                let w = ceil(cropped[index] * h)
                tiles.append(placed(index, CGRect(x: x, y: y, width: w, height: h), edges))
                x += w + spacing
                index += 1
            }
            y += h + spacing
        }

        // Rounding leaves each row a fraction of a point short of the others. Stretch the LAST tile of
        // every row out to the widest row's edge so the block has one flush right side.
        let widest = tiles.reduce(CGFloat(0)) { max($0, $1.rect.maxX) }
        tiles = tiles.map { tile in
            guard tile.edges.contains(.right), tile.rect.maxX < widest else { return tile }
            var rect = tile.rect
            rect.size.width = widest - rect.minX
            return Tile(index: tile.index, rect: rect, edges: tile.edges)
        }
        return finish(tiles)
    }

    // MARK: - Helpers

    private static func placed(_ index: Int, _ rect: CGRect, _ edges: Edges) -> Tile {
        Tile(index: index, rect: rect, edges: edges)
    }

    private static func finish(_ tiles: [Tile]) -> Result {
        var size = CGSize.zero
        for tile in tiles {
            size.width = max(size.width, tile.rect.maxX.rounded())
            size.height = max(size.height, tile.rect.maxY.rounded())
        }
        return Result(tiles: tiles, size: size)
    }
}
