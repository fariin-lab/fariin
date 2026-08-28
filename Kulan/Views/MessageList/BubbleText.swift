import UIKit

// ===== The bubble's text, and the footer that shares its last line =====
//
// The reference app's footer rule, which this reproduces exactly: the timestamp shares the
// message's LAST line when it fits, otherwise it drops to a row of its own. The fit case works by
// appending an INVISIBLE run that mirrors the real footer to the end of the body, so only the last
// line leaves a gap, with the real footer drawn on top of that gap. An `HStack { text; time }`
// instead reserves a full-height column beside the text and every line wraps early.
//
// ⚠️ THE RESERVATION IS REAL TEXT, NOT A SPACER BOX. An `NSTextAttachment` sized to the footer's
// width is one unbreakable glyph, so a long last word plus the box wraps differently from the same
// word plus breakable text — and `metaNeedsOwnLine` below exists precisely to decide that edge.
// Mirroring the footer's actual runs is what keeps the two decisions consistent.

enum BubbleText {
    // Built ONCE. Constructing an NSDataDetector or an NSRegularExpression per bubble per render
    // was the main scroll-jank source before the migration.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let mentionRegex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]{3,24})")

    /// A link range the renderer turned into a tappable run, so the cell can hit-test taps without
    /// re-running the detector.
    struct LinkRun: Equatable {
        var range: NSRange
        var url: URL
    }

    struct Built {
        var body: NSAttributedString          // body + (when it fits) the invisible footer reservation
        var links: [LinkRun]
        var metaOnOwnLine: Bool
    }

    // ── The body ──

    /// Body text with tappable links, @usernames, group mentions and the in-chat search highlight.
    /// `textColor` is the resolved foreground for this bubble (white on mine, black/white on theirs).
    static func body(_ t: BubbleBody.TextBody, isMe: Bool, textColor: UIColor,
                     accent: UIColor) -> (NSMutableAttributedString, [LinkRun]) {
        let full = t.text
        let out = NSMutableAttributedString(string: full, attributes: [
            .font: BubbleMetrics.bodyFont,
            .foregroundColor: textColor,
        ])
        let ns = full as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var links: [LinkRun] = []

        // In-chat search: highlight the matched TERM, never the whole bubble. Case, diacritic and
        // width insensitive so the highlight finds exactly what the search matched.
        if t.searchTerm.count >= 2 {
            var searchFrom = 0
            while searchFrom < ns.length {
                let r = ns.range(of: t.searchTerm, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                guard r.location != NSNotFound, r.length > 0 else { break }
                out.addAttributes([.backgroundColor: UIColor.systemYellow, .foregroundColor: UIColor.black], range: r)
                searchFrom = r.location + r.length
            }
        }

        // Fast path: no links, no @, no mentions → skip all regex work (the common case).
        guard full.contains("http") || full.contains("@") || !t.mentionTokens.isEmpty else {
            return (out, links)
        }

        // WHITE on my bubble: the fill is systemBlue (or a vivid custom chat colour), so a blue link
        // was blue-on-blue and effectively invisible. The underline still marks it as tappable.
        let linkColor: UIColor = isMe ? .white : .systemBlue
        func style(_ r: NSRange, url: URL?, underline: Bool) {
            guard r.location != NSNotFound, r.location + r.length <= ns.length else { return }
            out.addAttribute(.foregroundColor, value: linkColor, range: r)
            if underline { out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            if let url { links.append(LinkRun(range: r, url: url)) }
        }

        if let detector = linkDetector {
            for m in detector.matches(in: full, range: whole) where m.url != nil {
                style(m.range, url: m.url, underline: true)
            }
        }
        // @usernames → kulan://u/<handle>, resolved on tap.
        if let re = mentionRegex {
            for m in re.matches(in: full, range: whole) where m.numberOfRanges > 1 {
                let handle = ns.substring(with: m.range(at: 1))
                style(m.range, url: URL(string: "kulan://u/\(handle)"), underline: false)
            }
        }
        // Group @mentions by display name → bold, and accent-tinted on an incoming bubble. Applied
        // last so it overrides the generic username style above.
        // `count > 1` because a mention token is "@" + the display name, and an unresolved name
        // makes that a bare "@" — which would then bold and tint every at-sign in the message.
        for token in t.mentionTokens where token.count > 1 {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: token, range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound, r.length > 0 else { break }
                out.addAttribute(.font, value: UIFont.systemFont(ofSize: 17, weight: .semibold), range: r)
                if !isMe { out.addAttribute(.foregroundColor, value: accent, range: r) }
                from = r.location + r.length
            }
        }
        return (out, links)
    }

    // ── The footer ──

    /// The VISIBLE footer: "edited", the time, and the tick.
    /// ⛔ `showClock` IS GONE, AND THAT REVERSES AN OLDER RULE OF HIS ON HIS NEWER WORD.
    ///
    /// This footer used to hold the sending glyph back for 0.8s, on a 2026-08-12 note reasoning
    /// that "the reference never shows a clock on a healthy send". Read from their own source
    /// (`CVComponentFooter`, the `messageStatus` switch) that is not what they do:
    ///
    ///     case .uploading, .sending:
    ///         statusIndicator = StatusIndicator(imageName: "message_status_sending", isAnimated: true)
    ///
    /// No window, no delay — the indicator is there from the first frame and it SPINS. His report,
    /// 2026-08-26, with a photograph of the empty gap the grace window leaves: "time icon is
    /// coming late". So the glyph appears immediately, and `VoiceBubbleView`-style live state is
    /// not needed for it because the state it draws is already in the model.
    static func meta(_ m: MetaChrome, isMe: Bool, color: UIColor) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if m.edited {
            s.append(NSAttributedString(string: "edited ", attributes: [
                .font: BubbleMetrics.metaItalicFont, .foregroundColor: color]))
        }
        s.append(NSAttributedString(string: m.timeText, attributes: [
            .font: BubbleMetrics.metaFont, .foregroundColor: color]))
        // ⛔ A FAILED SEND HAS NO FOOTER GLYPH. Theirs: `case .failed: // No status indicator icon.`
        // The red (!) outside the bubble says it, and drawing both put two exclamation marks on one
        // message — which is what his 2026-08-26 screenshot shows.
        guard isMe, m.tick != .none, m.tick != .failed, let img = BubbleTicks.image(m.tick) else { return s }
        let a = NSTextAttachment()
        // ⛔ WHILE SENDING THE SLOT IS RESERVED BUT EMPTY. The spinning clock is a separate view
        // laid over this slot (`MessageRowView.setSendingSpin`), because an attachment cannot
        // rotate. Drawing the glyph here as well put a still clock UNDER the spinning one — his
        // 2026-08-26 screenshot, two clocks overlapping. Same image, same size, clear ink: the
        // footer measures identically, so the bubble never resizes when the tick lands.
        let ink: UIColor = m.tick == .sending ? .clear : (m.tick == .failed ? .systemRed : color)
        a.image = img.withTintColor(ink, renderingMode: .alwaysOriginal)
        // ⛔ CENTRED ON THE CAP HEIGHT, AND IT MUST NOT MAKE THE LINE TALLER — his screenshot,
        // 2026-08-28: on a photo, the timestamp sits low in its dark pill with a visible gap above
        // it and almost none below. Measured off that screenshot: a 59px pill with 27px above the
        // digits and 11px below.
        //
        // THE PILL WAS NOT THE PROBLEM; THIS LINE WAS. `y: -1` hangs a symbol image that is about
        // 12pt tall one point below the baseline, so it reaches ~11pt ABOVE it — past the 10pt
        // font's own ascent. `boundingRect` then reports a line ~2pt taller than the font's, the
        // capsule is built from that inflated box (`floatingMeta`), and the capsule grows UPWARD
        // while the text stays where its baseline puts it. The gap all ends up on top.
        //
        // Centring the glyph on the cap height is where the eye expects a tick beside text anyway,
        // and it keeps the glyph inside the font's own ascent/descent, so the line box is the
        // font's line box and every footer in the app is measured from the same number again.
        let f = BubbleMetrics.metaFont
        a.bounds = CGRect(x: 0, y: (f.capHeight - img.size.height) / 2,
                          width: img.size.width, height: img.size.height)
        s.append(NSAttributedString(string: " "))
        s.append(NSAttributedString(attachment: a))
        return s
    }

    /// The INVISIBLE reservation appended to the body so the last line leaves room for the footer.
    ///
    /// ⚠️ ONE CONSTANT WIDTH FOR EVERY SEND STATE, and that is the point: the reservation is what
    /// the last line wraps against and the bubble hugs that width, so mirroring whatever the footer
    /// happens to be drawing right now made the bubble RESIZE as the message progressed — it grew
    /// when the send landed and grew again when the other side read it. The widest state (the read
    /// pair) is reserved always; a narrower state just leaves invisible slack behind the timestamp.
    static func reservation(_ m: MetaChrome, isMe: Bool, ownLine: Bool) -> NSAttributedString {
        let clear = UIColor.clear
        let s = NSMutableAttributedString(string: ownLine ? "\n  " : "  ", attributes: [
            .font: BubbleMetrics.metaFont, .foregroundColor: clear])
        if m.edited {
            s.append(NSAttributedString(string: "edited ", attributes: [
                .font: BubbleMetrics.metaItalicFont, .foregroundColor: clear]))
        }
        s.append(NSAttributedString(string: m.timeText, attributes: [
            .font: BubbleMetrics.metaFont, .foregroundColor: clear]))
        guard isMe else { return s }
        s.append(NSAttributedString(string: " ", attributes: [
            .font: BubbleMetrics.metaFont, .foregroundColor: clear]))
        if let one = BubbleTicks.image(.sent) {
            for _ in 0..<2 {
                let a = NSTextAttachment()
                a.image = UIImage()                                   // draws nothing; the bounds reserve
                a.bounds = CGRect(x: 0, y: 0, width: one.size.width, height: 1)
                s.append(NSAttributedString(attachment: a))
            }
        }
        return s
    }

    /// True when the timestamp cannot share the message's last line — a word too long to leave room
    /// beside it. When true the body reserves NOTHING inline and the footer takes a real row, so
    /// the text keeps the full bubble width on every line.
    ///
    /// ⚠️ Reserving inline in that case is not merely tight, it is wrong for the WHOLE paragraph: a
    /// trailing run that begins on a new line still participates in the string's width, so every
    /// line wrapped short by the footer's width (the owner's long-paste screenshot).
    static func metaNeedsOwnLine(text: String, meta: MetaChrome, isMe: Bool, textAvail: CGFloat) -> Bool {
        var metaStr = meta.edited ? "edited " : ""
        metaStr += meta.timeText
        var metaW = (metaStr as NSString).size(withAttributes: [.font: BubbleMetrics.metaFont]).width
        // The read pair, ALWAYS — the same constant the reservation makes. These two must agree or
        // the measuring pass and the drawing pass answer differently about the same bubble.
        if isMe { metaW += 25 }
        metaW += BubbleMetrics.metaGap
        let longestWord = text.split(whereSeparator: { $0.isWhitespace })
            .map { (String($0) as NSString).size(withAttributes: [.font: BubbleMetrics.bodyFont]).width }
            .max() ?? 0
        return longestWord + metaW > textAvail
    }

    /// Body + reservation + the links found in it, decided against `textAvail` (the width the text
    /// actually wraps in — the bubble's width minus its insets, or a media box minus its caption
    /// insets).
    static func build(_ t: BubbleBody.TextBody, meta: MetaChrome, isMe: Bool,
                      textColor: UIColor, accent: UIColor, textAvail: CGFloat) -> Built {
        let ownLine = metaNeedsOwnLine(text: t.text, meta: meta, isMe: isMe, textAvail: textAvail)
        let (body, links) = self.body(t, isMe: isMe, textColor: textColor, accent: accent)
        if !ownLine { body.append(reservation(meta, isMe: isMe, ownLine: false)) }
        return Built(body: body, links: links, metaOnOwnLine: ownLine)
    }

    // ── Measurement ──

    /// The rect an attributed string occupies at `width`. `ceil` on both axes: a fractional height
    /// handed to a cell frame is rounded by UIKit at draw time, and a row measured 0.3pt short
    /// clips its own descenders.
    static func size(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        guard s.length > 0 else { return .zero }
        let r = s.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                               context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// A single line that must never wrap or truncate — the footer, a duration badge, a chip.
    ///
    /// ⚠️ It measures against an UNBOUNDED width and adds a point of slack. `boundingRect` and a
    /// UILabel's own typesetting can disagree by a fraction on a string carrying an image
    /// attachment (the tick), and when the label's frame IS the measured width that fraction is
    /// enough to drop the attachment — the owner's "2:44 PM…" with the ticks gone.
    static func lineSize(_ s: NSAttributedString) -> CGSize {
        guard s.length > 0 else { return .zero }
        let unbounded = CGFloat.greatestFiniteMagnitude
        let r = s.boundingRect(with: CGSize(width: unbounded, height: unbounded),
                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                               context: nil)
        return CGSize(width: ceil(r.width) + 1, height: ceil(r.height))
    }

    /// The jumbomoji point size for a 1…5 emoji message — the reference app's multipliers on the
    /// body point size, verbatim.
    static func jumbomojiFont(_ count: Int) -> UIFont {
        let base: CGFloat = 17
        let size: CGFloat
        switch count {
        case 1: size = base * 3.5
        case 2: size = base * 3.0
        case 3: size = base * 2.75
        case 4: size = base * 2.5
        default: size = base * 2.25   // 5 is the maximum that still counts as jumbomoji
        }
        return .systemFont(ofSize: size)
    }
}
