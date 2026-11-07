import SwiftUI
import UIKit

/// Settings > Appearance > Bubble Styles (owner 2026-11-06), and the "Chat bubble" row on a chat's
/// info page (owner 2026-11-07: the same picker, a shortcut, not a per-chat style).
///
/// ⛔ LAYOUT (owner 2026-11-07, second look): the live preview is pinned at the top and stays in
/// view while the grid scrolls; one short line under it; then a row of category chips ("Color"
/// first, the chat colour circles five to a row; then the picture packs) and only the chosen
/// category's grid, pictures three to a row with Default first. A round X and Save at the top.
/// Nothing changes until Save.
struct BubbleStylesPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var selected: String? = BubbleStyles.current
    @State private var plusNote = false
    @State private var decorOn = BubbleStyles.decorations
    /// ⛔ THE "COLOR" CHIP (owner 2026-11-07, his own mockup): the chat colour palette
    /// (`ChatColorStore`, the Bubble Color page's circles) as the first chip. The colour picked,
    /// nil = Auto, is held until Save like a style. `colorTouched`: a circle was tapped since the
    /// last picture style, so Save applies the colour to all chats and puts any picture style away.
    @State private var colorPick: ChatColorSpec? = ChatColorStore.shared.globalChosenColor
    @State private var colorTouched = false
    @State private var showCustom = false
    /// The chip that is open: the saved picture style's category, else Color.
    @State private var category: Category = Category.of(BubbleStyles.find(BubbleStyles.current))
        .flatMap { $0 == .colours ? nil : $0 } ?? .chatColor
    private var dark: Bool { scheme == .dark }
    /// The open chip, or Color when the admin panel hid every style in it.
    private var openCategory: Category { Category.shown.contains(category) ? category : .chatColor }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    private let colorCols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private var colorStore: ChatColorStore { .shared }

    enum Category: Hashable {
        /// The chat colour circles (not a sent style).
        case chatColor
        case pictures(PictureStyle.Pack)
        /// The sent colour styles. No chip offers them (owner 2026-11-07); they stay in
        /// `BubbleStyles` so a message sent with one still draws it.
        case colours

        static let all: [Category] = [.chatColor] + PictureStyle.Pack.allCases.map { .pictures($0) }
        var title: String {
            switch self {
            case .chatColor: return "Color"
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
            case .chatColor: return []
            case .pictures(let p): return BubbleStyles.shown.filter { $0.picture?.group == p }
            case .colours: return BubbleStyles.shown.filter { $0.picture == nil }
            }
        }
        /// The chips offered: Color, then each picture group that still has a style the admin
        /// panel did not hide. Read from a view, so the row redraws when the panel flips one.
        static var shown: [Category] { all.filter { $0 == .chatColor || !$0.styles.isEmpty } }
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
                    if openCategory == .chatColor {
                        colorGrid
                    } else {
                        LazyVGrid(columns: cols, spacing: 10) {
                            tile(nil)
                            ForEach(openCategory.styles) { s in tile(s) }
                        }
                    }
                    if openCategory == .colours {
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
        // Pushed from Settings, the edge swipe still goes back (owner 2026-11-07); hiding the back
        // button had turned it off. Like the X, it keeps nothing unsaved. In a sheet the stack has
        // one page, so the swipe never starts there.
        .background(RestoreSwipeBack())
        .toolbar {
            // The app's round glass X in place of "Cancel" (owner 2026-11-07); same action. On 26
            // the toolbar's own glass is hidden or the X is drawn as a circle inside a circle.
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) { CloseXButton { dismiss() }.accessibilityLabel("Cancel") }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { CloseXButton { dismiss() }.accessibilityLabel("Cancel") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(selected == BubbleStyles.current && decorOn == BubbleStyles.decorations && !colorTouched)
            }
        }
        .sheet(isPresented: $showCustom) {
            // The custom colour joins the library at once, as on the Bubble Color page; Save applies it.
            CustomColorView(cid: "__default__") { spec in
                colorStore.addCustom(spec)
                pickColor(spec)
            }
        }
        .alert("Fariin Plus", isPresented: $plusNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This style is part of Fariin Plus, coming soon. The free styles are ready to use now.")
        }
    }

    /// The sheet's height, the Replies sheet's (`PostReplies`). Settings pushes the page full height.
    static let sheetFraction: CGFloat = 0.70

    /// The message menu's "Bubble Style" (owner 2026-11-07): this page as a sheet over the chat.
    /// Presented from UIKit after the menu has gone, so the chat's long SwiftUI body is untouched.
    @MainActor static func presentSheet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let top = WebLink.topViewController() else { return }
            let host = UIHostingController(rootView: NavigationStack { BubbleStylesPage() })
            host.modalPresentationStyle = .pageSheet
            // 70% with the grabber, as the Replies sheet, so the chat stays in view above it
            // (owner 2026-11-07). The fixed preview and chips stay on top; the grid scrolls.
            if let sheet = host.sheetPresentationController {
                let f = sheetFraction
                sheet.detents = [.custom { ctx in ctx.maximumDetentValue * f }]
                sheet.prefersGrabberVisible = true
            }
            top.present(host, animated: true)
        }
    }

    private func save() {
        if let s = BubbleStyles.find(selected), !BubbleStyles.mayUse(s) { plusNote = true; return }
        // A colour tapped: the Bubble Color page's apply (all chats; a chat with its own keeps it).
        // `pickColor` already set `selected` to nil, so the picture style goes away below.
        if colorTouched { colorStore.applyToAllChats(colorPick) }
        BubbleStyles.current = selected
        BubbleStyles.decorations = decorOn
        Haptics.impact(.light)
        dismiss()
    }

    /// The category chips, one row that scrolls sideways.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.shown, id: \.self) { c in
                    let on = c == openCategory
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

    /// ⛔ THE PREVIEW NEVER CHANGES SIZE (owner 2026-11-07: switching styles made the card grow and
    /// shrink, so the chips and grid jumped). Both sample lines are short enough to stay one line
    /// in every style, the sent bubble's row is as tall as the tallest style's one-line bubble
    /// (art included), and a new style crossfades in place.
    private static let mineText = "My new bubble style!"   // same words, height and fade as Android
    private static let lineH = ceil(BubbleMetrics.bodyFont.lineHeight)
    private static let mineRowH: CGFloat = {
        let plain = lineH + 18
        let pictures = PictureStyles.all.map { p -> CGFloat in
            let ti = p.textInsets, a = p.art
            return ceil(max(lineH + ti.top + ti.bottom, p.minBubble.height) + a.top + a.bottom)
        }
        return max(120, plain, pictures.max() ?? 0)   // Android's row is 120
    }()

    private var preview: some View {
        let s = BubbleStyles.find(selected)
        let key = (selected ?? "default") + "|" + (colorPick?.stored ?? "auto")
        return VStack(spacing: 10) {
            HStack {
                Text("Looks so cute!")
                    .font(Font(BubbleMetrics.bodyFont as CTFont))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 40)
            }
            ZStack(alignment: .trailing) {
                Group {
                    if let p = s?.picture {
                        PictureBubble(style: p, text: Self.mineText, dark: dark)
                    } else {
                        Text(Self.mineText)
                            .font(Font(BubbleMetrics.bodyFont as CTFont))
                            .foregroundStyle(textColor(s))
                            .lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background { bubbleFill(s, corner: 18) }
                            .overlay { decorPreview(s) }
                    }
                }
                .id(key)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, minHeight: Self.mineRowH, maxHeight: Self.mineRowH, alignment: .trailing)
            .padding(.leading, 40)
            .animation(.easeInOut(duration: 0.18), value: key)
        }
        .padding(14)
        .background(Theme.bg(dark), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // ── the Color chip ──

    /// Auto, the palette in its order, the custom colours, then "+" (the custom colour editor).
    private var colorGrid: some View {
        let _ = colorStore.version
        let _ = WallpaperStore.shared.version   // Auto follows the Settings wallpaper
        return LazyVGrid(columns: colorCols, spacing: 14) {
            colorCircle(nil) {
                Circle().fill(colorStore.globalAutoColor.map { $0.fill } ?? AnyShapeStyle(Theme.defaultBubble(dark)))
                    .overlay(Text("Auto").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
            }
            ForEach(ChatColors.presets) { p in colorCircle(p) { Circle().fill(p.fill) } }
            ForEach(colorStore.customColors) { p in
                colorCircle(p) { Circle().fill(p.fill) }
                    .contextMenu {
                        Button(role: .destructive) { colorStore.removeCustom(p) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            Button { showCustom = true } label: {
                Circle().fill(Color(.systemGray5))
                    .overlay(Image(systemName: "plus").font(.system(size: 22, weight: .medium)).foregroundStyle(.primary))
                    .frame(width: Self.circle, height: Self.circle)
                    .padding(Self.ringGap)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom color")
        }
        // One rounded card, the preview card's ground (owner 2026-11-07).
        .padding(16)
        .background(Theme.bg(dark), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Five to a row inside the card: 5 x (48 + 2 x 5) + 4 x 6 = 314, the card's inside on a 393pt
    /// phone is 329. The ring is 2 wide, so 3 of clear gap shows between it and the circle.
    private static let circle: CGFloat = 48
    private static let ringGap: CGFloat = 5

    /// Ringed (a ring with a gap) only while no picture style is picked: one or the other applies.
    private func colorCircle<C: View>(_ spec: ChatColorSpec?, @ViewBuilder content: () -> C) -> some View {
        let isOn = selected == nil && colorPick?.stored == spec?.stored
        return Button { pickColor(spec) } label: {
            content()
                .frame(width: Self.circle, height: Self.circle)
                .padding(Self.ringGap)
                .overlay(Circle().strokeBorder(isOn ? Color.primary : .clear, lineWidth: 2))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spec == nil ? "Auto" : "Color")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func pickColor(_ spec: ChatColorSpec?) {
        colorPick = spec
        colorTouched = true
        selected = nil
        Haptics.impact(.light)
    }

    // ── tiles ──

    private func tile(_ s: BubbleStyle?) -> some View {
        let isOn = selected == s?.id
        return Button {
            selected = s?.id
            if s != nil { colorTouched = false }   // a picture style wins over a colour tapped before
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
            // No style: the chat colour, so the preview shows a circle's colour the moment it is tapped.
            shape.fill((colorPick ?? colorStore.globalAutoColor).map { $0.fill } ?? AnyShapeStyle(Theme.defaultBubble(dark)))
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
        let art = style.art, pad = PictureArt.pad
        let rim = style.lightText && dark
        PictureTextLayout(insets: style.textInsets, minSize: style.minBubble) {
            Text(text)
                .font(Font(BubbleMetrics.bodyFont as CTFont))
                .foregroundStyle(Color(hex: style.textHex))
        }
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

/// The words inside a picture bubble, placed with the chat's own math (`MessageRowLayout`, the
/// picture plan, owner 2026-11-07): the bubble widens, room allowing, until the smaller side
/// clearance matches the larger one, and the words are centred between the outline's edges without
/// entering either side's clearance. Text that fills the width keeps both insets as before.
private struct PictureTextLayout: Layout {
    let insets: UIEdgeInsets
    let minSize: CGSize

    private struct Plan { var size: CGSize; var origin: CGPoint; var text: CGSize }

    private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
        let l = insets.left, r = insets.right, t = insets.top, b = insets.bottom
        let room = proposal.width ?? .infinity
        let textRoom: CGFloat? = room.isFinite ? max(1, room - l - r) : nil
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: textRoom, height: nil)) ?? .zero
        let tw = ceil(size.width), th = ceil(size.height)
        var w = min(room, tw + max(l, r) * 2)
        w = ceil(max(w, tw + l + r, ceil(minSize.width)))
        let x = min(max((w - tw) / 2, l), w - r - tw).rounded()
        let h = max(th + t + b, ceil(minSize.height))
        let y = t + floor((h - (th + t + b)) / 2)
        return Plan(size: CGSize(width: w, height: h), origin: CGPoint(x: x, y: y), text: CGSize(width: tw, height: th))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(proposal, subviews)
        subviews.first?.place(at: CGPoint(x: bounds.minX + p.origin.x, y: bounds.minY + p.origin.y),
                              proposal: ProposedViewSize(p.text))
    }
}

/// A picker tile's picture: the whole picture, not stretched, decoded small (`PictureArt.thumbnail`).
/// Also the Bubble Styles strip in the chat's wallpaper sheet.
struct PictureThumb: View {
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
