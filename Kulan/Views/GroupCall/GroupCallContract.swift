import SwiftUI
import LiveKit

// ⛔ THE GROUP CALL STAGE — THE CONTRACT EVERY PIECE IS BUILT AGAINST (owner, 2026-10-06: the group
// call screen rebuilt to his spec, sections 8-16: who is speaking, screen capacity, adaptive quality,
// a real layout algorithm, smooth transitions, large-call priority, every state). This file holds the
// shared value types and the signatures; each piece lives in its own file beside it:
//
//   GroupCallLayoutEngine.swift   the grid / focus maths            (pure, no UIKit)
//   GroupCallSpeakerTracker.swift who is the active speaker, held   (pure state machine)
//   GroupCallPriority.swift       who gets a place on screen        (pure ordering)
//   GroupCallStage.swift          LiveKit room -> [CallTile], live  (ObservableObject)
//   GroupCallTileView.swift       one participant tile, every state
//   GroupCallGridView.swift       the grid page
//   GroupCallFocusView.swift      one large tile + the strip
//   GroupCallStripView.swift      the horizontal overflow strip
//   GroupCallStatusBanner.swift   reconnecting / poor network / lost
//   GroupCallParticipantList.swift the people list (replaces the old sheet's body)
//
// Rules every piece follows:
// - Quality is LiveKit's adaptiveStream (already on in GroupCallService's RoomOptions): a video view
//   that is on screen asks for the layer that fits its pixel size, a view that is NOT in the hierarchy
//   receives nothing. So a tile that is not shown must not be built at all (no hidden views), and a
//   camera-off tile draws an avatar, not a video view. No manual set(videoQuality:) calls.
// - One animation for every layout change: `GroupCallMotion.layout`. No bounce, no zoom.
// - Tile identity is the participant's sid string, stable for the whole call.

/// One person on the call, as the UI sees them. Built by `GroupCallStage` from the room.
struct CallTile: Identifiable, Equatable {
    let id: String              // participant sid (stable); "local" for me only before connect (no sid yet)
    let uid: String             // identity = Firebase uid ("" if unknown)
    var name: String
    var photoUrl: String?
    let isLocal: Bool
    var hasVideo: Bool          // camera published, enabled and not muted
    var isScreenShare: Bool     // this participant is presenting a screen
    var isMuted: Bool           // microphone off
    var isSpeaking: Bool        // LiveKit's live flag (raw, flickers)
    var lastSpokeAt: Date?      // LiveKit's last speech time
    var joinedAt: Date          // first seen by this phone
    var networkPoor: Bool       // connectionQuality .poor or .lost
    var isHost: Bool            // link creator / group admin / ad-hoc starter
}

/// What the stage is showing.
enum CallStageMode: Equatable {
    case grid                   // everyone that fits, the rest in the strip
    case focus(tileId: String)  // one large tile (pinned, or a screen share) + strip of the others
}

/// The grid's computed geometry. All values in points, in the stage's own coordinate space.
struct CallGridLayout: Equatable {
    var columns: Int
    var rows: Int
    var spacing: CGFloat
    var inset: CGFloat
    /// Frame of every tile that is ON the grid, keyed by tile id.
    var frames: [String: CGRect]
    /// Tiles that did not fit, in display order (they go to the strip).
    var overflow: [String]
}

/// Shared numbers (from the reference app's grid, owner's spec 9/11) — one place to tune them.
enum GroupCallMetrics {
    static let inset: CGFloat = 6
    static let spacing: CGFloat = 6
    static let tileCorner: CGFloat = 12
    static let stripTile: CGFloat = 72          // square strip tiles
    static let stripSpacing: CGFloat = 6
    static let stripInset: CGFloat = 12
    static let speakingBorder: CGFloat = 3
    static let speakerHold: TimeInterval = 1.5  // spec 8: no flicker between speakers
    /// Phone caps (spec 9): columns x rows the grid may use before people go to the strip.
    static func maxColumns(width: CGFloat) -> Int { width > 1080 ? 4 : (width > 768 ? 3 : 2) }
    static func maxRows(height: CGFloat) -> Int { height > 1024 ? 4 : 3 }
}

/// The one curve for every stage change (spec 12: smooth, no bounce, no excessive zoom).
enum GroupCallMotion {
    static let layout: Animation = .spring(response: 0.38, dampingFraction: 1.0)
    static let fade: Animation = .easeInOut(duration: 0.2)
}

// MARK: - Signatures the pieces implement (in their own files)

// GroupCallLayoutEngine.swift
//   enum GroupCallLayoutEngine {
//       /// The most-square grid for `ids` (already in display order) in `size`, capped by
//       /// GroupCallMetrics.maxColumns/maxRows; anything past the cap is `overflow`.
//       static func grid(ids: [String], in size: CGSize) -> CallGridLayout
//       /// How many tiles the grid can hold in `size` (columns x rows cap).
//       static func capacity(in size: CGSize) -> Int
//   }

// GroupCallSpeakerTracker.swift
//   struct GroupCallSpeakerTracker {
//       private(set) var activeSpeakerId: String?
//       /// Feed the raw speaking set every update; returns true when activeSpeakerId changed.
//       /// A new speaker takes over only after speaking continuously for 0.3s; the current one is
//       /// kept until someone else qualifies or `speakerHold` passes in silence.
//       mutating func update(speaking: Set<String>, now: Date) -> Bool
//   }

// GroupCallPriority.swift
//   enum GroupCallPriority {
//       /// Spec 13 order for who gets a place on screen: focused, active speaker, recently speaking
//       /// (lastSpokeAt within 30s, newest first), other video, audio-only; local last among equals.
//       /// The grid then shows the first `capacity` of these sorted back by joinedAt so tiles do not
//       /// jump around (`stableForGrid`).
//       static func ranked(_ tiles: [CallTile], focusedId: String?, speakerId: String?, now: Date) -> [CallTile]
//       static func stableForGrid(_ shown: [CallTile]) -> [CallTile]
//   }

// GroupCallStage.swift
//   @MainActor final class GroupCallStage: ObservableObject {
//       init(room: Room)
//       @Published private(set) var tiles: [CallTile]            // everyone, local included
//       @Published private(set) var activeSpeakerId: String?
//       @Published var pinnedId: String?                          // user's focus (tap a tile)
//       @Published private(set) var mode: CallStageMode          // focus if pinned or screen share
//       var inCallCount: Int { tiles.count }
//       func participant(_ tileId: String) -> Participant?       // for the video track
//       func videoTrack(_ tileId: String) -> VideoTrack?         // camera, or the screen share
//       func togglePin(_ tileId: String)                          // tap: pin / unpin
//       func refreshProfiles(_ members: [CallMember])            // names/photos from the service
//   }

// GroupCallTileView.swift
//   enum CallTileStyle { case grid, focus, strip, alone }
//   struct GroupCallTileView: View {
//       let tile: CallTile
//       let track: VideoTrack?        // nil = avatar
//       let style: CallTileStyle
//       let isActiveSpeaker: Bool
//       let isPinned: Bool
//       var onTap: () -> Void
//   }

// GroupCallGridView / GroupCallFocusView / GroupCallStripView / GroupCallStatusBanner /
// GroupCallParticipantList: see their files; each takes a `GroupCallStage` as @ObservedObject.
