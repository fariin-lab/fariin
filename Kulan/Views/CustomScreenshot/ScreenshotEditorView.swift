import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): the editor that opens from the pill after a screenshot.
//
// The picture is edited in place: swipe a message left to take it out, touch and hold to hide its
// text, pick a background under it, flip day and night at the top. Save and Share render the same
// views offscreen (`ScreenshotExporter`), so what is on screen is what is saved.

struct ScreenshotEditorView: View {
    let snapshot: ScreenshotSnapshot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Removed message ids, newest last, so Undo brings back the last one taken out.
    @State private var removed: [String] = []
    @State private var hiddenIds: Set<String> = []
    @State private var theme: ShotTheme = .current
    /// nil until the person flips it: the picture starts in the appearance the chat was in.
    @State private var darkChoice: Bool?
    /// ⛔ ALWAYS ON (owner 2026-11-13: "the user can't remove my logo and name"). Every saved or
    /// shared picture carries the Fariin logo and name; there is no switch for it.
    private let showLogo = true
    @State private var busy = false

    private var dark: Bool { darkChoice ?? (scheme == .dark) }
    private var look: ShotLook { ShotLook.resolve(theme, cid: snapshot.cid, dark: dark) }
    private var rows: [ShotMessage] {
        let gone = Set(removed)
        return snapshot.messages.filter { !gone.contains($0.id) }
    }

    var body: some View {
        let look = self.look
        canvas(look)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { panel(look) }
            .background { ShotBackgroundView(look: look).ignoresSafeArea() }
            .environment(\.colorScheme, dark ? .dark : .light)
            .animation(.easeInOut(duration: 0.2), value: removed)
            .animation(.easeInOut(duration: 0.2), value: hiddenIds)
    }

    // MARK: Picture

    private func canvas(_ look: ShotLook) -> some View {
        let rows = self.rows
        // Keyed by message id, not position, so a removed row animates out and its swipe state
        // does not pass to the row that takes its place.
        let items = zip(rows, ShotPlacement.of(rows)).map { ShotItem(m: $0.0, place: $0.1) }
        return ScrollView {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text("No messages left. Tap Undo to bring one back.")
                        .font(.subheadline)
                        .foregroundStyle(look.chipText)
                        .padding(.top, 80)
                }
                ForEach(items) { item in
                    ShotEditableRow(message: item.m, look: look, place: item.place,
                                    hidden: hiddenIds.contains(item.id),
                                    onRemove: { remove(item.id) },
                                    onToggleHidden: { toggleHidden(item.id) })
                }
                if showLogo && !rows.isEmpty {
                    ShotBranding(look: look).padding(.top, 10)
                }
            }
            .padding(.vertical, ScreenshotExporter.pageTop)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
    }

    private func remove(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        removed.append(id)
    }

    private func toggleHidden(_ id: String) {
        if hiddenIds.contains(id) { hiddenIds.remove(id) } else { hiddenIds.insert(id) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close")
            Spacer()
            Text("Screenshot")
                .font(.headline)
                .padding(.horizontal, 16).frame(height: 44)
                .glassEffect(.regular, in: Capsule())
            Spacer()
            Button { darkChoice = !dark } label: {
                Image(systemName: dark ? "sun.max" : "moon")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(dark ? "Day" : "Night")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Bottom panel

    private func panel(_ look: ShotLook) -> some View {
        VStack(spacing: 12) {
            hintRow
            ShotThemeRow(cid: snapshot.cid, dark: dark, selected: $theme)
            actions(look)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var hintRow: some View {
        HStack(spacing: 10) {
            Text("Swipe left to remove a message. Touch and hold to hide its text.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !removed.isEmpty {
                Button("Undo") { _ = removed.popLast() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
    }

    private func actions(_ look: ShotLook) -> some View {
        HStack(spacing: 12) {
            Button { export(look, share: false) } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            Button { export(look, share: true) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .glassEffect(.regular.tint(Color.fariinAction).interactive(), in: Capsule())
        }
        .foregroundStyle(.primary)
        .disabled(busy || rows.isEmpty)
        .opacity(busy || rows.isEmpty ? 0.5 : 1)
    }

    private func export(_ look: ShotLook, share: Bool) {
        guard !busy else { return }
        busy = true
        let images = ScreenshotExporter.render(rows: rows, look: look,
                                               hiddenIds: hiddenIds, showLogo: showLogo)
        if share {
            ScreenshotExporter.share(images)
            busy = false
        } else {
            Task {
                await ScreenshotExporter.save(images)
                busy = false
            }
        }
    }
}

private struct ShotItem: Identifiable {
    let m: ShotMessage
    let place: ShotPlacement
    var id: String { m.id }
}

/// A message in the editor: the same row the picture draws, plus the swipe and the hold menu.
private struct ShotEditableRow: View {
    let message: ShotMessage
    let look: ShotLook
    let place: ShotPlacement
    let hidden: Bool
    let onRemove: () -> Void
    let onToggleHidden: () -> Void

    @State private var dragX: CGFloat = 0
    private static let removeAt: CGFloat = 90

    var body: some View {
        ShotRowView(message: message, look: look, place: place, hidden: hidden)
            .offset(x: dragX)
            .opacity(1 - Double(min(1, -dragX / 220)))
            .contentShape(Rectangle())
            .onTapGesture { if hidden { onToggleHidden() } }
            .contextMenu { menu }
            .simultaneousGesture(swipe)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    @ViewBuilder private var menu: some View {
        Button(hidden ? "Show Text" : "Hide Text", systemImage: hidden ? "eye" : "eye.slash") {
            onToggleHidden()
        }
        Button("Remove from Picture", systemImage: "trash", role: .destructive) { onRemove() }
    }

    /// A left swipe only: a mostly vertical drag belongs to the scroll view.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > abs(dy) * 1.5 || dragX != 0 else { return }
                dragX = min(0, dx)
            }
            .onEnded { v in
                if v.translation.width < -Self.removeAt && dragX != 0 {
                    onRemove()
                    dragX = 0
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                }
            }
    }
}

/// The background choices: the chat's own look first, then the app's built-in wallpapers.
private struct ShotThemeRow: View {
    let cid: String
    let dark: Bool
    @Binding var selected: ShotTheme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(ShotTheme.all()) { theme in
                    Button { selected = theme } label: {
                        ShotThemeThumb(look: ShotLook.resolve(theme, cid: cid, dark: dark),
                                       isCurrent: theme == .current, selected: theme == selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label(theme))
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 3)
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

/// A small preview of one look: its background with one bubble from each side.
private struct ShotThemeThumb: View {
    let look: ShotLook
    let isCurrent: Bool
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(look.receivedFill).frame(width: 24, height: 9)
            Capsule().fill(look.sentFill).frame(width: 24, height: 9)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(7)
        .frame(width: 54, height: 72, alignment: .bottom)
        .background { ShotBackgroundView(look: look) }
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            if isCurrent {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(look.chipText)
                    .padding(5)
            }
        }
        .overlay { shape.strokeBorder(selected ? Color.primary : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2.5 : 1) }
    }
}

/// The pill that offers the editor for a few seconds after a screenshot.
struct ScreenshotOfferPill: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                Text("Customize screenshot")
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
