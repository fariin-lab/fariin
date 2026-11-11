import SwiftUI
import UIKit

/// ⛔ HOLD A PROFILE'S NAME OR @USERNAME TO COPY IT (owner 2026-11-11, with the reference app's
/// screenshot): a long press shows a small glass "Copy" pill right above the pressed text. A tap on
/// it copies, gives a light tap, and the pill says "Copied" for a moment before it goes. Left alone,
/// it goes by itself after a few seconds; a second hold on the text hides it.
struct HoldToCopy: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var copied = false
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.4) {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Haptics.impact(.light)
                if shown { hide() } else { show() }
            }
            .overlay(alignment: .top) {
                if shown {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.impact(.light)
                        withAnimation(.snappy(duration: 0.2)) { copied = true }
                        scheduleHide(after: 0.9)
                    } label: {
                        Text(copied ? "Copied" : "Copy")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16).frame(height: 34)
                            .liquidGlass(Capsule(), interactive: true)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(copied)
                    .fixedSize()
                    .alignmentGuide(.top) { d in d[.bottom] + 6 }   // sits just above the text
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    .accessibilityLabel(copied ? "Copied" : "Copy \(text)")
                }
            }
            .zIndex(shown ? 1 : 0)
            .onDisappear { hideTask?.cancel(); shown = false; copied = false }
    }

    private func show() {
        copied = false
        withAnimation(.spring(duration: 0.28, bounce: 0.25)) { shown = true }
        scheduleHide(after: 3)
    }

    private func hide() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { shown = false }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { shown = false }
            try? await Task.sleep(for: .seconds(0.2))
            copied = false
        }
    }
}

extension View {
    /// A long press shows a glass "Copy" pill above this view that copies `text`. See `HoldToCopy`.
    func holdToCopy(_ text: String) -> some View { modifier(HoldToCopy(text: text)) }
}
