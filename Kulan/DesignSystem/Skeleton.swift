import SwiftUI

// Shimmering skeleton placeholders. Shown ONLY while there's no data yet (first cold
// load); once content is cached it renders instantly, so this never flashes on warm
// loads — an always-stable, never-blank feel. Design-neutral: each skeleton
// mirrors the real row's shape so nothing jumps when the real content arrives.

// Shimmering gray that fills its frame — the building block for every skeleton, and
// usable on its own (e.g. as an image placeholder instead of a spinner).
struct SkeletonFill: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase: CGFloat = -1

    var body: some View {
        // Opaque system greys — a REAL skeleton block that's clearly visible on any background
        // (including over a chat wallpaper), not a near-transparent tint that vanished.
        let base = scheme == .dark ? Color(.systemGray5) : Color(.systemGray4)
        let highlight = scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.55)
        base.overlay(
            GeometryReader { geo in
                LinearGradient(colors: [.clear, highlight, .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: phase * geo.size.width * 1.7)
            }
        )
        .onAppear {
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 6
    var body: some View {
        SkeletonFill()
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SkeletonCircle: View {
    var size: CGFloat
    var body: some View {
        SkeletonFill().frame(width: size, height: size).clipShape(Circle())
    }
}

// MARK: - Chat list (mirrors ChatRow: 56 avatar + name line + preview line)

struct ChatRowSkeleton: View {
    var previewWidth: CGFloat = 210
    var body: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 56)
            VStack(alignment: .leading, spacing: 9) {
                SkeletonBlock(width: 140, height: 13)
                SkeletonBlock(width: previewWidth, height: 11)
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 76)
        .padding(.vertical, 2)
        .padding(.horizontal, 16)
    }
}

struct ChatListSkeleton: View {
    // Slightly varied preview widths read as a natural list, not identical bars.
    private let widths: [CGFloat] = [220, 150, 240, 120, 200, 170, 230, 140, 190]
    var body: some View {
        // A ScrollView (not a bare VStack) so a `.searchable` search bar reserves its space
        // ABOVE the rows — a plain stack let the search bar float over the first rows.
        ScrollView {
            VStack(spacing: 0) {
                ForEach(widths.indices, id: \.self) { i in ChatRowSkeleton(previewWidth: widths[i]) }
            }
        }
        .scrollDisabled(true)
    }
}

// MARK: - Calls list (mirrors CallHistoryRow: 46 avatar + name + subtitle + trailing)

struct CallRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 46)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(width: 130, height: 13)
                SkeletonBlock(width: 78, height: 10)
            }
            Spacer(minLength: 8)
            SkeletonBlock(width: 44, height: 11)
            SkeletonCircle(size: 30)
        }
        .frame(minHeight: 56)
        .padding(.vertical, 7)
        .padding(.horizontal, 16)
    }
}

struct CallListSkeleton: View {
    var body: some View {
        // ScrollView so `.searchable` places the search bar above the rows instead of
        // overlapping them (user report: skeleton overlapped the "Search calls" bar).
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { _ in CallRowSkeleton() }
            }
        }
        .scrollDisabled(true)
    }
}

// MARK: - Conversation (alternating placeholder bubbles)

struct ThreadSkeleton: View {
    private let rows: [(mine: Bool, w: CGFloat)] = [
        (false, 180), (false, 120), (true, 150), (false, 210), (true, 90),
        (false, 160), (true, 200), (false, 130), (true, 110), (false, 175),
    ]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 0) {
                    if r.mine { Spacer(minLength: 64) }
                    SkeletonBlock(width: r.w, height: 34, radius: 18)
                    if !r.mine { Spacer(minLength: 64) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
