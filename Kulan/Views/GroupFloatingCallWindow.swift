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
//
// Owner, 2026-10-06 (group call build plan, the screen package), both as the reference app's card:
// - the card shows whoever is SPEAKING (it showed the alphabetically first camera);
// - it moves up when the keyboard would cover it and goes back when the keyboard leaves.
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
    /// Whose camera the card showed last (their identity), kept while they are quiet.
    @State private var shownId: String?
    /// The docked keyboard's top edge in screen points, nil while it is down.
    @State private var keyboardTop: CGFloat?
    /// Where the card rested before the keyboard pushed it up, so it can go back. nil = not pushed.
    @State private var beforeKeyboard: CGFloat?

    private static let keyboardFrames = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillChangeFrameNotification)

    var body: some View {
        GeometryReader { geo in
            card
                // Where the minimize flight lands (`CallPipMorph`), reported on the 1:1 card's own
                // slot: only one of the two cards exists at a time. Owner, 2026-10-06: the group
                // call slid down instead of zooming out into the card like a normal call.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CallService.shared.cardFrame = $0 }
                .onDisappear { CallService.shared.cardFrame = .zero }
                .opacity(CallService.shared.cardHiddenForMorph ? 0 : 1)
                .offset(dragLive)
                .gesture(drag(in: geo.size))
                // CallContainer re-presents GroupCallView when `minimized` clears.
                .onTapGesture { service.minimized = false }
                .padding(.top, insets.top + 8 + base.height)
                .padding(.trailing, 12 - base.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .onReceive(Self.keyboardFrames) { note in keyboardMoved(note, in: geo.size) }
        }
        .ignoresSafeArea()
        .onAppear {
            insets = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
                .max(by: { $0.top < $1.top }) ?? .zero
            shownId = pickedId
        }
        .onChange(of: pickedId) { _, id in
            if let id { shownId = id }
        }
        .accessibilityLabel("Back to the call")
    }

    // MARK: - Drag

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let (maxLeft, maxDown) = limits(size)
                let x = min(0, max(maxLeft, base.width + v.translation.width))
                let y = min(maxDown, max(0, base.height + v.translation.height))
                dragLive = CGSize(width: x - base.width, height: y - base.height)
            }
            .onEnded { v in
                let (maxLeft, maxDown) = limits(size)
                // Where the throw was heading, not where the finger stopped.
                let thrownX = base.width + v.predictedEndTranslation.width
                let y = min(maxDown, max(0, base.height + v.predictedEndTranslation.height))
                // Moved by hand: this is its place now, the keyboard has nothing to put back.
                beforeKeyboard = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    base = CGSize(width: thrownX < maxLeft / 2 ? maxLeft : 0, height: y)
                    dragLive = .zero
                }
            }
    }

    private func limits(_ size: CGSize) -> (CGFloat, CGFloat) {
        let maxLeft = -(size.width - w - 24)
        var maxDown = max(0, size.height - h - (insets.top + 8) - (insets.bottom + 76))
        // With the keyboard up the card cannot be parked under it.
        if let keyboardTop { maxDown = min(maxDown, lowestRest(above: keyboardTop)) }
        return (maxLeft, maxDown)
    }

    // MARK: - Keyboard

    /// The lowest `base.height` whose card still ends 8pt above `top`.
    private func lowestRest(above top: CGFloat) -> CGFloat {
        max(0, top - 8 - h - (insets.top + 8))
    }

    /// The reference app's rule: a card the keyboard would cover moves up to sit just above it, and
    /// returns to where it was once the keyboard is out of the way. A card that was never covered
    /// does not move.
    private func keyboardMoved(_ note: Notification, in size: CGSize) {
        guard let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let seconds = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        // Down, or not docked to the bottom edge (floating on an iPad): it covers nothing here.
        let docked = end.height > 0 && end.minY < size.height && end.maxY >= size.height - 1
        let top: CGFloat? = docked ? end.minY : nil
        keyboardTop = top
        let wanted = beforeKeyboard ?? base.height
        var target = wanted
        var pushedFrom: CGFloat?
        if let top {
            let lowest = lowestRest(above: top)
            if wanted > lowest {
                target = lowest
                pushedFrom = wanted
            }
        }
        beforeKeyboard = pushedFrom
        guard target != base.height else { return }
        withAnimation(.easeOut(duration: max(0.1, seconds))) { base.height = target }
    }

    // MARK: - Content

    private var remotes: [RemoteParticipant] {
        room.remoteParticipants.values.sorted { ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "") }
    }

    private static func key(_ p: Participant) -> String { p.identity?.stringValue ?? "" }

    /// Whose camera fills the card, in the reference app's order: the first person speaking who has
    /// a live camera; else the one shown last, if their camera is still live (a quiet moment, or a
    /// speaker with no camera, does not change the picture); else the first live camera. nil = no
    /// camera is on, the card draws faces.
    /// One addition so two people talking at once do not make the card cut back and forth: the
    /// person on the card keeps it for as long as they are among the speakers.
    private var picked: (id: String, track: VideoTrack)? {
        var live: [(id: String, track: VideoTrack)] = []
        for p in remotes {
            if let track = p.firstCameraVideoTrack { live.append((id: Self.key(p), track: track)) }
        }
        guard let first = live.first else { return nil }
        var speaking: [String] = []   // loudest first, as the room lists them
        for speaker in room.activeSpeakers where speaker is RemoteParticipant {
            speaking.append(Self.key(speaker))
        }
        let shown = shownId.flatMap { id in live.first(where: { $0.id == id }) }
        if let shown, speaking.contains(shown.id) { return shown }
        for id in speaking {
            if let hit = live.first(where: { $0.id == id }) { return hit }
        }
        return shown ?? first
    }
    private var pickedId: String? { picked?.id }

    /// The call screen's own words (`GroupCallWords`), so minimizing never renames the stage.
    private func stageLabel(at now: Date) -> String? {
        let reconnecting = room.connectionState == .reconnecting
        if let words = GroupCallWords.status(joinState: service.joinState, connecting: service.connecting,
                                             reconnecting: reconnecting) { return words }
        if remotes.isEmpty { return GroupCallWords.alone(ringing: service.ringingNames(at: now)) }
        return nil
    }

    private var card: some View {
        Group {
            if let shown = picked {
                videoCard(shown.track, id: shown.id)
            } else if stageLabel(at: Date()) != nil {
                waitingCard
            } else {
                facesCard
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func videoCard(_ track: VideoTrack, id: String) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
            SwiftUIVideoView(track, layoutMode: .fill)
                .id(id)   // a new speaker is a new view, never the old one's last frame
                .frame(width: w, height: h)
                .clipped()
            countPill.padding(.bottom, 8)
        }
    }

    /// Nobody else connected yet, or the call is not simply running: a face and the header's line.
    /// On a clock, because "Ringing…" ends by time alone.
    private var waitingCard: some View {
        VStack(spacing: 10) {
            face(uid: firstOtherUid, fallbackName: service.callTitle, size: 54, speaking: false)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(stageLabel(at: ctx.date) ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2).minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .background(Color.black)
    }

    /// Up to two of the others, one panel each, the shape of the connected 1:1 card.
    private var facesCard: some View {
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
