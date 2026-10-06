import SwiftUI

// The self view pip (owner spec §16 "who am I showing"; reference app: bottom-right, 16pt from the
// trailing edge, 9:16, corner 10, shadow 4). Only drawn while at least one remote is on the call: alone,
// the local tile is the fullscreen tile and the grid/focus draw it. Tap to enlarge, tap to shrink.
// The parent places it bottom-trailing, bottom-aligned with the strip area, and uses `size` to keep
// the grid/strip clear of it.
struct GroupCallSelfView: View {
    @ObservedObject var stage: GroupCallStage
    /// Owned by GroupCallView: the strip's trailing gap follows the pip's real width.
    @Binding var expanded: Bool
    /// The stage area's size, for the enlarged cap.
    let stageSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let trailingInset: CGFloat = 16
    // owner, 2026-10-06: 10, the one corner of every group tile (it was 8).
    static let corner: CGFloat = GroupCallMetrics.tileCorner
    /// Enlarge and shrink: the reference app's 0.3s spring with no bounce, the pip growing out of
    /// the corner it is parked in (it was a 0.3s ease in and out).
    static let resize: Animation = .spring(response: 0.3, dampingFraction: 1)

    /// 72pt tall (9:16) with 2+ remotes, 90x160 with exactly one. Enlarged: 170x300, capped at 45%
    /// of the stage width and the stage height less 24 (a phone on its side, a small stage), with
    /// the same shape, so it never covers the whole stage. A zero size (first pass) is not a cap.
    static func size(remoteCount: Int, expanded: Bool, stageSize: CGSize) -> CGSize {
        if expanded {
            let aspect: CGFloat = 170.0 / 300.0
            var width: CGFloat = 170
            if stageSize.width > 0 { width = min(width, stageSize.width * 0.45) }
            if stageSize.height > 0 { width = min(width, (stageSize.height - 24) * aspect) }
            width = max(width, 40.5)   // never smaller than the small pip
            return CGSize(width: width, height: width / aspect)
        }
        if remoteCount <= 1 { return CGSize(width: 90, height: 160) }
        return CGSize(width: 40.5, height: 72)
    }

    private var local: CallTile? { stage.tiles.first(where: { $0.isLocal }) }
    private var remoteCount: Int { stage.tiles.filter { !$0.isLocal }.count }

    var body: some View {
        if let local, remoteCount >= 1 {
            let size = Self.size(remoteCount: remoteCount, expanded: expanded, stageSize: stageSize)
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
                .animation(reduceMotion ? nil : Self.resize, value: expanded)
                .animation(reduceMotion ? nil : Self.resize, value: remoteCount > 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(local.isMuted ? "Your video, muted" : "Your video")
                .accessibilityHint(expanded ? "Double-tap to shrink" : "Double-tap to enlarge")
                .accessibilityAddTraits(.isButton)
        }
    }

    private func toggle() { expanded.toggle() }
}

/// The self pip's current width (small, one-remote or enlarged), set by GroupCallView on the stage
/// so the strip's trailing gap clears the pip as it really is drawn.
private struct GroupCallSelfPipWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 40.5
}

extension EnvironmentValues {
    var groupCallSelfPipWidth: CGFloat {
        get { self[GroupCallSelfPipWidthKey.self] }
        set { self[GroupCallSelfPipWidthKey.self] = newValue }
    }
}
