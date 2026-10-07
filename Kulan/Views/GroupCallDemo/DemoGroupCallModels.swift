import Foundation

// GROUP CALL DEMO (owner, 2026-10-07): the value types of the simulated call. Nothing in this folder
// talks to LiveKit, Firestore, CallKit, push or the audio session. The demo only READS the real pure
// types (`CallTile`, `CallRole`, the layout / speaker / priority engines) so the logic it exercises is
// the production logic, fed by simulated people instead of a room.

/// The call's state machine. Every change goes through `DemoGroupCallEngine.setState(_:)`, which
/// refuses (and logs) a transition that is not in `allowed`, so a state bug shows up in the event log.
enum DemoCallState: String {
    case idle, connecting, ringing, connected, reconnecting, ended

    /// The transitions the engine accepts. `idle` is reached only through Reset.
    var allowed: Set<DemoCallState> {
        switch self {
        case .idle: return [.connecting]
        case .connecting: return [.ringing, .connected, .ended]
        case .ringing: return [.connected, .reconnecting, .ended]
        case .connected: return [.ringing, .reconnecting, .ended]
        case .reconnecting: return [.connected, .ringing, .ended]
        case .ended: return []
        }
    }

    /// The call is up (I am in the room), whether or not anyone else is.
    var isLive: Bool { self == .ringing || self == .connected }
}

/// Why the call ended for me. Shown as the closing notice, in the real screen's words.
enum DemoEndReason: Equatable {
    case left
    case endedByHost(String)
    case endedByMe
    case removed(by: String)
    case connectionLost
    case callFull

    var title: String {
        switch self {
        case .left: return "You left the call"
        case .endedByHost: return "Call ended"
        case .endedByMe: return "You ended the call"
        case .removed: return "You were removed"
        case .connectionLost: return "Connection lost"
        case .callFull: return "Call is full"
        }
    }

    var message: String {
        switch self {
        case .left: return "The call goes on for the others."
        case .endedByHost(let name): return "\(name) ended the call for everyone."
        case .endedByMe: return "The call was ended for everyone."
        case .removed(let name): return "\(name) removed you from the call."
        case .connectionLost: return "Couldn't reconnect to the call."
        case .callFull: return "This call has reached its limit. Try again later."
        }
    }
}

/// One simulated person's link to the call.
enum DemoLink: String {
    case ringing      // invited, phone ringing, not in the room yet
    case connecting   // in the room, media still arriving (the real tile's spinner)
    case connected
    case poor         // in the room, network weak (the real tile's network glyph)
    case lost         // in the room but gone silent; rejoins or times out
}

/// Everyone in the demo except me. `id` plays the part of the LiveKit sid (tile identity).
struct DemoPerson: Identifiable, Equatable {
    let id: String
    let uid: String
    var name: String
    var photoUrl: String?
    var role: CallRole
    var micOn: Bool
    var cameraOn: Bool
    var link: DemoLink
    var handRaised: Bool
    var joinedAt: Date
    /// Camera on but no picture (the real tile's "Can't show video").
    var videoBroken: Bool = false
    /// Bumped on every link change: a scheduled step carries the value it was made for and is
    /// dropped when it no longer matches, so an old reconnect timer cannot act on a new drop.
    var linkGen: Int = 0
}

/// Simulated voice activity for one person. Not published: speech changes ten times a second and,
/// like the real stage, only a change in WHO is speaking republishes anything.
struct DemoVoice {
    var talking = false
    var remaining: TimeInterval = 0
    var level: Double = 0
    var gap: TimeInterval = 0
    var forced: Bool?
    var forcedUntil: TimeInterval = 0
    var lastSpokeAt: Date?
}

/// A step the engine runs later, in simulated seconds (so the Speed switch scales it).
struct DemoPending {
    let at: TimeInterval
    let action: DemoAction
    let personId: String?
    let gen: Int
}

enum DemoAction {
    case connectDone
    case mediaArrived
    case answer
    case decline
    case ringTimeout
    case goLost
    case rejoin
    case giveUp
    case myReconnectOK
    case myReconnectFail
}

/// One line of the event log.
struct DemoLogEntry: Identifiable {
    enum Kind { case state, event, warning }
    let id = UUID()
    let simTime: TimeInterval
    let text: String
    let kind: Kind

    var stamp: String {
        let total = max(0, simTime)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }
}

/// A remove waiting for the confirm alert.
struct DemoRemoval: Identifiable {
    let tile: CallTile
    let block: Bool
    var id: String { tile.id + (block ? "-block" : "") }
}
