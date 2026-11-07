import SwiftUI
import UIKit

/// Settings > Appearance > Bubble Styles (owner 2026-11-06), and the "Chat bubble" row on a chat's
/// info page (owner 2026-11-07: the same picker, a shortcut, not a per-chat style). A live preview
/// of their bubble and mine at the top, the styles below in sections, Cancel and Save at the top.
/// Nothing changes until Save.
struct BubbleStylesPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var selected: String? = BubbleStyles.current
    @State private var plusNote = false
    @State private var decorOn = BubbleStyles.decorations
    private var dark: Bool { scheme == .dark }
    private let colourCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let pictureCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                section("Default") {
                    LazyVGrid(columns: colourCols, spacing: 14) { tile(nil) }
                }
                section("Colours") {
                    LazyVGrid(columns: colourCols, spacing: 14) {
                        ForEach(BubbleStyles.colours) { s in tile(s) }
                    }
                    // Optional decorations (owner 2026-11-06): hearts, bows, stars at the corners of
                    // the last bubble in a run, never on every bubble. Colour styles only; a picture
                    // brings its own art.
                    Toggle("Decorations", isOn: $decorOn)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(BubbleStyles.find(selected).map { $0.picture != nil } ?? true)
                        .padding(.top, 4)
                }
                ForEach(PictureStyle.Pack.allCases, id: \.self) { pack in
                    section(pack.rawValue) {
                        LazyVGrid(columns: pictureCols, spacing: 14) {
                            ForEach(BubbleStyles.all.filter { $0.picture?.group == pack }) { s in tile(s) }
                        }
                    }
                }
                Text("Your style only affects messages you send after saving. The people you write to see it too; messages you already sent keep their look.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bubble Style")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(selected == BubbleStyles.current && decorOn == BubbleStyles.decorations)
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
        BubbleStyles.decorations = decorOn
        Haptics.impact(.light)
        dismiss()
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
            content()
        }
    }

    // ── preview ──

    private var preview: some View {
        let s = BubbleStyles.find(selected)
        return VStack(spacing: 10) {
            HStack {
                Text("Looks so cute! I'm changing mine.")
                    .font(Font(BubbleMetrics.bodyFont as CTFont))
                    .foregroundStyle(Color(.label))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 40)
            }
            HStack {
                Spacer(minLength: 40)
                if let p = s?.picture {
                    PictureBubble(style: p, text: "Did you know you can change your bubble style? So cool!", dark: dark)
                        .id(p.id)
                } else {
                    Text("Did you know you can change your bubble style? So cool!")
                        .font(Font(BubbleMetrics.bodyFont as CTFont))
                        .foregroundStyle(textColor(s))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background { bubbleFill(s, corner: 18) }
                        .overlay { decorPreview(s) }
                }
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
                if let p = s?.picture {
                    PictureThumb(style: p)
                        .frame(height: 64)
                } else {
                    bubbleFill(s, corner: 14)
                        .frame(height: 38)
                        .overlay(alignment: .leading) {
                            Capsule().fill(textColor(s).opacity(0.55)).frame(width: 34, height: 5).padding(.leading, 12)
                        }
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

    /// The style's decorations on the preview bubble, placed as the chat places them.
    @ViewBuilder private func decorPreview(_ s: BubbleStyle?) -> some View {
        if let s, decorOn {
            GeometryReader { g in
                ForEach(Array(BubbleDecorSets.placed(styleId: s.id, isMe: true, dark: dark, first: true).enumerated()), id: \.offset) { _, d in
                    if let img = BubbleDecorArt.image(d.glyph, size: d.size, color: d.color) {
                        let w = g.size.width, h = g.size.height
                        let p: CGPoint = {
                            switch d.corner {
                            case .topLeading: return CGPoint(x: 4 - d.out, y: 2 - d.out)
                            case .topTrailing: return CGPoint(x: w - 4 + d.out, y: 2 - d.out)
                            case .bottomLeading: return CGPoint(x: 4 - d.out, y: h - 2 + d.out)
                            case .bottomTrailing: return CGPoint(x: w - 4 + d.out, y: h - 2 + d.out)
                            }
                        }()
                        Image(uiImage: img)
                            .rotationEffect(.radians(Double(d.rotation)))
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                            .position(p)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func textColor(_ s: BubbleStyle?) -> Color {
        guard let s else { return .white }
        return Color(hex: s.look(dark).text)
    }
}

/// A picture-style bubble drawn with the chat's own numbers (`PictureStyle.art`, `textInsets`,
/// `minBubble`) and the chat's own stretchable picture (`PictureArt`), so the preview is what the
/// chat will show.
struct PictureBubble: View {
    let style: PictureStyle
    let text: String
    let dark: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        let ti = style.textInsets, art = style.art, pad = PictureArt.pad
        let rim = style.lightText && dark
        Text(text)
            .font(Font(BubbleMetrics.bodyFont as CTFont))
            .foregroundStyle(Color(hex: style.textHex))
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: ti.top, leading: ti.left, bottom: ti.bottom, trailing: ti.right))
            .frame(minWidth: style.minBubble.width, minHeight: style.minBubble.height)
            .background {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable(capInsets: EdgeInsets(top: image.capInsets.top, leading: image.capInsets.left,
                                                             bottom: image.capInsets.bottom, trailing: image.capInsets.right),
                                       resizingMode: .stretch)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: style.fill))
                            .padding(EdgeInsets(top: art.top + pad, leading: art.left + pad,
                                                bottom: art.bottom + pad, trailing: art.right + pad))
                    }
                }
                .padding(EdgeInsets(top: -art.top - pad, leading: -art.left - pad,
                                    bottom: -art.bottom - pad, trailing: -art.right - pad))
            }
            .padding(EdgeInsets(top: art.top, leading: art.left, bottom: art.bottom, trailing: art.right))
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                let scale = displayScale > 0 ? displayScale : 3
                if let hit = PictureArt.cached(style, rim: rim, scale: scale) { image = hit; return }
                PictureArt.load(style, rim: rim, scale: scale) { image = $0 }
            }
    }
}

/// A picker tile's picture: the whole picture, not stretched, decoded small (`PictureArt.thumbnail`).
private struct PictureThumb: View {
    let style: PictureStyle
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: style.fill))
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            let scale = displayScale > 0 ? displayScale : 3
            PictureArt.thumbnail(style, width: 160, scale: scale) { image = $0 }
        }
    }
}
