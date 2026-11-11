import Foundation

/// Which bytes of a remote file are on disk: half-open ranges, kept sorted, non-overlapping and
/// with touching ranges joined. A pure value with no disk or network, so it can be tested alone
/// (see `ByteRangeMapTests`). Used by `ChatVideoStream` for the partial file a chat video plays from.
struct ByteRangeMap: Equatable {
    private(set) var ranges: [Range<Int64>] = []

    init() {}

    /// From a saved list. Empty or backwards ranges are dropped; the rest are merged.
    init(_ list: [Range<Int64>]) {
        for r in list { insert(r) }
    }

    /// Bytes held in total.
    var count: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    var isEmpty: Bool { ranges.isEmpty }

    /// Record `r` as held. Merges with anything it overlaps or touches.
    mutating func insert(_ r: Range<Int64>) {
        guard !r.isEmpty, r.lowerBound >= 0 else { return }
        var out: [Range<Int64>] = []
        out.reserveCapacity(ranges.count + 1)
        var cur = r
        var placed = false
        for x in ranges {
            if x.upperBound < cur.lowerBound {
                out.append(x)
            } else if x.lowerBound > cur.upperBound {
                if !placed { out.append(cur); placed = true }
                out.append(x)
            } else {
                cur = min(x.lowerBound, cur.lowerBound) ..< max(x.upperBound, cur.upperBound)
            }
        }
        if !placed { out.append(cur) }
        ranges = out
    }

    /// True when every byte of `r` is held.
    func contains(_ r: Range<Int64>) -> Bool {
        guard !r.isEmpty else { return true }
        return ranges.contains { $0.lowerBound <= r.lowerBound && $0.upperBound >= r.upperBound }
    }

    /// The run of held bytes starting at `offset`, capped at `limit`. Zero when `offset` is missing.
    func contiguous(from offset: Int64, limit: Int64 = .max) -> Int64 {
        for x in ranges where x.lowerBound <= offset && offset < x.upperBound {
            return min(limit, x.upperBound - offset)
        }
        return 0
    }

    /// The first stretch inside `r` that is NOT held, or nil when all of `r` is.
    func firstMissing(in r: Range<Int64>) -> Range<Int64>? {
        guard !r.isEmpty else { return nil }
        var start = r.lowerBound
        for x in ranges {
            if x.upperBound <= start { continue }
            if x.lowerBound >= r.upperBound { break }
            if x.lowerBound > start { return start ..< min(x.lowerBound, r.upperBound) }
            start = x.upperBound
            if start >= r.upperBound { return nil }
        }
        return start < r.upperBound ? start ..< r.upperBound : nil
    }

    /// Whole file present: one range from 0 to `total`.
    func isComplete(total: Int64) -> Bool { total > 0 && contains(0 ..< total) }
}
