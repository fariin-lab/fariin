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
    static let all: [QRTheme] = [
        QRTheme(top: Color(hex: 0x5AA2FF), bottom: Color(hex: 0x1D3FB0), ink: UIColor(red: 0.11, green: 0.25, blue: 0.69, alpha: 1), dot: Color(hex: 0x2C6BED)),
        QRTheme(top: Color(hex: 0xFFB36B), bottom: Color(hex: 0xB8432A), ink: UIColor(red: 0.66, green: 0.24, blue: 0.13, alpha: 1), dot: Color(hex: 0xF0703C)),
        QRTheme(top: Color(hex: 0x5FD39A), bottom: Color(hex: 0x137A4A), ink: UIColor(red: 0.06, green: 0.42, blue: 0.25, alpha: 1), dot: Color(hex: 0x21A366)),
        QRTheme(top: Color(hex: 0xC48BE8), bottom: Color(hex: 0x5B2585), ink: UIColor(red: 0.36, green: 0.15, blue: 0.52, alpha: 1), dot: Color(hex: 0x8E44AD)),
        QRTheme(top: Color(hex: 0x4A4A50), bottom: Color(hex: 0x111114), ink: UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1), dot: Color(hex: 0x222226)),
    ]
}

struct GroupLinkQRSheet: View {
    let title: String
    let link: String
    var photo: String? = nil
    var memberCount: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("groupQR.theme") private var themeIndex = 0
    @State private var toast: String?
    @State private var saving = false
    @State private var cardImage: UIImage?
    @State private var photoFull: UIImage?
    @State private var toastTask: Task<Void, Never>?

    private var theme: QRTheme { QRTheme.all[min(max(themeIndex, 0), QRTheme.all.count - 1)] }

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .liquidGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer(minLength: 56)
                card
                Spacer(minLength: 24)
                swatches
                actions.padding(.top, 24).padding(.bottom, 24)
            }
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .liquidGlass(Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: themeIndex)
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
        GroupQRCardFace(title: title, photo: photo, memberCount: memberCount, link: link, ink: theme.ink)
            .padding(.horizontal, 28)
    }

    private var swatches: some View {
        HStack(spacing: 14) {
            ForEach(QRTheme.all.indices, id: \.self) { i in
                Button { themeIndex = i } label: {
                    Circle().fill(QRTheme.all[i].dot)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.white, lineWidth: i == themeIndex ? 3 : 1.5))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(i + 1)")
                .accessibilityAddTraits(i == themeIndex ? .isSelected : [])
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 0) {
            if let img = cardImage {
                ShareLink(item: Image(uiImage: img),
                          preview: SharePreview(title, image: Image(uiImage: img))) {
                    PosterActionIcon(icon: "square.and.arrow.up", diameter: 58, label: "Share")
                }
                .buttonStyle(.plain)
            } else {
                PosterActionIcon(icon: "square.and.arrow.up", diameter: 58, label: "Share").opacity(0.5)
            }
            Button { save() } label: {
                PosterActionIcon(icon: "arrow.down.to.line", diameter: 58, label: saving ? "Saving…" : "Save")
            }
            .buttonStyle(.plain)
            .disabled(saving)
            Button {
                UIPasteboard.general.string = link
                Haptics.notify(.success)
                flash("Link copied")
            } label: {
                PosterActionIcon(icon: "link", diameter: 58, label: "Copy link")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    /// The card alone on its colour, at 3x, for Share and Save: the picture people send is the
    /// one on screen.
    @MainActor private func renderCard() -> UIImage? {
        let art = ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
            GroupQRCardFace(title: title, photo: photo, memberCount: memberCount, link: link, ink: theme.ink,
                            photoImage: photoFull ?? photo.flatMap { DiskImageCache.shared.smallImageSync($0) })
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
    var photoImage: UIImage? = nil

    private var subtitle: String {
        guard let n = memberCount else { return "Group" }
        return "Group · \(n) member\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                .lineLimit(2).multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.black.opacity(0.5))
            if let img = qrImage(from: link, clearCentre: 0.22, ink: ink) {
                ZStack {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    QRCentreMark(size: 46)
                }
                .frame(maxWidth: 250)
                .padding(.top, 14)
            }
            Text("Scan with the camera to join")
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
                .overlay(Circle().stroke(.white, lineWidth: 5))
                .offset(y: -46)
        }
    }

    @ViewBuilder private var avatar: some View {
        if let photoImage {
            Image(uiImage: photoImage).resizable().scaledToFill()
                .frame(width: 92, height: 92).clipShape(Circle())
        } else {
            AvatarView(name: title, photoUrl: photo, size: 92)
        }
    }
}
