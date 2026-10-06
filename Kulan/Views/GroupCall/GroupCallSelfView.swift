import SwiftUI

// The self view pip (owner spec §16 "who am I showing"; reference app: bottom-right, 16pt from the
// trailing edge, 9:16, corner 8, shadow 4). Only drawn while at least one remote is on the call: alone,
// the local tile is the fullscreen tile and the grid/focus draw it. Tap to enlarge, tap to shrink.
// The parent places it bottom-trailing, bottom-aligned with the strip area, and uses `size` to keep
// the grid/strip clear of it.
struct GroupCallSelfView: View {
    @ObservedObject var stage: GroupCallStage
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let trailingInset: CGFloat = 16
    static let corner: CGFloat = 8

    /// 72pt tall (9:16) with 2+ remotes, 90x160 with exactly one, 170x300 when enlarged.
    static func size(remoteCount: Int, expanded: Bool) -> CGSize {
        if expanded { return CGSize(width: 170, height: 300) }
        if remoteCount <= 1 { return CGSize(width: 90, height: 160) }
        return CGSize(width: 40.5, height: 72)
    }

    private var local: CallTile? { stage.tiles.first(where: { $0.isLocal }) }
    private var remoteCount: Int { stage.tiles.filter { !$0.isLocal }.count }

    var body: some View {
        if let local, remoteCount >= 1 {
            let size = Self.size(remoteCount: remoteCount, expanded: expanded)
            // The tile's video view already mirrors the local front camera (`.auto`); flipping it
            // again here un-mirrored the preview and drew the mute badge backwards.
            // Camera off, the tile draws the avatar look.
            let track = local.hasVideo ? stage.videoTrack(local.id) : nil
            GroupCallTileView(tile: local,
                              track: track,
                              style: .pip,
                              isActiveSpeaker: false,
                              isPinned: false,
                              onTap: toggle)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4)
                .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .padding(.trailing, Self.trailingInset)
                // Reduce Motion: the pip changes size in place, no growing animation.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: expanded)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: remoteCount > 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(local.isMuted ? "Your video, muted" : "Your video")
                .accessibilityHint(expanded ? "Double-tap to shrink" : "Double-tap to enlarge")
                .accessibilityAddTraits(.isButton)
        }
    }

    private func toggle() { expanded.toggle() }
}
