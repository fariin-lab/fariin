import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): the editor sheet that opens from the notice after a
// screenshot. Layout after his reference video: a header with close, title and day/night; a
// rounded card with the chat on the chosen background; round theme swatches; one Share button.
// The sheet is as tall as what it holds, never taller than the large size.
//
// The card shows the chat's REAL rows (`ShotRealRow`). Swipe a message left to take it out (a small
// Undo capsule comes up for a moment). Touch and hold a message's words to hide them. Share renders
// the pictures (`ScreenshotExporter`) and opens the app's own Share with sheet.

/// The rendered pictures, handed to the Share with sheet.
private struct ShotOutgoing: Identifiable {
    let id = UUID()
    let images: [UIImage]
}

struct ScreenshotEditorView: View {
    let snapshot: ScreenshotSnapshot
    /// The result line once pictures were sent ("Screenshot sent to …"), for the chat to show.
    var onSent: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Removed message ids, newest last, so Undo brings back the last one taken out.
    @State private var removed: [String] = []
    @State private var covers: [String: ShotCover] = [:]
    @State private var theme: ShotTheme = .current
    /// nil until the person flips it: the picture starts in the appearance the chat was in.
    @State private var darkChoice: Bool?
    @State private var plan = ShotPlan()
    @State private var undoFor: String?
    @State private var outgoing: ShotOutgoing?
    @State private var rendering = false
    /// The sheet's height, measured from its content (owner 2026-11-13: no empty space under the
    /// button). Starts near the large size so the first frame is not cramped.
    @State private var contentHeight: CGFloat = 640

    static let side: CGFloat = 16
    /// The sheet's height counts the home-indicator area too; the measured content does not.
    private static var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.bottom ?? 0
    }

    private var dark: Bool { darkChoice ?? (scheme == .dark) }
    private var look: ShotLook { ShotLook.resolve(theme, cid: snapshot.cid, dark: dark) }
    private var rows: [ShotMessage] {
        let gone = Set(removed)
        return snapshot.messages.filter { !gone.contains($0.id) }
    }
    private var planKey: String { "\(removed.count)|\(dark)" }

    var body: some View {
        content(look)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) { undoBar }
            .presentationDetents([.height(contentHeight + Self.bottomInset)])
            .presentationDragIndicator(.visible)
            .task(id: planKey) { plan = ScreenshotExporter.plan(rows: rows, look: look, cid: snapshot.cid) }
            .sheet(item: $outgoing) { out in
                SendContactSheet(contactText: "", pictures: out.images,
                                 onDispatched: { dismiss() }, onSent: onSent)
            }
    }

    private func content(_ look: ShotLook) -> some View {
        VStack(spacing: 0) {
            header
            ShotCard(rows: rows, look: look, cid: snapshot.cid, covers: $covers, onRemove: remove)
                .padding(.top, 22)
            ShotThemeRow(cid: snapshot.cid, dark: dark, selected: $theme)
                .padding(.top, 20)
            Divider().padding(.horizontal, Self.side).padding(.top, 16)
            shareButton(look).padding(.top, 20).padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func remove(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.22)) { removed.append(id); undoFor = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeOut(duration: 0.2)) { if undoFor == id { undoFor = nil } }
        }
    }

    private func undo() {
        withAnimation(.easeInOut(duration: 0.22)) {
            _ = removed.popLast()
            undoFor = nil
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("Share your chat").font(.system(size: 17, weight: .semibold))
                Text(countLine).font(.system(size: 13)).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            HStack {
                ShotRoundButton(symbol: "xmark", label: "Close") { dismiss() }
                Spacer()
                ShotRoundButton(symbol: dark ? "sun.max" : "moon.stars", label: dark ? "Day" : "Night") {
                    withAnimation(.easeInOut(duration: 0.25)) { darkChoice = !dark }
                }
            }
        }
        .padding(.horizontal, Self.side)
        .padding(.top, 16)
    }

    private var countLine: String {
        let n = rows.count, p = plan.pictureCount
        let pictures = p == 1 ? "1 picture" : "\(p) pictures"
        let messages = n == 1 ? "1 message" : "\(n) messages"
        return "\(pictures) · \(messages)"
    }

    // MARK: Share

    private func shareButton(_ look: ShotLook) -> some View {
        let p = plan.pictureCount
        return Button { share(look) } label: {
            ZStack {
                Text(p == 1 ? "Share Picture" : "Share \(p) Pictures").opacity(rendering ? 0 : 1)
                if rendering { ProgressView().tint(.white) }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.defaultBubble(scheme == .dark), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(rows.isEmpty || rendering)
        .opacity(rows.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 30)
    }

    private func share(_ look: ShotLook) {
        guard !rendering else { return }
        rendering = true
        let rows = rows, covers = covers, cid = snapshot.cid
        Task {
            let images = await ScreenshotExporter.render(rows: rows, look: look, covers: covers, cid: cid)
            rendering = false
            if !images.isEmpty { outgoing = ShotOutgoing(images: images) }
        }
    }

    /// A small glass capsule, centred, for a moment after a message is taken out.
    @ViewBuilder private var undoBar: some View {
        if undoFor != nil {
            HStack(spacing: 14) {
                Text("Message removed").font(.system(size: 15, weight: .medium))
                Button("Undo", action: undo)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.defaultBubble(scheme == .dark))
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The rounded card with the chat in it. As tall as its messages up to a cap, then it scrolls;
/// the footer stays at its bottom edge, as it sits at the bottom of every saved picture.
private struct ShotCard: View {
    let rows: [ShotMessage]
    let look: ShotLook
    let cid: String
    @Binding var covers: [String: ShotCover]
    let onRemove: (String) -> Void
    @State private var messagesHeight: CGFloat = 0

    private static let corner: CGFloat = 32
    private var width: CGFloat { UIScreen.main.bounds.width - ScreenshotEditorView.side * 2 }
    private var maxHeight: CGFloat { min(width + 40, UIScreen.main.bounds.height * 0.52) }
    private var footerBlock: CGFloat {
        ScreenshotExporter.footerHeight + ScreenshotExporter.footerSpacing + ScreenshotExporter.footerBottom
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        let height = min(maxHeight, max(160, messagesHeight))
        messages
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                ShotFooter(look: look).padding(.bottom, ScreenshotExporter.footerBottom)
            }
            .background { ShotBackgroundView(look: look) }
            .clipShape(shape)
            .animation(.easeInOut(duration: 0.22), value: rows.map(\.id))
    }

    private var messages: some View {
        let items = zip(rows, ShotPlacement.of(rows)).map { ShotItem(m: $0.0, place: $0.1) }
        return ScrollView {
            VStack(spacing: 0) {
                if rows.isEmpty { emptyLine }
                ForEach(items) { item in
                    ShotEditableRow(message: item.m, look: look, place: item.place, rowWidth: width,
                                    cid: cid, cover: covers[item.id] ?? ShotCover(), edit: edit(item.id))
                }
            }
            .padding(.top, ScreenshotExporter.pageTop)
            .padding(.bottom, footerBlock)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { messagesHeight = $0 }
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .mask { edgeFade }
    }

    private var emptyLine: some View {
        Text("No messages left").font(.subheadline).foregroundStyle(look.chipText)
            .padding(.top, 50)
    }

    /// Soft top and bottom edges, so a cut-off message reads as "there is more". Only on screen:
    /// the saved pictures are drawn without them.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 30)
        }
    }

    private func edit(_ id: String) -> ShotRowEdit {
        ShotRowEdit(
            text: ShotTextActions(
                cover: { r in covers[id, default: ShotCover()].cover(r) },
                coverWhole: { covers[id, default: ShotCover()].whole = true },
                reveal: { i in covers[id, default: ShotCover()].reveal(at: i) },
                remove: { onRemove(id) }),
            toggleWhole: { covers[id, default: ShotCover()].whole.toggle() })
    }
}

private struct ShotItem: Identifiable {
    let m: ShotMessage
    let place: ShotPlacement
    var id: String { m.id }
}

/// Everything one row in the editor can change.
private struct ShotRowEdit {
    let text: ShotTextActions
    let toggleWhole: () -> Void
}

/// A message in the editor: the chat's own row, plus the left swipe that removes it. Words are
/// picked with a long press on the text (see `ShotRowUIView`); a row with no words (a photo, a
/// sticker) gets a small menu instead.
private struct ShotEditableRow: View {
    let message: ShotMessage
    let look: ShotLook
    let place: ShotPlacement
    let rowWidth: CGFloat
    let cid: String
    let cover: ShotCover
    let edit: ShotRowEdit

    @State private var dragX: CGFloat = 0
    private static let removeAt: CGFloat = 80

    private var hasWords: Bool { !message.text.isEmpty && message.kind != .system }

    var body: some View {
        ShotRealRow(message: message, place: place, cover: cover, look: look, width: rowWidth,
                    cid: cid, actions: edit.text)
            .offset(x: dragX)
            .overlay(alignment: .trailing) { swipeMark }
            .contentShape(Rectangle())
            .onTapGesture { if cover.whole { edit.toggleWhole() } }
            .contextMenu { if !hasWords { menu } }
            .simultaneousGesture(swipe)
            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
    }

    @ViewBuilder private var menu: some View {
        Button(cover.whole ? "Show" : "Hide", systemImage: cover.whole ? "eye" : "eye.slash") {
            edit.toggleWhole()
        }
        Button("Remove", systemImage: "trash", role: .destructive) { edit.text.remove() }
    }

    /// A crossed-out eye that grows in from the right edge as the row is pulled.
    @ViewBuilder private var swipeMark: some View {
        if dragX < -8 {
            let progress = min(1, -dragX / Self.removeAt)
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(look.chipText)
                .frame(width: 32, height: 32)
                .background(look.chipFill, in: Circle())
                .scaleEffect(0.6 + 0.4 * progress)
                .opacity(progress)
                .padding(.trailing, 14)
        }
    }

    /// A left swipe only: a mostly vertical drag belongs to the scroll view.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > abs(dy) * 1.4 || dragX != 0 else { return }
                dragX = min(0, dx * 0.85)
            }
            .onEnded { _ in
                if dragX <= -Self.removeAt {
                    dragX = 0
                    edit.text.remove()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                }
            }
    }
}

/// Round swatches under the card: this chat's own look first, then the built-in wallpapers.
/// A swatch changes only the background; the bubbles keep the chat's own style.
private struct ShotThemeRow: View {
    let cid: String
    let dark: Bool
    @Binding var selected: ShotTheme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(ShotTheme.all()) { theme in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { selected = theme } } label: {
                        ShotSwatch(look: ShotLook.resolve(theme, cid: cid, dark: dark), selected: theme == selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label(theme))
                }
            }
            .padding(.horizontal, ScreenshotEditorView.side - 2)
        }
        .scrollIndicators(.hidden)
    }

    private func label(_ theme: ShotTheme) -> String {
        switch theme {
        case .current: return "This chat"
        case .builtIn(let id): return ChatWallpapers.gradient(id)?.name ?? "Wallpaper"
        }
    }
}

/// One swatch: the background in a circle, with a ring when it is the chosen one.
private struct ShotSwatch: View {
    let look: ShotLook
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ShotBackgroundView(look: look)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
            .padding(selected ? 4 : 2)
            .overlay {
                if selected {
                    Circle().strokeBorder(Theme.defaultBubble(scheme == .dark), lineWidth: 2)
                }
            }
            .frame(width: 40, height: 40)
    }
}

/// A 44 pt round glass button for the sheet's header.
private struct ShotRoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

/// The notice in the chat after a screenshot: liquid glass with continuous corners, a title and a
/// grey line in the theme's own colours, and an outlined capsule button on the right.
struct ShotNoticeBar: View {
    let title: String
    let detail: String?
    let action: String
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: onAction) {
                Text(action).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.fariinAction)
                    .padding(.horizontal, 14).frame(height: 32)
                    .overlay { Capsule().strokeBorder(Color.fariinAction, lineWidth: 1) }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 54)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
