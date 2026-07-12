import SwiftUI

// Text story (Instagram/WhatsApp-style): a gradient background + centered text, rendered
// to a 9:16 image and posted through the SAME story pipeline as a photo. Tap the palette
// to cycle backgrounds; type; Share. No new backend — it's just an image.
struct StoryTextComposer: View {
    var onShare: (Data) -> Void
    var onClose: () -> Void

    @State private var text = ""
    private let charLimit = 700   // WhatsApp-style text-status cap
    @State private var bgIndex = 0
    @FocusState private var focused: Bool
    @State private var showDiscard = false

    private let backgrounds: [[Color]] = [
        [Color(hex: 0x7F00FF), Color(hex: 0xE100FF)],
        [Color(hex: 0xFF512F), Color(hex: 0xDD2476)],
        [Color(hex: 0x11998E), Color(hex: 0x38EF7D)],
        [Color(hex: 0x2193B0), Color(hex: 0x6DD5ED)],
        [Color(hex: 0xF7971E), Color(hex: 0xFFD200)],
        [Color(hex: 0x141E30), Color(hex: 0x243B55)],
        [Color(hex: 0x0F2027), Color(hex: 0x2C5364)],
    ]
    private func gradient(_ i: Int) -> LinearGradient {
        LinearGradient(colors: backgrounds[i % backgrounds.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
            ZStack {
                // Full-bleed gradient background. Tapping it toggles the keyboard (WhatsApp: tap to
                // dismiss and see the full text, tap again to edit) — was stuck open with no way out.
                gradient(bgIndex).ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.35), value: bgIndex)   // smooth background cycle
                    .contentShape(Rectangle())
                    .onTapGesture { focused.toggle() }

                // Centered editable text — .plain removes the iOS default white box.
                ZStack {
                    if text.isEmpty {
                        Text("Type something…")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .onChange(of: text) { _, v in if v.count > charLimit { text = String(v.prefix(charLimit)) } }
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .textFieldStyle(.plain)          // prevents the system white-box background
                        .background(Color.clear)
                        .padding(.horizontal, 28)
                }

                // Top controls: close (X) left, palette right. Send docks bottom-right (Instagram-style).
                VStack {
                    HStack(spacing: 10) {
                        Button { if trimmed.isEmpty { onClose() } else { focused = false; showDiscard = true } }
                            label: { circle("xmark") }.buttonStyle(.plain)
                        Spacer()
                        Button { bgIndex += 1 } label: { circle("paintpalette.fill") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                    Spacer()
                    HStack {
                        Spacer()
                        Button { share() } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 54, height: 54)
                                .background(trimmed.isEmpty ? AnyShapeStyle(.ultraThinMaterial)
                                                            : AnyShapeStyle(Color(.systemGreen)), in: Circle())
                                .shadow(color: Color(.systemGreen).opacity(trimmed.isEmpty ? 0 : 0.5), radius: 8)
                        }
                        .buttonStyle(.plain).disabled(trimmed.isEmpty)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        .onAppear { focused = true }
        // X with text typed → confirm before throwing the status away (don't lose it on a stray tap).
        // A native ALERT, not confirmationDialog: over this full-screen cover the dialog rendered
        // as a centered popover, and popovers HIDE role-cancel buttons — the user only saw
        // "Discard" with no way out. Alerts always show both buttons.
        .alert("Discard this status?", isPresented: $showDiscard) {
            Button("Discard", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) { focused = true }
        }
    }

    // Render the gradient + text to a 1080×1920 JPEG and hand it to the poster.
    @MainActor private func share() {
        guard !trimmed.isEmpty else { return }
        // Render TALLER than any phone (2.5:1) so the status fills full-bleed with the gradient on
        // EVERY device (the viewer fills any image that's ≥ its own height). Rendering at the
        // author's device aspect broke on differently-proportioned viewers (blur bars). The text is
        // centred, so the small top/bottom crop on filling never touches it.
        let renderW: CGFloat = 1080
        let renderH: CGFloat = renderW * 2.5
        let card = ZStack {
            gradient(bgIndex)
            Text(trimmed)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
                .padding(80)
        }
        .frame(width: renderW, height: renderH)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        if let ui = renderer.uiImage, let data = ui.jpegData(compressionQuality: 0.9) {
            focused = false
            onShare(data)
        }
    }

    private func circle(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .liquidGlass(Circle())                      // non-interactive glass: its touch-tracking was
            .contentShape(Circle())                     // intermittently eating the Button tap ("sometimes works")
    }
}
