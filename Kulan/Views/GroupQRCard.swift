import SwiftUI
import UIKit
import PhotosUI

// ⛔ THE GROUP'S QR CODE, OUR OWN CARD (owner 2026-10-19: "make something cool, better than theirs,
// not a copy"). A full-screen colour, a white card with the group photo standing on its top edge,
// the name and size, the round-dot code in a dark shade of the colour with the Fariin mark in the
// middle, and "Scan with the camera to join". Five colours to pick (kept on this phone), then
// Share (the card as a picture), Save (to Photos) and Copy link as glass circles.
//
// The code stays dark-on-white with correction H (`qrImage`), so it scans in every colour; the
// mark sits in the module-cut hole, as on the profile's code.

private struct QRTheme {
    let top: Color, bottom: Color, ink: UIColor, dot: Color
    /// A multi-colour ground (owner 2026-10-27: "add multi colours like the wallpapers"): the four
    /// corners of a wallpaper gradient. Nil is the plain top-to-bottom pair.
    var corners: [Color]? = nil
    /// Two dark shades the code's dots run between on a multi-colour theme. Both stay dark enough
    /// on white to scan.
    var inks: [Color]? = nil

    /// Every ground is a 2x2 mesh, so switching between a plain and a multi-colour theme morphs the
    /// colours instead of cutting from one kind of gradient to another.
    var meshColors: [Color] { corners ?? [top, top, bottom, bottom] }

    static func multi(_ c: [UInt], inks i: [UInt]) -> QRTheme {
        let inkColors = i.map { Color(hex: $0) }
        return QRTheme(top: Color(hex: c[0]), bottom: Color(hex: c[3]), ink: UIColor(inkColors[0]),
                       dot: Color(hex: c[0]), corners: c.map { Color(hex: $0) }, inks: inkColors)
    }

    static let all: [QRTheme] = [
        QRTheme(top: Color(hex: 0x5AA2FF), bottom: Color(hex: 0x1D3FB0), ink: UIColor(red: 0.11, green: 0.25, blue: 0.69, alpha: 1), dot: Color(hex: 0x2C6BED)),
        QRTheme(top: Color(hex: 0xFFB36B), bottom: Color(hex: 0xB8432A), ink: UIColor(red: 0.66, green: 0.24, blue: 0.13, alpha: 1), dot: Color(hex: 0xF0703C)),
        QRTheme(top: Color(hex: 0x5FD39A), bottom: Color(hex: 0x137A4A), ink: UIColor(red: 0.06, green: 0.42, blue: 0.25, alpha: 1), dot: Color(hex: 0x21A366)),
        QRTheme(top: Color(hex: 0xC48BE8), bottom: Color(hex: 0x5B2585), ink: UIColor(red: 0.36, green: 0.15, blue: 0.52, alpha: 1), dot: Color(hex: 0x8E44AD)),
        QRTheme(top: Color(hex: 0x4A4A50), bottom: Color(hex: 0x111114), ink: UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1), dot: Color(hex: 0x222226)),
        // The wallpapers' own gradients (WallpaperStore), after the five plain ones so a saved pick
        // keeps its colour.
        .multi([0xF3DC47, 0xF2CD46, 0xE54F41, 0xE44040], inks: [0xB4410C, 0x7F1D1D]),
        .multi([0xE4384B, 0xF53844, 0x42378F, 0x533788], inks: [0xA61B34, 0x33287A]),
        .multi([0x0093E9, 0x0093E9, 0x80D0C7, 0x80D0C7], inks: [0x005A8F, 0x1C6B62]),
        .multi([0xDC7DE6, 0xED82E6, 0x3753E6, 0x4858E6], inks: [0x8E1C93, 0x1B2C9A]),
        .multi([0x65CDAC, 0x65CDAC, 0x0A995A, 0x0A995A], inks: [0x1C6E53, 0x064F2E]),
    ]
}

/// The ground: a 2x2 mesh of the theme's corners.
private struct QRGround: View {
    let theme: QRTheme
    var body: some View {
        MeshGradient(width: 2, height: 2,
                     points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                     colors: theme.meshColors)
    }
}

struct GroupLinkQRSheet: View {
    let title: String
    let link: String
    var photo: String? = nil
    var memberCount: Int? = nil
    /// The line under the name, in place of "Group · N members" (the profile's code: "@handle").
    var subtitle: String? = nil
    /// The line under the code.
    var hint: String = "Scan with the camera to join"
    /// A Scan circle beside the others (the profile's code, owner 2026-10-20).
    var onScan: (() -> Void)? = nil
    /// A channel's code (owner 2026-10-30: it said "Group · N members" and "to join"): its follower
    /// count turns the card into "Channel · N followers" and "to follow". Also read from the
    /// environment, for the cards that open this sheet without knowing they are on a channel.
    var channelFollowers: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.groupQRChannelFollowers) private var envChannelFollowers
    @AppStorage("groupQR.theme") private var themeIndex = 0
    @State private var toast: String?
    @State private var saving = false
    @State private var cardImage: UIImage?
    @State private var photoFull: UIImage?
    @State private var toastTask: Task<Void, Never>?
    @State private var cardDip = false

    private var theme: QRTheme { QRTheme.all[min(max(themeIndex, 0), QRTheme.all.count - 1)] }

    private var followers: Int? { channelFollowers ?? envChannelFollowers }
    /// The line under the name: the caller's own, else a channel's followers, else the group's size.
    private var faceSubtitle: String? {
        if let subtitle { return subtitle }
        guard let n = followers else { return nil }
        return "Channel · \(n) follower\(n == 1 ? "" : "s")"
    }
    private var faceHint: String { followers != nil ? "Scan with the camera to follow" : hint }

    var body: some View {
        ZStack {
            QRGround(theme: theme)
                .ignoresSafeArea()
            // Scrolls only when it does not fit (audit 2026-10-20: on an SE or at large text the close
            // X and the Share row went off the screen); on a normal phone it sits as before.
            GeometryReader { geo in
            ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .liquidGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .environment(\.colorScheme, .dark)   // dark glass in light mode too (owner 2026-10-21)
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer(minLength: 56)
                card
                Spacer(minLength: 24)
                swatches
                // Always dark glass, smaller row (owner 2026-10-21).
                actions.environment(\.colorScheme, .dark).padding(.top, 20).padding(.bottom, 16)
            }
            .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .liquidGlass(Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.45), value: themeIndex)
        // ⛔ A COLOUR CHANGE YOU CAN FEEL (owner 2026-10-27): the card dips and springs back while
        // the ground morphs and the code fades to its new colour, with a light tap.
        .onChange(of: themeIndex) {
            Haptics.impact(.light)
            withAnimation(.easeOut(duration: 0.12)) { cardDip = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { cardDip = false }
            }
        }
        .presentationDetents([.large])
        .task(id: themeIndex) {
            // The full photo first, so the shared picture is never missing it (audit 2026-10-20).
            if photoFull == nil, let p = photo {
                photoFull = await DiskImageCache.shared.image(for: p)
                if photoFull == nil, let u = URL(string: p), let (data, _) = try? await URLSession.shared.data(from: u) {
                    photoFull = UIImage(data: data)
                }
            }
            cardImage = renderCard()
        }
    }

    // MARK: Card

    private var card: some View {
        GroupQRCardFace(title: title, photo: photo, memberCount: memberCount, link: link, ink: theme.ink,
                        inks: theme.inks, themeKey: themeIndex, subtitleText: faceSubtitle, hint: faceHint, squircle: followers != nil)
            .padding(.horizontal, 28)
            .scaleEffect(cardDip ? 0.94 : 1)
    }

    /// Ten colours now, so the row scrolls sideways when it does not fit.
    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(QRTheme.all.indices, id: \.self) { i in
                    Button { themeIndex = i } label: {
                        swatch(QRTheme.all[i])
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white, lineWidth: i == themeIndex ? 3 : 1.5))
                            .scaleEffect(i == themeIndex ? 1.12 : 1)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(i + 1)")
                    .accessibilityAddTraits(i == themeIndex ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    @ViewBuilder private func swatch(_ t: QRTheme) -> some View {
        if let c = t.corners {
            Circle().fill(LinearGradient(colors: [c[0], c[3]], startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            Circle().fill(t.dot)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 0) {
            if let img = cardImage {
                ShareLink(item: Image(uiImage: img),
                          preview: SharePreview(title, image: Image(uiImage: img))) {
                    PosterActionIcon(icon: "ic_link_share", diameter: 50, label: "Share")
                }
                .buttonStyle(.plain)
            } else {
                PosterActionIcon(icon: "ic_link_share", diameter: 50, label: "Share").opacity(0.5)
            }
            Button { save() } label: {
                PosterActionIcon(icon: "arrow.down.to.line", diameter: 50, label: saving ? "Saving…" : "Save")
            }
            .buttonStyle(.plain)
            .disabled(saving)
            Button {
                UIPasteboard.general.string = link
                Haptics.notify(.success)
                flash("Link copied")
            } label: {
                PosterActionIcon(icon: "link", diameter: 50, label: "Copy link")
            }
            .buttonStyle(.plain)
            if let onScan {
                Button(action: onScan) {
                    PosterActionIcon(icon: "qrcode.viewfinder", diameter: 50, label: "Scan")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }

    /// The card alone on its colour, at 3x, for Share and Save: the picture people send is the
    /// one on screen.
    @MainActor private func renderCard() -> UIImage? {
        let art = ZStack {
            QRGround(theme: theme)
            GroupQRCardFace(title: title, photo: photo, memberCount: memberCount, link: link, ink: theme.ink,
                            inks: theme.inks, photoImage: photoFull ?? photo.flatMap { DiskImageCache.shared.smallImageSync($0) },
                            subtitleText: faceSubtitle, hint: faceHint, squircle: followers != nil)
                .padding(.horizontal, 32)
                .padding(.top, 40)
        }
        .frame(width: 390, height: 600)
        let r = ImageRenderer(content: art)
        r.scale = 3
        return r.uiImage
    }

    private func save() {
        guard let ui = cardImage ?? renderCard() else { flash("Could not save"); return }
        saving = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run { saving = false; flash("Photos access is off") }
                return
            }
            var ok = true
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: ui)
                }
            } catch { ok = false }
            await MainActor.run { saving = false; flash(ok ? "Saved to Photos" : "Could not save") }
        }
    }

    private func flash(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = text }
        // A new notice restarts the clock instead of being cut short by the last one's (audit).
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}

/// The white card itself: photo on the top edge, name, size, the code with the mark, the hint.
/// `photoImage` is for the rendered picture, which cannot wait for a download.
private struct GroupQRCardFace: View {
    let title: String
    let photo: String?
    let memberCount: Int?
    let link: String
    let ink: UIColor
    /// A multi-colour theme's two shades: the dots run from one to the other.
    var inks: [Color]? = nil
    /// Changes with the picked colour, so the code fades to its new colour instead of cutting.
    var themeKey: Int = 0
    var photoImage: UIImage? = nil
    var subtitleText: String? = nil
    var hint: String = "Scan with the camera to join"
    /// A channel's photo in the channel's shape, with the megaphone when it has none (owner
    /// 2026-10-30: the channel's code wore a round photo and a person's silhouette).
    var squircle = false
    private var faceShape: AnyShape { squircle ? AnyShape(SquircleShape()) : AnyShape(Circle()) }

    private var subtitle: String {
        if let subtitleText { return subtitleText }
        guard let n = memberCount else { return "Group" }
        return "Group · \(n) member\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                .lineLimit(2).multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.black.opacity(0.5))
            // One ZStack round it, so the old and new code overlap while they fade (in the VStack
            // they would stack for a moment).
            ZStack {
            if let img = qrImage(from: link, clearCentre: 0.22, ink: inks == nil ? ink : .black) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    // Black dots on white, screened with the gradient: each dot takes the gradient's
                    // colour where it sits and the white stays white. An OVERLAY, so it takes the
                    // code's size (owner 2026-10-27: in a ZStack the gradient filled all the height it
                    // was offered and the card grew).
                    .overlay {
                        if let inks {
                            LinearGradient(colors: inks, startPoint: .topLeading, endPoint: .bottomTrailing)
                                .blendMode(.screen)
                        }
                    }
                    .compositingGroup()
                    .overlay { QRCentreMark(size: 46, tint: inks.map { $0[0] } ?? Color(uiColor: ink)) }
                    .frame(maxWidth: 250)
                .id(themeKey)
                .transition(.opacity)
            }
            }
            .padding(.top, 14)
            Text(hint)
                .font(.footnote).foregroundStyle(Color.black.opacity(0.5))
                .padding(.top, 10)
        }
        .padding(.top, 58).padding(.bottom, 22).padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        // One layer first, so only the card casts the shadow (owner 2026-10-20: the code inside
        // had its own grey frame).
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
        .overlay(alignment: .top) {
            avatar
                .overlay(faceShape.stroke(.white, lineWidth: 5))
                .offset(y: -46)
        }
    }

    @ViewBuilder private var avatar: some View {
        if let photoImage {
            Image(uiImage: photoImage).resizable().scaledToFill()
                .frame(width: 92, height: 92).clipShape(faceShape)
        } else {
            AvatarView(name: title, photoUrl: photo, size: 92).avatarSquircle(squircle)
        }
    }
}

/// A channel's follower count for any QR sheet opened below (owner 2026-10-30). The about card's
/// link row opens the sheet itself and only knows a member count, so the channel page sets this
/// on the card instead of threading a flag through the shared card.
private struct GroupQRChannelFollowersKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var groupQRChannelFollowers: Int? {
        get { self[GroupQRChannelFollowersKey.self] }
        set { self[GroupQRChannelFollowersKey.self] = newValue }
    }
}
