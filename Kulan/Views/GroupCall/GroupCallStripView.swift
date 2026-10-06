import SwiftUI
import LiveKit

/// The horizontal overflow strip: people who are not in the grid, or the others while one tile is
/// focused (owner spec §9, §11). It matches the reference app: 72pt squares, 6pt apart, no scroll
/// indicators.
///
/// Lazy on purpose (spec §10): LazyHStack only builds the tiles that are scrolled into view, and a
/// tile that is not built (or has scrolled out, see `visible`) has no video view, so LiveKit's
/// adaptiveStream stops its video. A strip of
/// 40 people therefore costs about five live video layers, not 40.
struct GroupCallStripView: View {
    @ObservedObject var stage: GroupCallStage
    /// Tile ids in display order.
    let ids: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Tiles on screen now. LazyHStack keeps a tile it built once alive after it scrolls out, video
    /// view included, so adaptiveStream would keep that video coming: a tile gets its track only
    /// between onAppear and onDisappear (spec §10).
    @State private var visible: Set<String> = []

    /// The self view pip floats over the strip's trailing edge, so the last tile scrolls clear of it:
    /// the pip's small width, its trailing inset and 4pt (the reference app's trim). The only place
    /// this gap is kept; the grid and focus views do not pad the strip again.
    private var selfPipClearance: CGFloat {
        let remotes = stage.tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 }
        return GroupCallSelfView.size(remoteCount: remotes, expanded: false).width
            + GroupCallSelfView.trailingInset + 4
    }

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
                            // A presenter who is not the focus: their camera (or avatar), not a
                            // second 72pt copy of the screen.
                            track: (tile.hasVideo && visible.contains(id))
                                ? stage.videoTrack(id, preferScreen: false) : nil,
                            style: .strip,
                            isActiveSpeaker: stage.activeSpeakerId == id,
                            isPinned: stage.pinnedId == id,
                            onTap: { stage.togglePin(id) }
                        )
                        .frame(width: GroupCallMetrics.stripTile, height: GroupCallMetrics.stripTile)
                        .onAppear { visible.insert(id) }
                        .onDisappear { visible.remove(id) }
                    }
                }
            }
            .padding(.leading, GroupCallMetrics.stripInset)
            .padding(.trailing, selfPipClearance)
            .padding(.vertical, GroupCallMetrics.stripInset)
        }
        .frame(height: GroupCallStripView.height)
        // Tiles slide to their new place when someone joins, leaves or changes rank.
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: ids)
        // Reference app: the strip fades in and out when it becomes non-empty / empty.
        .opacity(ids.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: ids.isEmpty)
        .allowsHitTesting(!ids.isEmpty)
        // VoiceOver: one labelled container, the tiles inside stay reachable (spec §16).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More participants")
    }
}
