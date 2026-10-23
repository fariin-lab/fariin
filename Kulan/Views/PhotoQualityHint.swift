import SwiftUI

/// The short line that says what the HD button just did (2026-10-23). The button alone is two
/// letters that change colour; the reference app also says it in words for a moment, so the
/// person knows the photo will go small and fast, or sharp and slower.
///
/// Shown above the view it is attached to (the tool row), for 1.6 s after each tap, and never
/// takes a touch. Nothing shows when the screen opens, only on a change.
private struct PhotoQualityHint: ViewModifier {
    let hd: Bool
    @State private var shown: Bool?
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let shown {
                    Text(shown ? "HD: sharper photos, bigger upload" : "Standard: smaller photos, faster send")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.black.opacity(0.72), in: Capsule())
                        .fixedSize()
                        .offset(y: -40)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)   // the button's accessibility value says it
                }
            }
            .onChange(of: hd) { _, now in
                token += 1
                let mine = token
                withAnimation(.easeOut(duration: 0.15)) { shown = now }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    guard token == mine else { return }
                    withAnimation(.easeIn(duration: 0.2)) { shown = nil }
                }
            }
    }
}

extension View {
    func photoQualityHint(hd: Bool) -> some View { modifier(PhotoQualityHint(hd: hd)) }
}
