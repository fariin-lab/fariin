import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): the message text in the editor, selectable word by word.
//
// SwiftUI text cannot hand back a selected range, so the editor draws a message's text with a
// read-only UITextView: a long press selects words, and the edit menu offers only our own actions.
// The saved picture never uses this view; it draws the same text with `ShotDustRenderer`.

/// What the editor can do to one message from inside its text.
struct ShotTextActions {
    var cover: (NSRange) -> Void
    var coverWhole: () -> Void
    var reveal: (Int) -> Void
    var remove: () -> Void
}

struct ShotSelectableText: UIViewRepresentable {
    let text: String
    let color: UIColor
    let dustColor: UIColor
    let cover: ShotCover
    let actions: ShotTextActions

    private var font: UIFont { BubbleMetrics.bodyFont }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ShotTextView {
        let v = ShotTextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ v: ShotTextView, context: Context) {
        context.coordinator.parent = self
        v.show(attributed, covered: cover.ranges, dustColor: dustColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShotTextView, context: Context) -> CGSize? {
        let w = min(proposal.width ?? 10_000, 10_000)
        let box = attributed.boundingRect(with: CGSize(width: max(w, 1), height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: min(ceil(box.width), w), height: ceil(box.height))
    }

    /// Covered words are drawn clear: they keep their place in the line, and the dots sit on top.
    private var attributed: NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let length = (text as NSString).length
        for r in cover.ranges where NSMaxRange(r) <= length {
            out.addAttribute(.foregroundColor, value: UIColor.clear, range: r)
        }
        return out
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ShotSelectableText
        init(_ parent: ShotSelectableText) { self.parent = parent }

        /// Only our actions: copying or looking up words is not what this screen is for.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let actions = parent.actions
            var items: [UIMenuElement] = []
            if range.length > 0 {
                items.append(UIAction(title: "Hide Text", image: UIImage(systemName: "eye.slash")) { [weak textView] _ in
                    actions.cover(range)
                    textView?.selectedRange = NSRange(location: 0, length: 0)
                })
            }
            items.append(UIAction(title: "Hide Message", image: UIImage(systemName: "eye.slash.circle")) { _ in
                actions.coverWhole()
            })
            items.append(UIAction(title: "Remove", image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { _ in actions.remove() })
            return UIMenu(children: items)
        }

        /// A tap on covered words shows them again.
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView, !parent.cover.ranges.isEmpty,
                  let pos = tv.closestPosition(to: g.location(in: tv)) else { return }
            parent.actions.reveal(tv.offset(from: tv.beginningOfDocument, to: pos))
        }
    }
}

/// The text view, with one dot view per covered line fragment laid over it.
final class ShotTextView: UITextView {
    private var covered: [NSRange] = []
    private var dustColor: UIColor = .label
    private var dust: [ShotDustUIView] = []

    func show(_ text: NSAttributedString, covered: [NSRange], dustColor: UIColor) {
        if attributedText != text { attributedText = text }
        self.covered = covered
        self.dustColor = dustColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rects = covered.flatMap(rects(for:))
        while dust.count < rects.count {
            let d = ShotDustUIView()
            addSubview(d)
            dust.append(d)
        }
        for (i, d) in dust.enumerated() {
            d.isHidden = i >= rects.count
            guard i < rects.count else { continue }
            d.frame = rects[i]
            d.color = dustColor
        }
    }

    private func rects(for r: NSRange) -> [CGRect] {
        guard let start = position(from: beginningOfDocument, offset: r.location),
              let end = position(from: start, offset: r.length),
              let range = textRange(from: start, to: end) else { return [] }
        return selectionRects(for: range).map(\.rect).filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}
