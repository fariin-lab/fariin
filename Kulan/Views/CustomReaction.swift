import SwiftUI
import UIKit

// ⛔ ANIMATED CUSTOM REACTIONS (owner 2026-11-02). 181 .tgs files ship in the app, played by
// `TGSEngine` (rlottie off the main thread), never converted. A reaction is a string key on the post,
// "ce_1" to "ce_181", in the same `reactionCounts` as any emoji. Only @v may CHOOSE them for a
// channel (the Custom tab; the server's `setChannelReactions` enforces it); everyone can react with
// the ones a channel offers. A pill keeps moving while it is on screen (owner 2026-11-02).
enum CustomReaction {
    /// @v, the only account that sees the Custom tab.
    private static let chooserUid = "SVf0zxDVZzO8oLbGvM150QWgIWd2"
    private static let count = 181
    static let builtIn: [String] = (1...count).map { "ce_\($0)" }
    /// The built-in ones, then the ones uploaded in the admin panel (owner 2026-11-06), newest last.
    /// Read from a view, so the Custom tab redraws when the panel adds or removes one.
    @MainActor static var all: [String] { builtIn + LiveFeatures.shared.customEmoji.map { "cu_" + $0.id } }

    @MainActor static var canChoose: Bool { AuthService.shared.uid == chooserUid }

    static func isCustom(_ emoji: String?) -> Bool {
        guard let emoji else { return false }
        if UploadedEmoji.isKey(emoji) { return true }
        guard emoji.hasPrefix("ce_"), let n = Int(emoji.dropFirst(3)) else { return false }
        return n >= 1 && n <= count
    }

    /// The file to play. An uploaded one is nil until it has downloaded (asked for here); the view
    /// that wanted it reloads when it lands (`UploadedEmoji.landed`).
    static func url(_ key: String) -> URL? {
        if UploadedEmoji.isKey(key) {
            let id = String(key.dropFirst(3))
            // Removed in the panel: gone here too, even if this phone kept a copy (check-3 2026-11-06).
            guard UploadedEmoji.isListed(id) else { UploadedEmoji.forget(id); return nil }
            if let file = UploadedEmoji.fileURL(id) { return file }
            UploadedEmoji.fetch(id)
            return nil
        }
        return Bundle.main.url(forResource: key, withExtension: "tgs", subdirectory: "CustomReactions")
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

/// ⛔ CUSTOM EMOJI UPLOADED IN THE ADMIN PANEL (owner 2026-11-06). `config/features.customEmoji` =
/// `[{ id, url, name, at }]` (functions-admin customEmojiAdd). Key "cu_" + id, a 10-character id.
/// Files download once into Caches/CustomEmoji/<id>.tgs, checked to be gzip and at most 64 KB (the
/// server's own cap). Thread-safe: `url(_:)` is asked from drawing code on any thread.
enum UploadedEmoji {
    struct Item: Equatable { let id: String; let url: String }

    static let storeKey = "remoteFeatures.customEmoji.v1"
    /// Posted on the main thread with the id as `object` when a file has landed.
    static let landed = Notification.Name("UploadedEmoji.landed")

    private static let lock = NSLock()
    private static var remote: [String: String] = Dictionary(
        uniqueKeysWithValues: parse(UserDefaults.standard.array(forKey: storeKey)).map { ($0.id, $0.url) })
    private static var inFlight = Set<String>()

    static func isKey(_ s: String) -> Bool {
        guard s.count == 13, s.hasPrefix("cu_") else { return false }
        return s.dropFirst(3).allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The panel's list, keeping only well-formed https entries, in its order.
    static func parse(_ raw: Any?) -> [Item] {
        guard let list = raw as? [Any] else { return [] }
        var seen = Set<String>(), out: [Item] = []
        for x in list {
            guard let d = x as? [String: Any], let id = d["id"] as? String, let url = d["url"] as? String,
                  isKey("cu_" + id), url.hasPrefix("https://"), !seen.contains(id) else { continue }
            seen.insert(id); out.append(Item(id: id, url: url))
        }
        return out
    }

    /// Stored form for UserDefaults (plist-safe).
    static func stored(_ items: [Item]) -> [[String: String]] { items.map { ["id": $0.id, "url": $0.url] } }

    static func set(_ items: [Item]) {
        lock.withLock { remote = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.url) }) }
    }

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CustomEmoji", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func isListed(_ id: String) -> Bool { lock.withLock { remote[id] != nil } }

    /// Deletes this phone's copy of an emoji that left the list.
    static func forget(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).tgs"))
    }

    /// Off the panel's list: a reaction bar or chip leaves it out rather than drawing an empty slot.
    static func isRemoved(_ key: String) -> Bool { isKey(key) && !isListed(String(key.dropFirst(3))) }

    static func fileURL(_ id: String) -> URL? {
        let f = dir.appendingPathComponent("\(id).tgs")
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Download once. An id no longer on the list is not fetched (it was removed in the panel).
    static func fetch(_ id: String) {
        let link: URL? = lock.withLock {
            guard !inFlight.contains(id), let s = remote[id], let u = URL(string: s) else { return nil }
            inFlight.insert(id)
            return u
        }
        guard let link else { return }
        Task.detached(priority: .utility) {
            defer { UploadedEmoji.lock.withLock { _ = UploadedEmoji.inFlight.remove(id) } }
            guard let (data, resp) = try? await URLSession.shared.data(from: link),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 20, data.count <= 64 * 1024, data[0] == 0x1f, data[1] == 0x8b else { return }
            let f = UploadedEmoji.dir.appendingPathComponent("\(id).tgs")
            guard (try? data.write(to: f, options: .atomic)) != nil else { return }
            await MainActor.run { NotificationCenter.default.post(name: UploadedEmoji.landed, object: id) }
        }
    }
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

    private var landedObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(player)
        // An uploaded emoji (cu_) can arrive after this view asked for it: draw it then.
        landedObserver = NotificationCenter.default.addObserver(
            forName: UploadedEmoji.landed, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String, self.key == "cu_" + id else { return }
            self.load()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let landedObserver { NotificationCenter.default.removeObserver(landedObserver) } }

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
        if case .loop = motion { return }   // already moving; a single pass would stop it at the end
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
