import SwiftUI

/// Settings > Appearance > Bubble Styles (owner 2026-11-06). A live preview of my bubble and theirs at
/// the top, the styles below, Save at the top right. Nothing changes until Save.
struct BubbleStylesPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var selected: String? = BubbleStyles.current
    @State private var plusNote = false
    private var dark: Bool { scheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                Text("Your style goes with the messages you send from now on, so the people you write to see it too. Messages you already sent keep their look.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: cols, spacing: 14) {
                    tile(nil)
                    ForEach(BubbleStyles.all) { s in tile(s) }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bubble Styles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(selected == BubbleStyles.current)
            }
        }
        .alert("Fariin Plus", isPresented: $plusNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This style is part of Fariin Plus, coming soon. The free styles are ready to use now.")
        }
    }

    private func save() {
        if let s = BubbleStyles.find(selected), !BubbleStyles.mayUse(s) { plusNote = true; return }
        BubbleStyles.current = selected
        Haptics.impact(.light)
        dismiss()
    }

    // ── preview ──

    private var preview: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Looks so cute! I'm changing mine.")
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 40)
            }
            HStack {
                Spacer(minLength: 40)
                Text("Did you know you can change your bubble style? So cool!")
                    .font(.body)
                    .foregroundStyle(textColor(BubbleStyles.find(selected)))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background { bubbleFill(BubbleStyles.find(selected), corner: 18) }
            }
        }
        .padding(16)
        .background(Theme.bg(dark), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: selected)
    }

    // ── tiles ──

    private func tile(_ s: BubbleStyle?) -> some View {
        let isOn = selected == s?.id
        return Button {
            selected = s?.id
            Haptics.impact(.light)
        } label: {
            VStack(spacing: 8) {
                bubbleFill(s, corner: 14)
                    .frame(height: 38)
                    .overlay(alignment: .leading) {
                        Capsule().fill(textColor(s).opacity(0.55)).frame(width: 34, height: 5).padding(.leading, 12)
                    }
                HStack(spacing: 4) {
                    Text(s?.name ?? "Default")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if s?.plus == true {
                        Text("Plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple))
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel((s?.name ?? "Default") + (s?.plus == true ? ", Fariin Plus" : ""))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The style's fill as SwiftUI (the chat itself draws it in UIKit, `BubbleStyles.fill`).
    @ViewBuilder private func bubbleFill(_ s: BubbleStyle?, corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if let s {
            let look = s.look(dark)
            if look.glass {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.18 : 0.5), lineWidth: 1))
            } else if look.fill.count > 1 {
                shape.fill(LinearGradient(colors: look.fill.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(Color(hex: look.fill.first ?? 0x007AFF))
            }
        } else {
            shape.fill(Color(hex: dark ? 0x0A84FF : 0x007AFF))
        }
    }

    private func textColor(_ s: BubbleStyle?) -> Color {
        guard let s else { return .white }
        return Color(hex: s.look(dark).text)
    }
}
