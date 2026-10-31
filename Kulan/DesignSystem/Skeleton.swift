import SwiftUI
import UIKit

// Shimmering skeleton placeholders. Shown ONLY while there's no data yet (first cold
// load); once content is cached it renders instantly, so this never flashes on warm
// loads — an always-stable, never-blank feel. Design-neutral: each skeleton
// mirrors the real row's shape so nothing jumps when the real content arrives.

// Shimmering gray that fills its frame — the building block for every skeleton, and
// usable on its own (e.g. as an image placeholder instead of a spinner).
struct SkeletonFill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Opaque system greys — a REAL skeleton block that's clearly visible on any background
        // (including over a chat wallpaper), not a near-transparent tint that vanished.
        let base = scheme == .dark ? Color(.systemGray5) : Color(.systemGray4)
        let highlight = scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.55)
        // A timeline drives the sweep, never repeatForever (iOS 26 deadlock, build 959; audit H3).
        base.overlay(
            TimelineView(.animation) { ctx in
                let phase = -1 + 2 * ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.25) / 1.25
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, highlight, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 1.7)
                }
            }
        )
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
        .overlay(alignment: .top) { SlowLoadNote().padding(.top, 12) }
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
            // 22, not 30: the row's trailing control is the (i) glyph now, not the filled disc the
            // call-back button used to draw. This file's whole job is to be the same shape as the
            // row it stands in for, so it moves when the row does.
            SkeletonCircle(size: 22)
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
    // owner 2026-10-27 ("the skeleton looks half, make it full screen"): ten fixed bubbles filled
    // the top half. The pattern now repeats until the screen is full, and sits on the bottom like a
    // real conversation (newest at the foot); clipped, so a partial bubble at the top is fine.
    var body: some View {
        GeometryReader { g in
            let count = max(rows.count, Int(g.size.height / 44) + 1)
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ForEach(0..<count, id: \.self) { i in
                    let r = rows[i % rows.count]
                    HStack(spacing: 0) {
                        if r.mine { Spacer(minLength: 64) }
                        SkeletonBlock(width: r.w, height: 34, radius: 18)
                        if !r.mine { Spacer(minLength: 64) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
            .clipped()
        }
        .overlay(alignment: .top) { SlowLoadNote().padding(.top, 110) }
    }
}

// MARK: - UIKit twin (sticker tiles and chat stickers)

/// ⛔ THE SAME SHIMMER FOR UIKIT VIEWS — owner 2026-10-18: "when sticker is loading it shows empty,
/// use a skeleton animation". `SkeletonFill`'s look (same greys, same 55% band, same 1.25s linear
/// sweep across 1.7 widths) drawn by Core Animation, because the sticker views are plain UIKit and
/// ⛔ never SwiftUI repeatForever near the text field (the iOS 26 deadlock, build 959).
final class SkeletonShimmerView: UIView {
    private let band = CAGradientLayer()
    private static let sweepKey = "skeleton.sweep"
    private var on = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        clipsToBounds = true
        layer.cornerCurve = .continuous
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(band)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: SkeletonShimmerView, _: UITraitCollection) in
            v.applyColors()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the shimmer (and runs it) or takes it away.
    func setActive(_ active: Bool) {
        on = active
        isHidden = !active
        alpha = 1
        if active { startSweep() } else { band.removeAnimation(forKey: Self.sweepKey) }
    }

    /// The art has arrived: a short fade rather than a cut.
    func fadeOut() {
        guard on else { return }
        on = false
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in
            guard !self.on else { return }   // shown again meanwhile (a reused cell)
            self.isHidden = true
            self.alpha = 1
            self.band.removeAnimation(forKey: Self.sweepKey)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.55, height: bounds.height)
        CATransaction.commit()
        // The sweep's travel is in points of this width, so only a new width restarts it.
        if on, bounds.width != sweptWidth { startSweep(restart: true) }
    }
    private var sweptWidth: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if on, window != nil { startSweep() }
    }

    private func startSweep(restart: Bool = false) {
        guard bounds.width > 0 else { return }
        if !restart, band.animation(forKey: Self.sweepKey) != nil { return }
        sweptWidth = bounds.width
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = -1.7 * bounds.width
        a.toValue = 1.7 * bounds.width
        a.duration = 1.25
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.isRemovedOnCompletion = false
        band.add(a, forKey: Self.sweepKey)
    }

    private func applyColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        backgroundColor = (dark ? UIColor.systemGray5 : UIColor.systemGray4).resolvedColor(with: traitCollection)
        let hi = UIColor.white.withAlphaComponent(dark ? 0.14 : 0.55).cgColor
        let clear = UIColor.white.withAlphaComponent(0).cgColor
        band.colors = [clear, hi, clear]
    }
}

// MARK: - Find Channels (mirrors DiscoverChannelsView.row: 48 squircle + name + followers + Follow)

/// Owner 2026-10-31: the list showed one spinner on an empty page while it loaded.
struct DiscoverRowSkeleton: View {
    var nameWidth: CGFloat = 130
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(width: 48, height: 48, radius: 14)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: nameWidth, height: 13)
                SkeletonBlock(width: 80, height: 10)
            }
            Spacer(minLength: 8)
            SkeletonBlock(width: 76, height: 32, radius: 16)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

// MARK: - A group or channel's card before joining (mirrors groupBody: 100 photo, name, count)

/// Same height as the card it stands in for, so the Join button below does not move when it lands.
struct GroupCardSkeleton: View {
    var squircle = false
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if squircle { SkeletonBlock(width: 100, height: 100, radius: 28) } else { SkeletonCircle(size: 100) }
            }
            .padding(.top, 2)
            SkeletonBlock(width: 170, height: 20, radius: 8).padding(.top, 18)
            SkeletonBlock(width: 100, height: 12).padding(.top, 10)
            SkeletonBlock(width: 240, height: 12).padding(.top, 20)
            SkeletonBlock(width: 190, height: 12).padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { SlowLoadNote().offset(y: 56) }
        .accessibilityHidden(true)
    }
}


// MARK: - Slow connection

/// ⛔ A SLOW LOAD SAYS SO (owner 2026-10-31: "slow network: show real progress and a lighter path").
/// Nothing for the first 4 s, which is a normal load; after that one quiet line on the skeleton:
/// offline, it says the page fills in when the phone is back online; online, that the connection is
/// slow and what is saved on the phone still works.
struct SlowLoadNote: View {
    @State private var show = false
    @State private var offline = false
    var body: some View {
        Group {
            if show {
                Label(offline ? "You're offline. This fills in when you're back online."
                              : "Still loading. Your connection looks slow.",
                      systemImage: offline ? "wifi.slash" : "tortoise")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .liquidGlass(Capsule())
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            offline = !NetworkState.shared.isOnline
            withAnimation(.easeOut(duration: 0.3)) { show = true }
        }
        .accessibilityHidden(!show)
    }
}
