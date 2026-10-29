import Combine
import FirebaseFirestore
import UIKit

// ===== The card bubbles =====
//
// A shared place and a shared contact. Both are static pictures over a plan; neither owns any
// state, and every tap is hit-tested from the plan by the cell.

/// A shared place: the map picture flush to the top and the sides, the label under it.
///
/// ⚠️ IT IS A STILL, NOT AN EMBEDDED MAP, and it goes through the SAME `MapSnapshotCache` the
/// SwiftUI card used. A live map view inside a recycled cell is a renderer per bubble; and sharing
/// the cache means a place that has already been drawn once — including by the old path — costs
/// nothing to draw again.
final class LocationBubbleView: UIView {
    private let map = UIImageView()
    private let pin = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView()
    private var renderedKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        map.contentMode = .scaleAspectFill
        map.clipsToBounds = true
        map.backgroundColor = .secondarySystemFill
        addSubview(map)
        pin.contentMode = .scaleAspectFit
        addSubview(pin)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        chevron.contentMode = .scaleAspectFit
        addSubview(chevron)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ l: BubbleBody.LocationBody, plan: LocationPlan, tint: UIColor, dark: Bool) {
        map.frame = plan.map
        label.frame = plan.label
        label.attributedText = plan.labelAttr
        pin.frame = plan.pin
        // Palette, so the pin is a RED head on a light disc rather than one flat colour.
        pin.image = UIImage(systemName: "mappin.circle.fill", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 22)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemRed, tint])))
        chevron.frame = plan.chevron
        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        chevron.tintColor = tint.withAlphaComponent(0.7)

        let key = MapSnapshotCache.key(lat: l.lat, lon: l.lon, size: plan.map.size, dark: dark)
        if let hit = MapSnapshotCache.cached(key) {
            renderedKey = key
            map.image = hit
            return
        }
        guard renderedKey != key else { return }   // already asked for this one
        renderedKey = key
        map.image = nil
        MapSnapshotCache.render(lat: l.lat, lon: l.lon, size: plan.map.size, dark: dark,
                                key: key) { [weak self] image in
            // The view may have been recycled onto another place while the snapshotter worked.
            guard let self, self.renderedKey == key, let image else { return }
            self.map.image = image
            self.map.alpha = 0
            UIView.animate(withDuration: 0.2) { self.map.alpha = 1 }
        }
    }

    func prepareForReuse() {
        renderedKey = nil
        map.image = nil
    }
}

// ── The OG card inside a text bubble ──

final class LinkPreviewBubbleView: UIView {
    private let backing = UIView()
    private let hero = RowImageView(frame: .zero)
    private let avatar = RowAvatarView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let host = UILabel()
    private let divider = UIView()
    private let button = UIView()
    private let buttonLabel = UILabel()
    // A call card's circle and glyph (inside the card) and its Join button (under the words, so
    // on this view itself — `backing` clips to the card).
    private let glyphCircle = UIView()
    private let glyphIcon = UIImageView()
    private let joinButton = UIView()
    private let joinLabel = UILabel()
    /// ⛔ A STORY CARD'S PICTURE IS THE STORY'S DOOR (owner, 2026-10-11: View Story "is open like
    /// pop", and the pull-down did not go back to the card). The reference app opens the story out
    /// of the card's own image and, at the close, finds that image again where it is now and lands
    /// on it, hiding it while the story is up. The picture registers under this key in the story
    /// scope, which is all `StoryDoor` needs to fly out of it, hide it, and land back on it.
    /// Empty for every other kind of card.
    private(set) var flightKey = ""
    private var visibilityToken: AnyCancellable?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The published value, not a re-read of the property: see the note on `MediaBubbleView`'s
        // own sink for the one-step-behind blank that re-reading caused.
        visibilityToken = MediaSourceVisibility.shared.hiddenIdPublisher
            .removeDuplicates()
            .sink { [weak self] id in self?.applyVisibility(hiddenId: id) }
        glyphCircle.layer.cornerCurve = .circular
        glyphIcon.contentMode = .center
        joinButton.layer.cornerRadius = 10
        joinButton.layer.cornerCurve = .continuous
        joinLabel.textAlignment = .center
        addSubview(joinButton)
        addSubview(joinLabel)
        backing.layer.cornerRadius = 12
        backing.layer.cornerCurve = .continuous
        backing.clipsToBounds = true
        addSubview(backing)
        hero.contentMode = .scaleAspectFill
        backing.addSubview(hero)
        backing.addSubview(avatar)
        for l in [title, subtitle, host] {
            l.numberOfLines = 2
            l.lineBreakMode = .byTruncatingTail
            backing.addSubview(l)
        }
        host.numberOfLines = 1
        backing.addSubview(divider)
        backing.addSubview(button)
        buttonLabel.textAlignment = .center
        backing.addSubview(buttonLabel)
        backing.addSubview(glyphCircle)
        glyphCircle.addSubview(glyphIcon)
        // Last, so it lies over everything the card draws; it follows the card's size.
        pressDim.alpha = 0
        pressDim.isUserInteractionEnabled = false
        pressDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backing.addSubview(pressDim)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// ⛔ THE CARD ANSWERS THE FINGER — owner 2026-10-15: "when I tap a link preview there is no
    /// animation, it does not feel tappable; add a small one like the reference". The reference
    /// tints the card the moment it is touched and lets the tint go when the finger lifts. Same here:
    /// a tint of the bubble's own accent over the card, on at once, fading out over 0.2s.
    private let pressDim = UIView()
    func setPressed(_ on: Bool) {
        pressDim.frame = backing.bounds
        if on {
            pressDim.layer.removeAllAnimations()
            pressDim.alpha = 1
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.pressDim.alpha = 0
            }
        }
    }

    func configure(_ p: BubbleBody.LinkPreview, plan: LinkPreviewPlan, tint: UIColor, cid: String,
                   rowId: String = "") {
        var key = ""
        if case .story = p.shape, plan.hero != nil, !rowId.isEmpty {
            key = MediaOpenRects.key(.storyRow, Self.storySourceId(rowId))
        }
        setFlightKey(key)
        // The call card is rounder than a web preview (owner, 2026-10-07: "make the Kulan Call
        // corners rounded, Apple's rounded corners"): 16pt continuous, the glyph marks the kind.
        backing.layer.cornerRadius = plan.glyph != nil ? 16 : 12
        pressDim.backgroundColor = tint.withAlphaComponent(0.2)
        pressDim.layer.removeAllAnimations()
        pressDim.alpha = 0   // a recycled card never comes back pressed
        if let rect = plan.glyph {
            glyphCircle.isHidden = false
            glyphCircle.frame = rect
            glyphCircle.layer.cornerRadius = rect.width / 2
            glyphCircle.backgroundColor = tint.withAlphaComponent(0.16)
            glyphIcon.frame = glyphCircle.bounds
            glyphIcon.image = UIImage(systemName: "video.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            glyphIcon.tintColor = tint
        } else {
            glyphCircle.isHidden = true
        }
        if let rect = plan.join, let labelRect = plan.joinLabel, let attr = plan.joinAttr {
            joinButton.isHidden = false; joinLabel.isHidden = false
            joinButton.frame = rect
            joinButton.layer.cornerRadius = rect.height / 2   // a capsule, the way the system's own buttons round now (owner, 2026-10-07)
            // The contact card's button recipe: the bubble's own text colour, faint, so it reads on
            // the blue bubble, a chat colour and the incoming grey alike.
            joinButton.backgroundColor = tint.withAlphaComponent(0.12)
            joinLabel.frame = labelRect
            joinLabel.attributedText = attr
        } else {
            joinButton.isHidden = true; joinLabel.isHidden = true
        }

        backing.frame = plan.card
        backing.backgroundColor = tint.withAlphaComponent(0.10)

        // owner 2026-10-18: a group card's photo as it travelled in the message is ENCRYPTED, which
        // the avatar pipeline cannot open; the hero view can. So it sits in the avatar's circle, over
        // the avatar's fallback. A live photo from `GroupLinkDoor` (no `imageEnc`) takes the avatar.
        var groupPhotoRect: CGRect?
        // A channel's card wears the channel's squircle (owner 2026-10-29); its line counts
        // followers, the same test the button's "View Channel" uses.
        let channelCard = GroupDirectory.isChannelLine(p.desc)
        switch p.shape {
        case .group, .groupUnavailable:
            if p.imageEnc != nil, p.imageUrl != nil { groupPhotoRect = plan.avatar }
        default: break
        }
        if let rect = groupPhotoRect {
            hero.isHidden = false
            hero.frame = rect
            hero.clipsToBounds = true
            // `configure` sets the radius (and a continuous curve) from its argument.
            hero.configure(url: p.imageUrl, enc: p.imageEnc, cid: cid, cornerRadius: channelCard ? 0 : rect.width / 2)
            hero.layer.cornerCurve = .circular
            if channelCard {
                let mask = CAShapeLayer()
                mask.path = AvatarShape.cgPath(in: CGRect(origin: .zero, size: rect.size))
                hero.layer.mask = mask
            } else {
                hero.layer.mask = nil
            }
            backing.insertSubview(hero, aboveSubview: avatar)   // over the fallback, under the words
        } else if let rect = plan.hero {
            hero.isHidden = false
            hero.frame = rect
            hero.layer.mask = nil   // a reused cell may still carry a channel card's squircle
            // A story card's picture sits inside the card with its own corners; an article's runs
            // edge to edge and the card clips it.
            if case .story = p.shape {
                hero.layer.cornerRadius = 8
                hero.layer.cornerCurve = .continuous
                hero.clipsToBounds = true
            } else {
                hero.layer.cornerRadius = 0
            }
            // `smallSync` in the SwiftUI card's terms: a preview picture is small and is read
            // synchronously off disk, so it is there on the first frame instead of a beat late.
            hero.configure(url: p.imageUrl, enc: p.imageEnc, cid: cid)
        } else {
            hero.isHidden = true
            hero.reset()
        }

        if let rect = plan.avatar {
            avatar.isHidden = false
            avatar.frame = rect
            avatar.squircle = channelCard
            avatar.configure(name: p.title, photoUrl: groupPhotoRect == nil ? p.imageUrl : nil)
        } else {
            avatar.isHidden = true
        }

        title.frame = plan.title
        title.attributedText = plan.titleAttr
        title.isHidden = plan.titleAttr.length == 0

        if let rect = plan.subtitle, let attr = plan.subtitleAttr {
            subtitle.isHidden = false
            subtitle.frame = rect
            subtitle.attributedText = attr
        } else {
            subtitle.isHidden = true
        }

        if let rect = plan.host, let attr = plan.hostAttr {
            host.isHidden = false
            host.frame = rect
            host.attributedText = attr
        } else {
            host.isHidden = true
        }

        if let rect = plan.divider {
            divider.isHidden = false
            divider.frame = rect
            divider.backgroundColor = tint.withAlphaComponent(0.12)
        } else {
            divider.isHidden = true
        }

        if let rect = plan.button, let labelRect = plan.buttonLabel, let attr = plan.buttonAttr {
            button.isHidden = false; buttonLabel.isHidden = false
            button.frame = rect
            buttonLabel.frame = labelRect
            buttonLabel.attributedText = attr
        } else {
            button.isHidden = true; buttonLabel.isHidden = true
        }
        applyVisibility(hiddenId: MediaSourceVisibility.shared.hiddenId)
    }

    /// The id the chat hands `StoryDoor.openLink(from:)` for the card in row `rowId`; the door adds
    /// the story scope itself.
    static func storySourceId(_ rowId: String) -> String { "storylink-\(rowId)" }

    /// A recycled cell lets go of the row it drew before, or a flight for that row would land on
    /// whatever message this cell now shows (`MediaOpenRects.releaseView`).
    private func setFlightKey(_ key: String) {
        guard key != flightKey else { return }
        if !flightKey.isEmpty { MediaOpenRects.releaseView(flightKey, ifItIs: hero) }
        flightKey = key
        if !key.isEmpty { register() }
    }

    /// The view, and the picture's own 8pt corner: without a registered radius the flight's cover
    /// and landing take the stories row's 24 (`StoryDoor.sourceRadius`) and land as the wrong shape.
    /// The rectangle beside it is only the radius' carrier; the flight asks the live view.
    private func register() {
        MediaOpenRects.captureView(flightKey, hero)
        MediaOpenRects.capture(flightKey, hero.convert(hero.bounds, to: nil), cornerRadius: 8)
    }

    private func applyVisibility(hiddenId: String?) {
        hero.alpha = (!flightKey.isEmpty && hiddenId == flightKey) ? 0 : 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Re-registered on every window change, as the stories row does: a cell scrolled away and
        // back is a different answer to "where is it".
        if window != nil, !flightKey.isEmpty { register() }
    }

    func prepareForReuse() {
        hero.reset()
        setFlightKey("")
        hero.alpha = 1
    }
}

// ── A capsule with a glyph and a word ──

/// A view-once photo, a one-time voice note, or a message still being prepared.
final class PillBubbleView: UIView {
    private let glyph = UIImageView()
    private let label = UILabel()
    private var spinner: UIActivityIndicatorView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glyph.contentMode = .center
        addSubview(glyph)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ plan: PillPlan, tint: UIColor) {
        label.frame = plan.label
        label.attributedText = plan.labelAttr
        if plan.busy {
            glyph.isHidden = true
            let v = spinner ?? {
                let v = UIActivityIndicatorView(style: .medium); addSubview(v); spinner = v; return v
            }()
            v.isHidden = false
            v.frame = plan.glyph
            v.color = tint
            v.startAnimating()
        } else {
            spinner?.stopAnimating()
            spinner?.isHidden = true
            glyph.isHidden = false
            glyph.frame = plan.glyph
            glyph.image = UIImage(systemName: plan.symbol,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            glyph.tintColor = tint.withAlphaComponent(plan.dimmed ? 0.6 : 1)
        }
    }

    func prepareForReuse() { spinner?.stopAnimating() }
}

// ── A reply to somebody's story ──

/// The caption line and the big card that float ABOVE a story-reply bubble. It rides the reply
/// swipe with the bubble — swiping the card itself starts the reply too, which the SwiftUI version
/// had to be told twice before it did.
final class StoryReplyCardView: UIView {
    private let caption = UILabel()
    /// ⛔ THE STORY LINK CARD'S REGISTRATION, EXACTLY — owner 2026-10-13: "the reply preview's open
    /// and close animation must be the Story Link -> View Story one". Both open through
    /// `StoryDoor.open`, which looks the source up in the `.storyRow` scope. This card used to write
    /// its rectangle under the BARE key from `MessageRowView`, so the door found nothing: no cover
    /// lifted off the card, no landing back on it, and the card was never hidden while the story
    /// was out. Now it registers the way `LinkPreviewBubbleView` does: scoped key, the live view, its
    /// own 14pt corner, released on reuse, hidden while it is the flight's source.
    private(set) var flightKey = ""
    private var visibilityToken: AnyCancellable?
    private let bar = UIView()
    private let thumb = RowImageView(frame: .zero)
    private let unavailable = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        caption.lineBreakMode = .byTruncatingTail
        addSubview(caption)
        bar.layer.cornerRadius = 2.5
        addSubview(bar)
        thumb.layer.cornerRadius = 14
        thumb.layer.cornerCurve = .continuous
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = UIColor.label.withAlphaComponent(0.08).cgColor
        addSubview(thumb)
        unavailable.lineBreakMode = .byTruncatingTail
        addSubview(unavailable)
        visibilityToken = MediaSourceVisibility.shared.hiddenIdPublisher
            .removeDuplicates()
            .sink { [weak self] id in self?.applyVisibility(hiddenId: id) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ sr: StoryReplyChrome, plan: StoryReplyPlan, cid: String) {
        defer {
            setFlightKey(sr.opens && plan.thumb != nil ? MediaOpenRects.key(.storyRow, sr.anchorKey) : "")
            applyVisibility(hiddenId: MediaSourceVisibility.shared.hiddenId)
        }
        caption.frame = plan.caption
        caption.attributedText = plan.captionAttr

        if let barRect = plan.bar, let thumbRect = plan.thumb {
            bar.isHidden = false; thumb.isHidden = false
            bar.frame = barRect
            bar.backgroundColor = UIColor.label.withAlphaComponent(0.35)
            thumb.frame = thumbRect
            // A story thumbnail is NOT E2EE — it is baked plain into the reply so it shows in-window.
            // ⛔ NO CID, ON PURPOSE (owner 2026-10-27: the card stayed a grey box forever). With a
            // 1:1 cid and no `enc`, `MediaFetch.clearBytes` refuses the bytes as an unsealed 1:1
            // file, the job ends .failed and nothing is ever drawn. The story mention card passes
            // "" for the same reason.
            thumb.configure(url: sr.thumbUrl, enc: nil, cid: "", cornerRadius: 14)
        } else {
            bar.isHidden = true; thumb.isHidden = true; thumb.reset()
        }

        if let rect = plan.unavailable, let attr = plan.unavailableAttr {
            unavailable.isHidden = false
            unavailable.frame = rect
            unavailable.attributedText = attr
        } else {
            unavailable.isHidden = true
        }
    }

    func prepareForReuse() {
        thumb.reset()
        setFlightKey("")
        thumb.alpha = 1
    }

    private func setFlightKey(_ key: String) {
        if key != flightKey {
            if !flightKey.isEmpty { MediaOpenRects.releaseView(flightKey, ifItIs: thumb) }
            flightKey = key
        }
        // Re-registered on every configure too: the row may have moved under the same key.
        if !key.isEmpty { register() }
    }

    private func register() {
        guard window != nil, !thumb.isHidden else { return }
        MediaOpenRects.captureView(flightKey, thumb)
        MediaOpenRects.capture(flightKey, thumb.convert(thumb.bounds, to: nil), cornerRadius: 14)
    }

    private func applyVisibility(hiddenId: String?) {
        thumb.alpha = (!flightKey.isEmpty && hiddenId == flightKey) ? 0 : 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !flightKey.isEmpty { register() }
    }
}

// ── A poll ──

/// ⛔ THE ONLY ROW IN THIS DIRECTORY THAT OWNS A SUBSCRIPTION, and it is careful about it.
///
/// Votes arrive from a Firestore listener and change constantly. They change NO geometry — the bar
/// fills inside a fixed track and the percentage sits in a fixed slot — so the row is planned once
/// and this view repaints in place. A poll never re-measures, which is why a vote landing cannot
/// move the conversation under the reader.
///
/// ⚠️ THE LISTENER IS KEYED AND TORN DOWN ON REUSE. A recycled cell that kept its old listener would
/// paint another poll's votes into this one, and forty scrolled-past polls would each still hold a
/// live query.
final class PollBubbleView: UIView {
    private let question = UILabel()
    private let subtitle = UILabel()
    private let total = UILabel()
    private let hairline = UIView()             // Thick bars only (owner 2026-10-21)
    private var rows: [PollOptionRow] = []

    private var listener: ListenerRegistration?
    private var listeningKey: String?
    private var votes: [String: [Int]] = [:]
    private var plan: PollPlan?
    private var body: BubbleBody.PollBody?
    private var tint: UIColor = .label
    private var cid: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        question.numberOfLines = 0
        question.lineBreakMode = .byWordWrapping
        addSubview(question)
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(subtitle)
        total.lineBreakMode = .byTruncatingTail
        addSubview(total)
        addSubview(hairline)
        addSubview(footerStack)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { FirestoreHub.drop([listener]) }   // never remove() directly in a deinit: see ListenerBox

    func configure(_ p: BubbleBody.PollBody, plan: PollPlan, tint: UIColor, cid: String) {
        self.plan = plan
        self.body = p
        self.tint = tint
        self.cid = cid

        question.frame = plan.question
        question.attributedText = plan.questionAttr
        subtitle.frame = plan.subtitle
        subtitle.attributedText = plan.subtitleAttr
        total.frame = plan.total
        hairline.isHidden = plan.hairline == nil
        hairline.frame = plan.hairline ?? .zero
        hairline.backgroundColor = tint.withAlphaComponent(0.22)

        while rows.count < plan.options.count {
            let r = PollOptionRow()
            addSubview(r)
            rows.append(r)
        }
        for (i, r) in rows.enumerated() {
            guard i < plan.options.count else { r.isHidden = true; continue }
            r.isHidden = false
            r.frame = bounds
            r.apply(plan.options[i], filledRows: plan.filledRows, trackRadius: plan.trackRadius,
                    ink: tint, check: plan.checkColor)
        }

        let key = "\(cid)|\(p.messageId)"
        if listeningKey != key {
            listener?.remove()
            listeningKey = key
            votes = [:]
            listener = PollService.listen(cid: cid, messageId: p.messageId, channel: p.inChannel) { [weak self] v in
                guard let self, self.listeningKey == key else { return }
                self.votes = v
                self.paintVotes()
            }
        }
        paintVotes()
    }

    /// 2026-10-19: votes are taken until the creator stops the poll or its end time passes (the
    /// rules refuse a late vote too).
    var isOpen: Bool {
        guard let body, !body.closed else { return false }
        if let ends = body.endsAt { return Date().timeIntervalSince1970 * 1000 < ends }
        return true
    }

    /// Vote counts → the bar fills and the percentages. Geometry is untouched.
    private func paintVotes() {
        guard let plan, let body else { return }
        let voters = votes.count
        let mine = Set(votes[AuthService.shared.uid ?? ""] ?? [])
        // The footer is the door to the results page (who voted, Stop Poll). owner 2026-10-21 redesign:
        // "N votes · View results", or "No votes yet"; semibold once there are votes.
        let count = "\(voters) vote\(voters == 1 ? "" : "s")"
        let words: String
        if isOpen {
            words = voters > 0 ? "\(count) · View results" : "No votes yet"
        } else {
            words = voters > 0 ? "Poll ended · \(count)" : "Poll ended"
        }
        total.attributedText = NSAttributedString(
            string: words,
            attributes: [.font: UIFont.systemFont(ofSize: 13, weight: voters > 0 ? .semibold : .regular),
                         .foregroundColor: tint.withAlphaComponent(0.85)])
        // Bars and percentages show once I have voted or the poll is over (owner 2026-10-21 mockups:
        // the rows are plain before voting). The results page is always one tap away in the footer.
        let showResults = !mine.isEmpty || !isOpen
        // A quiz shows right and wrong once I have answered, or once the poll is over.
        let reveal = !body.correct.isEmpty && showResults
        // VOTER FACES (owner 2026-10-21, his mockup): up to three of the people who chose each
        // answer beside its percentage, and up to three voters beside "N votes". Never on a poll
        // that hides who voted. Photos from the group's own member map.
        let conv = ConversationsRepository.shared.conversations.first { $0.id == cid }
        let showFaces = showResults && !body.hideVoters
        func faces(_ uids: [String]) -> [(String, String?)] {
            uids.sorted().prefix(3).map { (conv?.names[$0] ?? "", conv?.photos[$0]) }
        }
        for (i, r) in rows.enumerated() where i < plan.options.count {
            let chose = votes.filter { $0.value.contains(i) }.map(\.key)
            let count = chose.count
            let fraction = voters > 0 ? Double(count) / Double(voters) : 0
            let mark: PollOptionRow.QuizMark = !reveal ? .none
                : body.correct.contains(i) ? .right : (mine.contains(i) ? .wrong : .none)
            r.paint(fraction: fraction, chosen: mine.contains(i), multiple: body.multiple,
                    showResults: showResults, quiz: mark)
            r.setFaces(showFaces ? faces(chose) : [])
        }
        let footerFaces = (!body.hideVoters && voters > 0) ? faces(Array(votes.keys)) : []
        footerStack.set(footerFaces, side: 18)
        let textW = ceil(total.attributedText?.size().width ?? 0)
        footerStack.frame.origin = CGPoint(x: total.frame.minX + min(textW, total.frame.width) + 6,
                                           y: total.frame.midY - footerStack.frame.height / 2)
    }
    private let footerStack = PollFaceStack()

    /// The footer ("N votes · Results ›"), for the tap that opens the results page.
    func hitsResults(_ point: CGPoint) -> Bool {
        total.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    /// Cast a vote on this option.
    ///
    /// ⚠️ THE WRITE IS BUILT HERE, not up in ThreadView, because a vote is a TOGGLE against what the
    /// voter can currently see — and the live selection only exists in this view's listener. Routing
    /// the tap upwards would have meant a second copy of the votes, one update behind.
    func castVote(option i: Int) {
        guard let body, isOpen else { return }
        // A light tap under the finger as the vote lands (owner 2026-10-21: "make the user feel it").
        Haptics.impact(.light)
        // A quiz takes one answer and keeps it: changing it after seeing right/wrong is cheating.
        if !body.correct.isEmpty, !(votes[AuthService.shared.uid ?? ""] ?? []).isEmpty { return }
        let me = AuthService.shared.uid ?? ""
        var mine = Set(votes[me] ?? [])
        if body.multiple {
            if mine.contains(i) { mine.remove(i) } else { mine.insert(i) }
        } else {
            // Single choice REPLACES, and tapping your own answer clears it.
            mine = mine == [i] ? [] : [i]
        }
        // Recorded here at once (audit 2026-10-20): two quick taps built from the listener's old
        // copy and kept only the second pick, and slipped past the quiz lock.
        votes[me] = mine.isEmpty ? nil : mine.sorted()
        paintVotes()
        PollService.setVote(cid: cid, messageId: body.messageId, options: mine.sorted())
    }

    /// Which option is at this point, for the tap that casts a vote.
    func optionIndex(at point: CGPoint) -> Int? {
        guard let plan else { return nil }
        // The plan's own tap rect: the whole filled row, or the row plus its bar (owner 2026-10-21).
        for (i, o) in plan.options.enumerated() where o.hit.contains(point) { return i }
        return nil
    }

    func prepareForReuse() {
        listener?.remove()
        listener = nil
        listeningKey = nil
        votes = [:]
    }
}

/// One option. owner 2026-10-21 redesign: the circle (or square) is drawn by hand so its stroke is
/// exactly 2pt, and a chosen option is a filled circle with a tick in the bubble's own colour.
/// The track is added FIRST, so in Filled rows the fill grows behind the words, not over them.
final class PollOptionRow: UIView {
    private let track = UIView()
    private let fill = UIView()
    private let glyph = UIView()                // the ring / square, or the filled mark
    private let mark = UIImageView()            // the tick (or a quiz cross) inside a filled mark
    private let label = UILabel()
    private let percent = UILabel()
    private var option: PollPlan.Option?
    private var filledRows = false
    private var ink: UIColor = .label
    private var check: UIColor = .systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        track.clipsToBounds = true
        addSubview(track)
        track.addSubview(fill)
        addSubview(glyph)
        mark.contentMode = .center
        glyph.addSubview(mark)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        percent.textAlignment = .right
        addSubview(percent)
        addSubview(faceStack)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ o: PollPlan.Option, filledRows: Bool, trackRadius: CGFloat, ink: UIColor, check: UIColor) {
        option = o
        self.filledRows = filledRows
        self.ink = ink
        self.check = check
        glyph.frame = o.glyph
        mark.frame = glyph.bounds
        label.frame = o.label
        label.attributedText = o.labelAttr
        percent.frame = o.percent
        track.frame = o.track
        track.layer.cornerRadius = trackRadius
        track.layer.cornerCurve = .continuous
        // Thick bars: the fill has the bar's own rounded ends. Filled rows: a plain rectangle the
        // row's corners clip, so it reads as the row filling from the left.
        fill.layer.cornerRadius = filledRows ? 0 : trackRadius
    }

    enum QuizMark { case none, right, wrong }

    private let faceStack = PollFaceStack()

    /// The people who chose this answer, just left of its percentage (owner 2026-10-21).
    func setFaces(_ faces: [(String, String?)]) {
        let side: CGFloat = 20
        faceStack.set(faces, side: side)
        let textW = ceil(percent.attributedText?.size().width ?? percent.intrinsicContentSize.width)
        faceStack.frame.origin = CGPoint(x: percent.frame.maxX - textW - 6 - faceStack.frame.width,
                                         y: percent.frame.midY - side / 2)
    }

    func paint(fraction: Double, chosen: Bool, multiple: Bool, showResults: Bool, quiz: QuizMark = .none) {
        guard let o = option else { return }
        let side = o.glyph.width
        let squareRadius = side * 0.27
        glyph.layer.cornerRadius = multiple ? squareRadius : side / 2
        glyph.layer.cornerCurve = .continuous
        let markConfig = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .bold)
        switch quiz {
        case .right:
            glyph.layer.borderWidth = 0
            glyph.backgroundColor = .systemGreen
            mark.image = UIImage(systemName: "checkmark", withConfiguration: markConfig)
            mark.tintColor = .white
        case .wrong:
            glyph.layer.borderWidth = 0
            glyph.backgroundColor = .systemRed
            mark.image = UIImage(systemName: "xmark", withConfiguration: markConfig)
            mark.tintColor = .white
        case .none:
            if chosen {
                glyph.layer.borderWidth = 0
                glyph.backgroundColor = ink
                mark.image = UIImage(systemName: "checkmark", withConfiguration: markConfig)
                mark.tintColor = check
            } else {
                glyph.backgroundColor = .clear
                glyph.layer.borderWidth = 2
                glyph.layer.borderColor = ink.withAlphaComponent(0.85).cgColor
                mark.image = nil
            }
        }
        // Filled rows: the chosen option's words go semibold (measured for it in the plan).
        label.attributedText = (filledRows && chosen) ? o.labelChosenAttr : o.labelAttr

        percent.isHidden = !showResults
        percent.attributedText = NSAttributedString(
            string: "\(Int((fraction * 100).rounded()))%",
            attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: ink])

        if filledRows {
            track.backgroundColor = ink.withAlphaComponent(showResults ? 0.10 : 0.14)
            fill.backgroundColor = ink.withAlphaComponent(chosen ? 0.32 : 0.20)
        } else {
            track.backgroundColor = ink.withAlphaComponent(0.22)
            fill.backgroundColor = chosen ? ink : ink.withAlphaComponent(0.70)
        }
        let shown = showResults ? CGFloat(max(0, min(1, fraction))) : 0
        // The one thing that animates in a poll: the fill growing as a vote lands.
        UIView.animate(withDuration: 0.25) {
            self.fill.frame = CGRect(x: 0, y: 0, width: o.track.width * shown, height: o.track.height)
        }
    }
}

/// A shared contact: the avatar row, then a full-width "message" button.
final class ContactBubbleView: UIView {
    private let avatar = RowAvatarView()
    private let name = UILabel()
    private let chevron = UIImageView()
    private let button = UIView()
    private let buttonLabel = UILabel()
    private let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(avatar)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        chevron.contentMode = .scaleAspectFit
        addSubview(chevron)
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        addSubview(button)
        buttonLabel.textAlignment = .center
        addSubview(buttonLabel)
        addSubview(divider)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ c: BubbleBody.ContactBody, plan: ContactPlan, tint: UIColor) {
        avatar.frame = plan.avatar
        avatar.configure(name: c.name, photoUrl: c.photo)
        name.frame = plan.name
        name.attributedText = plan.nameAttr
        chevron.frame = plan.chevron
        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        chevron.tintColor = tint.withAlphaComponent(0.7)

        if let rect = plan.button, let attr = plan.buttonAttr, let labelRect = plan.buttonLabel {
            button.isHidden = false; buttonLabel.isHidden = false; divider.isHidden = false
            button.frame = rect
            // Tinted from the bubble's own text colour, so it reads on a blue bubble, a custom chat
            // colour and the incoming grey without anyone picking three values.
            button.backgroundColor = tint.withAlphaComponent(0.12)
            buttonLabel.frame = labelRect
            buttonLabel.attributedText = attr
            divider.frame = CGRect(x: rect.minX, y: rect.minY - 5, width: rect.width,
                                   height: BubbleMetrics.hairline)
            divider.backgroundColor = tint.withAlphaComponent(0.15)
        } else {
            button.isHidden = true; buttonLabel.isHidden = true; divider.isHidden = true
        }
    }
}

/// Up to three small round faces, overlapping, each with a thin ring (owner 2026-10-21: voters on
/// a poll). Sized by `set`; the caller places it.
final class PollFaceStack: UIView {
    private var views: [RowAvatarView] = []
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ faces: [(String, String?)], side: CGFloat) {
        while views.count < faces.count {
            let v = RowAvatarView()
            v.layer.borderWidth = 1.5
            v.layer.borderColor = UIColor.systemBackground.cgColor
            v.clipsToBounds = true
            addSubview(v)
            views.append(v)
        }
        let step = side * 0.68
        for (i, v) in views.enumerated() {
            guard i < faces.count else { v.isHidden = true; continue }
            v.isHidden = false
            v.frame = CGRect(x: CGFloat(i) * step, y: 0, width: side, height: side)
            v.layer.cornerRadius = side / 2
            v.configure(name: faces[i].0, photoUrl: faces[i].1)
            // The first face on top, as a stack reads.
            bringSubviewToFront(views[faces.count - 1 - i])
        }
        isHidden = faces.isEmpty
        frame.size = faces.isEmpty ? .zero
            : CGSize(width: side + CGFloat(faces.count - 1) * step, height: side)
    }
}
