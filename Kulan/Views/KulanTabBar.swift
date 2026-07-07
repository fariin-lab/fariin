import SwiftUI

// Kulan's own floating tab bar (the Threads/WhatsApp pattern, our look): a glass capsule with
// outline→filled icons and a REAL Liquid Glass pill that slides to the selected tab, plus the
// detached circular search button. Replaces the native bar on the modern (iOS 26) path only.
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
    @Namespace private var pillNS

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                item(0, "message", "Chats")
                item(1, "phone", "Calls")
                item(2, "person.crop.circle", "Settings")
            }
            .padding(4)
            .liquidGlass(Capsule())

            // Detached circular search (mirrors the iOS 26 two-piece layout we replaced).
            Button { select(3) } label: {
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

    private func select(_ v: Int) {
        guard tab != v else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // The withAnimation drives the pill's matchedGeometry slide between tabs.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = v }
    }

    @ViewBuilder private func item(_ v: Int, _ icon: String, _ label: String) -> some View {
        let active = tab == v
        Button { select(v) } label: {
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
            .frame(width: 76, height: 52)
            .contentShape(Capsule())
            .background {
                // The sliding selection pill — REAL Liquid Glass (light-bending edge), moved
                // between tabs by matchedGeometry so it glides instead of popping.
                if active {
                    Color.clear
                        .liquidGlass(Capsule(), interactive: true)
                        .matchedGeometryEffect(id: "pill", in: pillNS)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
