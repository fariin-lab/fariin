import SwiftUI
import LiveKit

// ONE PARTICIPANT TILE, EVERY STATE (owner spec §8, §14). The look follows the reference app's tile:
// video fills the tile, camera off = the person's photo blurred behind a centred round avatar, a
// muted badge bottom-left, no names on tiles. Where the reference app draws nothing (who is speaking,
// pinned, poor network) the owner's spec adds a quiet mark: a thin border, two small glyphs.

/// Where the tile is drawn. Decides corner, badges and the name.
enum CallTileStyle { case grid, focus, strip, alone }

struct GroupCallTileView: View {
    let tile: CallTile
    let track: VideoTrack?        // nil = avatar
    let style: CallTileStyle
    let isActiveSpeaker: Bool
    let isPinned: Bool
    var onTap: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                content(width: width)
                badges(width: width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            // Spec §8: the speaker must be obvious. Thin border, no glow, no scale (owner rule).
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.green, lineWidth: GroupCallMetrics.speakingBorder)
                .opacity(isActiveSpeaker ? 1 : 0)
                .animation(GroupCallMotion.fade, value: isActiveSpeaker)
        )
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture { onTap() }
        // One VoiceOver element per tile (spec §16): who, their state, and what a tap does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isPinned ? "Double-tap to unpin" : "Double-tap to focus")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    private var corner: CGFloat { style == .strip ? 8 : GroupCallMetrics.tileCorner }

    // MARK: - Video or avatar

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let track {
            // A video view only when there is a track: adaptiveStream pauses a track that has no
            // attached view, so camera-off and unsubscribed tiles must not build one (contract rule).
            if tile.isScreenShare {
                // A shared screen is never cropped (text must stay readable) and never mirrored.
                ZStack {
                    Color.black
                    SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: .off)
                }
            } else {
                // `.auto` mirrors only the local front camera, the same as the old screen did.
                SwiftUIVideoView(track, layoutMode: .fill)
            }
        } else {
            cameraOff(width: width)
        }
    }

    /// The reference app's camera-off tile: blurred photo filling the tile, round avatar centred.
    private func cameraOff(width: CGFloat) -> some View {
        ZStack {
            TileBackdrop(photoUrl: tile.photoUrl)
            VStack(spacing: 10) {
                AvatarView(name: tile.name, photoUrl: tile.photoUrl, size: Self.avatarSize(width: width))
                if style == .alone {
                    Text(tile.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    /// The reference app's avatar size rule, by tile width.
    static func avatarSize(width: CGFloat) -> CGFloat {
        if width > 180 { return 112 }
        if width > 102 { return 96 }
        if width > 48 { return width - 36 }
        return 16
    }

    // MARK: - Badges

    @ViewBuilder
    private func badges(width: CGFloat) -> some View {
        let inset: CGFloat = width >= 170 ? 8 : 4
        ZStack {
            // Muted: the reference app hides it on the big speaker tile and fullscreen.
            if tile.isMuted && (style == .grid || style == .strip) {
                badge("mic.slash.fill", size: 28, glyph: 16)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
            }
            if tile.networkPoor {
                badge("wifi.exclamationmark", size: 22, glyph: 11)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
            if isPinned && style != .strip {
                badge("pin.fill", size: 22, glyph: 11)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .animation(GroupCallMotion.fade, value: tile.isMuted)
        .animation(GroupCallMotion.fade, value: tile.networkPoor)
        .animation(GroupCallMotion.fade, value: isPinned)
        .allowsHitTesting(false)
    }

    private func badge(_ symbol: String, size: CGFloat, glyph: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(0.7)))
    }

    // MARK: - VoiceOver

    private var accessibilityText: String {
        var parts = [tile.name]
        if tile.isMuted { parts.append("muted") }
        if isActiveSpeaker { parts.append("speaking") }
        if tile.isScreenShare { parts.append("presenting") }
        else if track == nil { parts.append("camera off") }
        if tile.networkPoor { parts.append("poor connection") }
        if isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

/// The camera-off background: the person's photo, blurred, filling the tile. Loads through the
/// app's one avatar pipeline (`ProfilePhotoLoader`, same as `AvatarView`); no photo = dark gradient.
private struct TileBackdrop: View {
    let photoUrl: String?
    @State private var image: UIImage?

    init(photoUrl: String?) {
        self.photoUrl = photoUrl
        // First frame from memory/disk, so a tile does not flash grey before the blur appears.
        _image = State(initialValue: ProfilePhotoLoader.shared.cachedAvatar(photoUrl))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 28, opaque: true)
                    .overlay(Color.black.opacity(0.35))   // keeps the white badges readable
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(GroupCallMotion.fade, value: image != nil)
        .task(id: photoUrl) {
            guard let s = photoUrl, !s.isEmpty else { image = nil; return }
            let img = await ProfilePhotoLoader.shared.avatar(s)
            guard !Task.isCancelled else { return }
            if let img { image = img }
        }
    }
}
