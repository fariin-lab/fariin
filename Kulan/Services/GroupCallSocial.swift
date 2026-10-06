import Foundation
import Combine
import UIKit
import LiveKit

/// The wire both halves of this file agree on. Outside the main-actor class so the room observer,
/// which runs on the SDK's own queue, can read it without crossing actors.
private enum SocialWire {
    static let topic = "kulan.social"
    /// Our own packets are under 100 bytes. Anything bigger on this topic is not ours.
    static let maxBytes = 1024
}

/// Raised hands, emoji reactions and the "<Name> muted you" note of a group call (owner,
/// 2026-10-06, group call build plan, package S).
///
/// Everything travels as LiveKit data on the topic "kulan.social", reliable, as small JSON:
///   {"t":"hand","up":true}            a participant raised or lowered a hand
///   {"t":"react","e":"<emoji>"}       a participant sent a reaction
///   {"t":"mutedBy","name":"Alice"}    the SERVER tells me who muted me
///
/// Who sent a packet is ALWAYS the room's own answer (`participant.identity`, stamped by the media
/// server), never anything inside the payload: a payload is whatever the other phone typed.
///
/// `GroupCallService` calls `attach` when a call is joined and `reset` when it is left. The views
/// only read the three published lists and call `setHand` / `react`.
@MainActor
final class GroupCallSocial: ObservableObject {
    static let shared = GroupCallSocial()
    private init() {}

    struct RaisedHand: Identifiable, Equatable {
        let uid: String
        let name: String
        let at: Date
        var id: String { uid }
    }

    struct Reaction: Identifiable, Equatable {
        let id: UUID
        let uid: String
        let name: String
        let emoji: String
        let at: Date
    }

    /// Oldest first, mine included.
    @Published private(set) var raisedHands: [RaisedHand] = []
    @Published private(set) var myHandUp = false
    /// Newest last, never more than `maxReactions`, each gone `reactionLife` after it arrived.
    @Published private(set) var reactions: [Reaction] = []
    /// When a "<Name> muted you" note last arrived from the server. `GroupCallService` reads it to
    /// skip its own nameless "You were muted" for the same mute.
    private(set) var lastMutedByAt: Date?

    /// The picker row: thumbs up, red heart, tears of joy, surprised, clapping, party. Written as
    /// escapes so no editor or encoding on the way to the build machine can damage them.
    static let quickEmojis: [String] = [
        "\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F44F}", "\u{1F389}",
    ]

    private static let maxReactions = 5
    private static let reactionLife: UInt64 = 4_000_000_000
    private static let maxNameLength = 40

    private var room: Room?
    /// Held here: the room keeps its delegates weakly.
    private var observer: SocialRoomObserver?
    /// Bumped by `reset`. Every observer and every waiting task carries the value it was made
    /// with, so nothing left over from the last call (the SDK hands delegate calls to its own queue
    /// and they can land after the delegate was removed) is applied to the next one.
    private var session = 0
    private var myUid = ""
    private var myName = ""

    private var reactionRemovals: [UUID: Task<Void, Never>] = [:]
    /// Per sender, on the uptime clock (wall time can jump): when their last few packets came.
    private var reactionStamps: [String: [TimeInterval]] = [:]
    private var handStamps: [String: [TimeInterval]] = [:]
    /// A hand change that came in over the limit: the newest one is kept and applied a moment
    /// later, so a sender who floods ends on their real last state instead of a stuck hand.
    private var lateHands: [String: (up: Bool, name: String)] = [:]
    private var lateHandTasks: [String: Task<Void, Never>] = [:]
    private var lastAnnounced: [String: TimeInterval] = [:]
    /// My own hand packets go out one after another, never side by side: see `queueHand`.
    private var handSendTail: Task<Void, Never>?
    private var greetTasks: [String: Task<Void, Never>] = [:]
    private var mutedByTask: Task<Void, Never>?

    // MARK: Lifecycle

    func attach(room: Room, myUid: String, myName: String) {
        // The same call attached again (a second join path): keep what is on screen.
        if let current = self.room, current === room, observer != nil, self.myUid == myUid {
            self.myName = Self.clean(myName)
            return
        }
        reset()
        self.room = room
        self.myUid = myUid
        self.myName = Self.clean(myName)
        let fresh = SocialRoomObserver(session: session)
        observer = fresh
        room.add(delegate: fresh)
    }

    func reset() {
        session &+= 1
        if let room, let observer { room.remove(delegate: observer) }
        observer = nil
        room = nil
        myUid = ""
        myName = ""
        lastMutedByAt = nil
        clearCallState()
    }

    /// Everything that belongs to one call. Also run when the room itself goes away, so a leave
    /// path that forgot `reset` cannot carry a raised hand into the next call.
    private func clearCallState() {
        for task in reactionRemovals.values { task.cancel() }
        for task in lateHandTasks.values { task.cancel() }
        for task in greetTasks.values { task.cancel() }
        mutedByTask?.cancel()
        mutedByTask = nil
        reactionRemovals = [:]
        lateHandTasks = [:]
        greetTasks = [:]
        lateHands = [:]
        reactionStamps = [:]
        handStamps = [:]
        lastAnnounced = [:]
        // Only when something changes: an assignment publishes even if the value is the same.
        if !raisedHands.isEmpty { raisedHands = [] }
        if myHandUp { myHandUp = false }
        if !reactions.isEmpty { reactions = [] }
    }

    // MARK: What the views call

    func setHand(_ up: Bool) {
        guard room != nil, !myUid.isEmpty, up != myHandUp else { return }
        myHandUp = up
        applyHand(uid: myUid, name: myName.isEmpty ? "You" : myName, up: up, announce: false)
        queueHand(to: nil)
    }

    func react(_ emoji: String) {
        guard room != nil, !myUid.isEmpty, Self.isEmoji(emoji) else { return }
        // The same limit the others hold me to: past it they would drop it anyway, and showing it
        // only on my own screen would be a lie.
        guard Self.allow(&reactionStamps, myUid, limit: 3, per: 1) else { return }
        show(Reaction(id: UUID(), uid: myUid, name: myName.isEmpty ? "You" : myName, emoji: emoji, at: Date()))
        Task { _ = await self.publish(["t": "react", "e": emoji], to: nil) }
    }

    func isHandRaised(_ uid: String) -> Bool {
        raisedHands.contains { $0.uid == uid }
    }

    // MARK: Hands

    private func applyHand(uid: String, name: String, up: Bool, announce: Bool) {
        let index = raisedHands.firstIndex { $0.uid == uid }
        if up {
            guard index == nil else { return }   // already up: a resend, nothing to do
            raisedHands.append(RaisedHand(uid: uid, name: name, at: Date()))
            if announce { announceHand(uid: uid, name: name) }
        } else if let index {
            raisedHands.remove(at: index)
        }
    }

    /// VoiceOver: "<Name> raised a hand". At most once every few seconds per person, so someone
    /// flicking a hand up and down cannot talk over the call.
    private func announceHand(uid: String, name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastAnnounced[uid], now - last < 5 { return }
        lastAnnounced[uid] = now
        UIAccessibility.post(notification: .announcement, argument: "\(name) raised a hand")
    }

    private func remoteHand(uid: String, name: String, up: Bool) {
        // 2026-10-06, package S (not in the plan, added while building): a hand is a tap, a few
        // changes in two seconds is already generous. Past that the newest state waits here and is
        // applied once, two seconds on; every phone in the call would otherwise redraw its stage as
        // fast as one changed app can send packets.
        guard Self.allow(&handStamps, uid, limit: 4, per: 2) else {
            lateHands[uid] = (up: up, name: name)
            guard lateHandTasks[uid] == nil else { return }
            let session = self.session
            lateHandTasks[uid] = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.session == session else { return }
                self.lateHandTasks[uid] = nil
                guard let late = self.lateHands.removeValue(forKey: uid) else { return }
                self.applyHand(uid: uid, name: late.name, up: late.up, announce: true)
            }
            return
        }
        // Inside the limit: this one is newer than anything still waiting.
        lateHands[uid] = nil
        applyHand(uid: uid, name: name, up: up, announce: true)
    }

    /// Sends my hand as it is AT THE MOMENT OF SENDING, after every earlier hand packet of mine
    /// has gone. Two sends side by side (a hello to a new joiner and a "lowered" to everyone) could
    /// reach a phone in the wrong order and leave my hand up there for the rest of the call.
    /// `uid` nil = everyone; a uid = only that person (the hello to someone who just joined).
    private func queueHand(to uid: String?) {
        let session = self.session
        let previous = handSendTail
        handSendTail = Task {
            _ = await previous?.value
            guard self.session == session else { return }
            let up = self.myHandUp
            // A hello only matters while the hand is up: a new joiner starts with it down.
            if uid != nil, !up { return }
            // To everyone: three tries, a second apart. To one person: one try, `participantArrived`
            // sends a second hello by itself.
            let tries = uid == nil ? 3 : 1
            for attempt in 1...tries {
                if await self.publish(["t": "hand", "up": up], to: uid) { return }
                guard attempt < tries else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Changed meanwhile: that change queued its own packet behind this one.
                guard self.session == session, self.myHandUp == up else { return }
            }
        }
    }

    // MARK: Reactions

    private func show(_ reaction: Reaction) {
        var list = reactions
        list.append(reaction)
        if list.count > Self.maxReactions {
            let overflow = list.count - Self.maxReactions
            for old in list.prefix(overflow) {
                reactionRemovals.removeValue(forKey: old.id)?.cancel()
            }
            list.removeFirst(overflow)
        }
        reactions = list

        let id = reaction.id
        reactionRemovals[id] = Task {
            try? await Task.sleep(nanoseconds: Self.reactionLife)
            guard !Task.isCancelled else { return }
            self.reactionRemovals[id] = nil
            self.reactions.removeAll { $0.id == id }
        }
    }

    // MARK: "<Name> muted you"

    /// 2026-10-06, package S (not in the plan, added while building): the SDK reports a server-sent
    /// packet as "no participant", but it reports the SAME for a packet whose sender it cannot find
    /// any more (someone who sent it and left at once: `Room.engine(_:didReceiveUserPacket:)` looks
    /// the sender up in `remoteParticipants`). So a note is believed only while my microphone
    /// really is off: now, or within the next few seconds (the note and the mute travel on
    /// different channels and either can come first). That stops a made-up "Alice muted you" while
    /// I am talking. It does NOT stop one while my microphone is already off; closing that needs
    /// the server to say it on a channel a participant cannot write to.
    private func mutedBy(_ rawName: String?) {
        let name = Self.clean(rawName)
        guard !name.isEmpty else { return }
        // At arrival, not when shown: the service's own "You were muted" must already see it
        // when the mute lands a beat after the note.
        lastMutedByAt = Date()
        mutedByTask?.cancel()
        mutedByTask = nil
        if microphoneIsOff {
            GroupCallService.shared.showToast("\(name) muted you")
            return
        }
        let session = self.session
        mutedByTask = Task {
            // 3 seconds: the same window the service looks back over `lastMutedByAt` when the mute
            // lands, so exactly one of the two notes is shown for one mute.
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, self.session == session else { return }
                if self.microphoneIsOff {
                    self.lastMutedByAt = Date()
                    GroupCallService.shared.showToast("\(name) muted you")
                    return
                }
            }
        }
    }

    /// The same reading the service uses to notice a server mute: my microphone publication is
    /// muted (or was never published).
    private var microphoneIsOff: Bool {
        guard let room else { return false }
        return !room.localParticipant.isMicrophoneEnabled()
    }

    // MARK: From the room (called by the observer, on the main queue, in arrival order)

    /// `fromServer` = the room named no sender. `uid` and `roomName` are the sender as the ROOM
    /// knows them; nothing about who sent it is read from `data`.
    fileprivate func received(_ data: Data, fromServer: Bool, uid: String, roomName: String?, session: Int) {
        guard session == self.session, room != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let kind = message["t"] as? String else { return }

        switch kind {
        case "mutedBy":
            // Only the server says this. From a participant it is someone pretending.
            guard fromServer else { return }
            mutedBy(message["name"] as? String)

        case "hand":
            guard !fromServer, !uid.isEmpty, uid != myUid, let up = message["up"] as? Bool else { return }
            remoteHand(uid: uid, name: displayName(uid: uid, roomName: roomName), up: up)

        case "react":
            guard !fromServer, !uid.isEmpty, uid != myUid,
                  let emoji = message["e"] as? String, Self.isEmoji(emoji),
                  Self.allow(&reactionStamps, uid, limit: 3, per: 1) else { return }
            show(Reaction(id: UUID(), uid: uid, name: displayName(uid: uid, roomName: roomName),
                          emoji: emoji, at: Date()))

        default:
            return
        }
    }

    /// Someone joined, or their connection just came up. They know nothing about my hand, so tell
    /// them alone. Twice: the first hello can arrive before their data channel is open (the room
    /// reports a joiner before their connection is ready), and a hello that is already known
    /// changes nothing on their side.
    fileprivate func participantArrived(uid: String, session: Int) {
        guard session == self.session, myHandUp, !uid.isEmpty, uid != myUid else { return }
        greetTasks[uid]?.cancel()
        queueHand(to: uid)
        greetTasks[uid] = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.session == session else { return }
            self.greetTasks[uid] = nil
            guard self.myHandUp else { return }
            self.queueHand(to: uid)
        }
    }

    fileprivate func participantLeft(uid: String, session: Int) {
        guard session == self.session, uid != myUid else { return }
        greetTasks.removeValue(forKey: uid)?.cancel()
        lateHandTasks.removeValue(forKey: uid)?.cancel()
        lateHands[uid] = nil
        handStamps[uid] = nil
        reactionStamps[uid] = nil
        if let index = raisedHands.firstIndex(where: { $0.uid == uid }) {
            raisedHands.remove(at: index)
        }
    }

    /// The room is gone (hung up, dropped, removed). The call's hands and reactions go with it even
    /// if nobody called `reset`.
    fileprivate func roomDisconnected(session: Int) {
        guard session == self.session else { return }
        clearCallState()
    }

    // MARK: Helpers

    /// Reliable, on our topic. False when it could not be sent (not connected yet, room gone).
    private func publish(_ payload: [String: Any], to uid: String?) async -> Bool {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var destinations: [Participant.Identity] = []
        if let uid { destinations = [Participant.Identity(from: uid)] }
        let options = DataPublishOptions(destinationIdentities: destinations,
                                         topic: SocialWire.topic,
                                         reliable: true)
        do {
            try await room.localParticipant.publish(data: data, options: options)
            return true
        } catch {
            return false
        }
    }

    /// The name the room has for them, else the call's own member list, else "Member".
    private func displayName(uid: String, roomName: String?) -> String {
        let fromRoom = Self.clean(roomName)
        if !fromRoom.isEmpty { return fromRoom }
        if let member = GroupCallService.shared.members.first(where: { $0.uid == uid }) {
            let fromList = Self.clean(member.name)
            if !fromList.isEmpty { return fromList }
        }
        return "Member"
    }

    /// One line, no control characters, a sane length: these strings end up in a toast and in
    /// VoiceOver's mouth.
    private static func clean(_ raw: String?) -> String {
        guard let raw else { return "" }
        let flat = raw.components(separatedBy: CharacterSet.controlCharacters.union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(maxNameLength))
    }

    /// One emoji and nothing else: at most 8 unicode scalars (the plan's limit), a single character
    /// on screen, and really an emoji. Without the last two checks a changed app could flash eight
    /// letters of its choosing on every phone in the call.
    private static func isEmoji(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard text.count == 1, scalars.count <= 8 else { return false }
        // A lone digit, "#" or "*" counts as an emoji in the Unicode tables. It is not one here.
        if scalars.count == 1, let only = scalars.first, only.isASCII { return false }
        return scalars.contains { $0.properties.isEmoji }
    }

    /// A sliding window per sender. True = inside the limit (and counted).
    private static func allow(_ stamps: inout [String: [TimeInterval]], _ uid: String,
                              limit: Int, per window: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        var recent = (stamps[uid] ?? []).filter { now - $0 < window }
        let inside = recent.count < limit
        if inside { recent.append(now) }
        stamps[uid] = recent
        return inside
    }
}

/// The room's events for `GroupCallSocial`. A separate NSObject because RoomDelegate is an @objc
/// protocol called on the SDK's own queue. Everything is read from the participant HERE (the SDK
/// clears a participant once its "left" call returns) and handed to the main queue as plain values.
/// `DispatchQueue.main.async`, not a Task: tasks do not promise to run in the order they were
/// made, and "hand up" then "hand down" must not swap.
private final class SocialRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let session: Int

    init(session: Int) {
        self.session = session
        super.init()
    }

    /// `participant` nil = the room named no sender (a server-sent packet).
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == SocialWire.topic, !data.isEmpty, data.count <= SocialWire.maxBytes else { return }
        let fromServer = participant == nil
        let uid = participant?.identity?.stringValue ?? ""
        let roomName = participant?.name
        let session = self.session
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GroupCallSocial.shared.received(data, fromServer: fromServer, uid: uid,
                                                roomName: roomName, session: session)
            }
        }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard let uid = participant.identity?.stringValue, !uid.isEmpty else { return }
        let session = self.session
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GroupCallSocial.shared.participantArrived(uid: uid, session: session)
            }
        }
    }

    /// `.active` = their connection is up, which is when a packet can actually reach them.
    func room(_ room: Room, participant: Participant, didUpdateState state: ParticipantState) {
        guard state == .active, participant is RemoteParticipant,
              let uid = participant.identity?.stringValue, !uid.isEmpty else { return }
        let session = self.session
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GroupCallSocial.shared.participantArrived(uid: uid, session: session)
            }
        }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let uid = participant.identity?.stringValue, !uid.isEmpty else { return }
        let session = self.session
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GroupCallSocial.shared.participantLeft(uid: uid, session: session)
            }
        }
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState,
              from oldConnectionState: ConnectionState) {
        guard connectionState == .disconnected else { return }
        let session = self.session
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GroupCallSocial.shared.roomDisconnected(session: session)
            }
        }
    }
}
