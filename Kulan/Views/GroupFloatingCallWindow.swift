import SwiftUI
import LiveKit

// The minimized MULTI-PERSON call (group, ad-hoc or link): the same floating card a minimized 1:1
// call gets, replacing the green full-width "Return to call" bar (owner, 2026-10-04: "group call is
// using old UI"). Same size, corner, border and shadow as `FloatingCallWindow`, same rules: no
// buttons on it, tap goes back to the call.
//
// ⛔ THE SAME MOVEMENT AS THE 1:1 CARD, FROM THE SAME CODE — owner 2026-10-28: this card "is full of
// lag" while the 1:1 card is smooth and tucks into the screen edge. It had its own simpler drag (no
// tab, no pinch, no overshoot) on a view that also observed the group call service, the room and the
// social state, so every publish during a call (speakers, levels, people coming and going) re-ran the
// view under the finger. Now `FloatingCardShell` moves it, the 1:1 card's own code, with its place
// in `GroupFloatingCardSpot` (kept across minimizes, cleared when the call ends). The observing
// lives only in `GroupFloatingCardContent`, which the shell never re-runs while dragging, and whose
// redraws on a publish never touch the shell.
//
// Owner, 2026-10-06 (group call build plan, the screen package), both as the reference app's card:
// - the card shows whoever is SPEAKING (it showed the alphabetically first camera); 2026-10-07 it
//   became one person always, camera or not, see `picked`;
// - it moves up when the keyboard would cover it and goes back when the keyboard leaves (the
//   shell's `avoidsKeyboard`, on for this card only).
struct GroupFloatingCallWindow: View {
    var body: some View {
        FloatingCardShell(spot: GroupFloatingCardSpot.shared, avoidsKeyboard: true, onTap: {
            Self.cardTapped()
        }, card: {
            GroupFloatingCardContent(framed: true)
        }, picture: {
            // The bare picture the edge tab blurs (no corner, border or shadow; the tab cuts its own).
            GroupFloatingCardContent(framed: false)
        })
        .accessibilityLabel("Back to the call")
    }

    /// Audit M-146, 2026-10-07: a tap while the call is already over or being left (the card can
    /// outlive it for a moment) did the restore into a dead call. Ignored then.
    /// CallContainer re-presents GroupCallView when `minimized` clears, through the morph, the 1:1
    /// card's way: the screen grows out of this card over 0.35s instead of cutting straight in
    /// (owner, 2026-10-07).
    private static func cardTapped() {
        let service = GroupCallService.shared
        // `connecting` too (verifier V4): F8 shows this card for a call minimized while still
        // connecting (M-087), and a tap there must bring that call back, not do nothing.
        guard service.isActive || service.connecting, !service.leaving else { return }
        CallPipMorph.restore { service.minimized = false }
    }
}

/// What the group card shows: one person (camera or face) or the call's waiting words. The ONLY
/// part of the card that watches the group call, so a publish redraws this and nothing that moves.
/// Its size follows the pinch step in `GroupFloatingCardSpot` (112x199 times the step).
private struct GroupFloatingCardContent: View {
    /// true = the finished card (corner, border, shadow); false = the bare picture for the edge tab.
    let framed: Bool

    @ObservedObject private var service = GroupCallService.shared
    @ObservedObject private var room = GroupCallService.shared.room
    /// Audit M-026, 2026-10-07: the quick reconnect's flag (`GroupCallSocial.quickReconnecting`).
    @ObservedObject private var social = GroupCallSocial.shared

    private var w: CGFloat { 112 * GroupFloatingCardSpot.shared.cardScale }
    private var h: CGFloat { 199 * GroupFloatingCardSpot.shared.cardScale }   // 9:16, the 1:1 card's shape

    /// Whose camera the card showed last (their identity), kept while they are quiet.
    @State private var shownId: String?

    var body: some View {
        Group {
            if framed { card } else { picture }
        }
        .onAppear { shownId = pickedId }
        .onChange(of: pickedId) { _, id in
            if let id { shownId = id }
        }
    }

    /// Audit M-026, 2026-10-07: either kind of reconnect, the call screen's own reading.
    private var reconnecting: Bool {
        room.connectionState == .reconnecting
            || (room.connectionState != .disconnected && social.quickReconnecting)
            || service.rejoining   // controls 7: the automatic rejoin after a lost connection
    }

    // MARK: - Content

    private var remotes: [RemoteParticipant] {
        room.remoteParticipants.values.sorted { ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "") }
    }

    private static func key(_ p: Participant) -> String { p.identity?.stringValue ?? "" }

    /// One person on the card, and their camera if it is on (nil track = draw their face).
    private struct Pick { let id: String; let track: VideoTrack? }

    /// Who fills the card. The reference app's rule (owner, 2026-10-07, "make it like" it, for 2, 3
    /// or 10 people alike): ONE person, the last one who SPOKE, camera on or not. Its card never
    /// splits into faces and carries no count; a speaker with the camera off is their photo on
    /// their profile colour, the call screen's own camera-off tile.
    /// - someone speaking: the person on the card keeps it while they are among the speakers (two
    ///   people talking at once do not make it cut back and forth), else the loudest takes it;
    /// - a quiet moment: the one shown last stays;
    /// - nobody has spoken yet: the first live camera, else the first person.
    /// Nobody else here: my own camera if it is on (owner, 2026-10-07: a link call minimized with the
    /// camera on showed a black card), else nil and the card shows the call's waiting words.
    private var picked: Pick? {
        let others = remotes
        guard let firstOther = others.first else {
            let me = room.localParticipant
            if service.cameraOn, let mine = me.firstCameraVideoTrack { return Pick(id: Self.key(me), track: mine) }
            return nil
        }
        func pick(_ p: RemoteParticipant) -> Pick { Pick(id: Self.key(p), track: p.firstCameraVideoTrack) }
        let speaking = room.activeSpeakers.compactMap { $0 as? RemoteParticipant }   // loudest first
        let shown = shownId.flatMap { id in others.first { Self.key($0) == id } }
        if let shown, speaking.contains(where: { Self.key($0) == Self.key(shown) }) { return pick(shown) }
        if let loudest = speaking.first { return pick(loudest) }
        if let shown { return pick(shown) }
        return pick(others.first { $0.firstCameraVideoTrack != nil } ?? firstOther)
    }
    private var pickedId: String? { picked?.id }

    /// The call screen's own words (`GroupCallWords`), so minimizing never renames the stage.
    private func stageLabel(at now: Date) -> String? {
        if let words = GroupCallWords.status(joinState: service.joinState, connecting: service.connecting,
                                             reconnecting: reconnecting) { return words }
        if remotes.isEmpty { return GroupCallWords.alone(ringing: service.ringingNames(at: now)) }
        return nil
    }

    /// The picture alone at card size: what the edge tab shows blurred, and what `card` frames.
    private var picture: some View {
        Group {
            if let shown = picked {
                personCard(shown)
            } else {
                waitingCard
            }
        }
        .animation(GroupCallMotion.fade, value: pickedId)   // a new speaker cross-fades in
        .frame(width: w, height: h)
    }

    private var card: some View {
        picture
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    /// The one person: their camera filling the card, or with it off their photo centred on their
    /// profile colour (`TileBackdrop`, the call screen's camera-off tile, so minimizing keeps the look).
    /// Avatar = card width - 36, the reference app's size for a card this narrow.
    private func personCard(_ shown: Pick) -> some View {
        ZStack {
            if let track = shown.track {
                Color.black
                SwiftUIVideoView(track, layoutMode: .fill)
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                let m = service.members.first { $0.uid == shown.id }
                // Audit round 2 (verifier V4, M-079): no member entry (group-chat and link calls)
                // = the stage's own profile lookup, so the card shows the face the screen does.
                let peer = m == nil ? GroupCallStage.peerForCard(shown.id) : nil
                let photo = m?.photoUrl ?? peer?.photo
                TileBackdrop(photoUrl: photo)
                AvatarView(name: displayName(shown.id, member: m, peer: peer), photoUrl: photo, size: w - 36)
            }
        }
        .id(shown.id)   // a new speaker is a new view, never the old one's last frame or colour
        .frame(width: w, height: h)
        // Audit M-026, 2026-10-07: a quick reconnect keeps everyone in the room, so the card kept
        // showing a person over a frozen call with nothing said. The header's word, small.
        .overlay(alignment: .bottom) {
            if reconnecting {
                Text("Reconnecting…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .transition(.opacity)
    }

    /// The name the call screen gives this person (`GroupCallStage`): the room's (unless it is the
    /// server's "Member" placeholder), the member's, the profile store's, then the room's anyway.
    private func displayName(_ id: String, member: CallMember?,
                             peer: (name: String, photo: String?)?) -> String {
        let p = room.remoteParticipants.values.first { Self.key($0) == id }
        if let n = p?.name, !n.isEmpty, n != "Member" { return n }
        if let n = member?.name, !n.isEmpty { return n }
        if let n = peer?.name, !n.isEmpty { return n }
        return "Member"
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

// MARK: - Call doors (group call overhaul A2/A3, 2026-10-23)

/// What a group call door (chat header, Join bar, group page, Calls tab) does when tapped.
enum GroupCallDoor { case open, restore, busy }

extension GroupCallService {
    /// ⛔ EVERY DOOR ASKS THIS BEFORE IT PUTS A CALL SCREEN UP. `start()` returns silently while a
    /// call is up or joining, so a door that opened its own cover first showed the OTHER group's
    /// call under this group's tap (A2), or a second screen over my own minimized call (A3).
    /// Same group = bring my call back (`restoreCall`); anything else running = "already on a call".
    /// Lives here, in a view file, so the service file stays with its own agent.
    func door(for cid: String) -> GroupCallDoor {
        let mine = activeCid == cid || (activeCid == nil && connecting && ringIsMine(roomId: cid, callerUid: ""))
        if mine && !leaving { return .restore }
        if activeCid != nil || connecting || waitingForApproval { return .busy }
        let s = CallService.shared.state
        if s == .outgoing || s == .incoming || s == .active || s == .reconnecting { return .busy }
        return .open
    }

    /// My call back on screen through the one restore path (the floating card's tap): clearing
    /// `minimized` makes `CallContainer` present the call screen. No second cover.
    func restoreCall() {
        guard minimized else { return }
        CallPipMorph.restore { minimized = false }
    }
}
