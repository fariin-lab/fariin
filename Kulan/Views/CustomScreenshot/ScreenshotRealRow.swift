import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13, after testing build 1183): the picture draws the chat's
// REAL rows. Each message is laid out and drawn by the same pipeline the chat list uses
// (`MessageRowLayout.plan` then `MessageRowView.apply`), so bubble styles, link cards, quote cards,
// stickers, photos and ticks come out exactly as in the chat. The SwiftUI copy in
// `ScreenshotBubbles` is only a fallback for a row the chat had no model for.
//
// Two things are changed on the way, both because the picture is drawn offscreen into an image:
// - a bubble or pill that the chat paints with a live blur gets the flat surface instead, since a
//   blur draws nothing in an offscreen image;
// - covered words are drawn clear, and dots are laid over them by a clear selectable text view on
//   top of the body, which is also what lets the editor select words.

/// Everything that decides how one row looks, so the view only rebuilds when one of them changes.
struct ShotRowKey: Equatable {
    var id: String
    var place: ShotPlacement
    var cover: ShotCover
    var dark: Bool
    var width: CGFloat
}

final class ShotRowUIView: UIView, UITextViewDelegate {
    private let row = MessageRowView()
    private let selector = ShotTextView()
    private let wholeCover = UIView()
    private let wholeDust = ShotDustUIView()
    private let fallback = UIImageView()
    private var key: ShotRowKey?
    /// The edit actions; nil while drawing a saved picture.
    var actions: ShotTextActions? { didSet { selector.isUserInteractionEnabled = actions != nil } }
    private(set) var rowHeight: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        addSubview(row)
        addSubview(fallback)
        selector.isEditable = false
        selector.isSelectable = true
        selector.isScrollEnabled = false
        selector.backgroundColor = .clear
        selector.textContainerInset = .zero
        selector.textContainer.lineFragmentPadding = 0
        selector.delegate = self
        selector.isUserInteractionEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        selector.addGestureRecognizer(tap)
        addSubview(selector)
        wholeCover.isUserInteractionEnabled = false
        wholeCover.layer.cornerCurve = .continuous
        wholeCover.addSubview(wholeDust)
        addSubview(wholeCover)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lays the row out at `width` and draws it. Returns quickly when nothing that matters changed.
    func show(_ m: ShotMessage, place: ShotPlacement, cover: ShotCover, look: ShotLook,
              width: CGFloat, cid: String) {
        let k = ShotRowKey(id: m.id, place: place, cover: cover, dark: look.dark, width: width)
        guard k != key else { return }
        key = k
        overrideUserInterfaceStyle = look.dark ? .dark : .light
        if let model = m.model {
            showReal(model, day: m.day, place: place, cover: cover, width: width, cid: cid)
        } else {
            showFallback(m, place: place, cover: cover, look: look, width: width)
        }
        frame.size = CGSize(width: width, height: rowHeight)
    }

    // MARK: The chat's own row

    private func showReal(_ model: MessageRowModel, day: String, place: ShotPlacement, cover: ShotCover,
                          width: CGFloat, cid: String) {
        fallback.isHidden = true
        row.isHidden = false
        let m = Self.prepared(model, day: day, showDay: place.showDay)
        var p = MessageRowLayout.plan(m, width: width)
        selector.isHidden = true
        wholeCover.isHidden = true
        switch p.body {
        case .bubble(var b):
            if b.fill.isWallpaperBlur { b.fill = .received }
            if !cover.ranges.isEmpty { b.bodyAttr = Self.clearing(b.bodyAttr, cover.ranges) }
            p.body = .bubble(b)
            placeSelector(b, cover: cover)
            if cover.whole { placeWholeCover(b.bubble, color: b.fill.representative, ink: b.textColor, radius: 18) }
        case .notice(var n):
            n.wallpaperBlur = nil
            n.onWallpaper = false
            p.body = .notice(n)
            if cover.whole { placeWholeCover(n.capsule, color: .systemGray5, ink: .label, radius: n.capsule.height / 2) }
        case .call:
            break
        }
        p.dateHeader?.wallpaperBlur = nil
        p.dateHeader?.onWallpaper = false
        row.frame = CGRect(x: 0, y: 0, width: p.width, height: p.height)
        row.apply(m, plan: p, cid: cid)
        row.setMediaOnScreen(true)   // stickers draw a frame, videos show their poster
        rowHeight = max(1, p.height + m.topSpacing)
        row.frame.origin.y = m.topSpacing
        selector.frame.origin.y += m.topSpacing
        wholeCover.frame.origin.y += m.topSpacing
    }

    /// A row as the picture wants it: no selection, highlight or unread line, a flat surface where
    /// the chat used a live blur, and the day pill where the picture (not the chat) puts it.
    private static func prepared(_ model: MessageRowModel, day: String, showDay: Bool) -> MessageRowModel {
        var m = model
        m.selecting = false; m.wasSelecting = false; m.selected = false; m.highlighted = false
        m.showsUnreadDivider = false
        m.wallpaperBlur = nil
        if showDay {
            var header = m.dateHeader ?? NoticeRow(text: day, symbol: nil, style: .pill, tapTargetId: nil,
                                                   onWallpaper: false, wallpaperBlur: nil)
            header.onWallpaper = false
            header.wallpaperBlur = nil
            m.dateHeader = header
        } else {
            m.dateHeader = nil
        }
        return m
    }

    private static func clearing(_ attr: NSAttributedString, _ ranges: [NSRange]) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: attr)
        for r in ranges where NSMaxRange(r) <= out.length {
            out.addAttribute(.foregroundColor, value: UIColor.clear, range: r)
        }
        return out
    }

    /// The clear text view over the body: the same words at the same place, drawn invisibly, so a
    /// long press selects real words and covered ranges get their dots in the right spot.
    private func placeSelector(_ b: BubblePlan, cover: ShotCover) {
        guard b.bodyAttr.length > 0, b.text.width > 1 else { return }
        let invisible = NSMutableAttributedString(attributedString: b.bodyAttr)
        invisible.addAttribute(.foregroundColor, value: UIColor.clear,
                               range: NSRange(location: 0, length: invisible.length))
        selector.isHidden = false
        selector.frame = b.text.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY)
        selector.show(invisible, covered: cover.ranges, dustColor: b.textColor)
    }

    private func placeWholeCover(_ rect: CGRect, color: UIColor, ink: UIColor, radius: CGFloat) {
        wholeCover.isHidden = false
        wholeCover.frame = rect
        wholeCover.backgroundColor = color == .clear ? .systemGray5 : color
        wholeCover.layer.cornerRadius = radius
        wholeDust.frame = wholeCover.bounds.insetBy(dx: 8, dy: 6)
        wholeDust.color = ink
    }

    // MARK: Fallback

    private func showFallback(_ m: ShotMessage, place: ShotPlacement, cover: ShotCover, look: ShotLook,
                              width: CGFloat) {
        row.isHidden = true
        selector.isHidden = true
        wholeCover.isHidden = true
        fallback.isHidden = false
        let renderer = ImageRenderer(content: ShotRowView(message: m, look: look, place: place,
                                                          rowWidth: width, cover: cover)
            .frame(width: width)
            .environment(\.colorScheme, look.dark ? .dark : .light))
        renderer.scale = UIScreen.main.scale
        let img = renderer.uiImage
        fallback.image = img
        rowHeight = max(1, img?.size.height ?? 1)
        fallback.frame = CGRect(x: 0, y: 0, width: width, height: rowHeight)
    }

    // MARK: Words

    /// Only our actions: copying or looking up words is not what this screen is for.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let actions else { return nil }
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
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let actions, let key, !key.cover.ranges.isEmpty,
              let pos = selector.closestPosition(to: g.location(in: selector)) else { return }
        actions.reveal(selector.offset(from: selector.beginningOfDocument, to: pos))
    }
}

/// The real row inside the editor's card.
struct ShotRealRow: UIViewRepresentable {
    let message: ShotMessage
    let place: ShotPlacement
    let cover: ShotCover
    let look: ShotLook
    let width: CGFloat
    let cid: String
    let actions: ShotTextActions

    func makeUIView(context: Context) -> ShotRowUIView { ShotRowUIView() }

    func updateUIView(_ v: ShotRowUIView, context: Context) {
        v.actions = actions
        v.show(message, place: place, cover: cover, look: look, width: width, cid: cid)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShotRowUIView, context: Context) -> CGSize? {
        uiView.show(message, place: place, cover: cover, look: look, width: width, cid: cid)
        return CGSize(width: width, height: uiView.rowHeight)
    }
}
