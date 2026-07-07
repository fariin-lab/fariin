import SwiftUI

// Kulan's own floating tab bar (the Threads/WhatsApp pattern, our look): a glass capsule with
// outline→filled icons and a REAL Liquid Glass lens pill over the selected tab, plus the
// detached circular search button. Replaces the native bar on the modern (iOS 26) path only.
//
// The pill is ONE persistent glass view (it never unmounts): tapping another tab makes it
// GLIDE there, and holding it lets you DRAG it between tabs with your finger — release
// commits the tab under it (the native iOS 26 bar's hold-and-slide behavior).
//
// Visibility: the native bar auto-hid inside pushed screens (thread, contact info) and in the
// chat list's selection mode via .toolbar(.hidden, for: .tabBar). This bar floats ABOVE the
// whole TabView, so those screens signal through TabBarChrome instead (counter, not a bool —
// nested hiders can overlap).
@Observable
final class TabBarChrome {
    static let shared = TabBarChrome()
    var hiddenCount = 0
    var hidden: Bool { hiddenCount > 0 }
}

private struct KulanTabBarHiddenWhen: ViewModifier {
    let hidden: Bool
    @State private var counted = false
    func body(content: Content) -> some View {
        content
            .onAppear { sync(hidden) }
            .onDisappear { sync(false) }
            .onChange(of: hidden) { _, h in sync(h) }
    }
    private func sync(_ h: Bool) {
        if h && !counted { counted = true; TabBarChrome.shared.hiddenCount += 1 }
        else if !h && counted { counted = false; TabBarChrome.shared.hiddenCount -= 1 }
    }
}

extension View {
    /// Hide the custom tab bar while this view is on screen (what .toolbar(.hidden, for: .tabBar) did).
    func hidesKulanTabBar() -> some View { modifier(KulanTabBarHiddenWhen(hidden: true)) }
    /// Hide the custom tab bar while `hidden` is true (e.g. the chat list's selection mode).
    func kulanTabBarHidden(_ hidden: Bool) -> some View { modifier(KulanTabBarHiddenWhen(hidden: hidden)) }
}

struct KulanTabBar: View {
    @Binding var tab: Int
    var missedBadge: Int
    var settingsIcon: UIImage?
    // Live finger x (in capsule space) while holding/dragging the pill; nil at rest.
    @State private var dragX: CGFloat?

    private let itemW: CGFloat = 76
    private let itemH: CGFloat = 52
    private let pad: CGFloat = 4

    private var currentSlot: Int { min(max(tab, 0), 2) }
    private var hoveredSlot: Int? { dragX.map { slot(at: $0) } }
    private func slot(at x: CGFloat) -> Int { min(2, max(0, Int((x - pad) / itemW))) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                // The lens pill — follows the finger mid-drag, else sits on the selected slot.
                Color.clear
                    .frame(width: itemW, height: itemH)
                    .liquidGlass(Capsule(), interactive: true)
                    .scaleEffect(dragX != nil ? 1.06 : 1)   // lifts slightly while held, like a lens
                    .offset(x: pillX)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragX != nil)

                HStack(spacing: 0) {
                    item(0, "message", "Chats")
                    item(1, "phone", "Calls")
                    item(2, "person.crop.circle", "Settings")
                }
            }
            .padding(pad)
            .liquidGlass(Capsule())
            .contentShape(Capsule())
            .gesture(barGesture)

            // Detached circular search (mirrors the iOS 26 two-piece layout we replaced).
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                tab = 3
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlass(Circle(), interactive: true)
        }
        .padding(.horizontal, 24)
    }

    private var pillX: CGFloat {
        if let x = dragX { return min(max(x - pad - itemW / 2, 0), itemW * 2) }
        return CGFloat(currentSlot) * itemW
    }

    // One gesture drives everything: touch-down brings the pill to the finger, dragging slides
    // it (haptic tick crossing each tab), release commits the tab under it. A plain tap is just
    // the degenerate case — down + release on the same spot.
    private var barGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let before = hoveredSlot
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragX = g.location.x }
                if let before, let now = hoveredSlot, before != now {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { g in
                let target = slot(at: g.location.x)
                if tab != target { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    dragX = nil
                    tab = target
                }
            }
    }

    @ViewBuilder private func item(_ v: Int, _ icon: String, _ label: String) -> some View {
        let active = (hoveredSlot ?? currentSlot) == v
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Group {
                    // Settings shows your profile photo when set (same as the native bar did).
                    if v == 2, let ui = settingsIcon {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 24, height: 24).clipShape(Circle())
                    } else {
                        Image(systemName: active ? icon + ".fill" : icon)
                            .font(.system(size: 20, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 30, height: 26)
                if v == 1 && missedBadge > 0 {
                    Text("\(missedBadge)")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(.red, in: Capsule())
                        .offset(x: 10, y: -4)
                }
            }
            Text(label)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
        }
        .foregroundStyle(.primary)
        .frame(width: itemW, height: itemH)
    }
}
