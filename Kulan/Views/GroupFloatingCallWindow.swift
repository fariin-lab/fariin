import SwiftUI
import LiveKit

// The minimized MULTI-PERSON call (group, ad-hoc or link): the same floating card a minimized 1:1
// call gets, replacing the green full-width "Return to call" bar (owner, 2026-10-04: "group call is
// using old UI"). Same size, corner, border and shadow as `FloatingCallWindow`, same rules: no
// buttons on it, tap goes back to the call, drag moves it and it snaps to the nearer side at the
// height you let go.
//
// Deliberately simpler than the 1:1 card: no stash-to-a-tab. That gesture is built on CallService's
// own card state, and a second copy of it for this card would be two implementations of one thing.
struct GroupFloatingCallWindow: View {
    @ObservedObject private var service = GroupCallService.shared
    @ObservedObject private var room = GroupCallService.shared.room

    private let w: CGFloat = 112
    private let h: CGFloat = 199   // 9:16, the 1:1 card's shape

    /// Settled position from the top-right home (x ≤ 0 is leftward, y ≥ 0 downward) and the live drag
    /// as a transform on top of it — the 1:1 card's split, for the same reason (layout at rest, a
    /// cheap transform under the finger).
    @State private var base: CGSize = .zero
    @State private var dragLive: CGSize = .zero
    @State private var insets: UIEdgeInsets = .zero

    var body: some View {
        GeometryReader { geo in
            card
                .offset(dragLive)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            let (maxLeft, maxDown) = limits(geo.size)
                            let x = min(0, max(maxLeft, base.width + v.translation.width))
                            let y = min(maxDown, max(0, base.height + v.translation.height))
                            dragLive = CGSize(width: x - base.width, height: y - base.height)
                        }
                        .onEnded { v in
                            let (maxLeft, maxDown) = limits(geo.size)
                            // Where the throw was heading, not where the finger stopped.
                            let thrownX = base.width + v.predictedEndTranslation.width
                            let y = min(maxDown, max(0, base.height + v.predictedEndTranslation.height))
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                base = CGSize(width: thrownX < maxLeft / 2 ? maxLeft : 0, height: y)
                                dragLive = .zero
                            }
                        }
                )
                // CallContainer re-presents GroupCallView when `minimized` clears.
                .onTapGesture { service.minimized = false }
                .padding(.top, insets.top + 8 + base.height)
                .padding(.trailing, 12 - base.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .onAppear {
            insets = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
                .max(by: { $0.top < $1.top }) ?? .zero
        }
        .accessibilityLabel("Back to the call")
    }

    private func limits(_ size: CGSize) -> (CGFloat, CGFloat) {
        let maxLeft = -(size.width - w - 24)
        let maxDown = max(0, size.height - h - (insets.top + 8) - (insets.bottom + 76))
        return (maxLeft, maxDown)
    }

    // MARK: - Content

    private var remotes: [RemoteParticipant] {
        room.remoteParticipants.values.sorted { ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "") }
    }

    /// The call screen's own words, so minimizing never renames the stage.
    private var stageLabel: String? {
        if service.waitingForApproval { return "Waiting to be let in…" }
        if service.connecting { return "Connecting…" }
        if room.connectionState == .reconnecting { return "Reconnecting…" }
        if remotes.isEmpty { return "Waiting for others…" }
        return nil
    }

    private var card: some View {
        Group {
            if let track = remotes.lazy.compactMap({ $0.firstCameraVideoTrack }).first {
                ZStack(alignment: .bottom) {
                    Color.black
                    SwiftUIVideoView(track, layoutMode: .fill)
                        .frame(width: w, height: h)
                        .clipped()
                    countPill.padding(.bottom, 8)
                }
            } else if let stage = stageLabel {
                VStack(spacing: 10) {
                    face(uid: firstOtherUid, fallbackName: service.callTitle, size: 54, speaking: false)
                    Text(stage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
                .background(Color.black)
            } else {
                // Up to two of the others, one panel each, the shape of the connected 1:1 card.
                VStack(spacing: 0) {
                    ForEach(Array(remotes.prefix(2).enumerated()), id: \.offset) { i, p in
                        if i > 0 { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5) }
                        ZStack {
                            Color.white.opacity(0.06)
                            face(uid: p.identity?.stringValue, fallbackName: p.name ?? "Member",
                                 size: i == 0 ? 46 : 40, speaking: p.isSpeaking)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color.black)
                .overlay(alignment: .bottom) {
                    if remotes.count > 2 { countPill.padding(.bottom, 8) }
                }
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var countPill: some View {
        Text("\(remotes.count + 1) in call")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }

    /// Someone other than me to put on a card that has nobody connected yet: the first invited
    /// person on an ad-hoc call; nil on a group/link call, which falls back to the call's title.
    private var firstOtherUid: String? {
        service.members.first { $0.uid != service.myUid }?.uid
    }

    private func face(uid: String?, fallbackName: String, size: CGFloat, speaking: Bool) -> some View {
        let m = uid.flatMap { u in service.members.first { $0.uid == u } }
        return AvatarView(name: m?.name ?? fallbackName, photoUrl: m?.photoUrl, size: size)
            .overlay(Circle().stroke(Color.green, lineWidth: speaking ? 2.5 : 0))
    }
}
