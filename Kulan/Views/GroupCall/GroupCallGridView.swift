import SwiftUI
import LiveKit

/// The grid page of the group call stage (owner spec §9, §11, §12, §13).
///
/// - Alone (no remotes): the local tile fills the stage in `.alone` style. The "Waiting for others…"
///   text is the header's job, not drawn here.
/// - Others present: only remotes go on the grid; the local camera is the self pip, drawn by the
///   parent at the bottom-right.
/// - Who gets a place: `GroupCallPriority.ranked` (spec §13), the first `capacity` of them, then put
///   back in join order with `stableForGrid` so tiles do not jump when the speaker changes.
/// - The rest go to `GroupCallStripView` at the bottom, and the grid area shrinks by the strip.
///
/// A ZStack with explicit frames (not a LazyVGrid) so join / leave / reflow animate as frame changes
/// with the one stage curve, `GroupCallMotion.layout` (spec §12: no bounce, no zoom). Tiles that are
/// not placed are never built, so adaptiveStream stops their video (contract rule).
struct GroupCallGridView: View {
    @ObservedObject var stage: GroupCallStage

    /// Strip row height: square tiles plus their inset above and below.
    private static let stripHeight: CGFloat = GroupCallMetrics.stripTile + 2 * GroupCallMetrics.stripInset

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        // Local goes to the pip once anyone else is present, so the grid is remotes only. Live
        // speech filled in for the ranking (the published tiles leave it out, see CallTile ==).
        let remotes = stage.tilesWithLiveSpeech.filter { !$0.isLocal }

        if remotes.isEmpty {
            aloneTile(size: size)
        } else {
            gridStage(remotes: remotes, size: size)
        }
    }

    // MARK: - Alone

    @ViewBuilder
    private func aloneTile(size: CGSize) -> some View {
        if let local = stage.tiles.first(where: { $0.isLocal }) {
            GroupCallTileView(
                tile: local,
                track: local.hasVideo ? stage.videoTrack(local.id) : nil,
                style: .alone,
                isActiveSpeaker: false,
                isPinned: false,
                onTap: {}
            )
            .frame(width: size.width, height: size.height)
            .transition(.opacity)
        } else {
            // Joining: no local participant yet. Draw nothing rather than a broken tile (spec §14).
            Color.clear
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private func gridStage(remotes: [CallTile], size: CGSize) -> some View {
        let geometry = Self.plan(
            remotes: remotes,
            pinnedId: stage.pinnedId,
            speakerId: stage.activeSpeakerId,
            size: size
        )
        let byId = Dictionary(remotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let layout = geometry.layout
        let placed = geometry.placedIds

        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(placed, id: \.self) { id in
                    if let tile = byId[id], let frame = layout.frames[id] {
                        GroupCallTileView(
                            tile: tile,
                            track: tile.hasVideo ? stage.videoTrack(id) : nil,
                            style: .grid,
                            isActiveSpeaker: stage.activeSpeakerId == id,
                            isPinned: stage.pinnedId == id,
                            onTap: { stage.togglePin(id) }
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .frame(width: geometry.gridSize.width, height: geometry.gridSize.height, alignment: .topLeading)
            .animation(GroupCallMotion.layout, value: layout.frames)

            if !layout.overflow.isEmpty {
                // The strip keeps its own trailing gap for the self pip (one place, not two).
                GroupCallStripView(stage: stage, ids: layout.overflow)
                    .frame(width: size.width, height: Self.stripHeight)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(GroupCallMotion.fade, value: layout.overflow.isEmpty)
    }

    // MARK: - Planning (pure)

    private struct Plan {
        var gridSize: CGSize
        var layout: CallGridLayout
        var placedIds: [String]
    }

    /// Decide the grid area, who is on it, and their frames.
    private static func plan(remotes: [CallTile], pinnedId: String?, speakerId: String?, size: CGSize) -> Plan {
        let ranked = GroupCallPriority.ranked(remotes, focusedId: pinnedId, speakerId: speakerId, now: Date())

        // The strip only exists when the full stage cannot hold everyone; only then does the grid
        // give up the strip's height.
        let fullCapacity = GroupCallLayoutEngine.capacity(in: size)
        let needsStrip = ranked.count > fullCapacity
        let gridSize = CGSize(
            width: size.width,
            height: max(0, size.height - (needsStrip ? stripHeight : 0))
        )
        let capacity = max(0, GroupCallLayoutEngine.capacity(in: gridSize))

        // Top `capacity` by priority, shown in join order; the rest follow so the engine hands them
        // back as `overflow` in priority order.
        let shown = GroupCallPriority.stableForGrid(Array(ranked.prefix(capacity)))
        let rest = ranked.dropFirst(capacity)
        let ids = shown.map(\.id) + rest.map(\.id)

        let layout = GroupCallLayoutEngine.grid(ids: ids, in: gridSize)
        let placed = ids.filter { layout.frames[$0] != nil }
        return Plan(gridSize: gridSize, layout: layout, placedIds: placed)
    }
}
