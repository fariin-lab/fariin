import SwiftUI
import LiveKit

/// The grid page of the group call stage (owner spec §9, §11, §12, §13).
///
/// - Alone (no remotes): the local tile fills the stage in `.alone` style. The "Waiting for others…"
///   text is the header's job, not drawn here.
/// - Others present: only remotes go on the grid; the local camera is the self pip, drawn by the
///   parent at the bottom-right.
/// - Who gets a place: `GroupCallStage.gridPlacement`, sticky cells (spec §12/§13): a placed tile
///   keeps its cell, and an active speaker off the grid takes the least important person's cell.
/// - The rest go to `GroupCallStripView` at the bottom, and the grid area shrinks by the strip.
///
/// A ZStack with explicit frames (not a LazyVGrid) so join / leave / reflow animate as frame changes
/// with the one stage curve, `GroupCallMotion.layout` (spec §12: no bounce, no zoom). Tiles that are
/// not placed are never built, so adaptiveStream stops their video (contract rule).
struct GroupCallGridView: View {
    @ObservedObject var stage: GroupCallStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

        // Alone -> the first person arrives (and back): one cross-fade, not a hard cut (spec §12).
        ZStack {
            if remotes.isEmpty {
                aloneTile(size: size)
            } else {
                gridStage(remotes: remotes, size: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(GroupCallMotion.fade, value: remotes.isEmpty)
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
        let geometry = Self.plan(remotes: remotes, stage: stage, size: size)
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
                        // Reduce Motion: a plain fade, no scale.
                        .transition(reduceMotion
                                    ? AnyTransition.opacity
                                    : AnyTransition.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .frame(width: geometry.gridSize.width, height: geometry.gridSize.height, alignment: .topLeading)
            .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: layout.frames)

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

    // MARK: - Planning

    private struct Plan {
        var gridSize: CGSize
        var layout: CallGridLayout
        var placedIds: [String]
    }

    /// Decide the grid area, who is on it, and their frames.
    @MainActor
    private static func plan(remotes: [CallTile], stage: GroupCallStage, size: CGSize) -> Plan {
        let ranked = GroupCallPriority.ranked(remotes, focusedId: stage.pinnedId,
                                              speakerId: stage.activeSpeakerId, now: Date())

        // The strip only exists when the full stage cannot hold everyone; only then does the grid
        // give up the strip's height.
        let fullCapacity = GroupCallLayoutEngine.capacity(in: size)
        let needsStrip = ranked.count > fullCapacity
        let gridSize = CGSize(
            width: size.width,
            height: max(0, size.height - (needsStrip ? stripHeight : 0))
        )
        let capacity = max(0, GroupCallLayoutEngine.capacity(in: gridSize))
        // The first layout pass has no size yet; its caps (rows by height) are not the real ones,
        // and feeding them to the sticky cells would drop and re-add people (a reorder).
        guard size.width > 0, size.height > 0 else {
            return Plan(gridSize: gridSize, layout: GroupCallLayoutEngine.grid(ids: [], in: gridSize), placedIds: [])
        }

        // Sticky cells from the stage (a speaker change swaps one cell, never reshuffles); the rest
        // follow in priority order, so the engine hands them back as `overflow` for the strip.
        let cells = stage.gridPlacement(remotes, capacity: capacity)
        let placedSet = Set(cells)
        let ids = cells + ranked.filter { !placedSet.contains($0.id) }.map(\.id)

        let layout = GroupCallLayoutEngine.grid(ids: ids, in: gridSize)
        let placed = ids.filter { layout.frames[$0] != nil }
        return Plan(gridSize: gridSize, layout: layout, placedIds: placed)
    }
}
