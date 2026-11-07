import SwiftUI
import UIKit

/// Settings > Appearance > Bubble Styles (owner 2026-11-06), and the "Chat bubble" row on a chat's
/// info page (owner 2026-11-07: the same picker, a shortcut, not a per-chat style).
///
/// ⛔ LAYOUT (owner 2026-11-07, second look): the live preview is pinned at the top and stays in
/// view while the grid scrolls; one short line under it; then a row of category chips (Colours
/// last) and only the chosen category's grid, three to a row, Default first in every grid.
/// Cancel and Save at the top. Nothing changes until Save.
struct BubbleStylesPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var selected: String? = BubbleStyles.current
    @State private var plusNote = false
    @State private var decorOn = BubbleStyles.decorations
    /// The chip that is open: the saved style's category, else Anime.
    @State private var category: Category = Category.of(BubbleStyles.find(BubbleStyles.current)) ?? .pictures(.anime)
    private var dark: Bool { scheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    enum Category: Hashable {
        case pictures(PictureStyle.Pack)
        case colours

        static let all: [Category] = PictureStyle.Pack.allCases.map { .pictures($0) } + [.colours]
        var title: String {
            switch self {
            case .pictures(let p): return p.rawValue
            case .colours: return "Colours"
            }
        }
        static func of(_ s: BubbleStyle?) -> Category? {
            guard let s else { return nil }
            return s.picture.map { .pictures($0.group) } ?? .colours
        }
        var styles: [BubbleStyle] {
            switch self {
            case .pictures(let p): return BubbleStyles.all.filter { $0.picture?.group == p }
            case .colours: return BubbleStyles.colours
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                preview
                Text("Applies to messages you send from now on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                chips
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: cols, spacing: 10) {
                        tile(nil)
                        ForEach(category.styles) { s in tile(s) }
                    }
                    if category == .colours {
                        // Optional decorations (owner 2026-11-06): hearts, bows, stars at the corners
                        // of the last bubble in a run, never on every bubble. Colour styles only; a
                        // picture brings its own art.
                        Toggle("Decorations", isOn: $decorOn)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .disabled(BubbleStyles.find(selected).map { $0.picture != nil } ?? true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
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

    /// The message menu's "Bubble Style" (owner 2026-11-07): this page as a sheet over the chat.
    /// Presented from UIKit after the menu has gone, so the chat's long SwiftUI body is untouched.
    @MainActor static func presentSheet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let top = WebLink.topViewController() else { return }
            let host = UIHostingController(rootView: NavigationStack { BubbleStylesPage() })
            host.modalPresentationStyle = .pageSheet
            top.present(host, animated: true)
        }
    }

    private func save() {
        if let s = BubbleStyles.find(selected), !BubbleStyles.mayUse(s) { plusNote = true; return }
        BubbleStyles.current = selected
        BubbleStyles.decorations = decorOn
        Haptics.impact(.light)
        dismiss()
    }

    /// The category chips, one row that scrolls sideways.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.all, id: \.self) { c in
                    let on = c == category
                    Button {
                        category = c
                        Haptics.impact(.light)
                    } label: {
                        Text(c.title)
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color(.systemBackground) : Color(.label))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(on ? Color(.label) : Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
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
        .padding(14)
        .background(Theme.bg(dark), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // ── tiles ──

    private func tile(_ s: BubbleStyle?) -> some View {
        let isOn = selected == s?.id
        return Button {
            selected = s?.id
            Haptics.impact(.light)
        } label: {
            VStack(spacing: 5) {
                if let p = s?.picture {
                    PictureThumb(style: p)
                        .frame(height: 42)
                } else {
                    bubbleFill(s, corner: 12)
                        .frame(height: 30)
                        .overlay(alignment: .leading) {
                            Capsule().fill(textColor(s).opacity(0.55)).frame(width: 26, height: 4).padding(.leading, 10)
                        }
                        .padding(.vertical, 6)
                }
                HStack(spacing: 4) {
                    Text(s?.name ?? "Default")
                        .font(.caption2.weight(.medium))
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
            .padding(.horizontal, 6).padding(.vertical, 7)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2)
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
            PictureArt.thumbnail(style, width: 120, scale: scale) { image = $0 }
        }
    }
}
