import SwiftUI
import LiveKit

// The live model behind the group call stage (owner spec §8-16): turns the LiveKit room into
// `[CallTile]`, decides grid vs focus, and holds the active speaker steady. Every view piece reads
// this one object, so the room is walked in one place and the views stay dumb.
//
// Two feeds keep it live: room delegate events (join, leave, publish, mute, quality, connection)
// for an immediate update, and a 0.25s tick for what LiveKit only exposes as polled state
// (isSpeaking, lastSpokeAt) and for the speaker hold, which needs time to pass even when no event
// arrives. Both end in `refresh()`, which only publishes what actually changed (spec §12: a speaking
// flag must not re-render a grid whose tiles did not change).
@MainActor
final class GroupCallStage: ObservableObject {
    let room: Room

    @Published private(set) var tiles: [CallTile] = []
    @Published private(set) var activeSpeakerId: String?
    /// The user's focus (tap a tile). Cleared when that person leaves.
    @Published var pinnedId: String? {
        didSet { if pinnedId != oldValue { updateMode() } }
    }
    @Published private(set) var mode: CallStageMode = .grid
    /// Mirrors `room.connectionState` for the status banner (spec §14: reconnecting / lost).
    @Published private(set) var connectionState: ConnectionState

    /// Host uids (link creator / group admin / ad-hoc starter). The screen sets it; tiles follow.
    var hostUids: Set<String> = [] {
        didSet { if hostUids != oldValue { refresh() } }
    }

    var inCallCount: Int { tiles.count }

    // Names and photos from the service's member list, keyed by uid (identity = Firebase uid).
    private var profiles: [String: CallMember] = [:]
    // Tile id -> participant, rebuilt with the tiles, for the video track lookups.
    private var participants: [String: Participant] = [:]
    // First time this phone saw each tile id: the stable grid order (spec §12, tiles do not jump).
    private var firstSeen: [String: Date] = [:]
    // When each remote started presenting: with two presenters the newest one takes the stage.
    private var shareStartedAt: [String: Date] = [:]
    private var speakerTracker = GroupCallSpeakerTracker()
    private var refreshScheduled = false
    // nonisolated(unsafe) on these two: only touched on the main thread, but deinit is nonisolated.
    nonisolated(unsafe) private var observer: StageRoomObserver?
    nonisolated(unsafe) private var timer: Timer?

    init(room: Room) {
        self.room = room
        self.connectionState = room.connectionState
        let observer = StageRoomObserver(
            onChange: { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        )
        self.observer = observer
        room.delegates.add(delegate: observer)
        refresh()   // also starts the tick unless the room is closed
    }

    deinit {
        timer?.invalidate()
        if let observer { room.delegates.remove(delegate: observer) }
    }

    // MARK: - Public API

    func participant(_ tileId: String) -> Participant? { participants[tileId] }

    /// The presenter's screen when they share (it is what they want seen), else the camera.
    /// nil = draw the avatar, so adaptiveStream stops that video (contract rule).
    func videoTrack(_ tileId: String) -> VideoTrack? {
        guard let p = participants[tileId] else { return nil }
        // My own screen is not drawn back to me (a hall of mirrors); my camera is.
        if !(p is LocalParticipant), let screen = Self.liveVideo(p.firstScreenSharePublication) { return screen }
        return Self.liveVideo(p.firstCameraPublication)
    }

    /// A video track only while its publication exists, is not muted and holds a track (spec §14:
    /// camera off draws the avatar). A muted track keeps its last frame, so a view attached to it
    /// would show a frozen picture. Every caller (hasVideo, isScreenShare, videoTrack) goes through
    /// here, so a tile's flags and the track it is handed always agree.
    private static func liveVideo(_ pub: TrackPublication?) -> VideoTrack? {
        guard let pub, !pub.isMuted, let track = pub.track, !track.isMuted else { return nil }
        return track as? VideoTrack
    }

    func togglePin(_ tileId: String) {
        guard participants[tileId] != nil else { return }
        pinnedId = (pinnedId == tileId) ? nil : tileId
    }

    func refreshProfiles(_ members: [CallMember]) {
        var map: [String: CallMember] = [:]
        for m in members { map[m.uid] = m }
        profiles = map
        refresh()
    }

    // MARK: - Building the tiles

    /// Many delegate events arrive in a burst (a join brings publish + subscribe + quality); one
    /// rebuild covers them all.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        syncConnectionState()
        let now = Date()

        var all: [Participant] = [room.localParticipant]
        all.append(contentsOf: room.remoteParticipants.values.map { $0 as Participant })

        var built: [CallTile] = []
        var byId: [String: Participant] = [:]
        var newShare = false
        for p in all {
            let isLocal = p is LocalParticipant
            // Before connect the local participant has no sid yet; "local" keeps my own tile on
            // screen while joining (spec §14) instead of an empty stage. A remote always has one.
            guard let id = p.sid?.stringValue ?? (isLocal ? "local" : nil) else { continue }
            byId[id] = p
            if firstSeen[id] == nil { firstSeen[id] = now }

            let uid = p.identity?.stringValue ?? ""
            let member = profiles[uid]
            let name: String = {
                if let n = p.name, !n.isEmpty { return n }
                if let n = member?.name, !n.isEmpty { return n }
                if isLocal, let n = ProfileStore.shared.me?.name, !n.isEmpty { return n }
                return isLocal ? "You" : "Member"
            }()
            let photo = isLocal ? (ProfileStore.shared.me?.photoUrl ?? member?.photoUrl) : member?.photoUrl
            let sharing = Self.liveVideo(p.firstScreenSharePublication) != nil
            if sharing, !isLocal, shareStartedAt[id] == nil { shareStartedAt[id] = now; newShare = true }
            if !sharing { shareStartedAt[id] = nil }

            built.append(CallTile(
                id: id,
                uid: uid,
                name: name,
                photoUrl: photo,
                isLocal: isLocal,
                hasVideo: Self.liveVideo(p.firstCameraPublication) != nil,
                isScreenShare: sharing,
                isMuted: !p.isMicrophoneEnabled(),
                isSpeaking: p.isSpeaking,
                lastSpokeAt: p.lastSpokeAt,
                joinedAt: firstSeen[id] ?? now,
                networkPoor: p.connectionQuality == .poor || p.connectionQuality == .lost,
                isHost: !uid.isEmpty && hostUids.contains(uid)
            ))
        }

        // Stable order: me first, then everyone in the order this phone first saw them (the room's
        // dictionary has no order, and a reshuffle every tick would move tiles around).
        built.sort { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            if a.joinedAt != b.joinedAt { return a.joinedAt < b.joinedAt }
            return a.id < b.id
        }

        // Forget people who left, so the maps do not grow over a long call.
        let present = Set(byId.keys)
        firstSeen = firstSeen.filter { present.contains($0.key) }
        shareStartedAt = shareStartedAt.filter { present.contains($0.key) }
        participants = byId

        if built != tiles { tiles = built }
        if let pin = pinnedId, !present.contains(pin) { pinnedId = nil }   // didSet updates mode
        // A share that just started takes the stage over an older pin (the latest thing wins).
        if newShare, pinnedId != nil { pinnedId = nil }

        // Spec §8: the highlight follows the tracker (0.3s to take over, 1.5s hold), not the raw flag.
        let speaking = Set(built.filter(\.isSpeaking).map(\.id))
        _ = speakerTracker.update(speaking: speaking, now: now)
        let speaker = speakerTracker.activeSpeakerId.flatMap { present.contains($0) ? $0 : nil }
        if speaker != activeSpeakerId { activeSpeakerId = speaker }

        updateMode()
    }

    /// The user's pin, then the presenter (a shared screen is what the room is looking at), else grid.
    /// The pin goes first so a tap on the strip or the people list during a share does show that
    /// person; a share that starts later clears the pin in `refresh()`, so it still takes over.
    private func updateMode() {
        let presenter = shareStartedAt.max { $0.value < $1.value }?.key
        let next: CallStageMode
        if let pin = pinnedId, participants[pin] != nil {
            next = .focus(tileId: pin)
        } else if let presenter, participants[presenter] != nil {
            next = .focus(tileId: presenter)
        } else {
            next = .grid
        }
        if next != mode { mode = next }
    }

    // MARK: - Connection state and the tick

    private func syncConnectionState() {
        let state = room.connectionState
        if state != connectionState { connectionState = state }
        // The tick has nothing to watch in a closed room; it comes back if the room reconnects.
        if state == .disconnected { stopTimer() } else { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common: keeps ticking while a list in the call screen is being scrolled.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// RoomDelegate is an @objc protocol called off the main thread, so a plain NSObject receives the
/// events and hands one "something changed" to the stage on the main actor. The room holds its
/// delegates weakly; the stage owns this object.
private final class StageRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState,
              from oldConnectionState: ConnectionState) { onChange() }
    // A quick reconnect does not report through didUpdateConnectionState.
    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) { onChange() }
    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) { onChange() }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) { onChange() }
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { onChange() }
    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { onChange() }
    func room(_ room: Room, participant: Participant, didUpdateName name: String) { onChange() }
    func room(_ room: Room, participant: Participant,
              didUpdateConnectionQuality quality: ConnectionQuality) { onChange() }

    func room(_ room: Room, participant: LocalParticipant,
              didPublishTrack publication: LocalTrackPublication) { onChange() }
    func room(_ room: Room, participant: LocalParticipant,
              didUnpublishTrack publication: LocalTrackPublication) { onChange() }
    func room(_ room: Room, participant: RemoteParticipant,
              didPublishTrack publication: RemoteTrackPublication) { onChange() }
    func room(_ room: Room, participant: RemoteParticipant,
              didUnpublishTrack publication: RemoteTrackPublication) { onChange() }
    func room(_ room: Room, participant: RemoteParticipant,
              didSubscribeTrack publication: RemoteTrackPublication) { onChange() }
    func room(_ room: Room, participant: RemoteParticipant,
              didUnsubscribeTrack publication: RemoteTrackPublication) { onChange() }
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication,
              didUpdateIsMuted isMuted: Bool) { onChange() }
}
