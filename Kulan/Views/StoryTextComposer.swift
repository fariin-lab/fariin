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
}

struct StoryTextCard: View {
    @Binding var text: String
    @Binding var styleIndex: Int
    @Binding var fontIndex: Int
    /// Mirrors the keyboard for the page above, which hides its bottom bar while you type.
    @Binding var typing: Bool
    var onClose: () -> Void

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
    private let charLimit = 720
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

            ZStack {
                if text.isEmpty {
                    Text("Type something…")
                        .font(TextStoryStyles.font(fontIndex, size: fontSize))
                        .foregroundStyle(style.ink.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                }
                // SIZED TO FIT — see `TextStoryStyles.fittedSize` — and SCROLLING, which is the
                // other half. See `StoryTextEditor`.
                StoryTextEditor(text: $text, focused: $focused,
                                font: TextStoryStyles.uiFont(fontIndex, size: fontSize),
                                color: UIColor(style.ink),
                                limit: charLimit)
                    .padding(.horizontal, 28)
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
        /// The words' own height, measured in the layout pass that already needed it. Kept because
        /// `point(inside:)` is asked on every touch and `sizeThatFits` on a text view is a layout.
        private var fittedHeight: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            let fits = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            fittedHeight = fits
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
        /// above and below the words, never beside them. Once the text overflows, the inset is zero
        /// and the band is taller than the view, so the whole thing claims touches again and
        /// scrolling and selection are untouched.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            // ⚠️ ONE LINE OF AIR ABOVE AND BELOW THE WORDS, NOT A FINGER EDGE — his 2026-08-17
            // drawing, a ring around the words with real space in it: "if I touch that area don't
            // close the keyboard".
            //
            // It was `+ 16`, eight points each side, which is the slop you give a BUTTON. This is not
            // a button — it is the thing being written, and the area a person reads as "the text" is
            // the words plus the space they are sitting in. Eight points meant a tap a thumb's width
            // under the last line ended the editing he was in the middle of.
            //
            // A line height is the unit because it is the only one that stays right at every size:
            // the composer's font runs from 20-odd points up to the full status size, and a fixed
            // number is either mean at the top of that range or swallows the card at the bottom.
            // The floor keeps a one-word status reachable when the fitted height is the 48 below.
            //
            // What it must NOT become is the whole card. The way out of the keyboard is a tap on the
            // card, so the bare space has to survive: at the largest text this leaves the top of the
            // card and the strip above the bar, which is where a thumb goes to finish anyway.
            let air = max(24, (font?.lineHeight ?? 24))
            let band = max(fittedHeight, 48) + air * 2
            // ⚠️ WHERE THE WORDS START ON SCREEN IS `-contentOffset.y`, NOT THE INSET. A scroll view
            // draws content at `contentY - contentOffset.y`, and a top inset does its work by moving
            // the offset to `-inset` rather than by shifting the drawing — so reading the inset here
            // as well would count the centring twice and put the band a whole inset too low. With
            // the text overflowing the inset is zero, the offset is positive, and this is negative,
            // which is exactly right: the band starts above the view and covers all of it.
            let top = -contentOffset.y - air
            return point.y >= top && point.y <= top + band
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
@MainActor func renderTextStory(text: String, styleIndex: Int, fontIndex: Int) -> Data? {
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
    let card = ZStack {
        style.bg
        Text(trimmed)
            .font(TextStoryStyles.font(fontIndex, size: size))
            .foregroundStyle(style.ink)
            .multilineTextAlignment(.center)
            // A belt, not the mechanism: the fit above is measured in UIKit's metrics and drawn in
            // SwiftUI's, and the last line must never be the one that gets clipped.
            .minimumScaleFactor(0.85)
            .padding(pad)
    }
    .frame(width: renderW, height: renderW * 2.5)

    let renderer = ImageRenderer(content: card)
    renderer.scale = 1
    return renderer.uiImage?.jpegData(compressionQuality: 0.9)
}
