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
//   GroupCallFocusView.swift      one large tile + the strip (a pin, a share, or the speaker page)
//   GroupCallStagePager.swift     grid page above, speaker page below, one vertical swipe apart
//   GroupCallStripView.swift      the horizontal overflow strip
//   GroupCallSelfView.swift       my own camera, the 9:16 pip bottom-right (when others are here)
//   GroupCallStatusBanner.swift   connection lost / poor network / join-leave toasts
//                                 (reconnecting is the header subtitle's job)
// Outside this folder: Views/GroupCallView.swift (header, controls, places the stage) and
// Views/GroupCallParticipantsSheet.swift (the people list), both reading the same stage.
//
// Rules every piece follows:
// - Quality is LiveKit's adaptiveStream (already on in GroupCallService's RoomOptions): a video view
//   that is on screen asks for the layer that fits its pixel size, a view that is NOT in the hierarchy
//   receives nothing. So a tile that is not shown must not be built at all (no hidden views), and a
//   camera-off tile draws an avatar, not a video view. No manual set(videoQuality:) calls.
// - One animation for every layout change: `GroupCallMotion.layout`. No bounce, no zoom. With
//   Reduce Motion on, `GroupCallMotion.stage(reduceMotion:)` swaps it for the fade, and no view
//   scales, flies (matchedGeometryEffect) or animates the self pip size.
// - Tile identity is the participant's sid string, stable for the whole call.
// - The pager builds a page only while part of it is on screen: the speaker page does not exist
//   until the swipe starts, and the grid page is dropped while the speaker page fills the stage.
// - The local participant is never ranked, placed on the grid, focused or fed to the speaker
//   tracker while anyone else is here: it is the self pip. Alone, it is the one fullscreen tile.

/// One person on the call, as the UI sees them. Built by `GroupCallStage` from the room.
struct CallTile: Identifiable, Equatable {
    let id: String              // participant sid (stable); "local" for me only before connect (no sid yet)
    let uid: String             // identity = Firebase uid ("" if unknown)
    var name: String
    var photoUrl: String?
    let isLocal: Bool
    var hasVideo: Bool          // camera publication exists, not muted, and holds a track
    var isScreenShare: Bool     // this participant is presenting a screen
    var isMuted: Bool           // microphone off
    var isSpeaking: Bool        // LiveKit's live flag (raw, flickers); NOT part of ==, see below
    var lastSpokeAt: Date?      // LiveKit's last speech time; NOT part of ==, see below
    var joinedAt: Date          // server join time, else first seen by this phone (kept across a reopen)
    var networkPoor: Bool       // connectionQuality .poor or .lost
    var isHost: Bool            // link creator / group admin / ad-hoc starter
    var cameraTrackSid: String? // the live camera track; a republish is a new sid, so views rebind
    var screenTrackSid: String? // the live screen share track, same reason
    // owner, 2026-10-06: the three states below, as the reference app's tile has them. Defaulted, so
    // a tile built without them is a plain one.
    var isConnecting: Bool = false      // media still arriving: just joined, or camera on but no picture yet
    var videoUnavailable: Bool = false  // camera on, and still no picture after the wait
    var isHandRaised: Bool = false      // raised hand (GroupCallSocial); never set on my own tile

    /// Speech is left out on purpose: the raw flag flips several times a second, and a tile that
    /// differs only in speech must not republish `tiles` and re-render the whole stage (spec §12).
    /// The live values sit in the stage's own store (`GroupCallStage.speech(for:)`), read whenever
    /// the stage re-renders for a real change or a new active speaker.
    /// A guard chain, not one long `&&` expression: sixteen mixed-type comparisons in one
    /// expression can time out the type checker.
    static func == (a: CallTile, b: CallTile) -> Bool {
        guard a.id == b.id, a.uid == b.uid, a.name == b.name else { return false }
        guard a.photoUrl == b.photoUrl, a.isLocal == b.isLocal else { return false }
        guard a.hasVideo == b.hasVideo, a.isScreenShare == b.isScreenShare else { return false }
        guard a.isMuted == b.isMuted, a.joinedAt == b.joinedAt else { return false }
        guard a.networkPoor == b.networkPoor, a.isHost == b.isHost else { return false }
        guard a.cameraTrackSid == b.cameraTrackSid else { return false }
        guard a.screenTrackSid == b.screenTrackSid else { return false }
        guard a.isConnecting == b.isConnecting, a.videoUnavailable == b.videoUnavailable else { return false }
        return a.isHandRaised == b.isHandRaised
    }
}

/// What a long press on a remote tile offers (owner, 2026-10-06; the reference app has the same
/// menu). Built by `GroupCallStage.tileMenu(for:)`, so the tile view stays dumb.
struct CallTileMenu {
    var isPinned: Bool
    /// The people list's access table: only then are Mute and Remove offered.
    var canModerate: Bool
    var onPin: () -> Void
    var onMute: () -> Void
    var onRemove: () -> Void
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
    // owner, 2026-10-06: one corner on every group tile (grid, focus, strip, self pip). It was 10;
    // owner, 2026-10-07 ("feeling like flat design", plan #3 softer tiles): 14. The two-person
    // tile keeps the 1:1 screen's own 18 (GroupCallDuoView).
    static let tileCorner: CGFloat = 14
    static let stripTile: CGFloat = 72          // square strip tiles
    static let stripSpacing: CGFloat = 4        // the reference app's (was 6)
    static let stripLeading: CGFloat = 16       // the strip's first tile from the screen edge (was 6)
    static let stripInset: CGFloat = 12         // under the strip; the self pip's bottom edge too
    /// How long a tile waits for media before it says so: 5s for a person who just joined (the
    /// reference app's wait), 8s for a camera that is on but sends no picture.
    static let joinGrace: TimeInterval = 5
    static let videoGrace: TimeInterval = 8
    static let speakingBorder: CGFloat = 2      // was 3, under a glow now (`SpeakerGlow`)
    static let speakerHold: TimeInterval = 1.5  // spec 8: no flicker between speakers
    /// Phone caps (spec 9): columns x rows the grid may use before people go to the strip.
    static func maxColumns(width: CGFloat) -> Int { width > 1080 ? 4 : (width > 768 ? 3 : 2) }
    static func maxRows(height: CGFloat) -> Int { height > 1024 ? 4 : 3 }
}

/// The one curve for every stage change (spec 12: smooth, no bounce, no excessive zoom).
enum GroupCallMotion {
    static let layout: Animation = .spring(response: 0.38, dampingFraction: 1.0)
    static let fade: Animation = .easeInOut(duration: 0.2)
    /// The layout curve, or the cross-fade when Reduce Motion is on (no sliding, no flying tiles).
    static func stage(reduceMotion: Bool) -> Animation { reduceMotion ? fade : layout }
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
//       /// Spec 13 order: presenter, focused, active speaker, recently speaking (lastSpokeAt within
//       /// 30s, newest first), other video, audio-only. The local tile is excluded whenever anyone
//       /// else is here (returned alone when it is the only one). Decides WHO overflows to the
//       /// strip; the grid's cells come from `GroupCallStage.gridPlacement` (sticky, no 30s tier).
//       static func ranked(_ tiles: [CallTile], focusedId: String?, speakerId: String?, now: Date) -> [CallTile]
//       static func stableForGrid(_ shown: [CallTile]) -> [CallTile]   // join order
//       static func newestFirst(_ tiles: [CallTile]) -> [CallTile]     // the strip's order
//       static func joinOrder(_ a: CallTile, _ b: CallTile) -> Bool    // joinedAt, uid, id
//   }

// GroupCallStage.swift
//   @MainActor final class GroupCallStage: ObservableObject {
//       init(room: Room)
//       @Published private(set) var tiles: [CallTile]            // everyone, local included
//       @Published private(set) var activeSpeakerId: String?     // remotes only
//       @Published var pinnedId: String?                          // user's focus (tap a tile)
//       @Published private(set) var mode: CallStageMode          // focus if pinned or screen share
//       @Published private(set) var connectionState: ConnectionState
//       @Published var removeCandidate: CallTile?                 // a tile's "Remove…"; the screen confirms
//       var speakerPageTileId: String?                            // speaker, else last speaker, else first remote
//       var hostUids: Set<String>
//       var inCallCount: Int { tiles.count }
//       var tilesWithLiveSpeech: [CallTile]                       // tiles + the unpublished speech
//       func speech(for tileId: String) -> (isSpeaking: Bool, lastSpokeAt: Date?)
//       func gridPlacement(_ remotes: [CallTile], capacity: Int) -> [String]   // sticky grid cells
//       func participant(_ tileId: String) -> Participant?       // for the video track
//       func videoTrack(_ tileId: String) -> VideoTrack?         // camera, or the screen share
//       func togglePin(_ tileId: String)                          // tap: pin / unpin (never local)
//       func tileMenu(for tile: CallTile) -> CallTileMenu?        // long press; nil on my own tile
//       func canModerate(_ tile: CallTile) -> Bool                // the people list's access table
//       func refreshProfiles(_ members: [CallMember])            // names/photos from the service
//   }

// GroupCallTileView.swift
//   enum CallTileStyle { case grid, focus, strip, alone, pip }
//   struct GroupCallTileView: View {
//       let tile: CallTile
//       let track: VideoTrack?        // nil = avatar
//       let style: CallTileStyle
//       let isActiveSpeaker: Bool
//       let isPinned: Bool
//       var onTap: () -> Void
//       var menu: CallTileMenu? = nil // long press: Pin / Unpin, and Mute / Remove… for a moderator
//   }

// GroupCallStagePager.swift
//   struct GroupCallStagePager: View {     // what the screen places between header and controls
//       init(stage: GroupCallStage, namespace: Namespace.ID?)
//   }
//   Fewer than 2 remotes, or focus mode: the grid / the focus view, exactly as the screen drew them
//   itself before. 2+ remotes on the grid: two pages, the grid and the speaker page.

// GroupCallGridView / GroupCallFocusView / GroupCallStripView / GroupCallSelfView /
// GroupCallStatusBanner: see their files; each takes a `GroupCallStage` as @ObservedObject.

/// The speaker's mark on a tile: a thin green edge with a soft green glow around it. Owner,
/// 2026-10-07 (plan #3, "feeling like flat design"): it was a hard 3pt border with no glow. Still
/// no scale and no layout change, so nothing moves when the speaker changes. Used by the real tile
/// and the demo's, so both draw the same mark.
struct SpeakerGlow: ViewModifier {
    let corner: CGFloat
    let on: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.green.opacity(0.95), lineWidth: GroupCallMetrics.speakingBorder)
                .shadow(color: .green.opacity(0.75), radius: 6)
                .shadow(color: .green.opacity(0.35), radius: 14)
                .opacity(on ? 1 : 0)
                .animation(GroupCallMotion.fade, value: on)
                .allowsHitTesting(false)
        )
    }
}
