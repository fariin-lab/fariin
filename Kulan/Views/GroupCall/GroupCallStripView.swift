import SwiftUI
import LiveKit

/// The horizontal overflow strip: people who are not in the grid, or the others while one tile is
/// focused (owner spec §9, §11). It matches the reference app: 72pt squares, 4pt apart, the first one
/// 16pt from the edge, the newest joiner first, no scroll indicators (owner, 2026-10-06: it was 6pt
/// apart, 6pt from the edge, in priority order).
///
/// Lazy on purpose (spec §10): LazyHStack only builds the tiles that are scrolled into view, and a
/// tile that is not built (or has scrolled out, see `visible`) has no video view, so LiveKit's
/// adaptiveStream stops its video. A strip of
/// 40 people therefore costs about five live video layers, not 40.
struct GroupCallStripView: View {
    @ObservedObject var stage: GroupCallStage
    /// Who is in the strip. The caller decides who; the order is the strip's own (newest first).
    let ids: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Tiles on screen now. LazyHStack keeps a tile it built once alive after it scrolls out, video
    /// view included, so adaptiveStream would keep that video coming: a tile gets its track only
    /// between onAppear and onDisappear (spec §10).
    @State private var visible: Set<String> = []

    /// The pip's width as drawn now (small, or enlarged), from GroupCallView.
    @Environment(\.groupCallSelfPipWidth) private var pipWidth

    /// The self view pip floats over the strip's trailing edge, so the last tile scrolls clear of it:
    /// the pip's current width, its trailing inset and the stage's 6pt spacing. The only place this
    /// gap is kept; the grid and focus views do not pad the strip again.
    private var selfPipClearance: CGFloat {
        pipWidth + GroupCallSelfView.trailingInset + GroupCallMetrics.spacing
    }

    /// The strip's own insets. Leading = 16, the reference app's (it used to be the grid's 6pt
    /// inset). Top = the stage spacing: the same 6pt gap the grid keeps between its tiles
    /// (the grid overlaps its own bottom inset with it, see GroupCallGridView). Bottom = the strip
    /// inset, which the self pip's bottom edge lines up with (GroupCallView).
    static let leadingInset: CGFloat = GroupCallMetrics.stripLeading
    static let topInset: CGFloat = GroupCallMetrics.spacing
    static let bottomInset: CGFloat = GroupCallMetrics.stripInset

    /// Height the parent reserves for the strip: 6 + 72 + 12.
    static var height: CGFloat { topInset + GroupCallMetrics.stripTile + bottomInset }

    var body: some View {
        let byId = Dictionary(stage.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered: [String] = GroupCallPriority.newestFirst(ids.compactMap { byId[$0] }).map(\.id)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: GroupCallMetrics.stripSpacing) {
                ForEach(ordered, id: \.self) { id in
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
                            onTap: { stage.togglePin(id) },
                            menu: stage.tileMenu(for: tile)
                        )
                        .frame(width: GroupCallMetrics.stripTile, height: GroupCallMetrics.stripTile)
                        .onAppear { visible.insert(id) }
                        .onDisappear { visible.remove(id) }
                    }
                }
            }
            .padding(.leading, Self.leadingInset)
            .padding(.trailing, selfPipClearance)
            .padding(.top, Self.topInset)
            .padding(.bottom, Self.bottomInset)
        }
        .frame(height: GroupCallStripView.height)
        // Tiles slide to their new place when someone joins or leaves.
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: ordered)
        // Reference app: the strip fades in and out when it becomes non-empty / empty.
        .opacity(ids.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: ids.isEmpty)
        .allowsHitTesting(!ids.isEmpty)
        // VoiceOver: one labelled container, the tiles inside stay reachable (spec §16).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More participants")
    }
}
