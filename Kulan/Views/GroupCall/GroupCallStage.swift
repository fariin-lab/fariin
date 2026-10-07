import SwiftUI
import Combine
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
    /// Audit M-026, 2026-10-07: the SDK's quick reconnect, which keeps `connectionState` at
    /// `.connected` (`GroupCallSocial.quickReconnecting`, mirrored here so the views can watch it).
    @Published private(set) var quickReconnecting = false
    /// What every "Reconnecting…" reads: a full reconnect or a quick one.
    var isReconnecting: Bool { connectionState == .reconnecting || quickReconnecting }
    /// Set by a tile's "Remove…" (long press). The screen asks "Remove <name> from the call?", runs
    /// the service's remove and clears it. Cleared here if that person leaves first.
    @Published var removeCandidate: CallTile?

    /// Who the speaker page shows large (owner, 2026-10-06, the reference app's rule): the active
    /// speaker, the last one while nobody speaks, else the first remote. Not published by itself:
    /// it only moves when `activeSpeakerId` or `tiles` do, and both publish.
    var speakerPageTileId: String? {
        if let id = activeSpeakerId, participants[id] != nil { return id }
        if let id = lastSpeakerId, participants[id] != nil { return id }
        return tiles.first(where: { !$0.isLocal })?.id
    }
    private var lastSpeakerId: String?

    /// Host uids (link creator / group admin / ad-hoc starter). The screen sets it; tiles follow.
    var hostUids: Set<String> = [] {
        didSet { if hostUids != oldValue { refresh() } }
    }

    var inCallCount: Int { tiles.count }

    // Names and photos from the service's member list, keyed by uid (identity = Firebase uid).
    private var profiles: [String: CallMember] = [:]
    // Tile id -> participant, rebuilt with the tiles, for the video track lookups.
    private var participants: [String: Participant] = [:]
    // Join time per tile id: the stable grid order (spec §12, tiles do not jump). The server's join
    // time when LiveKit gives one, so a stage built mid-call (the screen reopened after a minimize)
    // orders the people already there as they really joined; else the first time this phone saw them.
    private var firstSeen: [String: Date] = [:]
    // The service and its room outlive this screen (minimize, reopen), the stage does not: the join
    // order is kept here per room name, so the reopened stage starts from the same order.
    private static var joinOrderCache: (room: String, seen: [String: Date])?
    // When each remote started presenting: with two presenters the newest one takes the stage.
    private var shareStartedAt: [String: Date] = [:]
    // Raw speech per tile id, refreshed on every tick and never published (spec §12: the raw flag
    // flickers, and publishing it would re-render the whole stage several times a second).
    private var speechById: [String: (isSpeaking: Bool, lastSpokeAt: Date?)] = [:]
    private var speakerTracker = GroupCallSpeakerTracker()
    // The grid's cells in cell order, kept between renders so tiles stay put (see gridPlacement).
    private var placedIds: [String] = []
    // The two waiting windows behind `isConnecting` / `videoUnavailable` (owner, 2026-10-06). Phone
    // time only, never the server's join time: a phone whose clock is behind would keep a spinner
    // up for as long as it is behind.
    // When this stage first saw each remote: `.distantPast` for the people already here when the
    // stage was built (they did not just join), now for anyone who arrives after.
    private var arrivedAt: [String: Date] = [:]
    private var firstBuildDone = false
    // Since when a remote's camera has been on with no picture arriving. Only people inside that
    // wait have an entry, so the map is empty on a healthy call. No timer of its own: the 0.25s
    // tick below already re-reads the room, so a window closes within a tick of its deadline.
    private var cameraWaitSince: [String: Date] = [:]
    // Raised hands and role changes arrive from outside the room's own events.
    private var subscriptions: Set<AnyCancellable> = []
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
        if let name = room.name, let cached = Self.joinOrderCache, cached.room == name {
            firstSeen = cached.seen
        }
        // A hand going up or down rebuilds the tiles. The sink runs before the new value is stored
        // (a @Published fires in willSet), so the rebuild is deferred a turn, never run inline.
        GroupCallSocial.shared.$raisedHands
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            .store(in: &subscriptions)
        // Audit M-026, 2026-10-07: a quick reconnect starting or ending. Deferred a turn for the
        // same willSet reason as the hands above.
        GroupCallSocial.shared.$quickReconnecting
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            .store(in: &subscriptions)
        // My role, or anyone's, changed: the long-press menu's Mute / Remove may appear or go. The
        // role is not part of a tile, so the views are told directly.
        GroupCallService.shared.$myRole
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &subscriptions)
        GroupCallService.shared.$rolesVersion
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &subscriptions)
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
    /// `preferScreen: false` = the camera only: the strip shows a presenter who is not the focus as
    /// their face, not a second, unreadable 72pt copy of the screen.
    func videoTrack(_ tileId: String, preferScreen: Bool = true) -> VideoTrack? {
        guard let p = participants[tileId] else { return nil }
        // My own screen is not drawn back to me (a hall of mirrors); my camera is.
        if preferScreen, !(p is LocalParticipant),
           let screen = Self.liveVideo(p.firstScreenSharePublication) { return screen }
        return Self.liveVideo(p.firstCameraPublication)
    }

    /// A video track only while its publication exists, is not muted and holds a track (spec §14:
    /// camera off draws the avatar). A muted track keeps its last frame, so a view attached to it
    /// would show a frozen picture. Every caller (hasVideo, isScreenShare, videoTrack) goes through
    /// here, so a tile's flags and the track it is handed always agree.
    private static func liveVideo(_ pub: TrackPublication?) -> VideoTrack? {
        livePublication(pub)?.track as? VideoTrack
    }

    private static func livePublication(_ pub: TrackPublication?) -> TrackPublication? {
        guard let pub, !pub.isMuted, let track = pub.track, !track.isMuted, track is VideoTrack else { return nil }
        return pub
    }

    /// Live speech for one tile, from the unpublished store (CallTile's == ignores speech).
    func speech(for tileId: String) -> (isSpeaking: Bool, lastSpokeAt: Date?) {
        speechById[tileId] ?? (isSpeaking: false, lastSpokeAt: nil)
    }

    /// `tiles` with the live speech filled in, for the ranking (spec §13 "recently speaking").
    /// Read by the views when they re-render for a real tile change or a new active speaker.
    var tilesWithLiveSpeech: [CallTile] {
        tiles.map { tile in
            var t = tile
            if let s = speechById[t.id] { t.isSpeaking = s.isSpeaking; t.lastSpokeAt = s.lastSpokeAt }
            return t
        }
    }

    /// Who sits in the grid's `capacity` cells, in cell order (spec §12: a tile keeps its cell).
    /// Sticky: a placed person stays until they leave or the cells shrink. Only an active speaker who
    /// is off the grid swaps in, and takes the exact cell of the least important placed person.
    /// Free cells go to the most important unplaced people. The 30s "recently speaking" tier is not
    /// used here: on a big call it would reshuffle the grid every time someone new speaks.
    /// Called from the grid's body; it only mutates this unpublished cache, so no extra render.
    func gridPlacement(_ remotes: [CallTile], capacity: Int) -> [String] {
        guard capacity > 0 else { placedIds = []; return [] }
        let byId = Dictionary(remotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let speaker = activeSpeakerId.flatMap { byId[$0] != nil ? $0 : nil }
        var cells = placedIds.filter { byId[$0] != nil }

        // Fewer cells (the strip appeared, the phone turned): the least important leave first.
        while cells.count > capacity,
              let worst = weakest(cells, byId, keep: speaker), let i = cells.firstIndex(of: worst) {
            cells.remove(at: i)
        }
        // Free cells: the most important unplaced people, added in join order.
        if cells.count < capacity {
            let taken = Set(cells)
            let candidates = remotes.filter { !taken.contains($0.id) }.sorted { a, b in
                let ta = placementTier(a), tb = placementTier(b)
                if ta != tb { return ta < tb }
                let la = a.lastSpokeAt ?? .distantPast, lb = b.lastSpokeAt ?? .distantPast
                if la != lb { return la > lb }
                return GroupCallPriority.joinOrder(a, b)
            }
            cells += GroupCallPriority.stableForGrid(Array(candidates.prefix(capacity - cells.count))).map(\.id)
        }
        // The speaker is off the grid: they take the least important person's cell.
        if let speaker, !cells.contains(speaker),
           let worst = weakest(cells, byId, keep: speaker), let i = cells.firstIndex(of: worst) {
            cells[i] = speaker
        }
        placedIds = cells
        return cells
    }

    /// Spec §13 order for a grid cell, without the "recent" tier: presenter, pinned, speaker,
    /// camera on, audio only.
    private func placementTier(_ t: CallTile) -> Int {
        if t.isScreenShare { return 0 }
        if t.id == pinnedId { return 1 }
        if t.id == activeSpeakerId { return 2 }
        return t.hasVideo ? 3 : 4
    }

    /// The placed person to give up a cell: lowest tier, then the one heard longest ago, then the
    /// latest to join. Never `keep` (the active speaker).
    private func weakest(_ cells: [String], _ byId: [String: CallTile], keep: String?) -> String? {
        cells.compactMap { byId[$0] }.filter { $0.id != keep }.max { a, b in
            let ta = placementTier(a), tb = placementTier(b)
            if ta != tb { return ta < tb }
            let la = a.lastSpokeAt ?? .distantPast, lb = b.lastSpokeAt ?? .distantPast
            if la != lb { return la > lb }
            return GroupCallPriority.joinOrder(a, b)
        }?.id
    }

    func togglePin(_ tileId: String) {
        // My own tile is the self pip; focusing it (my own camera, or my own shared screen, a hall
        // of mirrors) would push everyone else off the stage.
        guard let p = participants[tileId], !(p is LocalParticipant) else { return }
        pinnedId = (pinnedId == tileId) ? nil : tileId
    }

    // MARK: - Long press on a tile (owner, 2026-10-06)

    /// The same access table the people list uses (GroupCallParticipantsSheet.canModerate): never
    /// myself on any of my devices, and only the roles my server-signed role reaches.
    func canModerate(_ tile: CallTile) -> Bool {
        let service = GroupCallService.shared
        guard !tile.isLocal, !tile.uid.isEmpty, tile.uid != service.myUid else { return false }
        // Audit M-072, 2026-10-07 (with fix/F4): a group call's live roles first, as the people list.
        if let live = service.groupRole(of: tile.uid) { return service.myRole.canModerate(live) }
        let attribute = participants[tile.id]?.attributes["role"]
        // No attribute (a server without roles yet): the tile's host mark, itself server-sourced.
        let role: CallRole = (attribute == nil && tile.isHost) ? .owner : CallRole(attribute: attribute)
        return service.myRole.canModerate(role)
    }

    /// What a long press on this tile offers. nil for my own tile (the self pip has no menu).
    func tileMenu(for tile: CallTile) -> CallTileMenu? {
        guard !tile.isLocal else { return nil }
        let id = tile.id
        return CallTileMenu(
            isPinned: pinnedId == id,
            canModerate: canModerate(tile),
            onPin: { [weak self] in
                guard let self else { return }
                self.togglePin(id)
            },
            onMute: { [weak self] in
                guard let self else { return }
                self.mute(tile)
            },
            onRemove: { [weak self] in
                guard let self else { return }
                // The screen confirms before anyone is removed.
                self.removeCandidate = tile
            }
        )
    }

    /// Mute needs no confirmation (the people list asks for none either): straight to the service's
    /// admin function, which the server checks against my role again.
    private func mute(_ tile: CallTile) {
        let uid = tile.uid
        guard !uid.isEmpty else { return }
        Task { @MainActor in
            do { try await GroupCallService.shared.admin(.mute, target: uid) }
            catch { GroupCallService.shared.showToast("Couldn't mute. Try again.") }
        }
    }

    func refreshProfiles(_ members: [CallMember]) {
        var map: [String: CallMember] = [:]
        for m in members { map[m.uid] = m }
        profiles = map
        refresh()
    }

    // Audit M-079, 2026-10-07: names and photos of people in the room who are not on the call's
    // member list (every group-chat and link call). Kept across stages (the screen is rebuilt on
    // every restore from the card); asked at most once per uid per stage.
    private static var peerProfiles: [String: (name: String, photo: String?)] = [:]
    private var peerLookups: Set<String> = []
    /// Sign-out (verifier V4): the photos here passed the OLD account's privacy check, so the
    /// next account on this phone must not see them. Called by `SessionWipe.wipeAccountData`.
    static func clearPeerProfiles() { peerProfiles = [:]; cardLookups = [] }

    /// Audit round 2 (verifier V4, M-079), 2026-10-07: the same lookup for the minimized card,
    /// which has no stage. The cached answer if there is one; otherwise one read per uid (until the
    /// next sign-out) whose answer the card picks up on its next redraw (it redraws with the room).
    private static var cardLookups: Set<String> = []
    static func peerForCard(_ uid: String) -> (name: String, photo: String?)? {
        guard !uid.isEmpty else { return nil }
        if let known = peerProfiles[uid] { return known }
        guard cardLookups.insert(uid).inserted else { return nil }
        Task { @MainActor in
            guard let p = await ProfileStore.shared.fetch(uid) else { return }
            let photo = ProfilePhotoIndex.header(uid: uid, fallbackPhoto: p.photoUrl, fallbackPoster: nil,
                                                 iAmContact: PrivacyPrefs.mayViewPhotoOf(uid)).photoUrl
            peerProfiles[uid] = (name: p.name, photo: photo)
        }
        return nil
    }

    /// What the profile store has for this uid, nil until its one read has answered. The photo
    /// goes through the same privacy answer the chat search uses (`ProfilePhotoIndex.header`).
    private func peerProfile(_ uid: String) -> (name: String, photo: String?)? {
        guard !uid.isEmpty else { return nil }
        if let known = Self.peerProfiles[uid] { return known }
        guard peerLookups.insert(uid).inserted else { return nil }
        Task { @MainActor [weak self] in
            guard let p = await ProfileStore.shared.fetch(uid) else { return }
            let photo = ProfilePhotoIndex.header(uid: uid, fallbackPhoto: p.photoUrl, fallbackPoster: nil,
                                                 iAmContact: PrivacyPrefs.mayViewPhotoOf(uid)).photoUrl
            Self.peerProfiles[uid] = (name: p.name, photo: photo)
            self?.scheduleRefresh()
        }
        return nil
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
            if firstSeen[id] == nil { firstSeen[id] = p.joinedAt ?? now }

            let uid = p.identity?.stringValue ?? ""
            let member = profiles[uid]
            // Audit M-079, 2026-10-07: group-chat and link calls have no member list, so a remote
            // had no photo at all and could be named "Member" (the server's word when it had no
            // name). Such a person is looked up in the app's own profile store, once per uid.
            let looked = (member == nil && !isLocal) ? peerProfile(uid) : nil
            let name: String = {
                if let n = p.name, !n.isEmpty, n != "Member" { return n }
                if let n = member?.name, !n.isEmpty { return n }
                if let n = looked?.name, !n.isEmpty { return n }
                if let n = p.name, !n.isEmpty { return n }
                if isLocal, let n = ProfileStore.shared.me?.name, !n.isEmpty { return n }
                return isLocal ? "You" : "Member"
            }()
            let photo = isLocal ? (ProfileStore.shared.me?.photoUrl ?? member?.photoUrl)
                : (member?.photoUrl ?? looked?.photo)
            let camera = Self.livePublication(p.firstCameraPublication)
            // Screen sharing, 2026-10-07: MY share never marks my own tile as presenting. My screen
            // is not drawn back to me (`videoTrack`), so a presenter flag on my tile would only cost
            // me the two-person view, move my own pip to the front of the grid and auto-focus a big
            // tile of my own camera or avatar. The others see my share; I keep my normal view.
            let screen = isLocal ? nil : Self.livePublication(p.firstScreenSharePublication)
            let sharing = screen != nil
            if sharing, !isLocal, shareStartedAt[id] == nil { shareStartedAt[id] = now; newShare = true }
            // Audit M-136, 2026-10-07: a share ENDS when its publication goes, not when its track
            // blips. A track dropped for a moment (a resubscribe, a quality switch) used to end the
            // share here and "start" it again a tick later, which cleared the viewer's pin and
            // yanked the stage. It still starts only once its picture is really here (above).
            let sharePublished = !isLocal && p.firstScreenSharePublication != nil
            if !sharePublished { shareStartedAt[id] = nil }

            // Media still on its way (the reference app's waiting tile, then its error tile).
            // Remotes only: my own camera has no wait to show me.
            if arrivedAt[id] == nil {
                let firstSight: Date = firstBuildDone ? now : Date.distantPast
                arrivedAt[id] = firstSight
            }
            var connecting = false
            var unavailable = false
            if !isLocal {
                if let pub = p.firstCameraPublication, !pub.isMuted, pub.track == nil {
                    // Their camera is on (a remote publication with no track reads the server's
                    // mute flag) and no picture has arrived: a spinner, then "Can't show video".
                    let since = cameraWaitSince[id] ?? now
                    cameraWaitSince[id] = since
                    if now.timeIntervalSince(since) < GroupCallMetrics.videoGrace {
                        connecting = true
                    } else {
                        unavailable = true
                    }
                } else {
                    cameraWaitSince[id] = nil
                    // Just joined and nothing published yet: their media is still arriving.
                    let arrived: Date = arrivedAt[id] ?? Date.distantPast
                    if p.trackPublications.isEmpty,
                       now.timeIntervalSince(arrived) < GroupCallMetrics.joinGrace {
                        connecting = true
                    }
                }
            }
            // Never on my own tile: I know my hand is up, and the pip is too small to say it.
            let handRaised = !isLocal && !uid.isEmpty && GroupCallSocial.shared.isHandRaised(uid)

            built.append(CallTile(
                id: id,
                uid: uid,
                name: name,
                photoUrl: photo,
                isLocal: isLocal,
                hasVideo: camera != nil,
                isScreenShare: sharing,
                isMuted: !p.isMicrophoneEnabled(),
                isSpeaking: p.isSpeaking,
                lastSpokeAt: p.lastSpokeAt,
                joinedAt: firstSeen[id] ?? now,
                networkPoor: p.connectionQuality == .poor || p.connectionQuality == .lost,
                isHost: !uid.isEmpty && hostUids.contains(uid),
                cameraTrackSid: camera?.sid.stringValue,
                screenTrackSid: screen?.sid.stringValue,
                isConnecting: connecting,
                videoUnavailable: unavailable,
                isHandRaised: handRaised
            ))
        }
        firstBuildDone = true

        // Stable order: me first, then everyone by join time (the room's dictionary has no order,
        // and a reshuffle every tick would move tiles around). Equal times (the server's are whole
        // seconds) fall back to identity, the same on every phone and across a reopen.
        built.sort { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            return GroupCallPriority.joinOrder(a, b)
        }

        // Forget people who left, so the maps do not grow over a long call. Only while connected: a
        // full reconnect empties the room and refills it, and pruning then would hand everyone a new
        // first-seen time and reshuffle the grid when they come back (spec §12).
        let present = Set(byId.keys)
        if connectionState == .connected {
            firstSeen = firstSeen.filter { present.contains($0.key) }
        }
        if let name = room.name, !name.isEmpty { Self.joinOrderCache = (name, firstSeen) }
        shareStartedAt = shareStartedAt.filter { present.contains($0.key) }
        // Someone who left takes their waiting window with them (nothing is left counting).
        arrivedAt = arrivedAt.filter { present.contains($0.key) }
        cameraWaitSince = cameraWaitSince.filter { present.contains($0.key) }
        participants = byId
        // Before `tiles` publishes, so a re-render reads this tick's speech.
        var speech: [String: (isSpeaking: Bool, lastSpokeAt: Date?)] = [:]
        for t in built { speech[t.id] = (t.isSpeaking, t.lastSpokeAt) }
        speechById = speech

        // CallTile's == ignores speech: a speaking flag alone publishes nothing (spec §12).
        if built != tiles { tiles = built }
        if let pin = pinnedId, !present.contains(pin) { pinnedId = nil }   // didSet updates mode
        // A share that just started takes the stage over an older pin (the latest thing wins).
        if newShare, pinnedId != nil { pinnedId = nil }
        // The person behind an open "Remove?" question left by themselves: nothing left to confirm.
        if let candidate = removeCandidate, !present.contains(candidate.id) { removeCandidate = nil }

        // Spec §8: the highlight follows the tracker (0.3s to take over, 1.5s hold), not the raw flag.
        // Remotes only: my own voice would hold the highlight while I talk, so nobody answering me
        // could take it, and my tile is the self pip, which never shows the ring anyway.
        // Audit M-137, 2026-10-07: only while really connected, and never a muted tile. The raw
        // flag can stay true through a reconnect (no audio arrives to clear it), which froze the
        // highlight on whoever spoke last before the blip.
        let live = connectionState == .connected && !quickReconnecting
        let speaking: Set<String> = live
            ? Set(built.filter { $0.isSpeaking && !$0.isLocal && !$0.isMuted }.map(\.id))
            : []
        _ = speakerTracker.update(speaking: speaking, now: now)
        let speaker = speakerTracker.activeSpeakerId.flatMap { present.contains($0) ? $0 : nil }
        // Remembered for the speaker page, which keeps the last speaker large through a silence.
        // Before `activeSpeakerId` publishes, so the re-render it causes reads this tick's value.
        if let speaker {
            lastSpeakerId = speaker
        } else if let last = lastSpeakerId, !present.contains(last) {
            lastSpeakerId = nil
        }
        if speaker != activeSpeakerId { activeSpeakerId = speaker }

        updateMode()
    }

    /// The user's pin, then the presenter (a shared screen is what the room is looking at), else grid.
    /// The pin goes first so a tap on the strip or the people list during a share does show that
    /// person; a share that starts later clears the pin in `refresh()`, so it still takes over.
    private func updateMode() {
        let presenter = shareStartedAt.max { $0.value < $1.value }?.key
        let next: CallStageMode
        // Never the local tile, however pinnedId was set (togglePin refuses it; this is the backstop).
        if let pin = pinnedId, let p = participants[pin], !(p is LocalParticipant) {
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
        let quick = state != .disconnected && GroupCallSocial.shared.quickReconnecting
        if quick != quickReconnecting { quickReconnecting = quick }
        // The tick has nothing to watch in a closed room; it comes back if the room reconnects.
        if state == .disconnected { stopTimer() } else { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            // A Void body: `{ self?.refresh() }` returned `Void?`, an unused-result warning.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
            }
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
