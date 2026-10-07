import Foundation
import SwiftUI
import UIKit

// GROUP CALL DEMO ENGINE (owner, 2026-10-07): the whole simulated call in one @MainActor object.
//
// What is REAL here: `CallTile` (the stage's value type), `CallRole` and its access table,
// `GroupCallSpeakerTracker` (who is the active speaker, with the 0.3s qualify and 1.5s hold),
// `GroupCallPriority` and `GroupCallLayoutEngine` (who gets a cell, the grid maths). The views call
// the last two; this engine feeds the tracker on every tick, exactly as `GroupCallStage.refresh()`
// does with a LiveKit room.
//
// What is a TWIN: `gridPlacement` and `speakerPageTileId`. In production they are methods of
// `GroupCallStage`, which cannot be built without a LiveKit `Room`, so their logic is copied here
// line for line. If the stage's copy changes, change this one too.
//
// What is SIMULATED: everything that would come from the network. Each person talks in bursts with
// pauses (the raw flag flickers inside a burst, as LiveKit's does), joins with a short "media still
// arriving" spinner, can go poor -> lost -> back, and every scenario runs through `setState(_:)` and
// the same depart / join paths, so nothing is a view-only fake.
//
// Time is simulated: `simNow` advances 0.1s x speed on every 10 Hz tick, and every date the engine
// hands out (join times, last spoke, the tracker's clock) is `simEpoch + simNow`, so 3x speed is
// 3x faster for every rule at once, the tracker's hold included.

@MainActor
final class DemoGroupCallEngine: ObservableObject {

    // MARK: Published state

    @Published private(set) var state: DemoCallState = .idle
    @Published private(set) var endReason: DemoEndReason?
    /// Everyone but me, people still being rung included.
    @Published private(set) var people: [DemoPerson] = []
    /// The stage's tiles, me included (`id == Self.localId`). Speech is not part of `==`.
    @Published private(set) var tiles: [CallTile] = []
    /// The tracker's held speaker, remotes only.
    @Published private(set) var activeSpeakerId: String?
    /// The raw speaking set (flickers), for the people list's live indicator.
    @Published private(set) var speakingIds: Set<String> = []
    @Published private(set) var pinnedId: String?
    @Published private(set) var mode: CallStageMode = .grid
    @Published private(set) var log: [DemoLogEntry] = []
    @Published private(set) var toast: String?
    @Published private(set) var departed: [DemoPerson] = []
    /// A Remove / Remove and Block waiting for the screen's confirm (the stage's `removeCandidate`).
    /// Cleared by `rebuild()` if that person leaves before the answer.
    @Published var removalRequest: DemoRemoval?

    // Me.
    @Published private(set) var micOn = true
    @Published private(set) var cameraOn = false
    @Published private(set) var isVideoCall = true
    @Published private(set) var frontCamera = true
    @Published private(set) var handRaised = false
    @Published private(set) var iAmOwner = false
    @Published private(set) var connectedAt: Date?

    // Scenario switches.
    @Published private(set) var speed: Double = 1
    @Published private(set) var callFullOnJoin = false

    /// The admin's display name is the real username, always; the photo comes from the lookup.
    static let ownerHandle = "realwarya"
    static let localId = "local"
    @Published private(set) var ownerPhotoUrl: String?

    // MARK: Private state

    private var simNow: TimeInterval = 0
    private let simEpoch = Date()
    var now: Date { simEpoch.addingTimeInterval(simNow) }

    private var voices: [String: DemoVoice] = [:]
    private var speechById: [String: (isSpeaking: Bool, lastSpokeAt: Date?)] = [:]
    private var tracker = GroupCallSpeakerTracker()
    private var lastSpeakerId: String?
    private var placedIds: [String] = []
    private var pending: [DemoPending] = []
    private var tickTask: Task<Void, Never>?
    private var toastSeq = 0
    private var blockedUids: Set<String> = []
    private var nextPersonNumber = 1
    private var myJoinedAt = Date()
    private var reconnectGen = 0

    /// Letter avatars for the simulated people (no photos: clearly stand-ins).
    private static let namePool = [
        "Amina Yusuf", "Hodan Ali", "Khadar Omar", "Ifrah Hassan", "Mahad Abdi", "Sagal Warsame",
        "Liban Farah", "Nimco Jama", "Abdirahman Noor", "Fartun Ahmed", "Bashir Aden",
        "Ilhan Mohamed", "Yasmin Hirsi", "Guled Ismail"
    ]

    /// Seconds (simulated) a lost participant gets to come back before they are dropped.
    static let lostTimeout: TimeInterval = 10
    /// Seconds (simulated) my own reconnect is given before the call ends.
    static let myReconnectTimeout: TimeInterval = 12
    /// The real ring window.
    static let ringWindow: TimeInterval = 30

    init() {
        record("Demo ready. Pick a preset in Scenarios.", .event)
    }

    // MARK: - Derived

    var myRole: CallRole { iAmOwner ? .owner : .participant }
    var ownerName: String { Self.ownerHandle }

    var myName: String {
        let name = ProfileStore.shared.me?.name ?? ""
        return name.isEmpty ? "You" : name
    }

    var myPhotoUrl: String? { ProfileStore.shared.me?.photoUrl }

    var inCall: [DemoPerson] { people.filter { $0.link != .ringing } }
    var ringing: [DemoPerson] { people.filter { $0.link == .ringing } }
    var remoteCount: Int { tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 } }
    var inCallCount: Int { tiles.count }

    /// `tiles` with the live speech filled in, for the ranking (the stage's same property).
    var tilesWithLiveSpeech: [CallTile] {
        tiles.map { tile in
            var t = tile
            if let s = speechById[t.id] { t.isSpeaking = s.isSpeaking; t.lastSpokeAt = s.lastSpokeAt }
            return t
        }
    }

    func person(_ id: String) -> DemoPerson? { people.first { $0.id == id } }

    func level(_ id: String) -> Double { voices[id]?.level ?? 0 }

    /// TWIN of `GroupCallStage.speakerPageTileId`.
    var speakerPageTileId: String? {
        let present = Set(tiles.map(\.id))
        if let id = activeSpeakerId, present.contains(id) { return id }
        if let id = lastSpeakerId, present.contains(id) { return id }
        return tiles.first(where: { !$0.isLocal })?.id
    }

    // MARK: - Lifecycle

    func loadOwnerProfile() async {
        guard let profile = await ChatService.findByHandle(Self.ownerHandle, allowSelf: true) else {
            record("Profile lookup for \(Self.ownerHandle) failed: letter avatar used", .warning)
            return
        }
        let photo = profile.photoUrl ?? profile.photoThumb
        ownerPhotoUrl = photo
        for i in people.indices where people[i].uid == Self.ownerUid { people[i].photoUrl = photo }
        record("Profile lookup for \(Self.ownerHandle): \(photo == nil ? "no photo" : "photo found")", .event)
        rebuild()
    }

    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func startClock() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    // MARK: - State machine

    /// The only way `state` changes (Reset aside). Refused transitions are logged, not applied.
    @discardableResult
    private func setState(_ next: DemoCallState) -> Bool {
        guard next != state else { return true }
        guard state.allowed.contains(next) else {
            record("REFUSED state change \(state.rawValue) -> \(next.rawValue)", .warning)
            return false
        }
        record("State: \(state.rawValue) -> \(next.rawValue)", .state)
        state = next
        if next == .connected, connectedAt == nil { connectedAt = now }
        return true
    }

    /// Ringing vs connected while the call is up: anyone in the room = connected; nobody in the
    /// room but someone ringing = ringing; nobody at all = connected and alone.
    private func settleState() {
        guard state.isLive else { return }
        if !inCall.isEmpty { setState(.connected) }
        else if !ringing.isEmpty { setState(.ringing) }
        else if state == .ringing { setState(.connected) }
    }

    private func end(_ reason: DemoEndReason) {
        guard state != .ended else { return }
        guard setState(.ended) else { return }
        endReason = reason
        record("Ended: \(reason.title). \(reason.message)", .state)
        pending.removeAll()
        pinnedId = nil
        removalRequest = nil
        tracker = GroupCallSpeakerTracker()
        activeSpeakerId = nil
        speakingIds = []
        handRaised = false
        shutdown()
    }

    // MARK: - Starting

    /// Preset: join a call that is already running with `total` people in it, me included.
    func startPreset(total: Int) {
        resetState(keepLog: true)
        record("Preset: \(total) participants (joining a running call)", .event)
        let others = max(1, total - 1)
        for i in 0..<others {
            var p = makePerson(owner: i == 0)
            p.joinedAt = now.addingTimeInterval(-Double(others - i) * 30)
            p.cameraOn = Double.random(in: 0...1) < (others > 4 ? 0.45 : 0.6)
            p.micOn = Double.random(in: 0...1) < (others > 4 ? 0.55 : 0.9)
            p.link = .connecting
            people.append(p)
        }
        beginConnecting()
    }

    /// Ringing scenario: I start the call and ring three people. Two answer, one declines.
    func startRinging() {
        resetState(keepLog: true)
        record("Scenario: I start a call and ring 3 people", .event)
        for i in 0..<3 {
            var p = makePerson(owner: i == 0)
            p.link = .ringing
            people.append(p)
        }
        beginConnecting()
    }

    private func beginConnecting() {
        myJoinedAt = now
        cameraOn = isVideoCall
        setState(.connecting)
        startClock()
        schedule(.connectDone, after: 1.2)
        rebuild()
    }

    private func makePerson(owner: Bool) -> DemoPerson {
        let n = nextPersonNumber
        nextPersonNumber += 1
        if owner {
            return DemoPerson(id: "PA_owner_\(n)", uid: Self.ownerUid, name: Self.ownerHandle,
                              photoUrl: ownerPhotoUrl, role: iAmOwner ? .moderator : .owner,
                              micOn: true, cameraOn: true, link: .connecting, handRaised: false,
                              joinedAt: now)
        }
        let taken = Set(people.map(\.name))
        let free = Self.namePool.filter { !taken.contains($0) && !blockedUids.contains(Self.uid(for: $0)) }
        let name = free.randomElement() ?? "Guest \(n)"
        return DemoPerson(id: "PA_\(n)", uid: Self.uid(for: name), name: name, photoUrl: nil,
                          role: .participant, micOn: true, cameraOn: false, link: .connecting,
                          handRaised: false, joinedAt: now)
    }

    private static let ownerUid = "demo-uid-realwarya"
    private static func uid(for name: String) -> String {
        "demo-uid-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - The tick

    private func tick() {
        simNow += 0.1 * speed
        runDue()
        if state == .connected || state == .ringing {
            advanceVoices(dt: 0.1 * speed)
        } else if state == .reconnecting {
            // My link is down: nobody can be heard.
            for id in voices.keys { voices[id]?.level = 0; voices[id]?.talking = false }
        }
        rebuild()
    }

    private func schedule(_ action: DemoAction, after seconds: TimeInterval, person: String? = nil, gen: Int = 0) {
        pending.append(DemoPending(at: simNow + seconds, action: action, personId: person, gen: gen))
    }

    private func runDue() {
        let due = pending.filter { $0.at <= simNow }.sorted { $0.at < $1.at }
        guard !due.isEmpty else { return }
        pending.removeAll { $0.at <= simNow }
        for step in due {
            guard state != .ended else { return }
            run(step)
        }
    }

    private func run(_ step: DemoPending) {
        switch step.action {
        case .connectDone:
            guard state == .connecting else { return }
            if callFullOnJoin {
                record("Join refused: the call is full", .warning)
                end(.callFull)
                return
            }
            setState(inCall.isEmpty && !ringing.isEmpty ? .ringing : .connected)
            for p in people {
                if p.link == .connecting {
                    schedule(.mediaArrived, after: Double.random(in: 0.3...2.0), person: p.id, gen: p.linkGen)
                } else if p.link == .ringing {
                    scheduleRingOutcome(p)
                }
            }
            if ringing.isEmpty == false {
                schedule(.ringTimeout, after: Self.ringWindow)
            }
        case .mediaArrived:
            guard let i = index(step), people[i].link == .connecting else { return }
            setLink(i, .connected)
        case .answer:
            guard let i = index(step), people[i].link == .ringing else { return }
            if blockedUids.contains(people[i].uid) {
                record("\(people[i].name) tried to join: blocked, refused", .warning)
                depart(people[i].id, why: "was refused (blocked)", announce: false)
                return
            }
            people[i].joinedAt = now
            setLink(i, .connecting)
            record("\(people[i].name) answered", .event)
            showToast("\(people[i].name) joined")
            schedule(.mediaArrived, after: Double.random(in: 0.8...3.0), person: people[i].id, gen: people[i].linkGen)
            settleState()
        case .decline:
            guard let i = index(step), people[i].link == .ringing else { return }
            depart(people[i].id, why: "declined", announce: false)
        case .ringTimeout:
            for p in ringing { depart(p.id, why: "didn't answer (ring timed out)", announce: false) }
        case .goLost:
            guard let i = index(step), people[i].link == .poor else { return }
            setLink(i, .lost)
        case .rejoin:
            guard let i = index(step), people[i].link == .lost else { return }
            record("\(people[i].name) is reconnecting", .event)
            setLink(i, .connecting)
            schedule(.mediaArrived, after: 1.0, person: people[i].id, gen: people[i].linkGen)
        case .giveUp:
            guard let i = index(step), people[i].link == .lost else { return }
            depart(people[i].id, why: "timed out after losing connection", announce: true)
        case .myReconnectOK:
            guard state == .reconnecting, step.gen == reconnectGen else { return }
            record("My connection is back", .event)
            if !inCall.isEmpty || ringing.isEmpty { setState(.connected) } else { setState(.ringing) }
            settleState()
        case .myReconnectFail:
            guard state == .reconnecting, step.gen == reconnectGen else { return }
            end(.connectionLost)
        }
    }

    /// The person a step was made for, only if the step is still current for them.
    private func index(_ step: DemoPending) -> Int? {
        guard let id = step.personId, let i = people.firstIndex(where: { $0.id == id }) else {
            if let id = step.personId { record("Dropped a stale step for \(id) (already gone)", .warning) }
            return nil
        }
        guard people[i].linkGen == step.gen else { return nil }
        return i
    }

    private func setLink(_ i: Int, _ link: DemoLink) {
        let old = people[i].link
        guard old != link else { return }
        people[i].link = link
        people[i].linkGen += 1
        record("\(people[i].name): \(old.rawValue) -> \(link.rawValue)", .event)
        if link == .lost || link == .connecting { voices[people[i].id] = nil }
    }

    private func scheduleRingOutcome(_ p: DemoPerson) {
        // The first person rung always answers, so the ringing -> connected step is always seen.
        let isFirst = people.first(where: { $0.link == .ringing })?.id == p.id
        if !isFirst && Double.random(in: 0...1) < 0.3 {
            schedule(.decline, after: Double.random(in: 4...8), person: p.id, gen: p.linkGen)
        } else {
            schedule(.answer, after: Double.random(in: 2.5...9), person: p.id, gen: p.linkGen)
        }
    }

    // MARK: - Voices

    private func advanceVoices(dt: TimeInterval) {
        let eligible = people.filter { $0.link == .connected || $0.link == .poor }
        let busy = eligible.count > 4
        var talkingCount = eligible.filter { voices[$0.id]?.talking == true && $0.micOn }.count
        let t = now
        for p in eligible {
            var v = voices[p.id] ?? DemoVoice(remaining: Double.random(in: 0.5...4))
            if let forced = v.forced, simNow < v.forcedUntil {
                v.talking = forced
            } else {
                v.forced = nil
                v.remaining -= dt
                if v.remaining <= 0 {
                    if v.talking {
                        v.talking = false
                        if p.micOn { talkingCount -= 1 }
                        v.remaining = Double.random(in: 2.5...9) * (busy ? 2 : 1)
                    } else if talkingCount < (busy ? 2 : 1) || Double.random(in: 0...1) < 0.12 {
                        v.talking = true
                        if p.micOn { talkingCount += 1 }
                        v.remaining = Double.random(in: 1.2...6)
                    } else {
                        v.remaining = Double.random(in: 0.5...3)
                    }
                }
            }
            // The raw flag flickers inside a burst (breaths), more on a poor link (dropouts).
            let target: Double
            if v.talking && p.micOn {
                if v.gap > 0 {
                    v.gap -= dt
                    target = 0.05
                } else {
                    let dropout = p.link == .poor ? 0.15 : 0.04
                    if Double.random(in: 0...1) < dropout { v.gap = Double.random(in: 0.1...0.35) }
                    target = Double.random(in: 0.45...1)
                }
            } else {
                target = 0
            }
            v.level = v.level * 0.5 + target * 0.5
            if v.level > 0.25 { v.lastSpokeAt = t }
            voices[p.id] = v
        }
    }

    private func isSpeaking(_ p: DemoPerson) -> Bool {
        guard p.micOn, p.link == .connected || p.link == .poor else { return false }
        return (voices[p.id]?.level ?? 0) > 0.25
    }

    // MARK: - Tiles (the GroupCallStage.refresh() twin)

    private func rebuild() {
        let t = now
        var built: [CallTile] = []
        if state != .idle {
            // Before my own connect finishes the room shows nobody else (the real stage only has
            // the local tile until the room is up).
            for p in people where p.link != .ringing && state != .connecting {
                built.append(CallTile(
                    id: p.id, uid: p.uid, name: p.name, photoUrl: p.photoUrl, isLocal: false,
                    hasVideo: p.cameraOn && p.link != .lost && !p.videoBroken,
                    isScreenShare: false, isMuted: !p.micOn,
                    isSpeaking: isSpeaking(p), lastSpokeAt: voices[p.id]?.lastSpokeAt,
                    joinedAt: p.joinedAt, networkPoor: p.link == .poor || p.link == .lost,
                    isHost: p.role == .owner,
                    cameraTrackSid: p.cameraOn ? "\(p.id)_cam" : nil, screenTrackSid: nil,
                    isConnecting: p.link == .connecting,
                    videoUnavailable: p.cameraOn && p.videoBroken,
                    isHandRaised: p.handRaised))
            }
            built.append(CallTile(
                id: Self.localId, uid: "demo-uid-me", name: myName, photoUrl: myPhotoUrl, isLocal: true,
                hasVideo: cameraOn, isScreenShare: false, isMuted: !micOn,
                isSpeaking: false, lastSpokeAt: nil, joinedAt: myJoinedAt,
                networkPoor: state == .reconnecting, isHost: iAmOwner,
                cameraTrackSid: cameraOn ? "local_cam" : nil, screenTrackSid: nil))
        }

        var speech: [String: (isSpeaking: Bool, lastSpokeAt: Date?)] = [:]
        for tile in built { speech[tile.id] = (tile.isSpeaking, tile.lastSpokeAt) }
        speechById = speech
        if built != tiles { tiles = built }

        let present = Set(built.map(\.id))
        if let pin = pinnedId, !present.contains(pin) {
            record("Pinned person is gone: pin cleared", .event)
            pinnedId = nil
        }
        if let request = removalRequest, !present.contains(request.tile.id) {
            record("Remove question dropped: \(request.tile.name) left first", .event)
            removalRequest = nil
        }

        let speaking = Set(built.filter { $0.isSpeaking && !$0.isLocal }.map(\.id))
        if speaking != speakingIds { speakingIds = speaking }
        _ = tracker.update(speaking: speaking, now: t)
        let speaker = tracker.activeSpeakerId.flatMap { present.contains($0) ? $0 : nil }
        if let speaker {
            lastSpeakerId = speaker
        } else if let last = lastSpeakerId, !present.contains(last) {
            lastSpeakerId = nil
        }
        if speaker != activeSpeakerId {
            let name = speaker.flatMap { id in built.first { $0.id == id }?.name } ?? "none"
            record("Active speaker: \(name)", .event)
            activeSpeakerId = speaker
        }
        updateMode()
    }

    private func updateMode() {
        let next: CallStageMode
        if let pin = pinnedId, pin != Self.localId, tiles.contains(where: { $0.id == pin }) {
            next = .focus(tileId: pin)
        } else {
            next = .grid
        }
        if next != mode { mode = next }
    }

    /// TWIN of `GroupCallStage.gridPlacement` (sticky cells; only an off-grid active speaker swaps
    /// in, taking the least important person's cell). Mutates only the unpublished cache.
    func gridPlacement(_ remotes: [CallTile], capacity: Int) -> [String] {
        guard capacity > 0 else { placedIds = []; return [] }
        let byId = Dictionary(remotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let speaker = activeSpeakerId.flatMap { byId[$0] != nil ? $0 : nil }
        var cells = placedIds.filter { byId[$0] != nil }

        while cells.count > capacity,
              let worst = weakest(cells, byId, keep: speaker), let i = cells.firstIndex(of: worst) {
            cells.remove(at: i)
        }
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
        if let speaker, !cells.contains(speaker),
           let worst = weakest(cells, byId, keep: speaker), let i = cells.firstIndex(of: worst) {
            cells[i] = speaker
        }
        placedIds = cells
        return cells
    }

    private func placementTier(_ t: CallTile) -> Int {
        if t.isScreenShare { return 0 }
        if t.id == pinnedId { return 1 }
        if t.id == activeSpeakerId { return 2 }
        return t.hasVideo ? 3 : 4
    }

    private func weakest(_ cells: [String], _ byId: [String: CallTile], keep: String?) -> String? {
        cells.compactMap { byId[$0] }.filter { $0.id != keep }.max { a, b in
            let ta = placementTier(a), tb = placementTier(b)
            if ta != tb { return ta < tb }
            let la = a.lastSpokeAt ?? .distantPast, lb = b.lastSpokeAt ?? .distantPast
            if la != lb { return la > lb }
            return GroupCallPriority.joinOrder(a, b)
        }?.id
    }

    // MARK: - Leaving (every way out goes through here)

    private func depart(_ id: String, why: String, announce: Bool) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let p = people.remove(at: i)
        var notes: [String] = []
        if id == activeSpeakerId { notes.append("was the active speaker") }
        if id == pinnedId { notes.append("was pinned") }
        if p.role == .owner { notes.append("was the host; the call goes on") }
        if p.link == .lost || p.link == .poor { notes.append("was \(p.link.rawValue)") }
        let extra = notes.isEmpty ? "" : " (" + notes.joined(separator: ", ") + ")"
        record("\(p.name) \(why)\(extra)", .event)
        voices[id] = nil
        pending.removeAll { $0.personId == id }
        if p.link != .ringing {
            departed.insert(p, at: 0)
            if departed.count > 12 { departed.removeLast() }
            if announce { showToast("\(p.name) left") }
        }
        if inCall.isEmpty && ringing.isEmpty && state.isLive { record("I am alone in the call", .event) }
        settleState()
        rebuild()
    }

    // MARK: - Me

    func toggleMic() {
        guard state != .idle && state != .ended else { return }
        micOn.toggle()
        record("My mic \(micOn ? "on" : "off")\(state == .reconnecting ? " (while reconnecting)" : "")", .event)
        rebuild()
    }

    func toggleCamera() {
        guard state != .idle && state != .ended, isVideoCall else { return }
        cameraOn.toggle()
        record("My camera \(cameraOn ? "on" : "off")\(state == .reconnecting ? " (while reconnecting)" : "")", .event)
        rebuild()
    }

    func switchCallKind() {
        guard state != .idle && state != .ended else { return }
        isVideoCall.toggle()
        cameraOn = isVideoCall
        record("Switched to a \(isVideoCall ? "video" : "voice") call", .event)
        showToast(isVideoCall ? "Video call" : "Voice call")
        rebuild()
    }

    func flipCamera() {
        guard cameraOn else { return }
        frontCamera.toggle()
        record("Flipped to the \(frontCamera ? "front" : "back") camera (no-op visual)", .event)
    }

    func toggleHand() {
        guard state.isLive else { return }
        handRaised.toggle()
        record("My hand \(handRaised ? "raised" : "lowered")", .event)
        showToast(handRaised ? "You raised your hand" : "You lowered your hand")
    }

    func leave() {
        guard state != .idle && state != .ended else { return }
        end(.left)
    }

    func setIAmOwner(_ on: Bool) {
        guard on != iAmOwner else { return }
        iAmOwner = on
        for i in people.indices where people[i].uid == Self.ownerUid {
            people[i].role = on ? .moderator : .owner
        }
        record(on ? "I am the owner now (\(Self.ownerHandle) is an admin)" : "\(Self.ownerHandle) is the owner again", .event)
        rebuild()
    }

    func togglePin(_ id: String) {
        guard id != Self.localId, tiles.contains(where: { $0.id == id }) else { return }
        pinnedId = (pinnedId == id) ? nil : id
        record(pinnedId == nil ? "Unpinned" : "Pinned \(tiles.first { $0.id == id }?.name ?? id)", .event)
        updateMode()
    }

    // MARK: - Owner controls (my actions on others)

    func canModerate(_ id: String) -> Bool {
        guard state.isLive || state == .reconnecting, let p = person(id), p.link != .ringing else { return false }
        return myRole.canModerate(p.role)
    }

    func canPromote(_ id: String) -> Bool {
        guard myRole == .owner, let p = person(id), p.link != .ringing else { return false }
        return p.role != .owner
    }

    func mute(_ id: String) {
        guard canModerate(id), let i = people.firstIndex(where: { $0.id == id }) else {
            record("REFUSED mute: no permission", .warning); return
        }
        guard people[i].micOn else { return }
        let wasTalking = speakingIds.contains(id)
        people[i].micOn = false
        record("I muted \(people[i].name)\(wasTalking ? " while they were speaking" : "")", .event)
        showToast("You muted \(people[i].name)")
        rebuild()
    }

    func remove(_ id: String, block: Bool) {
        guard canModerate(id), let p = person(id) else {
            record("REFUSED remove: no permission", .warning); return
        }
        if block { blockedUids.insert(p.uid) }
        showToast("\(p.name) was removed")
        depart(id, why: block ? "was removed and blocked by me" : "was removed by me", announce: false)
    }

    func toggleModerator(_ id: String) {
        guard canPromote(id), let i = people.firstIndex(where: { $0.id == id }) else {
            record("REFUSED role change: only the owner can", .warning); return
        }
        people[i].role = people[i].role == .moderator ? .participant : .moderator
        record("\(people[i].name) is now \(people[i].role == .moderator ? "an admin" : "a participant")", .event)
        showToast(people[i].role == .moderator ? "\(people[i].name) is now an admin" : "\(people[i].name) is no longer an admin")
        rebuild()
    }

    /// Long press / people list "Remove…": asks the screen to confirm first, like the real one.
    func requestRemove(_ id: String, block: Bool) {
        guard canModerate(id), let tile = tiles.first(where: { $0.id == id }) else {
            record("REFUSED remove: no permission", .warning); return
        }
        removalRequest = DemoRemoval(tile: tile, block: block)
    }

    func endForEveryone() {
        guard myRole == .owner, state != .idle, state != .ended else {
            record("REFUSED end for everyone: only the owner can", .warning); return
        }
        end(.endedByMe)
    }

    // MARK: - Scenario panel

    func addParticipant() {
        guard state.isLive || state == .reconnecting else { record("Add ignored: no call", .warning); return }
        let ownerHere = people.contains { $0.uid == Self.ownerUid }
        var p = makePerson(owner: !ownerHere)
        p.link = .ringing
        p.cameraOn = Double.random(in: 0...1) < 0.5
        people.append(p)
        record("Ringing \(p.name) (added)", .event)
        schedule(.answer, after: Double.random(in: 1.5...3), person: p.id, gen: p.linkGen)
        settleState()
        rebuild()
    }

    func removeRandom() {
        let candidates = inCall.filter { iAmOwner ? myRole.canModerate($0.role) : $0.role != .owner }
        guard let p = candidates.randomElement() else { record("Remove ignored: nobody removable", .warning); return }
        if iAmOwner { remove(p.id, block: false) }
        else {
            showToast("\(Self.ownerHandle) removed \(p.name)")
            depart(p.id, why: "was removed by \(Self.ownerHandle)", announce: false)
        }
    }

    func someoneLeaves() {
        guard let p = inCall.randomElement() else { record("Leave ignored: nobody here", .warning); return }
        depart(p.id, why: "left", announce: true)
    }

    func ownerLeaves() {
        guard let p = inCall.first(where: { $0.uid == Self.ownerUid }) else {
            record("\(Self.ownerHandle) is not in the call", .warning); return
        }
        depart(p.id, why: "left", announce: true)
    }

    func activeSpeakerLeaves() {
        guard let id = activeSpeakerId else { record("Nobody is the active speaker right now", .warning); return }
        depart(id, why: "left", announce: true)
    }

    func pinnedLeaves() {
        guard let id = pinnedId else { record("Nobody is pinned. Tap a tile first.", .warning); return }
        depart(id, why: "left", announce: true)
    }

    /// Someone's network goes poor, then lost; then they rejoin, or time out and leave.
    func dropSomeone(recovers: Bool) {
        guard let p = inCall.filter({ $0.link == .connected }).randomElement(),
              let i = people.firstIndex(where: { $0.id == p.id }) else {
            record("Drop ignored: nobody with a good connection", .warning); return
        }
        setLink(i, .poor)
        let gen = people[i].linkGen
        schedule(.goLost, after: 2, person: p.id, gen: gen)
        // After goLost the generation is gen + 1.
        if recovers {
            schedule(.rejoin, after: 2 + Double.random(in: 3...5), person: p.id, gen: gen + 1)
        } else {
            schedule(.giveUp, after: 2 + Self.lostTimeout, person: p.id, gen: gen + 1)
        }
        record("\(p.name)'s connection is dropping (\(recovers ? "will come back" : "will time out"))", .event)
        rebuild()
    }

    func dropMe(recovers: Bool) {
        guard state.isLive else { record("Drop ignored: the call is not up", .warning); return }
        guard setState(.reconnecting) else { return }
        reconnectGen += 1
        if recovers {
            schedule(.myReconnectOK, after: 4, gen: reconnectGen)
        } else {
            schedule(.myReconnectFail, after: Self.myReconnectTimeout, gen: reconnectGen)
        }
        record("My connection dropped (\(recovers ? "back in 4s" : "gives up after \(Int(Self.myReconnectTimeout))s"))", .event)
        rebuild()
    }

    func everyoneMutes() {
        for i in people.indices { people[i].micOn = false }
        record("Everyone else muted themselves", .event)
        rebuild()
    }

    func toggleSomeonesCamera() {
        guard let p = inCall.filter({ $0.link != .lost }).randomElement(),
              let i = people.firstIndex(where: { $0.id == p.id }) else { return }
        people[i].cameraOn.toggle()
        people[i].videoBroken = false
        let focused = pinnedId == p.id ? " (the focused tile)" : ""
        record("\(p.name) turned their camera \(people[i].cameraOn ? "on" : "off")\(focused)", .event)
        rebuild()
    }

    func breakSomeonesVideo() {
        guard let p = inCall.filter({ $0.cameraOn && !$0.videoBroken }).randomElement(),
              let i = people.firstIndex(where: { $0.id == p.id }) else {
            record("Nobody has a working camera to break", .warning); return
        }
        people[i].videoBroken = true
        record("\(p.name)'s camera is on but no picture arrives", .event)
        rebuild()
    }

    func someoneRaisesHand() {
        guard let p = inCall.filter({ !$0.handRaised }).randomElement(),
              let i = people.firstIndex(where: { $0.id == p.id }) else { return }
        people[i].handRaised = true
        record("\(p.name) raised their hand", .event)
        showToast("\(p.name) raised their hand")
        rebuild()
    }

    func someoneTalksNow() {
        let candidates = inCall.filter { $0.link == .connected || $0.link == .poor }
        guard var p = candidates.filter({ !speakingIds.contains($0.id) }).randomElement() ?? candidates.randomElement(),
              let i = people.firstIndex(where: { $0.id == p.id }) else {
            record("Nobody here to talk", .warning); return
        }
        if !people[i].micOn {
            people[i].micOn = true
            record("\(p.name) unmuted to talk", .event)
        }
        p = people[i]
        var v = voices[p.id] ?? DemoVoice()
        v.forced = true
        v.forcedUntil = simNow + 8
        voices[p.id] = v
        record("\(p.name) starts talking now (8s)", .event)
    }

    func everyoneStopsTalking() {
        for p in inCall {
            var v = voices[p.id] ?? DemoVoice()
            v.forced = false
            v.forcedUntil = simNow + 4
            v.talking = false
            voices[p.id] = v
        }
        record("Everyone stops talking (4s)", .event)
    }

    func hostMutesMe() {
        guard !iAmOwner else { record("I am the owner: nobody can mute me", .warning); return }
        guard state.isLive || state == .reconnecting else { return }
        guard people.contains(where: { $0.uid == Self.ownerUid && $0.link != .ringing }) else {
            record("\(Self.ownerHandle) is not in the call", .warning); return
        }
        if micOn {
            micOn = false
            record("\(Self.ownerHandle) muted me", .event)
        } else {
            record("\(Self.ownerHandle) muted me (already muted)", .event)
        }
        showToast("\(Self.ownerHandle) muted you")
        rebuild()
    }

    func hostRemovesMe() {
        guard !iAmOwner else { record("I am the owner: nobody can remove me", .warning); return }
        guard state != .idle && state != .ended else { return }
        end(.removed(by: Self.ownerHandle))
    }

    func hostEndsCall() {
        if iAmOwner { endForEveryone() } else {
            guard state != .idle && state != .ended else { return }
            end(.endedByHost(Self.ownerHandle))
        }
    }

    func setCallFull(_ on: Bool) {
        callFullOnJoin = on
        record("Call full on next join: \(on ? "on" : "off")", .event)
    }

    func setSpeed(_ value: Double) {
        speed = value
        record("Speed \(Int(value))x", .event)
    }

    func reset() {
        resetState(keepLog: true)
        record("Reset", .state)
    }

    func clearLog() { log.removeAll() }

    var logText: String {
        log.map { "\($0.stamp)  \($0.text)" }.joined(separator: "\n")
    }

    private func resetState(keepLog: Bool) {
        shutdown()
        if !keepLog { log.removeAll() }
        state = .idle
        endReason = nil
        people = []
        departed = []
        voices = [:]
        speechById = [:]
        tracker = GroupCallSpeakerTracker()
        lastSpeakerId = nil
        placedIds = []
        pending = []
        pinnedId = nil
        removalRequest = nil
        blockedUids = []
        activeSpeakerId = nil
        speakingIds = []
        handRaised = false
        micOn = true
        connectedAt = nil
        reconnectGen = 0
        rebuild()
    }

    // MARK: - Log and toast

    private func record(_ text: String, _ kind: DemoLogEntry.Kind) {
        log.append(DemoLogEntry(simTime: simNow, text: text, kind: kind))
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    func showToast(_ text: String) {
        toastSeq += 1
        let seq = toastSeq
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.toastSeq == seq else { return }
            self.toast = nil
        }
    }
}
