import SwiftUI
import LiveKit

/// The horizontal overflow strip: people who are not in the grid, or the others while one tile is
/// focused (owner spec §9, §11). It matches the reference app: 72pt squares, 6pt apart, no scroll
/// indicators.
///
/// Lazy on purpose (spec §10): LazyHStack only builds the tiles that are scrolled into view, and a
/// tile that is not built has no video view, so LiveKit's adaptiveStream stops its video. A strip of
/// 40 people therefore costs about five live video layers, not 40.
struct GroupCallStripView: View {
    @ObservedObject var stage: GroupCallStage
    /// Tile ids in display order.
    let ids: [String]

    /// The self view pip floats over the strip's trailing edge, so the last tile scrolls clear of it.
    private static let selfPipClearance: CGFloat = 90

    /// Height the parent reserves for the strip.
    static var height: CGFloat { GroupCallMetrics.stripTile + 2 * GroupCallMetrics.stripInset }

    var body: some View {
        let byId = Dictionary(stage.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: GroupCallMetrics.stripSpacing) {
                ForEach(ids, id: \.self) { id in
                    if let tile = byId[id] {
                        GroupCallTileView(
                            tile: tile,
                            track: stage.videoTrack(id),
                            style: .strip,
                            isActiveSpeaker: stage.activeSpeakerId == id,
                            isPinned: stage.pinnedId == id,
                            onTap: { stage.togglePin(id) }
                        )
                        .frame(width: GroupCallMetrics.stripTile, height: GroupCallMetrics.stripTile)
                    }
                }
            }
            .padding(.leading, GroupCallMetrics.stripInset)
            .padding(.trailing, GroupCallStripView.selfPipClearance)
            .padding(.vertical, GroupCallMetrics.stripInset)
        }
        .frame(height: GroupCallStripView.height)
        // Tiles slide to their new place when someone joins, leaves or changes rank.
        .animation(GroupCallMotion.layout, value: ids)
        // Reference app: the strip fades in and out when it becomes non-empty / empty.
        .opacity(ids.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: ids.isEmpty)
        .allowsHitTesting(!ids.isEmpty)
        // VoiceOver: one labelled container, the tiles inside stay reachable (spec §16).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More participants")
    }
}
