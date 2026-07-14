import SwiftUI
import UIKit
import Observation

// EXPERIMENTAL Telegram-architecture chat engine, behind Settings > Privacy > "Telegram Chat Engine".
// Purpose: a side-by-side FEEL comparison against the standard engine (ThreadView + NativeMessageList).
// The architecture mirrors Telegram-iOS's core decisions, adapted to UIKit primitives:
//   - INVERTED list (item 0 = newest message at the visual bottom). "Stay pinned to newest" is the
//     resting state of the data structure, not something we compute: at-bottom users see new messages
//     appear with zero scroll math, and paging OLDER history appends at the content end, which moves
//     nothing (no anchor-restore dance at all).
//   - Pure UIKit cells with MANUAL frames. One pure function (TGLayout.build) produces every subview
//     frame; the same layout object is used for both sizeForItemAt and cell rendering, so measured
//     height == rendered height by construction.
//   - ONE owner of the keyboard ride: the input bar hangs off view.keyboardLayoutGuide (tracks the
//     keyboard frame natively, including interactive dismissal), and viewDidLayoutSubviews derives the
//     list clearance from the bar's real frame inside the same layout transaction, so bar + list move
//     in lockstep with the keyboard's own animation curve.
//   - Custom gesture arbitration: the reply swipe disables list scrolling while active.
// Scope (core feel test): text, emoji, reply quotes, photo/video-thumb bubbles, ticks, sending.
// Voice notes, files, albums, reactions, editing and the media editor stay in the standard engine.

// MARK: - Route switch

/// Single entry point for opening a conversation: routes to the standard ThreadView or the
/// experimental Telegram-style engine based on the Privacy toggle.
struct ConversationRoute: View {
    let cid: String
    let title: String
    let photoUrl: String?
    @AppStorage("telegramChatEngine") private var telegramEngine = false
    var body: some View {
        if telegramEngine {
            TelegramChatScreen(cid: cid, title: title)
        } else {
            ThreadView(cid: cid, title: title, photoUrl: photoUrl)
        }
    }
}

struct TelegramChatScreen: View {
    let cid: String
    let title: String
    var body: some View {
        TGChatRepresentable(cid: cid)
            // The controller owns the bottom edge (input bar + keyboard). SwiftUI must neither
            // reserve the home-indicator strip nor resize us when the keyboard opens.
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TGChatRepresentable: UIViewControllerRepresentable {
    let cid: String
    func makeUIViewController(context: Context) -> TGChatViewController { TGChatViewController(cid: cid) }
    func updateUIViewController(_ vc: TGChatViewController, context: Context) {}
}

// MARK: - Shared layout math (measure == render, one source of truth)

enum TGRowKind { case text, media, system }

struct TGRowLayout {
    var height: CGFloat = 0           // full row height including the gap above
    var kind: TGRowKind = .text
    var isOutgoing = false
    var bubble: CGRect = .zero        // cell coords
    var author: CGRect?               // bubble coords (group incoming sender name)
    var reply: CGRect?                // bubble coords (quote block)
    var image: CGRect?                // bubble coords
    var text: CGRect?                 // bubble coords
    var meta: CGRect = .zero          // bubble coords (time label; ticks sit right after it)
    var tick: CGRect?                 // bubble coords (outgoing only)
    var system: CGRect?               // cell coords (centered capsule)
    var displayText = ""              // what the text label shows (placeholder for unsupported types)
    var metaText = ""
    var authorName: String?
}

enum TGLayout {
    static let bodyFont = UIFont.systemFont(ofSize: 17)
    static let metaFont = UIFont.systemFont(ofSize: 11)
    static let authorFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    static let replyFont = UIFont.systemFont(ofSize: 13)
    static let systemFont = UIFont.systemFont(ofSize: 12)
    static let hPad: CGFloat = 12, vPad: CGFloat = 7, side: CGFloat = 12
    static let tickWidth: CGFloat = 20

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    static func textSize(_ s: String, font: UIFont, maxW: CGFloat) -> CGSize {
        let r = (s as NSString).boundingRect(
            with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Text shown for message types the test engine doesn't render natively.
    static func placeholderText(_ m: Message) -> String? {
        if m.isAudio { return "🎤 Voice message" }
        if m.isFile { return "📎 \(m.fileName ?? "File")" }
        if m.isAlbum { return "🖼 Album · \(max(m.album.count, m.localAlbum.count)) items" }
        if m.isCall { return "📞 \(m.callVideo ? "Video" : "Voice") call" }
        if m.isGif { return "GIF" }
        if m.viewOnce { return "🔒 View-once photo" }
        return nil
    }

    static func snippet(_ m: Message) -> String {
        if !m.text.isEmpty { return m.text }
        if m.isImage { return "📷 Photo" }
        if m.isVideo { return "🎬 Video" }
        return placeholderText(m) ?? "Message"
    }

    /// The one layout function: every frame in the row, in one pass, from plain math.
    static func build(_ m: Message, me: String, width: CGFloat, gapAbove: CGFloat,
                      isGroup: Bool, authorName: String?) -> TGRowLayout {
        var l = TGRowLayout()
        let out = m.authorId == me
        l.isOutgoing = out
        l.metaText = (m.edited ? "edited " : "") + timeFormatter.string(from: m.createdAt)

        if m.isSystem {
            l.kind = .system
            let ts = textSize(m.text, font: systemFont, maxW: width - 96)
            let w = ts.width + 24, h = ts.height + 10
            l.system = CGRect(x: (width - w) / 2, y: gapAbove + 4, width: w, height: h)
            l.height = gapAbove + h + 8
            return l
        }

        let maxBubble = floor(width * 0.76)
        let textAvail = maxBubble - 2 * hPad
        let showsImage = (m.isImage && !m.viewOnce) || m.isVideo
        l.displayText = showsImage ? m.text : (placeholderText(m) ?? (m.text.isEmpty ? " " : m.text))

        let metaW = textSize(l.metaText, font: metaFont, maxW: 200).width
        let metaH = ceil(metaFont.lineHeight)
        let metaTotalW = metaW + (out ? tickWidth : 0)

        var contentW: CGFloat = 0
        var y: CGFloat = vPad

        // Group incoming: sender name on top of the bubble.
        if isGroup && !out {
            l.authorName = authorName ?? "Someone"
            let asz = textSize(l.authorName!, font: authorFont, maxW: textAvail)
            l.author = CGRect(x: hPad, y: y, width: asz.width, height: asz.height)
            contentW = max(contentW, asz.width)
            y += asz.height + 2
        }

        // Reply quote block.
        if let r = m.replyTo {
            let a = textSize(r.authorId == me ? "You" : "Reply", font: authorFont, maxW: textAvail - 10)
            let s = textSize(String(r.text.prefix(60)), font: replyFont, maxW: textAvail - 10)
            let w = min(textAvail, max(a.width, s.width) + 10)
            l.reply = CGRect(x: hPad, y: y, width: max(w, 80), height: 34)
            contentW = max(contentW, max(w, 80))
            y += 34 + 4
        }

        if showsImage {
            l.kind = .media
            let iw = m.width ?? 320, ih = m.height ?? 320
            let aspect = (iw > 0 && ih > 0) ? CGFloat(ih / iw) : 1
            let imgW = min(maxBubble - 6, 272)
            let imgH = min(max(imgW * aspect, 100), 360)
            // Media bubbles use a slim 3pt frame so the photo runs nearly edge to edge.
            let localY = (l.author != nil || l.reply != nil) ? y : 3
            l.image = CGRect(x: 3, y: localY, width: imgW, height: floor(imgH))
            contentW = max(contentW, imgW - 2 * hPad + 6)
            y = localY + floor(imgH) + 4
        }

        let bodyText = l.displayText
        if !bodyText.isEmpty && !(showsImage && m.text.isEmpty) {
            let ts = textSize(bodyText, font: bodyFont, maxW: textAvail)
            let singleLine = ts.height <= ceil(bodyFont.lineHeight) + 1
            let tx = showsImage ? hPad - 3 : hPad
            l.text = CGRect(x: tx, y: y, width: ts.width, height: ts.height)
            if singleLine && ts.width + 6 + metaTotalW <= textAvail {
                contentW = max(contentW, ts.width + 6 + metaTotalW)
                y += ts.height
            } else {
                contentW = max(contentW, max(ts.width, metaTotalW))
                y += ts.height + metaH + 2
            }
        } else {
            contentW = max(contentW, metaTotalW)
            y += showsImage ? metaH + 2 : metaH
        }

        let bubbleW = showsImage
            ? max((l.image?.width ?? 0) + 6, m.text.isEmpty ? (l.image?.width ?? 0) + 6 : contentW + 2 * hPad)
            : max(contentW + 2 * hPad, 44)
        let bubbleH = y + vPad

        l.meta = CGRect(x: bubbleW - hPad - metaTotalW + (out ? 0 : 0), y: bubbleH - vPad - metaH,
                        width: metaW, height: metaH)
        if out { l.tick = CGRect(x: l.meta.maxX + 3, y: l.meta.minY, width: tickWidth - 3, height: metaH) }

        let bx = out ? width - side - bubbleW : side
        l.bubble = CGRect(x: bx, y: gapAbove, width: bubbleW, height: bubbleH)
        l.height = gapAbove + bubbleH
        return l
    }
}

// MARK: - Async image loading (same E2EE pipeline as the standard engine)

enum TGImageLoader {
    static func load(_ m: Message, cid: String) async -> UIImage? {
        if let d = m.localImageData { return UIImage(data: d) }
        let urlString = m.isVideo ? m.thumbUrl : m.imageUrl
        guard let s = urlString, !s.isEmpty else { return nil }
        if let c = DiskImageCache.shared.memoryImage(s) { return c }
        if let c = await DiskImageCache.shared.image(for: s) { return c }
        guard let url = URL(string: s), let (cipher, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let meta = m.isVideo ? m.thumbEnc : m.enc
        if let meta, let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta),
           let ui = UIImage(data: dec) {
            DiskImageCache.shared.store(ui, data: dec, for: s)
            return ui
        }
        return UIImage(data: cipher)
    }
}

// MARK: - Message cell (pure UIKit, manual frames)

enum TGTickState { case sending, failed, sent, read }

final class TGMessageCell: UICollectionViewCell {
    static let reuse = "TGMessageCell"

    private let bubble = UIView()
    private let authorLabel = UILabel()
    private let replyContainer = UIView()
    private let replyBar = UIView()
    private let replyAuthor = UILabel()
    private let replySnippet = UILabel()
    private let photoView = UIImageView()
    private let textLabel = UILabel()
    private let metaLabel = UILabel()
    private let tickLabel = UILabel()
    private let systemLabel = UILabel()
    private let systemBackdrop = UIView()
    let swipeArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var loadTag = ""

    static let outgoingColor = UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 10/255, green: 132/255, blue: 1, alpha: 1)
                                      : UIColor(red: 0, green: 122/255, blue: 1, alpha: 1)
    }
    static let incomingColor = UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 0x26/255.0, green: 0x26/255.0, blue: 0x2B/255.0, alpha: 1)
                                      : UIColor(red: 0xE9/255.0, green: 0xE9/255.0, blue: 0xEB/255.0, alpha: 1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The list is flipped (scaleY -1); flip the content back so rows render upright.
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)

        authorLabel.font = TGLayout.authorFont
        bubble.addSubview(authorLabel)

        replyContainer.layer.cornerRadius = 6
        replyContainer.clipsToBounds = true
        replyBar.frame = CGRect(x: 0, y: 0, width: 3, height: 34)
        replyBar.autoresizingMask = .flexibleHeight
        replyAuthor.font = TGLayout.authorFont
        replySnippet.font = TGLayout.replyFont
        replyContainer.addSubview(replyBar)
        replyContainer.addSubview(replyAuthor)
        replyContainer.addSubview(replySnippet)
        bubble.addSubview(replyContainer)

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.layer.cornerRadius = 15
        photoView.layer.cornerCurve = .continuous
        bubble.addSubview(photoView)

        textLabel.font = TGLayout.bodyFont
        textLabel.numberOfLines = 0
        bubble.addSubview(textLabel)

        metaLabel.font = TGLayout.metaFont
        bubble.addSubview(metaLabel)
        tickLabel.font = TGLayout.metaFont
        bubble.addSubview(tickLabel)

        systemBackdrop.layer.cornerRadius = 11
        systemBackdrop.backgroundColor = UIColor.secondarySystemFill
        systemLabel.font = TGLayout.systemFont
        systemLabel.textColor = .secondaryLabel
        systemLabel.textAlignment = .center
        contentView.addSubview(systemBackdrop)
        systemBackdrop.addSubview(systemLabel)

        swipeArrow.tintColor = .tertiaryLabel
        swipeArrow.alpha = 0
        contentView.addSubview(swipeArrow)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTag = ""
        photoView.image = nil
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        swipeArrow.alpha = 0
    }

    func configure(_ m: Message, layout l: TGRowLayout, cid: String, nameFor: (String) -> String) {
        contentView.frame = bounds
        let isSystem = l.kind == .system
        bubble.isHidden = isSystem
        systemBackdrop.isHidden = !isSystem
        if isSystem, let sf = l.system {
            systemBackdrop.frame = sf
            systemLabel.frame = systemBackdrop.bounds
            systemLabel.text = m.text
            return
        }

        bubble.frame = l.bubble
        bubble.backgroundColor = l.isOutgoing ? Self.outgoingColor : Self.incomingColor
        let fg: UIColor = l.isOutgoing ? .white : .label
        let fgDim: UIColor = l.isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .secondaryLabel

        if let af = l.author {
            authorLabel.isHidden = false
            authorLabel.frame = af
            authorLabel.text = l.authorName
            authorLabel.textColor = l.isOutgoing ? .white : Self.outgoingColor
        } else { authorLabel.isHidden = true }

        if let rf = l.reply, let r = m.replyTo {
            replyContainer.isHidden = false
            replyContainer.frame = rf
            replyContainer.backgroundColor = fg.withAlphaComponent(0.08)
            replyBar.backgroundColor = l.isOutgoing ? .white : Self.outgoingColor
            replyBar.frame = CGRect(x: 0, y: 0, width: 3, height: rf.height)
            replyAuthor.frame = CGRect(x: 8, y: 3, width: rf.width - 12, height: 15)
            replySnippet.frame = CGRect(x: 8, y: 17, width: rf.width - 12, height: 15)
            replyAuthor.text = nameFor(r.authorId)
            replyAuthor.textColor = l.isOutgoing ? .white : Self.outgoingColor
            replySnippet.text = r.text
            replySnippet.textColor = fgDim
        } else { replyContainer.isHidden = true }

        if let imgF = l.image {
            photoView.isHidden = false
            photoView.frame = imgF
            photoView.backgroundColor = fg.withAlphaComponent(0.08)
            let tag = m.rowId
            loadTag = tag
            if let d = m.localImageData, let ui = UIImage(data: d) {
                photoView.image = ui
            } else if let s = (m.isVideo ? m.thumbUrl : m.imageUrl), let cached = DiskImageCache.shared.memoryImage(s) {
                photoView.image = cached
            } else {
                photoView.image = nil
                let msg = m
                Task { [weak self] in
                    let ui = await TGImageLoader.load(msg, cid: cid)
                    await MainActor.run {
                        guard let self, self.loadTag == tag, let ui else { return }
                        self.photoView.image = ui
                    }
                }
            }
        } else { photoView.isHidden = true }

        if let tf = l.text {
            textLabel.isHidden = false
            textLabel.frame = tf
            textLabel.text = l.displayText
            textLabel.textColor = fg
        } else { textLabel.isHidden = true }

        metaLabel.frame = l.meta
        metaLabel.text = l.metaText
        metaLabel.textColor = fgDim
        if let tk = l.tick {
            tickLabel.isHidden = false
            tickLabel.frame = tk
        } else { tickLabel.isHidden = true }

        swipeArrow.frame = CGRect(x: bounds.width - 40, y: l.bubble.midY - 12, width: 24, height: 24)
    }

    func setTick(_ state: TGTickState) {
        switch state {
        case .sending: tickLabel.text = "◷"; tickLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        case .failed:  tickLabel.text = "!"; tickLabel.textColor = .systemRed
        case .sent:    tickLabel.text = "✓"; tickLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        case .read:    tickLabel.text = "✓✓"; tickLabel.textColor = .white
        }
    }

    /// Reply-swipe drag: compose the horizontal translation with the un-flip transform.
    func setSwipeOffset(_ dx: CGFloat) {
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: dx, y: 0)
        swipeArrow.alpha = min(1, abs(dx) / 50)
    }
}

// MARK: - Input bar

@MainActor
protocol TGInputBarDelegate: AnyObject {
    func inputBarDidSend(_ text: String)
    func inputBarHeightChanged()
    func inputBarDidCloseReply()
}

final class TGInputBar: UIView, UITextViewDelegate {
    weak var delegate: TGInputBarDelegate?
    let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let replyContainer = UIView()
    private let replyBar = UIView()
    private let replyAuthor = UILabel()
    private let replySnippet = UILabel()
    private let replyClose = UIButton(type: .system)
    private(set) var replyActive = false
    private var textHeight: CGFloat = 36
    var heightConstraint: NSLayoutConstraint!

    var totalHeight: CGFloat { textHeight + 16 + (replyActive ? 40 : 0) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        replyBar.layer.cornerRadius = 1.5
        replyAuthor.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        replySnippet.font = UIFont.systemFont(ofSize: 13)
        replySnippet.textColor = .secondaryLabel
        replyClose.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        replyClose.tintColor = .tertiaryLabel
        replyClose.addAction(UIAction { [weak self] _ in self?.clearReply(notify: true) }, for: .touchUpInside)
        replyContainer.addSubview(replyBar)
        replyContainer.addSubview(replyAuthor)
        replyContainer.addSubview(replySnippet)
        replyContainer.addSubview(replyClose)
        replyContainer.isHidden = true
        addSubview(replyContainer)

        textView.font = TGLayout.bodyFont
        textView.layer.cornerRadius = 18
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 0.5
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.backgroundColor = UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.97, alpha: 1)
        }
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        textView.delegate = self
        textView.isScrollEnabled = false
        addSubview(textView)

        placeholder.text = "Message"
        placeholder.font = TGLayout.bodyFont
        placeholder.textColor = .tertiaryLabel
        addSubview(placeholder)

        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)), for: .normal)
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        addSubview(sendButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 8
        if replyActive {
            replyContainer.frame = CGRect(x: 12, y: y, width: bounds.width - 24, height: 34)
            replyBar.frame = CGRect(x: 0, y: 0, width: 3, height: 34)
            replyAuthor.frame = CGRect(x: 10, y: 1, width: replyContainer.bounds.width - 50, height: 16)
            replySnippet.frame = CGRect(x: 10, y: 17, width: replyContainer.bounds.width - 50, height: 16)
            replyClose.frame = CGRect(x: replyContainer.bounds.width - 32, y: 1, width: 32, height: 32)
            y += 40
        }
        let sendW: CGFloat = 40
        textView.frame = CGRect(x: 12, y: y, width: bounds.width - 24 - sendW - 6, height: textHeight)
        placeholder.frame = CGRect(x: 26, y: y + 8, width: 200, height: 22)
        sendButton.frame = CGRect(x: bounds.width - 12 - sendW, y: y + textHeight - 38, width: sendW, height: 38)
    }

    func textViewDidChange(_ tv: UITextView) {
        placeholder.isHidden = !tv.text.isEmpty
        let target = min(max(tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .infinity)).height, 36), 120)
        tv.isScrollEnabled = target >= 120
        if abs(target - textHeight) > 0.5 {
            textHeight = target
            heightConstraint.constant = totalHeight
            delegate?.inputBarHeightChanged()
        }
    }

    private func send() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.text = ""
        textViewDidChange(textView)
        delegate?.inputBarDidSend(text)
    }

    func setReply(author: String, snippet: String) {
        replyActive = true
        replyContainer.isHidden = false
        replyAuthor.text = author
        replyAuthor.textColor = TGMessageCell.outgoingColor
        replyBar.backgroundColor = TGMessageCell.outgoingColor
        replySnippet.text = snippet
        heightConstraint.constant = totalHeight
        delegate?.inputBarHeightChanged()
    }

    func clearReply(notify: Bool) {
        guard replyActive else { return }
        replyActive = false
        replyContainer.isHidden = true
        heightConstraint.constant = totalHeight
        delegate?.inputBarHeightChanged()
        if notify { delegate?.inputBarDidCloseReply() }
    }
}

// MARK: - Controller

final class TGChatViewController: UIViewController {
    private let cid: String
    private let repo: ThreadRepository
    private var rows: [Message] = []          // newest first; index 0 renders at the visual bottom
    private var byRowId: [String: Message] = [:]
    private var layouts: [String: (sig: String, layout: TGRowLayout)] = [:]
    private var isGroup = false
    private var groupUsers: [String]?
    private var convNames: [String: String] = [:]
    private var me: String { AuthService.shared.uid ?? "" }
    private var replyTarget: Message?
    private var didFirstApply = false
    private var lastIncomingId: String?

    private let listLayout = UICollectionViewFlowLayout()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let inputBar = TGInputBar()
    private let barBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let badge = UILabel()

    private var swipingIndexPath: IndexPath?
    private var swipeDx: CGFloat = 0

    init(cid: String) {
        self.cid = cid
        self.repo = ThreadRepository(cid: cid)
        super.init(nibName: nil, bundle: nil)
        if let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) {
            isGroup = conv.convType == "group"
            groupUsers = isGroup ? conv.users : nil
            convNames = conv.names
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(red: 0x12/255.0, green: 0x12/255.0, blue: 0x14/255.0, alpha: 1) : .white
        }

        listLayout.scrollDirection = .vertical
        listLayout.minimumLineSpacing = 0
        listLayout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: listLayout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)   // THE inversion
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.register(TGMessageCell.self, forCellWithReuseIdentifier: TGMessageCell.reuse)
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            [weak self] cv, indexPath, rowId in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: TGMessageCell.reuse, for: indexPath) as! TGMessageCell
            guard let self, let m = self.byRowId[rowId] else { return cell }
            let l = self.layoutFor(m, at: indexPath.item)
            cell.configure(m, layout: l, cid: self.cid) { [weak self] uid in self?.displayName(uid) ?? "" }
            if l.isOutgoing { cell.setTick(self.tickState(m)) }
            return cell
        }

        view.addSubview(barBackdrop)
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.delegate = self
        view.addSubview(inputBar)
        inputBar.heightConstraint = inputBar.heightAnchor.constraint(equalToConstant: inputBar.totalHeight)
        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // THE keyboard ride: the guide tracks the keyboard natively (including interactive
            // dismissal), so the bar and, via viewDidLayoutSubviews, the list follow in lockstep.
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            inputBar.heightConstraint,
        ])

        badge.text = "TG ENGINE"
        badge.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.55)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.clipsToBounds = true
        view.addSubview(badge)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        pan.delegate = self
        collectionView.addGestureRecognizer(pan)

        repo.start()
        observeRepo()
        applyRows()
        Task {
            await ChatService.resetUnread(cid)
            if !repo.iBlocked { await ChatService.markRead(cid) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            repo.stop()
            let c = cid
            Task { await ChatService.resetUnread(c) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        barBackdrop.frame = CGRect(x: 0, y: inputBar.frame.minY,
                                   width: view.bounds.width, height: view.bounds.height - inputBar.frame.minY)
        badge.frame = CGRect(x: view.bounds.width - 78, y: view.safeAreaInsets.top + 6, width: 66, height: 16)
        updateInsets()
        if collectionView.bounds.width > 0, abs(collectionView.bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = collectionView.bounds.width
            layouts.removeAll()
            listLayout.invalidateLayout()
        }
    }

    private var lastLayoutWidth: CGFloat = 0

    /// Derive the list's bottom clearance from the input bar's REAL frame. This runs inside the
    /// same layout transaction that moved the bar (keyboard or bar growth), so content rides along.
    private func updateInsets() {
        let clearance = view.bounds.height - inputBar.frame.minY + 8
        let old = collectionView.contentInset.top   // inverted: scroll-space top == visual bottom
        guard abs(clearance - old) > 0.5 else { return }
        let wasAtBottom = collectionView.contentOffset.y <= -old + 60
        collectionView.contentInset.top = clearance
        collectionView.contentInset.bottom = 8      // visual top clearance under the nav bar
        if wasAtBottom && !collectionView.isTracking && !collectionView.isDecelerating {
            collectionView.contentOffset.y = -clearance
        }
    }

    // MARK: Data

    private func observeRepo() {
        withObservationTracking {
            _ = repo.items
            _ = repo.otherLastReadMillis
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyRows()
                self.observeRepo()
            }
        }
    }

    private func displayName(_ uid: String) -> String {
        if uid == me { return "You" }
        return convNames[uid] ?? "Reply"
    }

    private func tickState(_ m: Message) -> TGTickState {
        if m.sendState == .sending { return .sending }
        if m.sendState == .failed { return .failed }
        return m.createdAt.timeIntervalSince1970 * 1000 <= repo.otherLastReadMillis ? .read : .sent
    }

    private func contentSig(_ m: Message, gap: CGFloat) -> String {
        "\(gap)|\(m.text)|\(m.edited)|\(m.type ?? "")|\(m.imageUrl ?? "")|\(m.width ?? 0)x\(m.height ?? 0)|\(m.replyTo?.text ?? "")|\(m.sendState == nil)"
    }

    private func gapAbove(_ index: Int) -> CGFloat {
        // The row visually above index i is rows[i+1] (older). Tight gap between same-author runs.
        guard index + 1 < rows.count else { return 8 }
        let older = rows[index + 1]
        return (older.authorId == rows[index].authorId && !older.isSystem && !rows[index].isSystem) ? 2 : 8
    }

    private func layoutFor(_ m: Message, at index: Int) -> TGRowLayout {
        let width = collectionView.bounds.width
        let gap = gapAbove(index)
        let sig = contentSig(m, gap: gap) + "|\(Int(width))"
        if let cached = layouts[m.rowId], cached.sig == sig { return cached.layout }
        let l = TGLayout.build(m, me: me, width: width, gapAbove: gap, isGroup: isGroup,
                               authorName: convNames[m.authorId])
        layouts[m.rowId] = (sig, l)
        return l
    }

    private func applyRows() {
        let newRows = Array(repo.items.reversed())
        let oldIds = dataSource.snapshot().itemIdentifiers
        let oldFirst = oldIds.first
        let wasAtBottom = collectionView.contentOffset.y <= -collectionView.contentInset.top + 60

        rows = newRows
        byRowId = Dictionary(newRows.map { ($0.rowId, $0) }, uniquingKeysWith: { a, _ in a })

        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        snap.appendSections([0])
        let ids = newRows.map(\.rowId)
        snap.appendItems(ids)
        // Reconfigure rows whose content changed in place (edit, reaction, echo confirm).
        let oldSet = Set(oldIds)
        var changed: [String] = []
        for (i, m) in newRows.enumerated() where oldSet.contains(m.rowId) {
            let sig = contentSig(m, gap: gapAbove(i)) + "|\(Int(collectionView.bounds.width))"
            if let cached = layouts[m.rowId], cached.sig != sig { changed.append(m.rowId) }
        }
        if !changed.isEmpty { snap.reconfigureItems(changed) }
        dataSource.apply(snap, animatingDifferences: false)

        // New rows at the FRONT (newest end).
        var frontNew: [String] = []
        for id in ids {
            if id == oldFirst { break }
            if !oldSet.contains(id) { frontNew.append(id) }
        }

        let inset = collectionView.contentInset.top
        if !didFirstApply {
            if !rows.isEmpty { didFirstApply = true }
            collectionView.contentOffset.y = -inset
        } else if !frontNew.isEmpty {
            let delta = frontNew.enumerated().reduce(CGFloat(0)) { acc, pair in
                guard let m = byRowId[pair.element] else { return acc }
                return acc + layoutFor(m, at: pair.offset).height
            }
            if wasAtBottom {
                // Reveal the new message with a ride from the pre-insert position.
                collectionView.contentOffset.y = -inset + delta
                let cv = collectionView!
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86,
                               initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    cv.contentOffset.y = -inset
                }
            } else {
                // Reading history: keep the viewport glued to what the user is reading.
                collectionView.contentOffset.y += delta
            }
            // Mark newly arrived incoming messages read while the chat is open.
            if let newest = rows.first, newest.authorId != me, newest.id != lastIncomingId {
                lastIncomingId = newest.id
                ChatService.markReadThrottled(cid)
            }
        }
        updateVisibleTicks()
    }

    private func updateVisibleTicks() {
        for ip in collectionView.indexPathsForVisibleItems {
            guard ip.item < rows.count else { continue }
            let m = rows[ip.item]
            guard m.authorId == me, !m.isSystem,
                  let cell = collectionView.cellForItem(at: ip) as? TGMessageCell else { continue }
            cell.setTick(tickState(m))
        }
    }

    // MARK: Reply swipe (scroll locked while active)

    @objc private func handleSwipe(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let p = g.location(in: collectionView)
            guard let ip = collectionView.indexPathForItem(at: p), ip.item < rows.count,
                  !rows[ip.item].isSystem, rows[ip.item].sendState == nil else { return }
            swipingIndexPath = ip
            collectionView.isScrollEnabled = false   // vertical scrolling locked while the swipe is active
        case .changed:
            guard let ip = swipingIndexPath, let cell = collectionView.cellForItem(at: ip) as? TGMessageCell else { return }
            var dx = min(0, g.translation(in: collectionView).x)
            if dx < -60 { dx = -60 + (dx + 60) / 4 }   // rubber-band past the trigger
            let fired = dx <= -50
            let wasFired = swipeDx <= -50
            if fired != wasFired { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            swipeDx = dx
            cell.setSwipeOffset(dx)
        case .ended, .cancelled, .failed:
            collectionView.isScrollEnabled = true
            if let ip = swipingIndexPath, let cell = collectionView.cellForItem(at: ip) as? TGMessageCell {
                if swipeDx <= -50, ip.item < rows.count { beginReply(rows[ip.item]) }
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                    cell.setSwipeOffset(0)
                }
            }
            swipingIndexPath = nil
            swipeDx = 0
        default: break
        }
    }

    private func beginReply(_ m: Message) {
        replyTarget = m
        inputBar.setReply(author: displayName(m.authorId), snippet: TGLayout.snippet(m))
        inputBar.textView.becomeFirstResponder()
    }
}

// MARK: Delegate conformances

extension TGChatViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard indexPath.item < rows.count else { return CGSize(width: collectionView.bounds.width, height: 1) }
        let m = rows[indexPath.item]
        return CGSize(width: collectionView.bounds.width, height: layoutFor(m, at: indexPath.item).height)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Inverted list: older history lives at the END of the content. Appending there moves
        // nothing on screen, so paging needs no scroll-anchor gymnastics at all.
        guard didFirstApply, repo.canLoadOlder, !repo.loadingOlder else { return }
        let distanceToOldest = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        if distanceToOldest < scrollView.bounds.height * 1.5 {
            repo.loadOlder { }
        }
    }
}

extension TGChatViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, pan.view == collectionView else { return true }
        if pan == collectionView.panGestureRecognizer { return true }
        let v = pan.velocity(in: collectionView)
        return v.x < 0 && abs(v.x) > abs(v.y) * 1.5   // clearly horizontal, leftward
    }
}

extension TGChatViewController: TGInputBarDelegate {
    func inputBarDidSend(_ text: String) {
        let clientId = UUID().uuidString
        let reply: ReplyRef? = replyTarget.map {
            ReplyRef(id: $0.id, authorId: $0.authorId, text: String(TGLayout.snippet($0).prefix(120)))
        }
        replyTarget = nil
        inputBar.clearReply(notify: false)
        repo.addPending(Message(localText: text, authorId: me, clientId: clientId, replyTo: reply, sendState: .sending))
        // Same durable-send path as the standard engine: persist before the network call.
        SendQueue.add(clientId: clientId, cid: cid, text: text, mentions: [], reply: reply,
                      ts: Date().timeIntervalSince1970)
        let c = cid, g = groupUsers
        Task {
            do {
                try await ChatService.sendText(cid: c, text: text, replyTo: reply, clientId: clientId,
                                               group: g, mentions: [])
                SendQueue.remove(clientId: clientId)
            } catch {
                await MainActor.run { [weak self] in self?.repo.markFailed(clientId: clientId) }
            }
        }
    }

    func inputBarHeightChanged() {
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    func inputBarDidCloseReply() { replyTarget = nil }
}
