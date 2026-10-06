import SwiftUI
import CoreImage
import LiveKit

// ONE PARTICIPANT TILE, EVERY STATE (owner spec §8, §14). The look follows the reference app's tile:
// video fills the tile, camera off = the person's photo blurred behind a centred round avatar, a
// muted badge bottom-left, no names on tiles. Where the reference app draws nothing (who is speaking,
// pinned, poor network) the owner's spec adds a quiet mark: a thin border, two small glyphs.

/// Where the tile is drawn. Decides corner, badges and the name. `.pip` is my own self view: at its
/// small 40pt width the badges shrink (16pt muted badge, no network badge) so they do not cover it.
enum CallTileStyle { case grid, focus, strip, alone, pip }

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
                content(width: width, height: geo.size.height)
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

    private var corner: CGFloat {
        switch style {
        case .strip, .pip: return 8
        case .alone: return 0          // edge to edge, nothing to round against
        case .grid, .focus: return GroupCallMetrics.tileCorner
        }
    }

    // MARK: - Video or avatar

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
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
            cameraOff(width: width, height: height)
        }
    }

    /// The reference app's camera-off tile: blurred photo filling the tile, round avatar centred.
    private func cameraOff(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            TileBackdrop(photoUrl: tile.photoUrl)
            VStack(spacing: 10) {
                AvatarView(name: tile.name, photoUrl: tile.photoUrl,
                           size: Self.avatarSize(width: width, height: height))
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

    /// The reference app's avatar size rule, by tile width, capped by the height (a wide, short
    /// landscape tile would otherwise clip the circle top and bottom).
    static func avatarSize(width: CGFloat, height: CGFloat) -> CGFloat {
        let byWidth: CGFloat
        if width > 180 { byWidth = 112 }
        else if width > 102 { byWidth = 96 }
        else if width > 48 { byWidth = width - 36 }
        else { byWidth = 16 }
        return min(byWidth, max(16, height - 16))
    }

    // MARK: - Badges

    @ViewBuilder
    private func badges(width: CGFloat) -> some View {
        let inset: CGFloat = width >= 170 ? 8 : 4
        // The small self pip (40pt wide): a 28pt badge would cover most of it.
        let compact = style == .pip && width < 60
        ZStack {
            // Muted, on every style. The reference app hides it on the big tile and fullscreen, but
            // here the big tile is a pinned person (spec §16: who is muted) and fullscreen is me
            // alone (I must see that I am muted).
            if tile.isMuted {
                badge("mic.slash.fill", size: compact ? 16 : 28, glyph: compact ? 9 : 16)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
            }
            if tile.networkPoor && !compact {
                // The focus tile's top-leading corner holds the "Pinned" / "Presenting" label.
                badge("wifi.exclamationmark", size: 22, glyph: 11)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: style == .focus ? .topTrailing : .topLeading)
                    .transition(.opacity)
            }
            // Not on the focus tile: its "Pinned" label already says it.
            if isPinned && style != .strip && style != .pip && style != .focus {
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
/// The blur is made ONCE per photo url, on a 64px copy, and cached (`TileBackdropBlur`): a live
/// `.blur(radius:)` re-ran a full-size Gaussian on every frame of every reflow, for every camera-off
/// tile of a big call (spec §10 performance).
private struct TileBackdrop: View {
    let photoUrl: String?
    @State private var image: UIImage?

    init(photoUrl: String?) {
        self.photoUrl = photoUrl
        // First frame from the blur cache, else from the avatar in memory/disk (blurring a 64px copy
        // is cheap), so a tile does not flash grey before the blur appears.
        _image = State(initialValue: TileBackdropBlur.cachedOrMake(photoUrl))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)   // smooth upscale of the 64px copy
                    .scaledToFill()
                    .overlay(Color.black.opacity(0.35))   // keeps the white badges readable
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(GroupCallMotion.fade, value: image != nil)
        .task(id: photoUrl) {
            guard let s = photoUrl, !s.isEmpty else { image = nil; return }
            if let hit = TileBackdropBlur.cached(s) { image = hit; return }
            let img = await ProfilePhotoLoader.shared.avatar(s)
            guard !Task.isCancelled, let img else { return }
            if let blurred = TileBackdropBlur.make(img, url: s) { image = blurred }
        }
    }
}

/// The pre-blurred backdrops, one per photo url. A photo change is a new url (`?v=`), so an entry
/// never needs invalidating. 64px images, a few KB each.
private enum TileBackdropBlur {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()
    // One context for every tile: building a CIContext is expensive.
    private static let context = CIContext(options: nil)
    private static let side: CGFloat = 64
    // Sigma on the 64px copy. The tile then scales the copy up 2-10x, which softens it further, so
    // this reads as the old 28pt blur at every tile size.
    private static let sigma: Double = 3

    static func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    /// The cached blur, else one made now from the avatar already in memory/disk. nil = load later.
    static func cachedOrMake(_ url: String?) -> UIImage? {
        guard let url, !url.isEmpty else { return nil }
        if let hit = cached(url) { return hit }
        guard let avatar = ProfilePhotoLoader.shared.cachedAvatar(url) else { return nil }
        return make(avatar, url: url)
    }

    /// Downsample to 64px on the long side, blur once, cache under `url`.
    static func make(_ source: UIImage, url: String) -> UIImage? {
        if let hit = cached(url) { return hit }
        let long = max(source.size.width, source.size.height)
        guard long > 0 else { return nil }
        let scale = min(1, side / long)
        let target = CGSize(width: max(1, (source.size.width * scale).rounded()),
                            height: max(1, (source.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cg = small.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        // Clamped first so the edges do not fade to transparent, cropped back after.
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let out = context.createCGImage(blurred, from: input.extent) else { return nil }
        let image = UIImage(cgImage: out, scale: 1, orientation: .up)
        cache.setObject(image, forKey: url as NSString)
        return image
    }
}
