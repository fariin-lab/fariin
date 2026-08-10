import SwiftUI
import UIKit   // the window's safe-area insets, read directly (see `bottomInset`)

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

    /// The home-indicator strip, read from the window the same way the editors read the top one.
    /// The card's layout already excludes it; the keyboard's height does not.
    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
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
            // HALF the keyboard, because the words are CENTRED: lifting them by the whole height
            // would put them as far above the middle as they were below it. Half keeps them centred
            // in the part of the card you can still see.
            .offset(y: -keyboard.height / 2)
            .animation(.easeOut(duration: 0.22), value: keyboard.height)

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
                // 2026-08-04: "Aa and Done button and keyboard has more space").
                //
                // `keyboard.height` is measured from the bottom of the SCREEN — it is
                // `screenHeight - keyboardTop` — but this card is laid out inside the safe area, so
                // its own bottom already sits about 34pt up on any phone with a home indicator.
                // Padding by the full keyboard height therefore counted that strip twice and left
                // the buttons ~48pt clear of the keys instead of 14. Take the inset back off.
                .padding(.bottom, keyboard.height > 0
                         ? max(10, 14 + keyboard.height - bottomInset)
                         : 14)
                .animation(.easeOut(duration: 0.22), value: keyboard.height)
            }
            .foregroundStyle(style.ink)
        }
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
        .alert("Discard this status?", isPresented: $showDiscard) {
            Button("Discard", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) { focused = true }
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
