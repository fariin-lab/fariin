import SwiftUI
import UIKit

// The TEXT half of the story camera, to the owner's reference (2026-08-03): a coloured card with
// the X top-left and the colour button top-right, the words in the middle, "Aa" bottom-left, and a
// tick bottom-right while the keyboard is up.
//
// IT IS A CARD, NOT A SCREEN. It used to be its own full-screen cover raised from the camera, which
// meant the CAMERA / TEXT switch disappeared the moment you used it — you could get into text mode
// but not back out without closing. In his drawing that switch stays on screen and TEXT is simply
// the other thing the same page can show, so this draws only the card and `StoryCameraView` keeps
// the bar underneath it.

/// ONE CAP FOR EVERY STORY TEXT FIELD, because it was written twice and the two copies disagreed.
///
/// The text composer capped at 720 and the editor's caption at 700 — and the caption's own comment
/// says "cap like the text composer", so 700 was not a number anybody chose, it was a copy that
/// drifted. Nothing on the server bounds either field, so the two only ever had each other to agree
/// with. One constant now, so they cannot part again.
enum StoryText {
    static let charLimit = 720

    /// WHERE A LINK CARD SITS, AS FRACTIONS, AND THE TWO PLACES THAT DRAW IT BOTH READ THESE.
    ///
    /// The composer card is roughly the phone's shape and the posted file is a fixed 1:2.5 (see
    /// `renderTextStory`), so the only way for what he composes and what he posts to be the same
    /// picture is for the card's place to be described in terms both shapes share. A fraction is
    /// that; a point measurement is right on exactly one of them.
    ///
    /// It is also what the tap area is built from, so a viewer's finger and the drawing agree by
    /// construction rather than by two sets of arithmetic being kept in step by hand.
    static let linkCardWidthFraction: CGFloat = 0.72

    /// ⛔ THE AIR BETWEEN THE WORDS AND THE CARD — owner, 2026-08-23: "there is an unwanted empty
    /// space between the story text and the link preview … position them naturally and closely
    /// together."
    ///
    /// ⚠️ `linkCardCentreY` IS GONE AND THAT IS THE FIX. The card used to be pinned at 62% of the
    /// height whatever the status said, and the words centred themselves in whatever was left above
    /// it — so a short status sat around a third of the way down with the card still at 62%, and the
    /// hole between them was the difference. Nothing was inserting that space; two independently
    /// centred things were.
    ///
    /// They are one stack now, centred as a group, so the only distance between them is this. As a
    /// fraction of the WIDTH, like every other number on this screen, so the composer and the render
    /// describe the same picture — see `fittedSize` for why ratios rather than points.
    static let linkGapRatio: CGFloat = 0.04
}

/// Which of the two cards a story's link is wearing.
///
/// ⛔ TWO STYLES, AND A TAP ON THE CARD SWAPS THEM — owner, 2026-08-23: "I want 2 different preview
/// styles … when I tap the preview, it should switch to the other preview type. Both preview types
/// must work correctly with the same link."
///
/// ⚠️ `compact` IS THE DEFAULT, on his word: "always the new one, that one is better, use always
/// default". It is also the one that fits: `large` stands more than twice as tall, which is most of
/// what he means by the preview being too big.
enum StoryTextLinkStyle: Equatable {
    /// A row: a square of the page's picture on the left, its words to the right. His image 2.
    case compact
    /// The picture across the top with the words beneath it. The original card, smaller than it was.
    case large

    var other: StoryTextLinkStyle { self == .compact ? .large : .compact }
}

/// ⛔ THE LINK IS FOUND IN THE WORDS. THERE IS NO LINK BUTTON ANY MORE — owner, 2026-08-23: "Remove
/// this button completely … the user should be able to simply paste or type a URL directly into the
/// text … there should be no need for a separate Link button."
///
/// ⚠️ `NSDataDetector`, NOT A REGEX OF OURS. It is the same detector the system uses to underline
/// addresses in Notes and Messages, so what it finds is what an iPhone user already expects a URL to
/// be — including a bare `example.com` with no scheme, which is how people type. A pattern written
/// here would be a second, worse opinion about the same question, and it would be the one that has
/// to be maintained.
///
/// Two filters on top of it, and both are narrowing rather than second-guessing:
///
///   • HTTP AND HTTPS ONLY. The detector also matches `mailto:` for an email address and `tel:` for
///     a phone number, and a story that quietly grew a link card because somebody wrote their email
///     in it would be the app doing something nobody asked for.
///   • A HOST WITH A DOT IN IT, which is the same test the link sheet used before this and keeps a
///     stray word from being read as a hostname.
///
/// The FIRST one wins. A story carries one link (the reference app's shape, and what the posted
/// picture and its tap rectangle are built for), so "first" is the rule rather than a limitation —
/// it is the one the reading eye picks too.
enum StoryTextLinkDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstURL(in text: String) -> URL? {
        guard let detector, !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, host.contains(".")
            else { continue }
            return url
        }
        return nil
    }
}

/// One background and the ink that stays legible on it. Paired deliberately: a palette that only
/// stored colours would eventually put dark text on a dark card.
struct TextStoryStyle {
    let bg: Color
    let ink: Color
}

enum TextStoryStyles {
    /// The first one is the periwinkle from his screenshot, with black text, so the screen he drew
    /// is the screen it opens on.
    static let all: [TextStoryStyle] = [
        TextStoryStyle(bg: Color(hex: 0x8B87D8), ink: .black),
        TextStoryStyle(bg: Color(hex: 0xF4D06F), ink: .black),
        TextStoryStyle(bg: Color(hex: 0x7ED8A5), ink: .black),
        TextStoryStyle(bg: Color(hex: 0xF08A8A), ink: .black),
        TextStoryStyle(bg: Color(hex: 0x1E2A44), ink: .white),
        TextStoryStyle(bg: Color(hex: 0x0E3B36), ink: .white),
        TextStoryStyle(bg: Color(hex: 0x5B2333), ink: .white),
        TextStoryStyle(bg: Color(hex: 0x111113), ink: .white),
    ]

    /// Four faces, cycled by the Aa button. Design variants rather than bundled fonts: they ship
    /// with the system, they carry every weight, and they render identically in the story image.
    static func font(_ index: Int, size: CGFloat) -> Font {
        switch abs(index) % 4 {
        case 1:  return .system(size: size, weight: .black, design: .rounded)
        case 2:  return .system(size: size, weight: .semibold, design: .serif)
        case 3:  return .system(size: size, weight: .semibold, design: .monospaced)
        default: return .system(size: size, weight: .bold)
        }
    }

    static func style(_ index: Int) -> TextStoryStyle { all[abs(index) % all.count] }

    // MARK: - How big the words are

    /// THE TEXT'S BOX IS A SHAPE, NOT A SIZE — `width × width * boxAspect`, centred — and every
    /// number below is a RATIO of that width.
    ///
    /// ⚠️ THIS IS THE ONLY REASON THE CARD AND THE POSTED PICTURE AGREE. The card is about 370pt
    /// wide and the render is 920, so a rule written in points would start shrinking the words at
    /// two different lengths and what he composed would not be what posts. Written as ratios the
    /// rule is scale-free: the same text picks the same size RELATIVE to its box in both places, and
    /// the two pictures match by construction rather than by a constant somebody kept in step.
    ///
    /// 1.6 is a little shorter than the card's own 9:16, which is what leaves room for the X above
    /// the words and the Aa row below them. The render's frame is far taller than that (2.5:1, so it
    /// fills any viewer full-bleed), and the extra is deliberate over-bleed that gets cropped — the
    /// words are held to this shape in the middle of it, where every phone shows them.
    static let boxAspect: CGFloat = 1.6
    /// 0.081 of the box width is ~30pt on the card, which is the size this screen has always opened
    /// at, so nothing about a short status changes.
    static let maxSizeRatio: CGFloat = 0.081
    /// ...and ~12pt, which is where it stops. 720 characters land at about 15, so the floor is a
    /// backstop rather than the working end of the range.
    static let minSizeRatio: CGFloat = 0.032

    /// The measuring twin of `font(_:size:)`. SwiftUI's `Font` cannot be asked how tall a paragraph
    /// set in it would be; `UIFont` can, and these two must describe the same typeface or the fit
    /// would be measured in one face and drawn in another.
    static func uiFont(_ index: Int, size: CGFloat) -> UIFont {
        let weight: UIFont.Weight
        let design: UIFontDescriptor.SystemDesign
        switch abs(index) % 4 {
        case 1:  weight = .black;    design = .rounded
        case 2:  weight = .semibold; design = .serif
        case 3:  weight = .semibold; design = .monospaced
        default: weight = .bold;     design = .default
        }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: d, size: size)
    }

    /// THE BIGGEST SIZE THIS TEXT STILL FITS AT — the reference app's behaviour, and his 2026-08-16
    /// instruction: "when the text becomes longer, the text should automatically zoom out so that
    /// all text fits properly inside the story frame… do not let it get cut off."
    ///
    /// Measured, not bucketed by character count. Buckets are what most apps do and they are wrong
    /// twice over for this audience: they cannot know that a Somali word is longer than an English
    /// one, and they cannot know that this card has four faces of very different widths — the
    /// monospaced one needs about a third more room than the rounded one for the same sentence. The
    /// question "does this paragraph fit in this box in this face" has an exact answer, so it is
    /// asked rather than guessed.
    ///
    /// Steps down rather than binary-searching: a short status answers on the first measurement,
    /// which is the case that runs on every keystroke.
    static func fittedSize(for text: String, boxWidth w: CGFloat, fontIndex: Int) -> CGFloat {
        let maxSize = w * maxSizeRatio
        guard w > 1, !text.isEmpty else { return maxSize }
        let minSize = w * minSizeRatio
        // 0.98 of the box, because SwiftUI's line metrics and UIKit's differ by a hair and the hair
        // must fall on the side of fitting.
        let maxHeight = w * boxAspect * 0.98
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let ns = text as NSString
        let step = max(0.5, maxSize * 0.03)
        var size = maxSize
        while size > minSize {
            let h = ns.boundingRect(
                with: CGSize(width: w, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: uiFont(fontIndex, size: size), .paragraphStyle: para],
                context: nil).height
            if h <= maxHeight { return size }
            size -= step
        }
        return minSize
    }

    /// How tall this status actually stands at that size — the same measurement `fittedSize` makes
    /// on its way to an answer, exposed because the LAYOUT needs it too.
    ///
    /// ⛔ THIS IS WHAT LETS THE WORDS AND A LINK CARD BE ONE STACK. A `UITextView` fills whatever box
    /// it is given, so in a stack it would take everything and leave the card nothing; told its own
    /// height it takes exactly its own room and the two sit together. See `linkLayout`.
    ///
    /// ⚠️ MEASURED IN UIKIT AND DRAWN IN SWIFTUI, which differ by a hair — the same hair `fittedSize`
    /// keeps on the safe side with its 0.98. The callers add a little slack for the same reason, and
    /// it must be slack rather than a tighter number: too much room is invisible, too little clips
    /// the last line.
    static func measuredHeight(for text: String, boxWidth w: CGFloat,
                               fontIndex: Int, size: CGFloat) -> CGFloat {
        guard w > 1, !text.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        return (text as NSString).boundingRect(
            with: CGSize(width: w, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: uiFont(fontIndex, size: size), .paragraphStyle: para],
            context: nil).height
    }
}

/// Where the words and the link card sit inside a box of a given size — asked by the composer and by
/// the render with their own numbers, so the two describe one picture.
///
/// ⛔ A STACK, CENTRED AS A GROUP. The card used to be pinned at a fixed fraction of the height and
/// the words centred themselves in whatever was above it, which is exactly the gap he asked to have
/// removed: two things each centred in a different box, with the leftover between them.
///
/// ⚠️ NOTHING HERE IS MEASURED AFTER THE FACT. The card states its own height and the words are
/// measured before layout, so every number below is known on the first pass — which is what stops
/// the card appearing over the words and the words then moving. See `StoryTextLinkPreview.height`.
enum StoryTextLinkLayout {
    /// - Returns: the height to give the words, and where the card's centre lands as a FRACTION of
    ///   the box — the fraction being what the posted tap target is built from.
    static func place(textHeight: CGFloat, cardHeight: CGFloat,
                      boxWidth: CGFloat, boxHeight: CGFloat) -> (text: CGFloat, cardCentreY: CGFloat) {
        let gap = boxWidth * StoryText.linkGapRatio
        // The words never take so much that the card is pushed off the bottom. A very long status in
        // a keyboard-shortened box hits this and scrolls inside what is left, which is the same
        // thing it has always done — the card keeping its room is the part that matters.
        let text = max(0, min(textHeight, boxHeight - cardHeight - gap))
        let group = text + gap + cardHeight
        let top = max(0, (boxHeight - group) / 2)
        let centre = top + text + gap + cardHeight / 2
        return (text, boxHeight > 1 ? centre / boxHeight : 0.5)
    }
}

struct StoryTextCard: View {
    @Binding var text: String
    @Binding var styleIndex: Int
    @Binding var fontIndex: Int
    /// Mirrors the keyboard for the page above, which hides its bottom bar while you type.
    @Binding var typing: Bool
    /// The one link this status carries, or none. Owned by the page above because it is part of what
    /// gets POSTED, and this card is only where it is edited. See `StoryTextLink`.
    @Binding var link: StoryTextLink?
    var onClose: () -> Void

    /// The debounce-and-fetch for whatever URL the words currently hold. Cancelled by the next
    /// keystroke, which is what keeps a typed-out address from firing a request per character.
    @State private var linkTask: Task<Void, Never>?

    /// ⛔ THE SMALL CARD WHILE THE KEYBOARD IS UP, WHATEVER HE PICKED — owner, 2026-08-23: "the big
    /// one make small; when I open the keyboard use the small one."
    ///
    /// His choice is not lost, only overruled while there is nowhere to put it: the keyboard takes
    /// most of the card, and the tall style plus a status of any length in what is left means the
    /// words scrolling in a sliver. It comes straight back when the keyboard goes down, which is the
    /// state the story is composed and posted in — the BAKE always draws `link.style`, never this.
    private var shownLinkStyle: StoryTextLinkStyle {
        guard let link else { return .compact }
        return focused ? .compact : link.style
    }

    /// ⚠️ PLAIN `@State`, NOT `@FocusState`. The words are a `UITextView` now (`StoryTextEditor`), and
    /// focus there is `becomeFirstResponder` rather than SwiftUI's focus system — one of the two has
    /// to be the truth and it cannot be the one that does not own the keyboard.
    @State private var focused = false
    @State private var showDiscard = false
    /// The page no longer resizes for the keyboard, so the card has to lift its own contents over it.
    /// Measured rather than guessed: a hardware keyboard, a floating one and a language bar are all
    /// different heights, and a constant would be wrong on all three.
    @StateObject private var keyboard = KeyboardWatcher()

    /// THE CARD'S OWN BOTTOM EDGE ON SCREEN, and the whole keyboard problem is solved in its terms.
    @State private var cardMaxY: CGFloat = 0
    /// ...and its width, which is what the words are sized against. Measured from the same place for
    /// the same reason: a card that is told how wide it is cannot disagree with the one on screen.
    @State private var cardWidth: CGFloat = 0

    /// HOW MUCH OF THIS CARD THE KEYBOARD ACTUALLY COVERS — Signal's number, not ours.
    ///
    /// ⚠️ IT WAS `keyboard.height`, MEASURED FROM THE BOTTOM OF THE SCREEN, AND THIS CARD IS NOT AT
    /// THE BOTTOM OF THE SCREEN.
    ///
    /// The card is the top half of a VStack whose other half is the 88pt CAMERA/TEXT bar, sitting
    /// above the home indicator: its bottom edge is roughly 122pt up from the screen's. Every
    /// consumer of `keyboard.height` here was therefore counting that 122pt as if the keyboard had
    /// covered it. The old code took back the home-indicator strip and named the double-count in a
    /// comment, but it never took back the BAR — which is 88 of the 122. That is the owner's Aa row
    /// floating a long way above the keys, and the words lifting about 44pt too far, because the
    /// same wrong number is halved and spent again as an offset.
    ///
    /// Signal does not compute this from the screen at all.
    /// `PhotoCaptureViewController.handleKeyboardNotification` converts the keyboard's end frame
    /// into the composer's own coordinate space and insets by the difference against its own
    /// bounds, so what the composer moves by cannot depend on what is laid out beneath it. This is
    /// that: our own bottom edge, minus where the keyboard's top edge really is.
    ///
    /// With the keyboard down `topOnScreen` is `.infinity`, so this is 0 with no special case.
    private var keyboardOverlap: CGFloat {
        max(0, cardMaxY - keyboard.topOnScreen)
    }

    /// 720, his 2026-08-16 number, up from 700. The words shrink to fit now, so the limit is no
    /// longer standing in for "past this it stops looking like a status" — it is only a ceiling.
    private let charLimit = StoryText.charLimit
    private var style: TextStoryStyle { TextStoryStyles.style(styleIndex) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The words' own box: the card less the 28pt breathing room down each side.
    ///
    /// ⚠️ NOT NARROWED WHILE THE KEYBOARD IS UP, and that is deliberate. The size is fitted against a
    /// box that never changes, so opening the keyboard cannot resize the words under his hand — a
    /// paragraph that jumps a size smaller the moment you tap it reads as a glitch, and the picture
    /// he is composing is the one with the keyboard DOWN.
    private var textBoxWidth: CGFloat {
        max(1, (cardWidth > 1 ? cardWidth : UIScreen.main.bounds.width) - 56)
    }
    private var fontSize: CGFloat {
        TextStoryStyles.fittedSize(for: text, boxWidth: textBoxWidth, fontIndex: fontIndex)
    }

    var body: some View {
        ZStack {
            style.bg
                .contentShape(Rectangle())
                // ⚠️ A TAP ON THE CARD TOGGLES EDITING. IT USED TO ONLY EVER RAISE THE KEYBOARD.
                //
                // Signal's text-story composer has exactly one gesture on the whole card, and it is
                // the same one both ways round (`PhotoCaptureViewController`, `placeholderTapped`):
                //
                //     if textView.isFirstResponder {
                //         textView.acceptAutocorrectSuggestion()
                //         textView.resignFirstResponder()
                //     } else {
                //         textView.becomeFirstResponder()
                //     }
                //
                // Ours was `focused = true`, which is that with the first half missing — so the only
                // way out of typing was the ✓ button, and tapping the card did nothing at all once
                // the keyboard was up. That is his report.
                //
                // Their "outside the text" is real estate we did not have: their text view is sized
                // to the words (min 48pt tall) and centred, so the card ABOVE and BELOW it is bare
                // and the tap lands here. Ours filled the card, so this gesture was unreachable
                // wherever it mattered. `CentringTextView.point(inside:)` is the other half.
                .onTapGesture { focused.toggle() }
                .animation(.easeInOut(duration: 0.3), value: styleIndex)

            // ⛔ THE WORDS AND THE CARD ARE ONE STACK, CENTRED AS A GROUP — owner, 2026-08-23, twice
            // over: "remove that extra spacing so the text and link preview are positioned naturally
            // and closely together", and "the preview temporarily overlaps the text, after a few
            // seconds the text suddenly moves upward".
            //
            // ⚠️ BOTH OF THOSE CAME FROM THE SAME ARRANGEMENT AND NEITHER WAS A SPACING VALUE. The
            // card was pinned at a fixed fraction of the height and the words centred themselves in
            // whatever was above it — two things centred in two different boxes, with the leftover
            // showing as a hole between them. And the room the words had to leave was worked out
            // from the card's height, which was MEASURED after drawing it and read back a pass
            // later: until that arrived the words were laid out against a height of zero, which is
            // the overlap, and when it arrived they moved, which is the jump.
            //
            // A stack answers both. The card states its own height before anything is drawn
            // (`StoryTextLinkPreview.height`) and the words are measured before layout, so the whole
            // arrangement is known on the first pass and there is nothing left to arrive late.
            //
            // The box is what is LEFT after the keyboard, so both are inside what is visible.
            GeometryReader { g in
                let boxH = g.size.height
                let cardW = g.size.width * StoryText.linkCardWidthFraction
                let cardH = link.map {
                    StoryTextLinkPreview.height(width: cardW, style: shownLinkStyle, draft: $0.draft)
                } ?? 0
                // 1.06 of the measured height, and the slack is deliberate: the fit is measured in
                // UIKit's metrics and drawn in SwiftUI's. Too much room is invisible; too little
                // clips the last line.
                let textH = TextStoryStyles.measuredHeight(for: text, boxWidth: g.size.width - 56,
                                                           fontIndex: fontIndex, size: fontSize) * 1.06
                let place = StoryTextLinkLayout.place(textHeight: textH, cardHeight: cardH,
                                                      boxWidth: g.size.width, boxHeight: boxH)
                VStack(spacing: link == nil ? 0 : g.size.width * StoryText.linkGapRatio) {
                    ZStack {
                        if text.isEmpty {
                            Text("Type something…")
                                .font(TextStoryStyles.font(fontIndex, size: fontSize))
                                .foregroundStyle(style.ink.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .allowsHitTesting(false)
                        }
                        // SIZED TO FIT — see `TextStoryStyles.fittedSize` — and SCROLLING, which is
                        // the other half. See `StoryTextEditor`.
                        StoryTextEditor(text: $text, focused: $focused,
                                        font: TextStoryStyles.uiFont(fontIndex, size: fontSize),
                                        color: UIColor(style.ink),
                                        limit: charLimit)
                            .padding(.horizontal, 28)
                    }
                    // ⚠️ TOLD ITS HEIGHT ONLY WHEN THERE IS A CARD BELOW IT. A `UITextView` fills
                    // whatever it is offered, so in a stack it would take everything and leave the
                    // card nothing. With no link it keeps the whole box and centres in it, which is
                    // exactly what a text-only status has always done — that case is untouched.
                    .frame(height: link == nil ? nil : place.text)

                    // ⛔ NO LONGER HIDDEN WHILE TYPING (2026-08-23, his rule that a detected link's
                    // preview is always on screen), and now TAPPABLE: a tap swaps the two card
                    // styles. It is the only control the card has, which is why the tap is the whole
                    // card rather than a button in a corner — and why it must take the touch before
                    // the background behind it, whose own tap raises and drops the keyboard.
                    if let link {
                        StoryTextLinkPreview(draft: link.draft, width: cardW, style: shownLinkStyle)
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.25)) {
                                    self.link?.style = link.style.other
                                }
                            }
                            .transition(.opacity)
                    }
                }
                // ⚠️ STATED, BECAUSE A `GeometryReader` ALIGNS ITS CONTENT TOP-LEADING. Without this
                // the words would stop being centred in the card the moment they were wrapped in one
                // — they were a plain child of the card's `ZStack` before — and the stack would sit
                // against the top instead of in the middle.
                .frame(width: g.size.width, height: g.size.height)
            }
            // ⚠️ THE KEYBOARD IS TAKEN OUT OF THE WORDS' BOX, NOT SUBTRACTED FROM THEIR POSITION —
            // his 2026-08-16 report: "text typing is entering under keyboard, i can't see what i am
            // writing."
            //
            // This was `.offset(y: -keyboardOverlap / 2)`: the words kept the whole card's height and
            // were slid up by half of what the keyboard covered. For a short status that is the same
            // thing and it looked right for months. For a long one it is not: the text was TALLER
            // than the space left above the keys, so sliding it moved the overflow from the bottom to
            // both ends at once — the line being typed is the last line, and the last line was always
            // the one furthest under the keyboard.
            //
            // Making it the box's own bottom inset is what the note on `keyboardOverlap` says the
            // reference composer does: the keyboard becomes part of this view's OWN geometry, and
            // whatever is left is where the words live. Short text still centres in it, exactly as
            // before; long text now scrolls inside it with the caret in view.
            //
            // The extra 68 clears the Aa / colour / ✓ row, which rides just above the keys.
            .padding(.bottom, keyboardOverlap > 0 ? keyboardOverlap + 68 : 0)

            VStack(spacing: 0) {
                HStack {
                    Button { close() } label: { glassCircle { Image(systemName: "xmark") } }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 14)

                Spacer(minLength: 0)

                HStack {
                    // ⚠️ THE TWO STYLE BUTTONS SIT TOGETHER, and the colour one came DOWN from the
                    // top-right corner to get here (owner 2026-08-10, with the move drawn on his
                    // screenshot). They change the same thing — how the card looks — so they belong
                    // in the same reach, and the top corners are left to the two that LEAVE: the X,
                    // and the checkmark opposite this pair.
                    HStack(spacing: 12) {
                        Button { fontIndex += 1 } label: {
                            glassCircle {
                                Text("Aa").font(.system(size: 16, weight: .bold)).foregroundStyle(style.ink)
                            }
                        }
                        .buttonStyle(.plain)
                        // The colour button IS a colour: an open ring showing the card's own ink,
                        // which is what his drawing had in the corner it used to live in. A
                        // paint-palette glyph would say "settings" where this says "this one, tap
                        // for the next".
                        Button { styleIndex += 1 } label: {
                            glassCircle {
                                Circle().strokeBorder(style.ink, lineWidth: 2).frame(width: 21, height: 21)
                            }
                        }
                        .buttonStyle(.plain)
                        // ⛔ THE LINK BUTTON WAS HERE AND IS GONE — owner, 2026-08-23, in those
                        // words. Nothing replaces it: a link is now something the words CONTAIN, so
                        // a control for it would be a second way to say what typing already says,
                        // and the two could disagree. See `StoryTextLinkDetector`.
                    }
                    Spacer()
                    // Only while the keyboard is up, exactly as he drew it: it is the way OUT of
                    // typing, and with the keyboard down there is nothing for it to do.
                    if focused {
                        Button { focused = false } label: {
                            glassCircle {
                                Image(systemName: "checkmark")
                            }
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14)
                // RIDE JUST ABOVE THE KEYBOARD, and this time actually 14pt above it (owner
                // 2026-08-04: "Aa and Done button and keyboard has more space", and again on
                // 2026-08-13 with the row floating in the middle of the card).
                //
                // ⚠️ THE SUBTRACTION THAT USED TO BE HERE IS GONE, NOT CORRECTED. It was
                // `14 + keyboard.height - bottomInset`: a screen-referenced height with one of the
                // two things between this card and the screen's bottom taken back off. The other one
                // is the 88pt bar, and nothing here can know about that — which is the sign the
                // arithmetic belonged somewhere else entirely. `keyboardOverlap` is measured against
                // this card's own bottom edge, so there is nothing left to subtract: what it covers
                // is what we clear.
                .padding(.bottom, 14 + keyboardOverlap)
            }
            .foregroundStyle(style.ink)
        }
        // WHERE THIS CARD'S BOTTOM EDGE REALLY IS. Read from the card itself rather than worked out
        // from the screen and what is stacked under it — see `keyboardOverlap`. It is a `.background`
        // so it measures the card's own frame and takes part in no layout of its own, and the frame
        // it reports is the CARD's, which the keyboard never moves, so this cannot feed back on the
        // offset it feeds.
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { cardMaxY = g.frame(in: .global).maxY; cardWidth = g.size.width }
                    .onChange(of: g.frame(in: .global).maxY) { _, v in cardMaxY = v }
                    .onChange(of: g.size.width) { _, v in cardWidth = v }
            }
        )
        // ⚠️ ONE ANIMATION FOR THE WHOLE CARD, DRIVEN BY ONE VALUE, AND THAT IS THE OTHER HALF OF
        // SIGNAL'S APPROACH.
        //
        // The words and the button row used to carry an `.animation` each, both keyed on
        // `keyboard.height`, while the host carried a THIRD on `typing` for the 12pt of side margin
        // it drops when the keyboard arrives. Three implicit animations over one subtree, on two
        // durations and two curves, all started by the same event: every keystroke that changes the
        // layout re-enters them and they disagree about where things are on the way. Signal moves
        // ONE constraint inside a single `UIView.animate` taking the keyboard's own duration and
        // curve, and its composer's frame never changes at all.
        .animation(.easeOut(duration: 0.22), value: keyboardOverlap)
        // NO KEYBOARD ON ARRIVAL (owner 2026-08-03: "dont open keyboard in story when i click text
        // tab"). Tapping TEXT is choosing a MODE, not asking to type — and a keyboard that arrives
        // uninvited covers the CAMERA/TEXT switch you may have come to use. Tap the card when you
        // want to write; the background already listens.
        // (The Aa and the colour ring used to be in that list. They ride above the keyboard now that
        // both live in the bottom bar, so they are no longer a reason for this rule — the switch is.)
        .onChange(of: focused) { _, f in withAnimation(.easeInOut(duration: 0.2)) { typing = f } }
        // X with text typed → confirm before throwing the status away (don't lose it on a stray tap).
        // A native ALERT, not confirmationDialog: over a full-screen presentation the dialog renders
        // as a centered popover, and popovers HIDE role-cancel buttons — the user saw only "Discard"
        // with no way out.
        // Ours rather than SwiftUI's, so it is dark on a light-mode phone — the same dialog on the
        // same flow as the two editors. See `darkConfirm`.
        .darkConfirm("Discard this status?", isPresented: $showDiscard,
                     destructive: "Discard",
                     onDestructive: { onClose() },
                     onCancel: { focused = true })
        // THE WORDS ARE THE ONLY INPUT. Every edit re-asks what URL they hold; `syncDetectedLink`
        // decides whether that is a change worth a fetch.
        .onChange(of: text) { _, _ in syncDetectedLink() }
        // ...and on arrival, because the card can be re-entered with a status already written — a
        // draft carried back from the CAMERA page, or a discard that was cancelled.
        .onAppear { syncDetectedLink() }
        .onDisappear { linkTask?.cancel(); linkTask = nil }
    }

    /// ⛔ THE PREVIEW IS A FUNCTION OF THE WORDS, and this is the only thing that writes `link`.
    ///
    /// Four cases, in the order they are asked:
    ///
    ///   • NO URL IN THE TEXT — the card goes. Deleting the address is how a link is removed now,
    ///     and it is the only way, which is deliberate: with a ✕ as well there would be a state
    ///     where the words name a link and the picture does not show one, and nothing on screen
    ///     would explain why.
    ///   • THE URL WE ALREADY HAVE — nothing at all. Typing on either side of a link must not make
    ///     its card blink, and this is what stops it.
    ///   • A NEW URL — fetched after a beat, and only installed if the words still name it. A reply
    ///     for an address the field has moved on from is thrown away rather than shown, which is the
    ///     same rule the link sheet carried before it.
    ///   • A URL NOTHING ANSWERED FOR — the card goes ONLY if the host changed too. Half of
    ///     `https://example.com/artic` is a URL that no page will answer for, and clearing on every
    ///     one of those would flash the card off and on all the way through typing a long address.
    ///
    /// ⚠️ 400ms, AND THE DEBOUNCE IS NOT AN OPTIMISATION HERE. The link sheet fetched on every
    /// keystroke because the whole field was the address; here the address is inside a sentence he
    /// is still writing, so every character after it would re-ask a question already answered.
    private func syncDetectedLink() {
        let found = StoryTextLinkDetector.firstURL(in: text)
        guard let found else {
            linkTask?.cancel(); linkTask = nil
            if link != nil { withAnimation(.smooth(duration: 0.2)) { link = nil } }
            return
        }
        guard link?.url != found else { return }
        linkTask?.cancel()
        linkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let d = await LinkPreviewService.shared.draft(for: found)
            if Task.isCancelled { return }
            await MainActor.run {
                guard StoryTextLinkDetector.firstURL(in: text) == found else { return }
                guard let d else {
                    if link?.url.host != found.host {
                        withAnimation(.smooth(duration: 0.2)) { link = nil }
                    }
                    return
                }
                withAnimation(.smooth(duration: 0.2)) { link = StoryTextLink(draft: d) }
            }
        }
    }

    private func close() {
        if trimmed.isEmpty { onClose() } else { focused = false; showDiscard = true }
    }

    /// The card's controls, all one shape and one material, matching the camera's own chrome.
    private func glassCircle<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 46, height: 46)
            .liquidGlass(Circle())      // non-interactive: its touch tracking intermittently ate the tap
            .contentShape(Circle())
    }
}

/// THE WORDS THEMSELVES.
///
/// ⚠️ A `UITextView`, NOT `TextField(axis: .vertical)`, AND THAT SWAP IS HIS 2026-08-16 REPORT: "text
/// typing is entering under keyboard, i can't see what i am writing."
///
/// A vertical `TextField` GROWS. It has no scrolling of any kind — the view simply gets taller as you
/// type, and once it is taller than the room above the keys there is nowhere for the extra to go and
/// no way to reach it. Every arrangement of a growing view has the same hole in it, because the line
/// being typed is always the LAST line, which is always the one furthest out of sight. Only a view
/// that scrolls can keep a caret visible, and `UITextView` scrolls to its own caret for nothing.
///
/// ⚠️ AND IT CENTRES ITSELF VERTICALLY WHILE THE TEXT STILL FITS. That is what the card has always
/// looked like and what most statuses are — a line or two in the middle of a colour. A scroll view
/// pins its content to the top by default, so without this every short status would have jumped to
/// the top of the card the moment this landed. It is done as a content inset in `layoutSubviews`,
/// where the real height is known, rather than guessed from the font.
struct StoryTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let font: UIFont
    let color: UIColor
    let limit: Int

    /// Vertically centred until it overflows, top-aligned and scrolling after that.
    final class CentringTextView: UITextView {
        override func layoutSubviews() {
            super.layoutSubviews()
            let fits = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            let inset = max(0, (bounds.height - fits) / 2)
            // The threshold is what stops this from being a layout loop: writing `contentInset`
            // triggers another layout pass, so it must settle rather than merely converge.
            if abs(contentInset.top - inset) > 0.5 { contentInset.top = inset }
        }

        /// ⚠️ THIS VIEW ONLY CLAIMS THE BAND ITS WORDS ARE ON, AND THAT IS WHAT GIVES THE CARD AN
        /// "OUTSIDE THE TEXT" TO TAP.
        ///
        /// Signal's composer does not need this because its text view IS the size of the text: it is
        /// laid out at the content width and at the height the words fit in, with a 48pt floor, and
        /// centred in the card. Everything above and below it is bare card, so a tap there reaches
        /// their one gesture and ends editing.
        ///
        /// Ours fills the card — the words are centred by a content inset instead of by the view's
        /// own height, which is what lets a long status scroll with the caret in view (see the note
        /// on this type). The side effect is that the view swallowed every touch on the card, so the
        /// composer's own tap could never fire and there was no way out of the keyboard but the ✓.
        ///
        /// Full WIDTH is claimed, not a box round the glyphs, because theirs is full width too
        /// (`withHorizontalFittingPriority: .required` against the content guide) — the bare card is
        /// above and below the words, never beside them.
        ///
        /// ⚠️ THE BAND IS ASKED FOR, NOT DERIVED, AND THE DERIVING IS WHAT HIS "sometimes touching the
        /// text closes the keyboard" WAS.
        ///
        /// It used to be built out of `sizeThatFits` and `contentOffset`, which meant reasoning about
        /// where a scroll view has decided to put its content: a top inset centres the words by moving
        /// the offset, EXCEPT in the states where UIKit leaves the offset alone, and the band was then
        /// a whole inset away from the words. Blank lines inside a status move it further, because the
        /// fitted height counts them and the eye does not. I got that arithmetic wrong twice in one
        /// day, which is the real argument against it.
        ///
        /// `caretRect(for:)` is UIKit's own answer, in THIS VIEW'S coordinates, already accounting for
        /// the inset, the offset, the line heights and the container. The caret at the start of the
        /// document and the caret at the end bracket every line between them, blank ones included —
        /// so the region is the text as drawn, whatever the scroll view did to get it there. It is
        /// also TextKit-agnostic, which reading the layout manager is not: touching `layoutManager` on
        /// a TextKit 2 view silently drops it back to TextKit 1.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            let first = caretRect(for: beginningOfDocument)
            let last = caretRect(for: endOfDocument)
            // A caret can legitimately be unavailable for a frame — mid-relayout, or before the first
            // layout pass. Keeping the touch is the safe answer to a question we cannot yet answer,
            // because the failure it avoids is the one he is reporting.
            // `CGRect.null` and infinities are both real answers from `caretRect(for:)` before the
            // first layout pass.
            guard !first.isNull, !last.isNull, first.minY.isFinite, last.maxY.isFinite else { return true }
            // One line of air above and below, his 2026-08-17 drawing: a ring around the words with
            // real space in it. A line height rather than a fixed number because the composer's font
            // runs from about twenty points to the full status size, so any constant is either mean
            // at the top of that range or swallows the card at the bottom.
            let air = max(24, font?.lineHeight ?? 24)
            return point.y >= min(first.minY, last.minY) - air
                && point.y <= max(first.maxY, last.maxY) + air
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let v = CentringTextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.isScrollEnabled = true
        v.showsVerticalScrollIndicator = false
        v.alwaysBounceVertical = false
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.textAlignment = .center
        v.font = font
        v.textColor = color
        v.tintColor = color
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        // Only when it actually differs: assigning `text` moves the caret to the end, so doing it on
        // every update would fight the person typing in the middle of their own status.
        if v.text != text { v.text = text }
        if v.font != font { v.font = font; v.setNeedsLayout() }
        if v.textColor != color { v.textColor = color }
        v.tintColor = color
        v.textAlignment = .center
        if focused, !v.isFirstResponder { v.becomeFirstResponder() }
        if !focused, v.isFirstResponder {
            // ⚠️ WHAT THE KEYBOARD IS STILL HOLDING IS COMMITTED FIRST — Signal's
            // `acceptAutocorrectSuggestion`, which it calls on both of its ways out of editing (the
            // card tap and the Done button) and never on the way in.
            //
            // A suggestion the person has not accepted, and marked text in a two-stage input, live
            // in the keyboard rather than in the text view. Resigning without asking for them drops
            // the last word of a status typed in Somali or in any language that composes.
            //
            // The empty round trip through the input delegate is the whole trick: telling the system
            // the selection is about to move makes it flush what it is holding, and nothing else here
            // moves the selection.
            v.inputDelegate?.selectionWillChange(v)
            v.inputDelegate?.selectionDidChange(v)
            v.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StoryTextEditor
        init(_ p: StoryTextEditor) { parent = p }

        func textViewDidChange(_ v: UITextView) {
            if v.text.count > parent.limit { v.text = String(v.text.prefix(parent.limit)) }
            parent.text = v.text
            // The size is fitted to the text, so the text changing can change the size — and a
            // changed size changes where the middle is.
            v.setNeedsLayout()
        }
        // The flag is the card's, and the card hangs its ✓ button and its close confirmation off it,
        // so it has to hear about a keyboard raised or dropped by any route — including the system's.
        func textViewDidBeginEditing(_ v: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ v: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}

/// Renders a text story to the image the story pipeline posts. Free function rather than a method on
/// the card, because the button that fires it lives on the page BELOW the card.
///
/// TALLER THAN ANY PHONE (2.5:1) so the status fills full-bleed on EVERY device — the viewer fills
/// any image at least as tall as itself. Rendering at the author's own aspect broke on
/// differently-proportioned viewers, which showed as blur bars. The text is centred, so the small
/// top and bottom crop never touches it.
/// What a rendered text story hands back: the picture, and where the link card landed inside it.
///
/// The rectangle is normalised 0-1 and goes straight into a `StoryTapTarget`, which is how the card
/// stays tappable after the post. There is nothing else it could be: the picture is flat by then, so
/// the only thing that knows a link is there is this rectangle travelling beside it.
struct RenderedTextStory {
    var data: Data
    var linkTap: StoryTapTarget?
}

@MainActor func renderTextStory(text: String, styleIndex: Int, fontIndex: Int,
                                link: StoryTextLink? = nil) -> RenderedTextStory? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let style = TextStoryStyles.style(styleIndex)
    let renderW: CGFloat = 1080
    let pad: CGFloat = 80
    // THE SAME RULE THE CARD USED, ASKED AT THIS SIZE. It was a flat 64pt with
    // `minimumScaleFactor(0.4)` underneath it, which is SwiftUI shrinking the words on its own terms
    // at its own moment — so the posted picture and the card he composed on could pick different
    // sizes for the same status, and neither knew about the other. One function answers for both now;
    // the ratios in it are what make the answer come out the same. See `fittedSize`.
    let size = TextStoryStyles.fittedSize(for: trimmed, boxWidth: renderW - pad * 2, fontIndex: fontIndex)
    let renderH = renderW * 2.5

    // ⛔ THE SAME STACK THE COMPOSER DRAWS, WITH THIS PICTURE'S OWN NUMBERS. The card no longer sits
    // at a fixed fraction with the words pushed above it; the two are one group, centred, with the
    // gap between them and nothing else. `StoryTextLinkLayout` is the one place that arrangement is
    // worked out, so the composer and this cannot describe different pictures.
    //
    // ⚠️ THE CARD IS NO LONGER PRE-RENDERED TO LEARN ITS HEIGHT. It states it
    // (`StoryTextLinkPreview.height`), which is what the tap rectangle is built from — so the extra
    // `ImageRenderer` pass that existed only to measure is gone, and with it the chance of the
    // measured height and the drawn one being two different answers.
    let cardW = renderW * StoryText.linkCardWidthFraction
    let cardH = link.map {
        StoryTextLinkPreview.height(width: cardW, style: $0.style, draft: $0.draft)
    } ?? 0
    // The words' own height at this size, with the same 1.06 of slack the composer allows for the
    // difference between UIKit's metrics and SwiftUI's.
    let textH = TextStoryStyles.measuredHeight(for: trimmed, boxWidth: renderW - pad * 2,
                                               fontIndex: fontIndex, size: size) * 1.06
    let place = StoryTextLinkLayout.place(textHeight: textH, cardHeight: cardH,
                                          boxWidth: renderW, boxHeight: renderH)

    let words = Text(trimmed)
        .font(TextStoryStyles.font(fontIndex, size: size))
        .foregroundStyle(style.ink)
        .multilineTextAlignment(.center)
        // A belt, not the mechanism: the fit above is measured in UIKit's metrics and drawn in
        // SwiftUI's, and the last line must never be the one that gets clipped.
        .minimumScaleFactor(0.85)
        .padding(.horizontal, pad)

    let card = ZStack {
        style.bg
        if let link {
            VStack(spacing: renderW * StoryText.linkGapRatio) {
                words.frame(height: place.text)
                StoryTextLinkPreview(draft: link.draft, width: cardW, style: link.style)
            }
        } else {
            // Untouched: with no card there is nothing to make room for, and a text-only status is
            // the same picture it has always been.
            words.padding(.vertical, pad)
        }
    }
    .frame(width: renderW, height: renderH)

    let renderer = ImageRenderer(content: card)
    renderer.scale = 1
    guard let data = renderer.uiImage?.jpegData(compressionQuality: 0.9) else { return nil }
    let tap = link.map { l in
        StoryTapTarget(x: 0.5,
                       y: place.cardCentreY,
                       w: StoryText.linkCardWidthFraction,
                       h: cardH / renderH,
                       rotation: 0,
                       url: l.url.absoluteString)
    }
    return RenderedTextStory(data: data, linkTap: tap)
}

// MARK: - A link on a text story

/// A link the author attached to a text story, with the page's own card already fetched.
///
/// ⚠️ ONE PER STORY, AND ATTACHED TO THE STORY RATHER THAN TO A RANGE OF THE WORDS. That is the
/// reference app's shape, read from its source before this was built: its text attachment carries a
/// single optional preview, its composer holds one draft, and the card is laid out as its own view
/// under the text rather than as an attribute inside it. It also has no separate display text — you
/// type a URL and what you see is the page's own title. Copying that exactly was the owner's call on
/// 2026-08-22, in preference to the linked-words idea he first described.
///
/// The draft is carried whole because the card is drawn from it twice: once live on the composer and
/// once into the posted picture. Fetching again for the second would be a second answer to a question
/// already asked, and the page could have changed in between.
struct StoryTextLink: Equatable {
    var draft: LinkPreviewService.LinkDraft
    /// Which card it wears. Travels with the link because the POSTED picture has to be the one he
    /// chose — the composer is where it is picked and the bake is where it matters.
    var style: StoryTextLinkStyle = .compact
    var url: URL { draft.url }
}

/// The preview card as it appears on a text story, in the composer and in the posted picture.
///
/// Their numbers: 18pt corners for a full card, 12 when the fetch came back with nothing but a host,
/// 12pt of side padding and 8pt top and bottom on the text block, title and description clamped to
/// two lines each, the host underneath them both.
///
/// ⚠️ SIZED IN POINTS AGAINST A GIVEN WIDTH, not against the screen. The composer draws it at card
/// width and the renderer draws it at 1080; one number in and everything else follows, which is what
/// keeps the two pictures the same picture.
struct StoryTextLinkPreview: View {
    let draft: LinkPreviewService.LinkDraft
    /// The width the card is being drawn at. 1 unit of scale = the composer's own size.
    var width: CGFloat
    var style: StoryTextLinkStyle = .compact

    /// Nothing came back but a host — their `.domainOnly` card, and it is deliberately still a card.
    /// A link that silently vanishes because a site would not answer is worse than a plain one.
    private var domainOnly: Bool { draft.title.isEmpty && draft.desc.isEmpty }

    private var k: CGFloat { width / 300 }      // everything below is quoted at a 300pt reference
    private var hasPicture: Bool { draft.image != nil && !domainOnly }

    /// ⛔ THE CARD SAYS HOW TALL IT IS, RATHER THAN BEING MEASURED AFTER THE FACT, and that is the
    /// whole of his "the preview overlaps the text, then a few seconds later the text jumps up".
    ///
    /// ⚠️ THE HEIGHT USED TO BE AN ANSWER THAT ARRIVED LATE. The layout above it needed to know how
    /// much room to leave, so the card was drawn, measured through a `GeometryReader`, written into
    /// `@State`, and read back on the NEXT pass — a full round trip through SwiftUI's update cycle
    /// for a number that is a pure function of the width and the draft. Until that trip finished the
    /// words were laid out against a height of zero, which is the overlap; when it finished they
    /// moved, which is the jump. Nothing was delayed on purpose and no animation was too slow: the
    /// layout genuinely did not know the answer yet.
    ///
    /// Every ingredient is fixed — two lines of title, two of description, one host, a square or a
    /// banner of picture — so the answer can simply be stated, and both the composer and the render
    /// get it before they lay anything out. The text block is pinned to it below, so a one-line
    /// title cannot make the card shorter than this says it is.
    static func height(width: CGFloat, style: StoryTextLinkStyle,
                       draft: LinkPreviewService.LinkDraft) -> CGFloat {
        let k = width / 300
        let bare = draft.title.isEmpty && draft.desc.isEmpty
        let hasPicture = draft.image != nil && !bare
        switch style {
        case .compact: return textBlockHeight * k
        case .large:   return (hasPicture ? bannerHeight : 0) * k + textBlockHeight * k
        }
    }

    /// The words' side of the card, at the 300pt reference. Title 2 × 18, description 2 × 15, host
    /// 15, two 2pt gaps, 7pt of air top and bottom.
    private static let textBlockHeight: CGFloat = 100
    /// The picture across the top of the `large` card. 120, down from 150 — his "make it smaller and
    /// properly sized", and the compact card's own square is this block's height instead.
    private static let bannerHeight: CGFloat = 120

    private var cardHeight: CGFloat { Self.height(width: width, style: style, draft: draft) }

    @ViewBuilder private var words: some View {
        VStack(alignment: .leading, spacing: 2 * k) {
            if !draft.title.isEmpty {
                Text(draft.title)
                    .font(.system(size: 15 * k, weight: .semibold))
                    .lineLimit(2)
            }
            if !draft.desc.isEmpty {
                Text(draft.desc)
                    .font(.system(size: 12.5 * k))
                    .lineLimit(2)
            }
            Text(draft.host)
                .font(.system(size: 12.5 * k))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.leading)
        // Pinned to the declared height and top-aligned, so a one-line title leaves its space empty
        // rather than making the card a different size from the one `height(width:style:draft:)`
        // promised. That promise is what the layout above is built on.
        .frame(maxWidth: .infinity, minHeight: Self.textBlockHeight * k,
               maxHeight: Self.textBlockHeight * k, alignment: .topLeading)
        .padding(.horizontal, 12 * k)
        .padding(.vertical, 7 * k)
        .clipped()
    }

    var body: some View {
        Group {
            switch style {
            // ⛔ HIS IMAGE 2, AND THE DEFAULT. A square of the page's own picture on the left with
            // the words beside it, so the card is one text block tall instead of a banner plus a
            // text block. A page that answered with no picture is simply the words, full width,
            // which is the same card the `large` style falls back to — one link, two heights,
            // never two different amounts of information.
            case .compact:
                HStack(spacing: 0) {
                    if hasPicture, let img = draft.image {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cardHeight, height: cardHeight)
                            .clipped()
                    }
                    words
                }
            case .large:
                VStack(alignment: .leading, spacing: 0) {
                    if hasPicture, let img = draft.image {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: Self.bannerHeight * k)
                            .clipped()
                    }
                    words
                }
            }
        }
        .frame(width: width, height: cardHeight)
        .background(Color(white: 0.97))
        .foregroundStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: (domainOnly ? 12 : 18) * k, style: .continuous))
        // ⛔ THE ✕ IS GONE, AND ITS ABSENCE IS THE FEATURE — owner, 2026-08-23: "when a valid link
        // is detected, its link preview must always remain visible … must never become hidden".
        //
        // ⚠️ IT COULD ONLY EVER CREATE A STATE NOTHING ON SCREEN EXPLAINS. The card is drawn from
        // whatever URL the words hold, so dismissing it would leave the address sitting in the
        // status with no preview under it and no way to tell why — and the next keystroke would
        // either bring it back or not, depending on how the dismissal was remembered. Deleting the
        // address is the removal now, it is the only one, and it is the one the words already
        // describe.
        //
        // The composer and the bake therefore draw exactly the same view with the same numbers,
        // which is what the old note here was protecting by making the button an overlay: the two
        // have to agree on the card's height or the posted tap area lands somewhere the picture does
        // not. There is nothing left to disagree about.
    }
}

// ⛔ `StoryTextLinkSheet` LIVED HERE AND IS DELETED — owner, 2026-08-23, with the button that
// opened it. It was a whole screen whose only job was to collect an address, and the address is
// now in the words. Nothing else ever presented it (checked: the composer's `.sheet` was its one
// call site), so it went with its button rather than being left behind unreachable.
//
// The one thing worth keeping out of it is written down where it is still true: the test for a
// good link is whether a page ANSWERS, not whether the string matches a pattern — see
// `syncDetectedLink`, which installs a card only on a real draft. Their own rule, and it is why a
// well-formed address for a site that does not exist gets no card here either.
