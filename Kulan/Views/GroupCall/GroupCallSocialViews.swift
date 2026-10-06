import SwiftUI

// The in-call notices that are not about the connection (owner, 2026-10-06: raise hand, reactions and
// "who muted you", built the way the reference app does them). Three small views the call screen
// mounts; each reads its own singleton, so the screen passes nothing in:
//
//   GroupCallTopToast          the service's short note ("Alice muted you"), at the top
//   GroupCallReactionsOverlay  the emoji people send, rising in a column, with a burst
//   GroupCallRaisedHandsPill   who has a hand up; the only one of the three that takes touches
//
// The join/leave banner and the look the toast shares with it are in GroupCallStatusBanner.swift.
// Rule for all of them: nothing here takes a touch from the stage except the pill itself.

// MARK: - Top toast

/// The service's short note, in the banner's look, sliding down from the top and back up. The
/// service sets and clears `toast` (3s) and speaks it to VoiceOver itself, so this view only draws.
/// Zero height when there is nothing to say.
struct GroupCallTopToast: View {
    @ObservedObject private var service = GroupCallService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {}

    var body: some View {
        ZStack(alignment: .top) {
            if let text = service.toast {
                GroupCallNoticeCard(text: text)
                    .padding(.top, 8)
                    .transition(GroupCallNoticeMotion.entry(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(GroupCallNoticeMotion.slide(reduceMotion: reduceMotion), value: service.toast)
        .allowsHitTesting(false)
    }
}

// MARK: - Reactions

/// The emoji people send during the call: a column at the bottom-leading corner, newest at the
/// bottom, each row the emoji and the sender's name in a dark capsule. `GroupCallSocial` owns the
/// list (at most 5, each gone after 4s); this view only draws it. A new row rises in over 0.2s and
/// pushes the older ones up; a row that times out fades. When three or more of the same emoji are
/// on screen a burst of that emoji floats up from the corner.
/// Reduce Motion: no burst, and rows fade in and out without moving.
/// The frame is fixed (the reference app's 217pt column, five rows high) and the rows sit at its
/// bottom, so wherever the screen mounts it the column grows upward. It carries its own 16pt
/// leading margin and takes no touches.
struct GroupCallReactionsOverlay: View {
    @ObservedObject private var social = GroupCallSocial.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bursts: [ReactionBurst] = []
    // Burst limits (the reference app's): one emoji bursts at most every 2s, and no more than 3
    // bursts of any kind inside 4s, so a room spamming reactions does not fill the screen.
    @State private var lastBurstAt: [String: Date] = [:]
    @State private var recentBursts: [Date] = []

    private static let width: CGFloat = 217
    private static let rowHeight: CGFloat = 36
    private static let rowSpacing: CGFloat = 12
    private static let maxRows: CGFloat = 5
    private static let burstCount = 3
    private static let burstCooloff: TimeInterval = 2
    private static let burstWindow: TimeInterval = 4
    private static let maxBurstsInWindow = 3

    private static var height: CGFloat { maxRows * rowHeight + (maxRows - 1) * rowSpacing }

    init() {}

    private var ids: [UUID] { social.reactions.map(\.id) }

    private var rowTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: AnyTransition.move(edge: .bottom).combined(with: .opacity),
                           removal: .opacity)
    }

    var body: some View {
        rows
            .frame(width: Self.width, height: Self.height, alignment: .bottomLeading)
            .overlay(alignment: .bottomLeading) { burstLayer }
            .padding(.leading, 16)
            // Rows rise in 0.2s ease-out (the reference app's number); Reduce Motion: the stage's fade.
            .animation(reduceMotion ? GroupCallMotion.fade : Animation.easeOut(duration: 0.2), value: ids)
            .allowsHitTesting(false)
            .onChange(of: ids) { old, _ in reactionsChanged(old: old) }
            .onDisappear { bursts = [] }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(social.reactions) { reaction in
                row(reaction).transition(rowTransition)
            }
        }
    }

    private func row(_ reaction: GroupCallSocial.Reaction) -> some View {
        let name = Self.shownName(reaction)
        return HStack(spacing: 18) {
            Text(reaction.emoji)
                .font(.system(size: 28))
                .lineLimit(1)
                .layoutPriority(1)      // a long name gives way, the emoji is never squeezed
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) reacted \(reaction.emoji)")
    }

    /// My own reaction reads "You", like the reference app's.
    private static func shownName(_ reaction: GroupCallSocial.Reaction) -> String {
        if !reaction.uid.isEmpty, reaction.uid == GroupCallService.shared.myUid { return "You" }
        let n = reaction.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Member" : n
    }

    private var burstLayer: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(bursts) { burst in
                ReactionBurstView(burst: burst, onDone: {
                    bursts.removeAll { $0.id == burst.id }
                })
            }
        }
        .accessibilityHidden(true)
    }

    /// A reaction just arrived: if three or more of its emoji are now on screen, burst once.
    private func reactionsChanged(old: [UUID]) {
        guard !reduceMotion else { return }
        let seen = Set(old)
        let all = social.reactions
        let now = Date()
        lastBurstAt = lastBurstAt.filter { now.timeIntervalSince($0.value) < Self.burstCooloff }
        recentBursts = recentBursts.filter { now.timeIntervalSince($0) < Self.burstWindow }
        var checked: Set<String> = []
        for reaction in all where !seen.contains(reaction.id) {
            let emoji = reaction.emoji
            guard !checked.contains(emoji) else { continue }
            checked.insert(emoji)
            let onScreen = all.filter { $0.emoji == emoji }.count
            guard onScreen >= Self.burstCount else { continue }
            guard lastBurstAt[emoji] == nil, recentBursts.count < Self.maxBurstsInWindow else { continue }
            lastBurstAt[emoji] = now
            recentBursts.append(now)
            bursts.append(ReactionBurst.make(emoji: emoji))
        }
    }
}

/// One burst: a handful of copies of an emoji, each with its own path, decided once when the burst
/// is made so a re-render does not send them somewhere new.
private struct ReactionBurst: Identifiable, Equatable {
    struct Particle: Identifiable, Equatable {
        let id: Int
        let drift: CGFloat      // sideways, mostly toward the middle of the screen
        let rise: CGFloat       // how far up it floats
        let scale: CGFloat      // it grows as it goes
        let spin: Double        // degrees, from -spin to +spin
        let duration: Double
        let delay: Double
    }

    let id: UUID
    let emoji: String
    let particles: [Particle]

    static let particleCount = 7
    /// Longer than the slowest particle (0.18s delay + 1.2s): when the burst is taken down.
    static let lifetime: Double = 1.6

    static func make(emoji: String) -> ReactionBurst {
        var particles: [Particle] = []
        for i in 0..<particleCount {
            particles.append(Particle(
                id: i,
                drift: CGFloat.random(in: -16...84),
                rise: CGFloat.random(in: 200...320),
                scale: CGFloat.random(in: 1.6...2.6),
                spin: Double.random(in: -24...24),
                duration: Double.random(in: 0.9...1.2),
                delay: Double(i) * 0.03
            ))
        }
        return ReactionBurst(id: UUID(), emoji: emoji, particles: particles)
    }
}

/// Draws one burst from the bottom-leading corner (where the newest reaction's emoji sits), then
/// asks to be removed. The `.task` ends with the view, so nothing outlives the overlay.
private struct ReactionBurstView: View {
    let burst: ReactionBurst
    let onDone: () -> Void

    @State private var flying = false

    init(burst: ReactionBurst, onDone: @escaping () -> Void) {
        self.burst = burst
        self.onDone = onDone
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(burst.particles) { p in
                floatingEmoji(p)
            }
        }
        .onAppear { flying = true }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(ReactionBurst.lifetime * 1_000_000_000))
            if Task.isCancelled { return }
            onDone()
        }
    }

    /// Floats up easing out, and fades easing in, so it stays visible for most of the way.
    private func floatingEmoji(_ p: ReactionBurst.Particle) -> some View {
        Text(burst.emoji)
            .font(.system(size: 28))
            .scaleEffect(flying ? p.scale : 1)
            .rotationEffect(.degrees(flying ? p.spin : -p.spin))
            .offset(x: flying ? p.drift : 0, y: flying ? -p.rise : 0)
            .animation(.easeOut(duration: p.duration).delay(p.delay), value: flying)
            .opacity(flying ? 0 : 1)
            .animation(.easeIn(duration: p.duration).delay(p.delay), value: flying)
    }
}

// MARK: - Raised hands

/// Who has a hand up. Nothing at all when nobody does. Folded, it is a small pill: the hand and
/// "You" / "You +2" / the count. Open, it says who ("Alice raised a hand", "Alice +4 raised a hand")
/// and, when my own hand is up, offers "Lower". It opens by itself for the first hand and for my own
/// (the reference app's rule, so the name is seen without a tap), opens on a tap, and folds again
/// after 4s. A tap on the open text calls `onTap` (the screen opens the people list).
/// Spring 0.3s, no bounce; Reduce Motion swaps it for the stage's fade.
struct GroupCallRaisedHandsPill: View {
    let onTap: () -> Void

    @ObservedObject private var social = GroupCallSocial.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>? = nil

    private static let openSeconds: Double = 4

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    private var handUids: [String] { social.raisedHands.map(\.uid) }

    private var motion: Animation {
        reduceMotion ? GroupCallMotion.fade : .spring(response: 0.3, dampingFraction: 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if !social.raisedHands.isEmpty {
                pill
                    .padding(.top, 8)
                    .transition(GroupCallNoticeMotion.entry(reduceMotion: reduceMotion))
            }
        }
        // Full width with no background: only the pill itself can be touched.
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(motion, value: handUids)
        .animation(motion, value: expanded)
        .onChange(of: handUids) { old, new in handsChanged(old: old, new: new) }
        .onChange(of: social.myHandUp) { _, up in
            // I just raised my hand: open, so "Lower" is right there.
            if up { expand() }
        }
        .onDisappear {
            collapseTask?.cancel()
            collapseTask = nil
            expanded = false
        }
    }

    // MARK: Pieces

    /// A capsule when folded, corner 10 when open (the reference app's shapes). 24 is half the
    /// folded pill's height at the default text size.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? 10 : 24, style: .continuous)
    }

    private var pill: some View {
        HStack(spacing: 0) {
            Button {
                mainTapped()
            } label: {
                mainLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expandedText)
            .accessibilityHint(mainHint)
            if expanded && social.myHandUp {
                lowerButton.transition(.opacity)
            }
        }
        .frame(maxWidth: expanded ? 512 : nil)
        .background(backdrop)
        .padding(.horizontal, 16)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var mainLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.white)
            Text(expanded ? expandedText : collapsedText)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(expanded ? 3 : 1)
                .multilineTextAlignment(.leading)
                // Two different texts, not one that changes: they cross-fade as the pill resizes.
                .id(expanded)
                .transition(.opacity)
            if expanded { Spacer(minLength: 0) }
        }
        .padding(.horizontal, expanded ? 12 : 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var lowerButton: some View {
        Button {
            social.setHand(false)
        } label: {
            Text("Lower")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Lower hand")
    }

    private var backdrop: some View {
        ZStack {
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            shape.fill(Color.black.opacity(0.4))
        }
    }

    // MARK: Texts

    private var collapsedText: String {
        let count = social.raisedHands.count
        if social.myHandUp { return count > 1 ? "You +\(count - 1)" : "You" }
        return "\(count)"
    }

    private var expandedText: String {
        let hands = social.raisedHands
        let others = max(hands.count - 1, 0)
        if social.myHandUp {
            return others > 0 ? "You +\(others) raised a hand" : "Your hand is raised"
        }
        // Oldest first: the person who has waited longest is the one named.
        let first = (hands.first?.name ?? "").trimmingCharacters(in: .whitespaces)
        let name = first.isEmpty ? "Someone" : first
        return others > 0 ? "\(name) +\(others) raised a hand" : "\(name) raised a hand"
    }

    /// A String, not a literal in the modifier: the call then has one overload to pick, not three.
    private var mainHint: String {
        expanded ? "Opens the people list" : "Shows who raised a hand"
    }

    // MARK: Opening and folding

    private func mainTapped() {
        if expanded { onTap() } else { expand() }
    }

    private func expand() {
        expanded = true
        queueCollapse()
    }

    private func handsChanged(old: [String], new: [String]) {
        guard !new.isEmpty else {
            // The last hand went down: the pill is gone, and the next one starts from scratch.
            collapseTask?.cancel()
            collapseTask = nil
            expanded = false
            return
        }
        if old.isEmpty {
            expand()            // the first hand: say who, then fold away
        } else if expanded {
            queueCollapse()     // still changing while open: keep it open a little longer
        }
    }

    /// Folds the pill 4s from now. Restarted, never stacked: the older task is cancelled first and
    /// leaves without touching anything.
    private func queueCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.openSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            expanded = false
            collapseTask = nil
        }
    }
}
