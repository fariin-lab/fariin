import SwiftUI

/// ⛔ THE STORY HEADER'S PRESS — owner 2026-10-12: "when I tap the repost avatar and name there is no
/// animation". The reference app's header block is a plain highlight button, read from its source:
///   • touch down: alpha 0.7 at once, and the content shrinks to (width − 8) / width over 0.2s
///     ease-in-out, from the centre;
///   • touch up: alpha back to 1 over 0.2s, scale overshoots to (width + 2) / width in 0.13s
///     ease-out, then settles to 1 in 0.1s ease-in.
/// The action runs on release, as a button's does. Nothing else moves: what opens is unchanged.
struct StoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StoryPressBody(configuration: configuration)
    }
}

private struct StoryPressBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var width: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var dimmed = false

    private func grown(by points: CGFloat) -> CGFloat {
        width > 0 ? (width + points) / width : 1
    }

    var body: some View {
        configuration.label
            .opacity(dimmed ? 0.7 : 1)
            .scaleEffect(scale, anchor: .center)
            .background(GeometryReader { g in
                Color.clear.onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { w in width = w }
            })
            .onChange(of: configuration.isPressed) { pressed in
                if pressed {
                    dimmed = true   // at once, as the reference sets it
                    withAnimation(.easeInOut(duration: 0.2)) { scale = grown(by: -8) }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { dimmed = false }
                    withAnimation(.easeOut(duration: 0.13)) { scale = grown(by: 2) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                        withAnimation(.easeIn(duration: 0.1)) { scale = 1 }
                    }
                }
            }
    }
}
