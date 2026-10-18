import SwiftUI

/// ⛔ THE BUSY ARC — owner 2026-10-18, with pictures of the look he wants: one thick rounded arc
/// turning, in place of the system's ticking spinner. The big one says what is happening under it
/// ("Signing Out…"); the small one sits inside a busy button (sign-in, password, delete account).
/// Driven by the screen's frame clock (`TimelineView(.animation)`), NOT a `repeatForever` animation:
/// one of those near a text field deadlocked on iOS 26 (build 959), so moving things here never use it.
struct BusyArc: View {
    var size: CGFloat = 88
    var lineWidth: CGFloat = 9
    var color: Color = Color(hex: 0x2C6BED)

    /// The size that fits inside a button or a row, at the label's height.
    static func small(_ color: Color) -> BusyArc { BusyArc(size: 22, lineWidth: 2.5, color: color) }

    var body: some View {
        TimelineView(.animation) { t in
            let turn = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0, to: 0.78)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size + lineWidth, height: size + lineWidth)
        .accessibilityHidden(true)
    }
}

/// The page-wide busy state: the arc and what is happening, in words, over the page as it is (no
/// wash, owner 2026-10-18: "the animation alone is cool"). Swallows touches, because whatever is
/// running cannot be interrupted.
struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
            VStack(spacing: 26) {
                BusyArc()
                Text(text).font(.system(size: 19)).foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .transition(.opacity)
    }
}
