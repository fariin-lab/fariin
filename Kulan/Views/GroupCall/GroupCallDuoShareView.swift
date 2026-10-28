import SwiftUI
import LiveKit

/// ⛔ TWO PEOPLE AND A SHARED SCREEN: THE 1:1 CALL'S SHARE LAYOUT (owner 2026-10-28: "when the group
/// call is only 2 people, use exactly the person-to-person call's screen share UI"). It had the group
/// stage instead: a "Presenting" tile with a floating self card over it. Now, as `CallView`
/// `shareLayoutView` draws it: the shared screen in a rounded card under the header, whole and never
/// cropped (or, while I share, "You're sharing your screen" with Stop), and the two people as tiles
/// under it, them first, then me. A tap anywhere shows or hides the controls, as on the 1:1 screen.
/// `GroupCallView` puts it in the stage's slot, so the header and the call buttons stay as they are.
struct GroupCallDuoShareView: View {
    @ObservedObject var stage: GroupCallStage
    let local: CallTile
    let remote: CallTile
    let iAmSharing: Bool
    let onTap: () -> Void
    let onStop: () -> Void

    var body: some View {
        GeometryReader { geo in
            // The 1:1 layout's tile height: about a sixth of the screen, 96 to 150 pt.
            let tileH = min(150, max(96, geo.size.height * 0.17))
            VStack(spacing: 12) {
                card
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 10) {
                    personTile(remote, height: tileH)
                    personTile(local, height: tileH)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder private var card: some View {
        if iAmSharing {
            GroupCallSharingCard(onStop: onStop, onTap: onTap)
        } else {
            // Their screen: the tile draws a screen track whole, on black, never mirrored.
            GroupCallTileView(tile: remote,
                              track: stage.videoTrack(remote.id, preferScreen: true),
                              style: .focus,
                              isActiveSpeaker: false,
                              isPinned: false,
                              onTap: onTap)
                .clipShape(RoundedRectangle(cornerRadius: GroupCallMetrics.tileCorner, style: .continuous))
        }
    }

    /// A person: their camera when it is on (never a screen), otherwise their photo.
    private func personTile(_ t: CallTile, height: CGFloat) -> some View {
        GroupCallTileView(tile: t,
                          track: t.hasVideo ? stage.videoTrack(t.id, preferScreen: false) : nil,
                          style: .grid,
                          isActiveSpeaker: stage.activeSpeakerId == t.id,
                          isPinned: false,
                          onTap: onTap)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: GroupCallMetrics.tileCorner, style: .continuous))
    }
}
