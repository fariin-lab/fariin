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
}

struct StoryTextCard: View {
    @Binding var text: String
    @Binding var styleIndex: Int
    @Binding var fontIndex: Int
    /// Mirrors the keyboard for the page above, which hides its bottom bar while you type.
    @Binding var typing: Bool
    var onClose: () -> Void

    @FocusState private var focused: Bool
    @State private var showDiscard = false
    /// The page no longer resizes for the keyboard, so the card has to lift its own contents over it.
    /// Measured rather than guessed: a hardware keyboard, a floating one and a language bar are all
    /// different heights, and a constant would be wrong on all three.
    @StateObject private var keyboard = KeyboardWatcher()

    /// THE CARD'S OWN BOTTOM EDGE ON SCREEN, and the whole keyboard problem is solved in its terms.
    @State private var cardMaxY: CGFloat = 0

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

    private let charLimit = 700
    private var style: TextStoryStyle { TextStoryStyles.style(styleIndex) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            style.bg
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .animation(.easeInOut(duration: 0.3), value: styleIndex)

            ZStack {
                if text.isEmpty {
                    Text("Type something…")
                        .font(TextStoryStyles.font(fontIndex, size: 30))
                        .foregroundStyle(style.ink.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .onChange(of: text) { _, v in if v.count > charLimit { text = String(v.prefix(charLimit)) } }
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(TextStoryStyles.font(fontIndex, size: 30))
                    .foregroundStyle(style.ink)
                    .tint(style.ink)
                    .textFieldStyle(.plain)          // prevents the system white-box background
                    .background(Color.clear)
                    .padding(.horizontal, 28)
            }
            // HALF the covered part, because the words are CENTRED: lifting them by the whole
            // overlap would put them as far above the middle as they were below it. Half keeps them
            // centred in the part of the card you can still see.
            .offset(y: -keyboardOverlap / 2)

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
                    .onAppear { cardMaxY = g.frame(in: .global).maxY }
                    .onChange(of: g.frame(in: .global).maxY) { _, v in cardMaxY = v }
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
    let card = ZStack {
        style.bg
        Text(trimmed)
            .font(TextStoryStyles.font(fontIndex, size: 64))
            .foregroundStyle(style.ink)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.4)
            .padding(80)
    }
    .frame(width: renderW, height: renderW * 2.5)

    let renderer = ImageRenderer(content: card)
    renderer.scale = 1
    return renderer.uiImage?.jpegData(compressionQuality: 0.9)
}
