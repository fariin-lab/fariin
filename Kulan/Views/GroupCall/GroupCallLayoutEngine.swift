import CoreGraphics
import Foundation

// The grid maths for the group call stage (owner spec §9 capacity, §11 a real layout algorithm).
// Same method as the reference app's grid: try every column count up to the cap, keep the ones whose
// row count fits, pick the most square tiles, then let every row span the full width so a short last
// row gets wider tiles instead of leaving a hole. Tiles fill the stage (no fixed aspect), so the
// whole area is used whatever the count. Pure value maths: no UIKit, safe to call from a body.
enum GroupCallLayoutEngine {

    /// The most-square grid for `ids` (already in display order) in `size`, capped by
    /// GroupCallMetrics.maxColumns/maxRows; anything past the cap is `overflow`.
    static func grid(ids: [String], in size: CGSize) -> CallGridLayout {
        let inset = GroupCallMetrics.inset
        let spacing = GroupCallMetrics.spacing

        // A duplicate id would overwrite its own frame and leave a hole; keep the first.
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }

        let caps = limits(for: size)
        let shown = Array(unique.prefix(caps.columns * caps.rows))
        let overflow = Array(unique.dropFirst(shown.count))

        let width = size.width - 2 * inset
        let height = size.height - 2 * inset
        // Empty call, or the first layout pass before the stage has a size (spec §14: no broken
        // layout): nothing to place. Overflow still reports the cap so the strip does not flash.
        guard !shown.isEmpty, width > 0, height > 0 else {
            return CallGridLayout(columns: 0, rows: 0, spacing: spacing, inset: inset,
                                  frames: [:], overflow: overflow)
        }

        let shape = bestShape(count: shown.count, width: width, height: height, caps: caps)
        let rowHeight = (height - spacing * CGFloat(shape.rows - 1)) / CGFloat(shape.rows)

        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(shown.count)
        for row in 0..<shape.rows {
            let start = row * shape.columns
            let inRow = min(shape.columns, shown.count - start)
            // Every row spans the full width: the last, shorter row gets wider tiles.
            let tileWidth = (width - spacing * CGFloat(inRow - 1)) / CGFloat(inRow)
            let y = inset + CGFloat(row) * (rowHeight + spacing)
            for col in 0..<inRow {
                let x = inset + CGFloat(col) * (tileWidth + spacing)
                frames[shown[start + col]] = CGRect(x: x, y: y, width: tileWidth, height: rowHeight)
            }
        }

        return CallGridLayout(columns: shape.columns, rows: shape.rows, spacing: spacing, inset: inset,
                              frames: frames, overflow: overflow)
    }

    /// How many tiles the grid can hold in `size` (columns x rows cap).
    static func capacity(in size: CGSize) -> Int {
        let caps = limits(for: size)
        return caps.columns * caps.rows
    }

    // MARK: - Internals

    /// Column / row caps. The reference app's caps are by screen size only; a phone on its side
    /// would then be held to 2 wide columns, so a landscape stage may use 3 (owner spec §9). A short
    /// stage (a phone on its side, under 300pt tall) holds 2 rows: three rows there are thin strips
    /// with no room for a face; the rest go to the strip.
    private static func limits(for size: CGSize) -> (columns: Int, rows: Int) {
        var columns = GroupCallMetrics.maxColumns(width: size.width)
        if size.width > size.height { columns = max(columns, 3) }
        var rows = GroupCallMetrics.maxRows(height: size.height)
        if size.height < 300 { rows = min(rows, 2) }
        return (max(columns, 1), max(rows, 1))
    }

    /// Picks columns x rows for `count` tiles in the content area (`width` x `height`, inset
    /// already removed). Score = mean distance of every tile's aspect from square, on a log scale so
    /// 2:1 and 1:2 count the same, counting the wider last-row tiles as they will really be drawn.
    /// Near-ties go to more rows than columns, as in the reference app. `count` must fit the caps.
    private static func bestShape(count: Int, width: CGFloat, height: CGFloat,
                                  caps: (columns: Int, rows: Int)) -> (columns: Int, rows: Int) {
        let spacing = GroupCallMetrics.spacing
        var best: (columns: Int, rows: Int, score: CGFloat)?

        // More columns than tiles would only repeat the cols = count shape.
        for columns in 1...max(1, min(caps.columns, count)) {
            let rows = (count + columns - 1) / columns
            guard rows <= caps.rows else { continue }

            let rowHeight = (height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let fullWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let lastCount = count - columns * (rows - 1)
            let lastWidth = (width - spacing * CGFloat(lastCount - 1)) / CGFloat(lastCount)
            guard rowHeight > 0, fullWidth > 0 else { continue }

            let fullCost = abs(log(fullWidth / rowHeight)) * CGFloat(count - lastCount)
            let lastCost = abs(log(lastWidth / rowHeight)) * CGFloat(lastCount)
            let score = (fullCost + lastCost) / CGFloat(count)

            if let current = best {
                let nearTie = abs(score - current.score) < 0.01
                if nearTie ? rows > current.rows : score < current.score {
                    best = (columns: columns, rows: rows, score: score)
                }
            } else {
                best = (columns: columns, rows: rows, score: score)
            }
        }

        // Only reached on a degenerate size (content too small for the spacing): fall back to
        // the widest allowed shape so every shown tile still gets a frame.
        guard let chosen = best else {
            let columns = max(1, min(caps.columns, count))
            return (columns, (count + columns - 1) / columns)
        }
        return (chosen.columns, chosen.rows)
    }
}

#if DEBUG
extension GroupCallLayoutEngine {
    /// Documentation as code: the layouts a 390x700 portrait stage should get (inset 6, spacing 6,
    /// cap 2 x 3 = 6). Not run automatically; call it from a test or the debugger. Returns the
    /// mismatches, empty when the engine matches.
    ///   n=1  1 col x 1 row   one tile 378x688
    ///   n=2  1 x 2           two full-width tiles 378x341, stacked
    ///   n=3  2 x 2           186x341 pair on top, one 378x341 tile below
    ///   n=4  2 x 2           four 186x341 tiles
    ///   n=5  2 x 3           two rows of 186x225.3, one 378x225.3 tile below
    ///   n=6  2 x 3           six 186x225.3 tiles
    ///   n=7  2 x 3           as n=6, 1 in overflow
    ///   n=8  2 x 3           as n=6, 2 in overflow
    static func debugSelfCheck() -> [String] {
        let size = CGSize(width: 390, height: 700)
        // (count, columns, rows, overflow, size of the LAST shown tile)
        let expected: [(Int, Int, Int, Int, CGSize)] = [
            (1, 1, 1, 0, CGSize(width: 378, height: 688)),
            (2, 1, 2, 0, CGSize(width: 378, height: 341)),
            (3, 2, 2, 0, CGSize(width: 378, height: 341)),
            (4, 2, 2, 0, CGSize(width: 186, height: 341)),
            (5, 2, 3, 0, CGSize(width: 378, height: 676.0 / 3)),
            (6, 2, 3, 0, CGSize(width: 186, height: 676.0 / 3)),
            (7, 2, 3, 1, CGSize(width: 186, height: 676.0 / 3)),
            (8, 2, 3, 2, CGSize(width: 186, height: 676.0 / 3)),
        ]
        var failures: [String] = []
        if capacity(in: size) != 6 { failures.append("capacity \(capacity(in: size)) != 6") }
        let empty = grid(ids: [], in: size)
        if !empty.frames.isEmpty || !empty.overflow.isEmpty { failures.append("n=0 not empty") }

        for (n, columns, rows, overflow, lastSize) in expected {
            let ids = (0..<n).map { "p\($0)" }
            let layout = grid(ids: ids, in: size)
            if layout.columns != columns || layout.rows != rows {
                failures.append("n=\(n): \(layout.columns)x\(layout.rows), want \(columns)x\(rows)")
            }
            if layout.overflow.count != overflow || layout.frames.count != n - overflow {
                failures.append("n=\(n): \(layout.frames.count) shown + \(layout.overflow.count) overflow")
            }
            if let last = layout.frames[ids[n - overflow - 1]],
               abs(last.width - lastSize.width) > 0.5 || abs(last.height - lastSize.height) > 0.5 {
                failures.append("n=\(n): last tile \(last.size), want \(lastSize)")
            }
            if let first = layout.frames[ids[0]], first.minX != 6 || first.minY != 6 {
                failures.append("n=\(n): first tile at \(first.origin), want (6, 6)")
            }
        }
        return failures
    }
}
#endif
