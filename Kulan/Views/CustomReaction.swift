import SwiftUI
import UIKit

// ⛔ ANIMATED CUSTOM REACTIONS (owner 2026-11-02). 181 .tgs files ship in the app, played by
// `TGSEngine` (rlottie off the main thread), never converted. A reaction is a string key on the post,
// "ce_1" to "ce_181", in the same `reactionCounts` as any emoji. Only @v may CHOOSE them for a
// channel (the Custom tab; the server's `setChannelReactions` enforces it); everyone can react with
// the ones a channel offers. A pill rests on a still and plays once when I react with it.
enum CustomReaction {
    /// @v, the only account that sees the Custom tab.
    private static let chooserUid = "SVf0zxDVZzO8oLbGvM150QWgIWd2"
    private static let count = 181
    static let all: [String] = (1...count).map { "ce_\($0)" }

    @MainActor static var canChoose: Bool { AuthService.shared.uid == chooserUid }

    static func isCustom(_ emoji: String?) -> Bool {
        guard let emoji, emoji.hasPrefix("ce_"), let n = Int(emoji.dropFirst(3)) else { return false }
        return n >= 1 && n <= count
    }

    static func url(_ key: String) -> URL? {
        Bundle.main.url(forResource: key, withExtension: "tgs", subdirectory: "CustomReactions")
    }

    /// A list as words: custom keys are not text, so they stay out of any sentence.
    static func words(_ list: [String], separator: String = " ") -> String {
        list.filter { !isCustom($0) }.joined(separator: separator)
    }

    /// What a screen reader says.
    static func spoken(_ emoji: String) -> String { isCustom(emoji) ? "Custom emoji" : emoji }

    /// Marks a pill's text as holding a custom reaction, and which one.
    static let attribute = NSAttributedString.Key("fariinCustomReaction")

    private static let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// The room a custom emoji takes in a pill's text. The pill's own view draws it there.
    static func pillText(_ key: String, font: UIFont) -> NSAttributedString {
        let side = pillSide(font.pointSize)
        let a = NSTextAttachment(image: blank)
        a.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        let s = NSMutableAttributedString(attachment: a)
        s.addAttributes([.font: font, attribute: key], range: NSRange(location: 0, length: s.length))
        return s
    }

    static func pillSide(_ fontSize: CGFloat) -> CGFloat { (fontSize * 1.3).rounded() }
}

/// One custom emoji on screen. It plays only while it is in a window, and its frames are drawn off
/// the main thread, so a screen full of them never holds up scrolling.
final class CustomReactionView: UIView {
    enum Motion: Equatable {
        case still
        /// `step` 2 is half rate, for a grid of many.
        case loop(step: Int)
    }

    private let player = TGSPlayer()
    private var key = ""
    private var motion = Motion.still

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(player)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ key: String, motion: Motion) {
        if key != self.key { player.clear() }
        self.key = key
        self.motion = motion
        load()
    }

    func clear() {
        key = ""
        player.clear()
    }

    /// Once through from the start, then it rests on the last frame.
    func playOnce() {
        guard !key.isEmpty else { return }
        player.playOnce()
    }

    private func load() {
        guard !key.isEmpty, bounds.width > 0, let url = CustomReaction.url(key) else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        var step = 1
        if case .loop(let s) = motion { step = s }
        player.set(key: "cr:\(key)", source: .file(url), pixelBox: Int(bounds.width * scale), step: step)
        switch motion {
        case .loop:
            if window != nil { player.play() } else { player.pause() }
        case .still:
            guard !player.hasFrame, player.contents == nil else { return }
            let wanted = key
            TGSSticker.stillAsync(url: url, side: bounds.width) { [weak self] img in
                guard let self, self.key == wanted, !self.player.hasFrame else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.player.contents = img?.cgImage
                CATransaction.commit()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if case .loop = motion, window == nil { player.pause() } else { load() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.frame = bounds
        CATransaction.commit()
        load()
    }
}

struct CustomReactionIcon: UIViewRepresentable {
    let key: String
    var motion: CustomReactionView.Motion = .loop(step: 1)

    func makeUIView(context: Context) -> CustomReactionView { CustomReactionView() }
    func updateUIView(_ v: CustomReactionView, context: Context) { v.show(key, motion: motion) }
}

/// A custom emoji to put inside a SwiftUI button.
/// ⛔ THE TOUCH NEVER REACHES THE UIKIT VIEW (owner 2026-11-02: "when I click this emoji nothing
/// happens"). A hosted UIView takes the touch from the Button around it, so the Button never fired.
/// The view is shut out of hit testing and a clear layer over it is what the Button feels.
struct CustomReactionTile: View {
    let key: String
    var side: CGFloat
    var motion: CustomReactionView.Motion = .loop(step: 1)
    var body: some View {
        ZStack {
            CustomReactionIcon(key: key, motion: motion).allowsHitTesting(false)
            Color.clear.contentShape(Rectangle())
        }
        .frame(width: side, height: side)
    }
}

/// Any reaction in a SwiftUI screen: the emoji as text, or the custom one playing.
struct ReactionGlyph: View {
    let emoji: String
    var size: CGFloat = 30
    var body: some View {
        if CustomReaction.isCustom(emoji) {
            CustomReactionTile(key: emoji, side: size * 1.2)
        } else {
            Text(emoji).font(.system(size: size))
        }
    }
}
