import SwiftUI
import LiveKit

/// ⛔ TWO PEOPLE IN A GROUP OR LINK CALL LOOK LIKE A 1:1 CALL — owner, 2026-10-06, with screenshots
/// of a two-person link call drawn as a letterboxed group tile: "2 people = normal one-to-one call
/// UI, 3 or more = group call UI", like the reference app. While exactly one other person is in the
/// call (and nobody is presenting a screen), `GroupCallView` draws this instead of the stage:
///
/// - the other person edge to edge, behind the header and the controls (their camera, or their
///   photo in the middle when it is off);
/// - my camera as the 1:1 call's corner tile: 135x240 with the controls up, 79x140 with them away,
///   bottom-right at home, dragged to any corner (`PipTileDrag`, the 1:1 tile's own gesture), a tap
///   on the grown tile swaps big and small with the same 0.25s ease;
/// - a voice call (no camera on either side) is just their photo, no tile, as a 1:1 voice call is;
///   on a voice call the ground is their colour, on a video call it is black (the 1:1 rules).
///
/// The numbers are the 1:1 screen's (`CallView.pipLayer`), so the two cannot drift apart unnoticed:
/// change one, change both.
struct GroupCallDuoView: View {
    @ObservedObject var stage: GroupCallStage
    let local: CallTile
    let remote: CallTile
    /// My feed is the big one. Owned by `GroupCallView` so it survives a re-render.
    @Binding var swapped: Bool
    let chromeVisible: Bool
    let insets: EdgeInsets
    let onBackgroundTap: () -> Void
    /// A finger is on the tile (the hide clock stops) / it was let go (the clock starts again).
    let onTileTouch: () -> Void
    let onTileRelease: () -> Void
    /// The chrome comes back (a tap on the small tile while it is away).
    let onShowChrome: () -> Void

    @State private var cornerLeft = false
    @State private var cornerTop = false

    private var big: CallTile { swapped ? local : remote }
    private var small: CallTile { swapped ? remote : local }
    /// The live feeds, nil while a camera is off OR its track has not arrived yet (a camera marked
    /// on with no picture must show the photo, not a black screen).
    private var bigTrack: VideoTrack? { big.hasVideo ? stage.videoTrack(big.id, preferScreen: false) : nil }
    private var smallTrack: VideoTrack? { small.hasVideo ? stage.videoTrack(small.id, preferScreen: false) : nil }
    /// A video call, in the 1:1 sense: someone's camera is on.
    private var anyVideo: Bool { local.hasVideo || remote.hasVideo }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ground
                bigFeed(geo)
                // The 1:1 screen's dark top scrim: white name and buttons stay readable over a
                // bright picture (CallView, "L1").
                if bigTrack != nil {
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: insets.top + 140)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
                // Tap anywhere that is not the tile: show or hide the chrome (the 1:1 screen's rule).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onBackgroundTap() }
                if bigTrack == nil {
                    AvatarView(name: big.name, photoUrl: big.photoUrl, size: 180)
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if anyVideo {
                    tile(geo).zIndex(2)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: swapped)
        .animation(.easeInOut(duration: 0.2), value: bigTrack != nil)
        .animation(.easeInOut(duration: 0.3), value: anyVideo)
    }

    // MARK: - Big

    /// Voice: their colour (the profile's palette, read from the picture already on screen), black
    /// when there is none. Video: black, the floor under a feed (CallView `background`).
    private var ground: some View {
        let colour: Color = {
            guard !anyVideo, let url = big.photoUrl, !url.isEmpty else { return .black }
            if let p = ProfilePalette.warm(url: url) { return Color(p.page) }
            if let shown = ProfilePhotoLoader.shared.cachedAvatar(url),
               let p = ProfilePalette.now(shown, url: url) { return Color(p.page) }
            return .black
        }()
        return colour.ignoresSafeArea()
    }

    @ViewBuilder
    private func bigFeed(_ geo: GeometryProxy) -> some View {
        if let track = bigTrack {
            SwiftUIVideoView(track, layoutMode: .fill)
                .id(big.cameraTrackSid)   // a republished camera rebinds (as the tiles do)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Corner tile

    private func tile(_ geo: GeometryProxy) -> some View {
        let tileW: CGFloat = chromeVisible ? 135 : 79
        let tileH: CGFloat = chromeVisible ? 240 : 140
        // Clear of the controls capsule (54pt buttons + 12pt padding, 10pt from the safe bottom)
        // with the chrome up; near the edge with it away, as the 1:1 tile.
        let bottomPad = insets.bottom + (chromeVisible ? 104 : 12)
        let maxLeft = -(geo.size.width - tileW - 24)
        let maxUp = -max(0, geo.size.height - tileH - (insets.top + 64) - bottomPad)
        let rest = CGSize(width: cornerLeft ? maxLeft : 0, height: cornerTop ? maxUp : 0)
        return tileContent
            .frame(width: tileW, height: tileH)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .modifier(PipTileDrag(
                rest: rest, maxLeft: maxLeft, maxUp: maxUp, entering: false,
                onBegin: onTileTouch,
                onSnap: { left, top in cornerLeft = left; cornerTop = top },
                onFinish: onTileRelease
            ))
            // Two stages, as the 1:1 tile: with the chrome away a tap only brings it back (and grows
            // the tile); with it up, a tap swaps big and small.
            .onTapGesture {
                guard chromeVisible else { onShowChrome(); return }
                onShowChrome()
                withAnimation(.easeInOut(duration: 0.25)) { swapped.toggle() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(small.isLocal ? "Your video" : "\(small.name)'s video")
            .accessibilityHint("Double-tap to swap")
            .accessibilityAddTraits(.isButton)
            .padding(.bottom, bottomPad)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.spring(duration: 0.4), value: chromeVisible)
    }

    /// That person's video, or their photo on a dark card with the camera-off glyph (the 1:1 tile).
    @ViewBuilder
    private var tileContent: some View {
        if let track = smallTrack {
            SwiftUIVideoView(track, layoutMode: .fill)
                .id(small.cameraTrackSid)
        } else {
            ZStack {
                Color.black
                AvatarView(name: small.name, photoUrl: small.photoUrl, size: 54)
                VStack {
                    Spacer()
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 8)
                }
            }
        }
    }
}
