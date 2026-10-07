import SwiftUI

import LiveKit

// ONE PARTICIPANT TILE, EVERY STATE (owner spec §8, §14). The look follows the reference app's tile:
// video fills the tile, camera off = the person's photo blurred behind a centred round avatar, a
// muted badge bottom-left, no names on tiles. Where the reference app draws nothing (who is speaking,
// pinned, poor network) the owner's spec adds a quiet mark: a thin border, two small glyphs.
// owner, 2026-10-06: three more states from the reference app's tile. Media still arriving = the
// camera-off look under a spinner; a camera that is on but never shows = a "Can't show video" tile
// whose tap explains; a raised hand = a white chip top-left. And a long press opens a menu.

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
    /// Long press (remote tiles; from `GroupCallStage.tileMenu(for:)`). nil = no menu.
    var menu: CallTileMenu? = nil

    @State private var showVideoNote = false

    /// "Can't show video" is drawn: no picture to show and the wait is over.
    private var showsUnavailable: Bool { track == nil && tile.videoUnavailable }

    var body: some View {
        tileBody
            .modifier(CallTileMenuModifier(tile: tile, menu: menu))
            .alert("Can't show video", isPresented: $showVideoNote) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(tile.name)'s video can't be shown right now. Their connection may be weak.")
            }
    }

    private var tileBody: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                content(width: width, height: geo.size.height)
                badges(width: width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        // Spec §8: the speaker must be obvious, no scale. Owner, 2026-10-07: a soft glow now
        // instead of the hard border (`SpeakerGlow`).
        .modifier(SpeakerGlow(corner: corner, on: isActiveSpeaker))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture { tapped() }
        // One VoiceOver element per tile (spec §16): who, their state, and what a tap does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHintText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tapped() }
    }

    /// A tile that cannot show its video explains why on a tap (the reference app's error tile);
    /// pinning it is still in the long-press menu. Every other tile does what the parent says.
    private func tapped() {
        if showsUnavailable { showVideoNote = true } else { onTap() }
    }

    private var corner: CGFloat {
        switch style {
        case .alone: return 0          // edge to edge, nothing to round against
        case .grid, .focus, .strip, .pip: return GroupCallMetrics.tileCorner
        }
    }

    // MARK: - Video or avatar

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
        if let track {
            // A video view only when there is a track: adaptiveStream pauses a track that has no
            // attached view, so camera-off and unsubscribed tiles must not build one (contract rule).
            // By the track itself, not `tile.isScreenShare`: the strip hands a presenter's camera
            // (`videoTrack(_:preferScreen: false)`), which must fill and mirror like any camera.
            if track.source == .screenShareVideo {
                // A shared screen is never cropped (text must stay readable) and never mirrored.
                ZStack {
                    Color.black
                    SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: .off)
                }
                // Keyed on the track sid: a republished share is a new track, and a fresh view
                // binds to it cleanly instead of the old view swapping tracks under itself.
                .id(tile.screenTrackSid)
            } else {
                // `.auto` mirrors only the local front camera, the same as the old screen did.
                SwiftUIVideoView(track, layoutMode: .fill)
                    .id(tile.cameraTrackSid)   // same reason: a republished camera rebinds
            }
        } else if tile.videoUnavailable {
            cameraOff(width: width, height: height)
                .overlay { unavailableNote(width: width) }
        } else if tile.isConnecting {
            cameraOff(width: width, height: height)
                .overlay { connectingNote(width: width) }
        } else {
            cameraOff(width: width, height: height)
        }
    }

    /// Media still arriving (the reference app's first seconds of a tile): the camera-off look,
    /// dimmed, under a spinner. The stage ends this state by itself (GroupCallMetrics.joinGrace /
    /// videoGrace), so the spinner never stays for good.
    private func connectingNote(width: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .controlSize(width > 102 ? .large : .regular)
        }
    }

    /// Their camera is on and no picture came (the reference app's error tile). The words only where
    /// they fit; a strip tile shows the glyph alone. The tap that explains is `tapped()`.
    private func unavailableNote(width: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 6) {
                Image(systemName: "video.slash")
                    .font(.system(size: width > 102 ? 24 : 16, weight: .semibold))
                if width > 102 {
                    Text("Can't show video")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
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
        // The focus tile's top-leading corner holds the "Pinned" / "Presenting" label (or the raised
        // hand, drawn there by GroupCallFocusView), so its network glyph sits top-trailing.
        let networkLeading = style != .focus
        let showNetwork = tile.networkPoor && !compact
        let showHand = tile.isHandRaised && style != .focus && style != .pip
        ZStack {
            // Muted. owner, 2026-10-06: not on the big focus tile, as the reference app hides it
            // there (the people list and VoiceOver still say it). It stays on grid, strip and pip,
            // and on fullscreen, which is me alone (I must see that I am muted).
            if tile.isMuted && style != .focus {
                badge("mic.slash.fill", size: compact ? 16 : 28, glyph: compact ? 9 : 16)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
            }
            // Top-leading: the raised hand, then the network glyph beside it (alone, the glyph is
            // where it always was).
            if showHand || (showNetwork && networkLeading) {
                HStack(spacing: 4) {
                    if showHand {
                        CallRaisedHandChip(name: (style == .strip || width < 150) ? nil : tile.name)
                            .transition(.opacity)
                    }
                    if showNetwork && networkLeading {
                        badge("wifi.exclamationmark", size: 22, glyph: 11)
                            .transition(.opacity)
                    }
                }
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
            }
            if showNetwork && !networkLeading {
                badge("wifi.exclamationmark", size: 22, glyph: 11)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        .animation(GroupCallMotion.fade, value: tile.isHandRaised)
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
        if tile.isHandRaised { parts.append("hand raised") }
        if tile.isScreenShare { parts.append("presenting") }
        else if showsUnavailable { parts.append("video can't be shown") }
        else if track == nil && tile.isConnecting { parts.append("connecting") }
        else if track == nil { parts.append("camera off") }
        if tile.networkPoor { parts.append("poor connection") }
        if isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityHintText: String {
        if showsUnavailable { return "Double-tap to hear why" }
        return isPinned ? "Double-tap to unpin" : "Double-tap to focus"
    }
}

/// The raised hand mark (the reference app's): a white circle with the hand, and the person's name
/// beside it where there is room. `name: nil` = the 28pt circle alone (strip tiles, narrow tiles).
/// Also drawn by GroupCallFocusView in place of its "Pinned" label.
struct CallRaisedHandChip: View {
    let name: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white))
            if let name {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.trailing, 10)
            }
        }
        .background(Capsule().fill(Color.black.opacity(name == nil ? 0 : 0.5)))
    }
}

/// The long-press menu on a remote tile (owner, 2026-10-06): the name as its title, Pin / Unpin,
/// and for someone the people list would let me act on, Mute and Remove…. The lifted preview is the
/// person's camera-off look, not the tile: a snapshot of a live video layer can come out black.
private struct CallTileMenuModifier: ViewModifier {
    let tile: CallTile
    let menu: CallTileMenu?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu {
                CallTileMenuItems(tile: tile, menu: menu)
            } preview: {
                CallTileMenuPreview(tile: tile)
            }
        } else {
            content
        }
    }
}

private struct CallTileMenuItems: View {
    let tile: CallTile
    let menu: CallTileMenu

    var body: some View {
        Section(tile.name) {
            Button { menu.onPin() } label: {
                Label(menu.isPinned ? "Unpin" : "Pin", systemImage: menu.isPinned ? "pin.slash" : "pin")
            }
            if menu.canModerate {
                // Like the people list: no Mute for someone already muted.
                if !tile.isMuted {
                    Button { menu.onMute() } label: {
                        Label("Mute", systemImage: "mic.slash")
                    }
                }
                Button(role: .destructive) { menu.onRemove() } label: {
                    Label("Remove…", systemImage: "person.fill.xmark")
                }
            }
        }
    }
}

private struct CallTileMenuPreview: View {
    let tile: CallTile

    var body: some View {
        ZStack {
            TileBackdrop(photoUrl: tile.photoUrl)
            AvatarView(name: tile.name, photoUrl: tile.photoUrl, size: 96)
        }
        .frame(width: 200, height: 200)
    }
}
/// The camera-off background: the PERSON'S PROFILE COLOUR filling the tile, with a soft darker fall
/// toward the bottom. Owner, 2026-10-07 ("group link call users now is using blur profile, use
/// profile user color"): it was a blurred copy of their photo. Now the same colour their 1:1 call,
/// the two-person screen and the pre-join screen take from the photo (`ProfilePalette`), so a person
/// keeps one colour across every call screen. No photo, or no colour yet = the dark gradient.
struct TileBackdrop: View {   // also the minimized card's and the demo's camera-off backdrop
    let photoUrl: String?
    @State private var colour: Color?

    init(photoUrl: String?) {
        self.photoUrl = photoUrl
        // First frame from the caches the avatar is drawn from (memory lookups only), so a tile
        // whose person is already on screen does not flash grey before its colour.
        _colour = State(initialValue: GroupCallRingingView.cachedColour(photoUrl))
    }

    var body: some View {
        // The colour rides as an OVERLAY on the gradient, so the gradient alone sets the size
        // (the pre-join screen's Leave/Join once grew past both edges from a wide sibling).
        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                if let colour {
                    colour
                        .overlay(LinearGradient(colors: [.white.opacity(0.06), .black.opacity(0.28)],
                                                startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(GroupCallMotion.fade, value: colour != nil)
            .task(id: photoUrl) {
                guard let s = photoUrl, !s.isEmpty else { colour = nil; return }
                if colour != nil { return }
                if let p = await ProfilePalette.resolve(url: s) { colour = Color(p.page); return }
                // Not on disk yet: load the avatar the way AvatarView does, then take its colour.
                let img = await ProfilePhotoLoader.shared.avatar(s)
                guard !Task.isCancelled, let img, let p = ProfilePalette.now(img, url: s) else { return }
                colour = Color(p.page)
            }
    }
}
