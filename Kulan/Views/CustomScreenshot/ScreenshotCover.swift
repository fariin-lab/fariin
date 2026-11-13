import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): hiding words inside a message.
//
// A cover is kept per message in the editor, never written into the message itself. Covered words
// are not drawn at all; dots are drawn where they were, so nothing can be read back out of a saved
// picture, even zoomed in.

/// What is covered in one message: some ranges of its text, or the whole message.
struct ShotCover: Equatable {
    /// Ranges in the text's UTF-16 units (what `NSString` and `UITextView` use), sorted, never
    /// overlapping.
    var ranges: [NSRange] = []
    /// The whole message: its text, its quote and its picture.
    var whole = false

    var isEmpty: Bool { ranges.isEmpty && !whole }

    /// Adds a range, folding it into any range it touches.
    mutating func cover(_ r: NSRange) {
        guard r.length > 0 else { return }
        var merged = r
        var kept: [NSRange] = []
        for x in ranges {
            if NSMaxRange(x) < merged.location || NSMaxRange(merged) < x.location {
                kept.append(x)
            } else {
                let start = min(x.location, merged.location)
                merged = NSRange(location: start, length: max(NSMaxRange(x), NSMaxRange(merged)) - start)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.location < $1.location }
    }

    /// Shows again the range that holds `index`. Returns false when nothing was covered there.
    @discardableResult
    mutating func reveal(at index: Int) -> Bool {
        guard let i = ranges.firstIndex(where: { NSLocationInRange(index, $0) }) else { return false }
        ranges.remove(at: i)
        return true
    }

    /// The text split into plain and covered pieces, clamped to the text's length.
    func pieces(of text: String) -> [(String, Bool)] {
        let ns = text as NSString
        var out: [(String, Bool)] = []
        var cursor = 0
        for r in ranges {
            let start = min(max(r.location, cursor), ns.length)
            let end = min(NSMaxRange(r), ns.length)
            if start > cursor { out.append((ns.substring(with: NSRange(location: cursor, length: start - cursor)), false)) }
            if end > start { out.append((ns.substring(with: NSRange(location: start, length: end - start)), true)) }
            cursor = max(cursor, end)
        }
        if cursor < ns.length { out.append((ns.substring(from: cursor), false)) }
        return out
    }
}

/// Marks a run of text as covered, for `ShotDustRenderer`.
struct ShotCoveredRun: TextAttribute {}

/// Draws a text with its covered runs replaced by dots. Pure SwiftUI drawing, so it also works
/// when the picture is rendered offscreen to an image.
struct ShotDustRenderer: TextRenderer {
    let color: Color

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[ShotCoveredRun.self] != nil {
                    ShotDust.paint(in: run.typographicBounds.rect, color: color, ctx: &ctx)
                } else {
                    ctx.draw(run)
                }
            }
        }
    }
}

extension ShotCover {
    /// The SwiftUI text for a message with its covered pieces marked.
    func text(_ s: String) -> Text {
        pieces(of: s).reduce(Text(verbatim: "")) { acc, piece in
            let t = Text(verbatim: piece.0)
            return piece.1 ? Text("\(acc)\(t.customAttribute(ShotCoveredRun()))") : Text("\(acc)\(t)")
        }
    }
}

/// The dots, drawn the same way everywhere: in SwiftUI (`paint`) and in UIKit (`ShotDustUIView`).
enum ShotDust {
    /// Fixed pseudo-random dots, seeded from the rectangle, so a covered word looks the same in the
    /// editor and in the saved picture. Roughly one dot per 6 square points.
    static func dots(in rect: CGRect) -> [(CGRect, Double)] {
        var seed = UInt64(abs(Int(rect.minX * 31 + rect.minY * 17 + rect.width))) &+ 0x9E3779B97F4A7C15
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        let count = max(8, Int(rect.width * rect.height / 6))
        var out: [(CGRect, Double)] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let x = rect.minX + CGFloat(next() >> 40 & 0xFFFF) / 65535 * rect.width
            let y = rect.minY + CGFloat(next() >> 40 & 0xFFFF) / 65535 * rect.height
            let v = next()
            let r: CGFloat = (v >> 20) & 1 == 0 ? 0.6 : 0.9
            let alpha = 0.4 + Double((v >> 30) & 0xFF) / 255 * 0.6
            out.append((CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), alpha))
        }
        return out
    }

    static func paint(in rect: CGRect, color: Color, ctx: inout GraphicsContext) {
        for (dot, alpha) in dots(in: rect) {
            ctx.fill(Path(ellipseIn: dot), with: .color(color.opacity(alpha)))
        }
    }
}

/// Dots over a whole area (a covered picture, quote or event line).
struct ShotDustView: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            ShotDust.paint(in: CGRect(origin: .zero, size: size), color: color, ctx: &ctx)
        }
        .allowsHitTesting(false)
    }
}

/// The same dots as a UIKit view, laid over covered words in the editor's selectable text.
final class ShotDustUIView: UIView {
    var color: UIColor = .label { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        for (dot, alpha) in ShotDust.dots(in: bounds) {
            color.withAlphaComponent(alpha).setFill()
            UIBezierPath(ovalIn: dot).fill()
        }
    }
}
