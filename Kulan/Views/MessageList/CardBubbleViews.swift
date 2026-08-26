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

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
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
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ p: BubbleBody.LinkPreview, plan: LinkPreviewPlan, tint: UIColor, cid: String) {
        backing.frame = plan.card
        backing.backgroundColor = tint.withAlphaComponent(0.10)

        if let rect = plan.hero {
            hero.isHidden = false
            hero.frame = rect
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
            avatar.configure(name: p.title, photoUrl: p.imageUrl)
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
    }

    func prepareForReuse() { hero.reset() }
}

// ── A reply to somebody's story ──

/// The caption line and the big card that float ABOVE a story-reply bubble. It rides the reply
/// swipe with the bubble — swiping the card itself starts the reply too, which the SwiftUI version
/// had to be told twice before it did.
final class StoryReplyCardView: UIView {
    private let caption = UILabel()
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
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ sr: StoryReplyChrome, plan: StoryReplyPlan, cid: String) {
        caption.frame = plan.caption
        caption.attributedText = plan.captionAttr

        if let barRect = plan.bar, let thumbRect = plan.thumb {
            bar.isHidden = false; thumb.isHidden = false
            bar.frame = barRect
            bar.backgroundColor = UIColor.label.withAlphaComponent(0.35)
            thumb.frame = thumbRect
            // A story thumbnail is NOT E2EE — it is baked plain into the reply so it shows in-window.
            thumb.configure(url: sr.thumbUrl, enc: nil, cid: cid, cornerRadius: 14)
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

    func prepareForReuse() { thumb.reset() }
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
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { listener?.remove() }

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

        while rows.count < plan.options.count {
            let r = PollOptionRow()
            addSubview(r)
            rows.append(r)
        }
        for (i, r) in rows.enumerated() {
            guard i < plan.options.count else { r.isHidden = true; continue }
            r.isHidden = false
            r.frame = bounds
            r.apply(plan.options[i], tint: tint)
        }

        let key = "\(cid)|\(p.messageId)"
        if listeningKey != key {
            listener?.remove()
            listeningKey = key
            votes = [:]
            listener = PollService.listen(cid: cid, messageId: p.messageId) { [weak self] v in
                guard let self, self.listeningKey == key else { return }
                self.votes = v
                self.paintVotes()
            }
        }
        paintVotes()
    }

    /// Vote counts → the bar fills and the percentages. Geometry is untouched.
    private func paintVotes() {
        guard let plan, let body else { return }
        let voters = votes.count
        let mine = Set(votes[AuthService.shared.uid ?? ""] ?? [])
        total.attributedText = NSAttributedString(
            string: "\(voters) vote\(voters == 1 ? "" : "s")",
            attributes: [.font: UIFont.systemFont(ofSize: 11),
                         .foregroundColor: tint.withAlphaComponent(0.7)])
        for (i, r) in rows.enumerated() where i < plan.options.count {
            let count = votes.values.reduce(0) { $0 + ($1.contains(i) ? 1 : 0) }
            let fraction = voters > 0 ? Double(count) / Double(voters) : 0
            r.paint(fraction: fraction, chosen: mine.contains(i),
                    multiple: body.multiple, tint: tint)
        }
    }

    /// Cast a vote on this option.
    ///
    /// ⚠️ THE WRITE IS BUILT HERE, not up in ThreadView, because a vote is a TOGGLE against what the
    /// voter can currently see — and the live selection only exists in this view's listener. Routing
    /// the tap upwards would have meant a second copy of the votes, one update behind.
    func castVote(option i: Int) {
        guard let body else { return }
        let me = AuthService.shared.uid ?? ""
        var mine = Set(votes[me] ?? [])
        if body.multiple {
            if mine.contains(i) { mine.remove(i) } else { mine.insert(i) }
        } else {
            // Single choice REPLACES, and tapping your own answer clears it.
            mine = mine == [i] ? [] : [i]
        }
        PollService.setVote(cid: cid, messageId: body.messageId, options: mine.sorted())
    }

    /// Which option is at this point, for the tap that casts a vote.
    func optionIndex(at point: CGPoint) -> Int? {
        guard let plan else { return nil }
        for (i, o) in plan.options.enumerated() {
            let hit = o.glyph.union(o.label).union(o.percent).insetBy(dx: 0, dy: -4)
            if hit.contains(point) { return i }
        }
        return nil
    }

    func prepareForReuse() {
        listener?.remove()
        listener = nil
        listeningKey = nil
        votes = [:]
    }
}

final class PollOptionRow: UIView {
    private let glyph = UIImageView()
    private let label = UILabel()
    private let percent = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var option: PollPlan.Option?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glyph.contentMode = .scaleAspectFit
        addSubview(glyph)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        percent.textAlignment = .right
        addSubview(percent)
        track.clipsToBounds = true
        addSubview(track)
        track.addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ o: PollPlan.Option, tint: UIColor) {
        option = o
        glyph.frame = o.glyph
        label.frame = o.label
        label.attributedText = o.labelAttr
        percent.frame = o.percent
        track.frame = o.track
        track.layer.cornerRadius = o.track.height / 2
        track.backgroundColor = tint.withAlphaComponent(0.18)
        fill.layer.cornerRadius = o.track.height / 2
    }

    func paint(fraction: Double, chosen: Bool, multiple: Bool, tint: UIColor) {
        guard let o = option else { return }
        let symbol = multiple
            ? (chosen ? "checkmark.square.fill" : "square")
            : (chosen ? "largecircle.fill.circle" : "circle")
        glyph.image = UIImage(systemName: symbol,
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 16))
        glyph.tintColor = tint
        percent.attributedText = NSAttributedString(
            string: "\(Int((fraction * 100).rounded()))%",
            attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: tint.withAlphaComponent(0.85)])
        fill.backgroundColor = tint
        // The one thing that animates in a poll: the bar growing as a vote lands.
        UIView.animate(withDuration: 0.25) {
            self.fill.frame = CGRect(x: 0, y: 0,
                                     width: o.track.width * CGFloat(max(0, min(1, fraction))),
                                     height: o.track.height)
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
