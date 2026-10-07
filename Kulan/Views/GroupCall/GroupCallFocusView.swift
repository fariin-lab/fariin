import SwiftUI
import LiveKit

// The speaker page: one large tile filling the stage and, below it, the strip with everyone else.
// The reference app has this page (its top speaker full size, the rest in the overflow strip); the
// tap-to-unpin and the "Pinned" / "Presenting" label are the owner's additions (spec §16: the user
// must see who they are viewing and how to get back). The local participant never appears here: they
// are the self pip, drawn by the parent.
// owner, 2026-10-06: also the pager's second page (GroupCallStagePager), where the large tile is
// whoever is speaking, not a pin: `isSpeakerPage` drops the "Pinned" label there, and a tap pins.
struct GroupCallFocusView: View {
    @ObservedObject var stage: GroupCallStage
    let focusId: String
    /// Passed by the parent so the large tile can fly from its grid frame. Without it the tile fades.
    var namespace: Namespace.ID? = nil
    /// The pager's speaker page: the large tile follows the active speaker and nobody is pinned.
    var isSpeakerPage: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Audit M-101, 2026-10-07: the large tile's top is the stage inset from the top of the screen,
    /// under the status bar and the header; its label and top marks move down by the rest.
    @Environment(\.groupCallTopClearance) private var topClearance
    private var labelDrop: CGFloat { max(0, topClearance - GroupCallMetrics.inset) }

    private var focusTile: CallTile? {
        stage.tiles.first { $0.id == focusId }
    }

    /// Everyone but the focused tile and the local participant. The strip puts them in its own
    /// order (newest joiner first, owner 2026-10-06), so no ranking here any more.
    private var others: [String] {
        stage.tiles.filter { $0.id != focusId && !$0.isLocal }.map(\.id)
    }

    var body: some View {
        let stripIds = others
        // No spacing of its own: the strip's 6pt top inset is the gap below the large tile.
        VStack(spacing: 0) {
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
                // On the speaker page nobody is pinned yet, so the same tap pins this person.
                withAnimation(GroupCallMotion.stage(reduceMotion: reduceMotion)) { stage.togglePin(tile.id) }
            },
            menu: stage.tileMenu(for: tile),
            topClearance: labelDrop
        )
        .clipShape(RoundedRectangle(cornerRadius: GroupCallMetrics.tileCorner, style: .continuous))
        .overlay(alignment: .topLeading) {
            viewingLabel(tile)
                .padding(.top, labelDrop)
                .animation(GroupCallMotion.fade, value: tile.isHandRaised)
        }
        .padding(.horizontal, GroupCallMetrics.inset)
        .padding(.top, GroupCallMetrics.inset)
        // With the strip below, its own inset is the gap; without it the tile keeps the stage inset.
        .padding(.bottom, hasStrip ? 0 : GroupCallMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHint(Text(tapHint(tile)))
    }

    private func tapHint(_ tile: CallTile) -> String {
        if isAutoPresenter(tile) { return "" }
        return isSpeakerPage ? "Double-tap to pin" : "Double-tap to return to the grid"
    }

    /// Shown large because they are presenting, not because the user pinned them.
    private func isAutoPresenter(_ tile: CallTile) -> Bool {
        tile.isScreenShare && stage.pinnedId != tile.id
    }

    /// The large tile's top-left corner. "Presenting" wins; a raised hand takes the place of
    /// "Pinned" while it is up (owner, 2026-10-06); the speaker page has no "Pinned" to show.
    @ViewBuilder
    private func viewingLabel(_ tile: CallTile) -> some View {
        if tile.isScreenShare {
            viewingCapsule("Presenting")
        } else if tile.isHandRaised {
            CallRaisedHandChip(name: tile.name)
                .padding(.top, 10)
                .padding(.leading, 10)
                .padding(.trailing, 44)   // clear of the network glyph, top-right on this tile
                .allowsHitTesting(false)
                .accessibilityHidden(true)   // the tile's own label says "hand raised"
        } else if !isSpeakerPage {
            viewingCapsule("Pinned")
        }
    }

    /// Quiet capsule that names why this tile is large (spec §16: who they are viewing).
    private func viewingCapsule(_ text: String) -> some View {
        Text(text)
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
