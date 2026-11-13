import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): the editor sheet that opens from the notice after a
// screenshot. Layout after his reference video: a header with close, title and day/night; a
// rounded card with the chat on the chosen background; round theme swatches; one Share button.
//
// Swipe a message left to take it out (a small Undo bar comes up for a moment). Touch and hold a
// message's words to hide them. Share renders the same views offscreen (`ScreenshotExporter`) and
// opens the app's own Share with sheet to send them as photos, or save them.

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

    static let side: CGFloat = 16

    private var dark: Bool { darkChoice ?? (scheme == .dark) }
    private var look: ShotLook { ShotLook.resolve(theme, cid: snapshot.cid, dark: dark) }
    private var rows: [ShotMessage] {
        let gone = Set(removed)
        return snapshot.messages.filter { !gone.contains($0.id) }
    }
    private var planKey: String { "\(removed.count)|\(theme.id)|\(dark)" }

    var body: some View {
        let look = self.look
        VStack(spacing: 0) {
            header
            ShotCard(rows: rows, look: look, covers: $covers, onRemove: remove)
                .padding(.top, 22)
            ShotThemeRow(cid: snapshot.cid, dark: dark, selected: $theme)
                .padding(.top, 20)
            Divider().padding(.horizontal, Self.side).padding(.top, 16)
            shareButton(look).padding(.top, 20)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { undoBar }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: planKey) { plan = ScreenshotExporter.plan(rows: rows, look: look) }
        .sheet(item: $outgoing) { out in
            SendContactSheet(contactText: "", pictures: out.images,
                             onDispatched: { dismiss() }, onSent: onSent)
        }
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
        return Button {
            let images = ScreenshotExporter.render(rows: rows, look: look, covers: covers)
            if !images.isEmpty { outgoing = ShotOutgoing(images: images) }
        } label: {
            Text(p == 1 ? "Share Picture" : "Share \(p) Pictures")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.defaultBubble(scheme == .dark), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(rows.isEmpty)
        .opacity(rows.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 30)
    }

    @ViewBuilder private var undoBar: some View {
        if undoFor != nil {
            ShotNoticeBar(title: "Message removed", detail: nil, action: "Undo", onAction: undo)
                .padding(.horizontal, Self.side)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The rounded card with the chat in it. It scrolls when the messages do not fit; the footer
/// stays at its bottom edge, as it sits at the bottom of every saved picture.
private struct ShotCard: View {
    let rows: [ShotMessage]
    let look: ShotLook
    @Binding var covers: [String: ShotCover]
    let onRemove: (String) -> Void

    private static let corner: CGFloat = 32
    private var width: CGFloat { UIScreen.main.bounds.width - ScreenshotEditorView.side * 2 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        messages
            .frame(width: width, height: width + 40)
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
                                    cover: covers[item.id] ?? ShotCover(),
                                    edit: edit(item.id))
                }
            }
            .padding(.top, ScreenshotExporter.pageTop)
            .padding(.bottom, ScreenshotExporter.footerHeight + ScreenshotExporter.footerSpacing
                     + ScreenshotExporter.footerBottom)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .mask { edgeFade }
    }

    private var emptyLine: some View {
        Text("No messages left").font(.subheadline).foregroundStyle(look.chipText)
            .padding(.top, 120)
    }

    /// Soft top and bottom edges, so a cut-off message reads as "there is more". Only on screen:
    /// the saved pictures are drawn without them.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 40)
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

/// A message in the editor: the same row the picture draws, plus the left swipe that removes it.
/// Text rows select words on a long press (see `ShotSelectableText`); a picture or an event line
/// has a small menu instead, since it has no words to pick.
private struct ShotEditableRow: View {
    let message: ShotMessage
    let look: ShotLook
    let place: ShotPlacement
    let rowWidth: CGFloat
    let cover: ShotCover
    let edit: ShotRowEdit

    @State private var dragX: CGFloat = 0
    private static let removeAt: CGFloat = 80

    private var isText: Bool { message.kind == .text }

    var body: some View {
        ShotRowView(message: message, look: look, place: place, rowWidth: rowWidth,
                    cover: cover, actions: isText ? edit.text : nil)
            .offset(x: dragX)
            .overlay(alignment: .trailing) { swipeMark }
            .contentShape(Rectangle())
            .onTapGesture { if cover.whole { edit.toggleWhole() } }
            .contextMenu { if !isText { menu } }
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

/// The dark rounded bar used for the screenshot notice in the chat and for Undo in the editor:
/// a bold line, an optional grey line, and a text button on the right.
struct ShotNoticeBar: View {
    let title: String
    let detail: String?
    let action: String
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                if let detail {
                    Text(detail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            Button(action: onAction) {
                Text(action).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4DA3FF))
                    .padding(.vertical, 8).padding(.leading, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, detail == nil ? 10 : 9)
        .frame(minHeight: 50)
        .background(Color(white: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
