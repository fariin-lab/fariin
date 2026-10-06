import SwiftUI
import LiveKit

// The speaker page: one large tile filling the stage and, below it, the strip with everyone else.
// The reference app has this page (its top speaker full size, the rest in the overflow strip); the
// tap-to-unpin and the "Pinned" / "Presenting" label are the owner's additions (spec §16: the user
// must see who they are viewing and how to get back). The local participant never appears here: they
// are the self pip, drawn by the parent.
struct GroupCallFocusView: View {
    @ObservedObject var stage: GroupCallStage
    let focusId: String
    /// Passed by the parent so the large tile can fly from its grid frame. Without it the tile fades.
    var namespace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusTile: CallTile? {
        stage.tiles.first { $0.id == focusId }
    }

    /// Everyone but the focused tile and the local participant, in spec §13 order, so the most
    /// relevant people sit at the visible start of the strip.
    private var others: [String] {
        let rest = stage.tilesWithLiveSpeech.filter { $0.id != focusId && !$0.isLocal }
        return GroupCallPriority.ranked(rest, focusedId: nil,
                                        speakerId: stage.activeSpeakerId, now: Date())
            .map(\.id)
    }

    var body: some View {
        let stripIds = others
        VStack(spacing: GroupCallMetrics.spacing) {
            if let tile = focusTile {
                largeTile(tile, hasStrip: !stripIds.isEmpty)
                    // Reduce Motion: no flying tile, the fade below.
                    .modifier(FocusTileTransition(id: tile.id, namespace: reduceMotion ? nil : namespace,
                                                  animation: GroupCallMotion.stage(reduceMotion: reduceMotion)))
            } else {
                // The focused person just left: keep the space still for the one frame before the
                // stage drops back to the grid, so nothing jumps (spec §14).
                Color.clear
            }
            if !stripIds.isEmpty {
                GroupCallStripView(stage: stage, ids: stripIds)
                    .transition(.opacity)
            }
        }
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: stripIds)
    }

    private func largeTile(_ tile: CallTile, hasStrip: Bool) -> some View {
        // A screen share is drawn with .fit by the tile view for style .focus (a cropped slide is
        // unreadable); a camera fills the frame.
        GroupCallTileView(
            tile: tile,
            // Camera off and not presenting = the avatar (no frozen last frame).
            track: (tile.hasVideo || tile.isScreenShare) ? stage.videoTrack(tile.id) : nil,
            style: .focus,
            isActiveSpeaker: stage.activeSpeakerId == tile.id,
            isPinned: stage.pinnedId == tile.id,
            onTap: {
                // A presenter the stage put here by itself (nobody pinned) stays: the share holds
                // the stage until it ends, so a pin would only add a badge and change nothing.
                guard !isAutoPresenter(tile) else { return }
                // Tap again to go back to the grid (owner spec §16: how to focus someone, and undo it).
                withAnimation(GroupCallMotion.stage(reduceMotion: reduceMotion)) { stage.togglePin(tile.id) }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: GroupCallMetrics.tileCorner, style: .continuous))
        .overlay(alignment: .topLeading) { viewingLabel(tile) }
        .padding(.horizontal, GroupCallMetrics.inset)
        .padding(.top, GroupCallMetrics.inset)
        // With the strip below, its own inset is the gap; without it the tile keeps the stage inset.
        .padding(.bottom, hasStrip ? 0 : GroupCallMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHint(Text(isAutoPresenter(tile) ? "" : "Double-tap to return to the grid"))
    }

    /// Shown large because they are presenting, not because the user pinned them.
    private func isAutoPresenter(_ tile: CallTile) -> Bool {
        tile.isScreenShare && stage.pinnedId != tile.id
    }

    /// Quiet capsule that names why this tile is large (spec §16: who they are viewing).
    private func viewingLabel(_ tile: CallTile) -> some View {
        let text = tile.isScreenShare ? "Presenting" : "Pinned"
        return Text(text)
            .font(.footnote.weight(.semibold))   // 13pt at default, follows Dynamic Type
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .padding(.top, 10)
            .padding(.leading, 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // the tile's own label already says pinned / presenting
    }
}

/// Matched geometry when the parent shares a namespace with the grid, a plain fade otherwise.
/// One curve for both (GroupCallMotion.layout, the fade under Reduce Motion), no scale, so there is
/// no zoom (spec §12).
private struct FocusTileTransition: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    let animation: Animation

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content.transition(AnyTransition.opacity.animation(animation))
        }
    }
}
