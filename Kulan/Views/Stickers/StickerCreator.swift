import UIKit
import SwiftUI
import ImageIO
import Vision
import VisionKit
import CoreImage

// ⛔ MAKE A STICKER FROM A PHOTO — owner 2026-10-17. Pick one photo, lift the subject out of it
// on this phone (Vision's foreground mask, the same on-device model the system Photos lift uses),
// show it, save it to Favorites. NOTHING LEAVES THE PHONE: no upload, no service, no network. When
// the model finds no subject, the photo itself can be kept as a rounded-square sticker instead.
//
// Every step can fail (a broken file, an iCloud photo that will not download, no subject) and each
// failure says so in an alert rather than closing silently.
//
// ⛔ OUR PICKER, NOT APPLE'S, AND THE PHOTO FLIES — owner 2026-10-18: "do not open Apple's default
// Photo Library. Use our existing custom photo library sheet, the one I am using in story." The
// sheet is `StoryLibraryPicker` (photos only here). The picked photo zooms out of its tile onto the
// Save page through `MediaOpen.fly` with the attach editor's own numbers, and the X or a drag down
// flies it back into the same tile through `MediaDismissHost`, as the attach editor closes. The
// picker stays under the Save page the whole time, so X still lands back on the library.
enum StickerCreatorDoor {
    /// Weak: once the sheet is gone (X, swipe down, Save) nothing holds it, and the next tap opens
    /// a fresh one.
    @MainActor private static weak var presented: UIViewController?

    @MainActor static func present() {
        guard presented == nil, let top = WebLink.topViewController() else { return }
        let host = UIHostingController(rootView: StickerCreatorSheet())
        // The picker is a story surface: always dark, black behind its rounded corners.
        host.view.backgroundColor = .black
        host.overrideUserInterfaceStyle = .dark
        presented = host
        top.present(host, animated: true)
    }

    /// The sheet and everything it raised, in one motion; `done` once they are gone.
    @MainActor static func close(then done: (() -> Void)? = nil) {
        guard let host = presented else { done?(); return }
        presented = nil
        // The presenter, not the host: the host has the Save page up, and dismissing the host
        // itself would only take that down (see `StoryCameraDoor.close`).
        (host.presentingViewController ?? host).dismiss(animated: true, completion: done)
    }
}

/// The finished art, at most 512 × 512, transparent where there is no subject.
private struct StickerArt {
    let cutout: UIImage?        // the lifted subject with its white outline, nil when none was found
    let rounded: UIImage        // the whole photo as a rounded square
}

/// One photo on its way to the Save page.
private struct StickerEditItem: Identifiable {
    let id = UUID()
    let photo: UIImage          // the picked photo, upright, at most 2048 px
    let cg: CGImage             // the same pixels, for Vision
    let sourceKey: String?      // its tile in `MediaOpenRects` (.sticker); nil = no tile to fly from
    let arrival: EditorArrival
}

// MARK: - The picker

private struct StickerCreatorSheet: View {
    @State private var editing: StickerEditItem?
    @State private var opening = false
    @State private var unreadable = false

    var body: some View {
        StoryLibraryPicker(
            onImage: { ui, id in open(ui, assetID: id) },
            onVideo: { _, _ in },   // `photosOnly`: there is no video tile to pick
            photosOnly: true,
            flyScope: .sticker,
            pickLabel: "Make Sticker")
        // Raised from INSIDE the sheet, as the story library raises its editor: the picker stays
        // where it is under it, scroll position and all, and the X lands back on it.
        .fullScreenCover(item: $editing) { item in
            StickerSaveView(item: item, arrival: item.arrival)
                // Clear, so a drag-close fades the page down to the picker, not to black. The page
                // paints its own black once the photo has landed.
                .presentationBackground(.clear)
        }
        .alert("Couldn't Make a Sticker", isPresented: $unreadable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This photo couldn't be opened. Try another one.")
        }
    }

    private func open(_ ui: UIImage, assetID: String?) {
        guard editing == nil, !opening else { return }
        opening = true
        Task {
            // Upright and at most 2048 px before anything else: a 48 MP original is ~190 MB, and
            // both the flight and Vision only need this much.
            let cg = await Task.detached(priority: .userInitiated) { StickerArtMaker.normalized(ui) }.value
            guard let cg else { opening = false; unreadable = true; return }
            let photo = UIImage(cgImage: cg)
            let key = assetID.map { MediaOpenRects.key(.sticker, $0) }
            // The rect is read after the hop above, never before it: the grid may have moved.
            guard let key, let from = MediaOpenRects.liveRect(key), let to = StickerSaveView.stageRect() else {
                // No tile to fly from: the plain cover, closed the plain way.
                opening = false
                editing = StickerEditItem(photo: photo, cg: cg, sourceKey: nil, arrival: EditorArrival(landed: true))
                return
            }
            let item = StickerEditItem(photo: photo, cg: cg, sourceKey: key, arrival: EditorArrival(landed: false))
            // The tile is hidden for the flight so the photo is never on screen twice.
            MediaSourceVisibility.shared.hide(key)
            // ⛔ THE ATTACH EDITOR'S OPEN, NUMBER FOR NUMBER (see `ThreadView.openAttachPhoto`): the
            // chat viewer's spring and duration, the 0.15s black, clipped to the grid at the start.
            // Square tile onto the square stage, the corners rounding to the stage's on the way.
            MediaOpen.fly(image: photo, from: from, sourceCornerRadius: 0,
                          clip: MediaOpenRects.liveViewRect(MediaOpenRects.key(.sticker, "grid")),
                          to: to, destinationCornerRadius: StickerSaveView.cornerRadius(to.width),
                          timing: MediaOpen.spring,
                          timingDuration: MediaOpen.duration,
                          backdropFade: MediaOpen.attachBackdropFade,
                          // The page comes up at the start, under the flying copy, its controls
                          // fading in with the black; its photo shows once the copy has landed.
                          onStart: {
                              MediaPresentGate.present {
                                  InstantCover.run { editing = item }   // no system slide
                              }
                          }) {
                item.arrival.landed = true
                opening = false
                // The page is opaque over the tile by now; give it back for the close to find.
                DispatchQueue.main.async { MediaSourceVisibility.shared.reveal() }
            }
        }
    }
}

// MARK: - The Save page

/// ⛔ REDESIGNED — owner 2026-10-18: the old page "looks too basic". Dark like the story editor: a
/// glass X and a title on top, the sticker on a soft checkerboard (so the transparent cutout reads
/// as transparent), a Cutout / Original switch and one white Save capsule at the bottom. The stage
/// sits at a fixed, computable rect (`stageRect`) because the open lands on it and the close lifts
/// off it.
private struct StickerSaveView: View {
    let item: StickerEditItem
    @ObservedObject var arrival: EditorArrival
    @Environment(\.dismiss) private var dismiss

    @State private var art: StickerArt?
    @State private var noArt = false            // Vision and the fallback both failed
    @State private var revealed = false         // the cutout has taken over from the flown photo
    @State private var useOriginal = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var dismissing = false       // a close is flying: the copy shows the photo
    @State private var closeToken = 0           // bump: MediaDismissHost flies the X close home
    @State private var chromeShown = false

    // MARK: Geometry (shared by the open, the page and the close)

    private static let topBarH: CGFloat = 60
    private static let bottomChromeH: CGFloat = 176

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// Where the sticker stage sits, in window coordinates.
    static func stageRect() -> CGRect? {
        guard let w = window else { return nil }
        return stageRect(in: w.bounds.size, insets: w.safeAreaInsets)
    }

    private static func stageRect(in size: CGSize, insets: UIEdgeInsets) -> CGRect {
        let top = insets.top + topBarH
        let bottom = size.height - insets.bottom - bottomChromeH
        let side = max(120, min(size.width - 48, bottom - top - 24, 440)).rounded()
        return CGRect(x: ((size.width - side) / 2).rounded(), y: ((top + bottom - side) / 2).rounded(),
                      width: side, height: side)
    }

    /// The stage's corners: the saved rounded-square sticker's own proportion (`roundedSquare`).
    static func cornerRadius(_ side: CGFloat) -> CGFloat { side * 0.14 }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let insets = Self.window?.safeAreaInsets ?? .zero
            let stage = Self.stageRect(in: geo.size, insets: insets)
            ZStack {
                // While the copy flies, its own black backdrop (under this cover) is the background.
                Color.black.opacity(arrival.landed ? 1 : 0)
                stageView(stage.width)
                    .position(x: stage.midX, y: stage.midY)
                    .opacity(dismissing || !arrival.landed ? 0 : 1)
                chrome(insets: insets, stage: stage, size: geo.size)
                    // Only the opacity animates (the attach editor's rule): the controls fade in
                    // over 0.15s with the black instead of sliding in with the cover's first layout.
                    .animation(.easeInOut(duration: 0.15)) { $0.opacity(item.sourceKey == nil || chromeShown ? 1 : 0) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        // Dark whatever the phone is set to, alerts included (the story surfaces' rule).
        .storyAlwaysDark()
        .overlay { dismissHost }
        // Nothing is tappable until the photo has landed (the attach editor's rule too).
        .allowsHitTesting(arrival.landed)
        .onAppear {
            // One hop, so the fade runs outside the no-animation transaction that presented the cover.
            if item.sourceKey != nil, !chromeShown { DispatchQueue.main.async { chromeShown = true } }
        }
        // The cover is really gone: release a tap on another tile that came in while it was leaving.
        .onDisappear { if item.sourceKey != nil { MediaPresentGate.noteClosed() } }
        .task { await makeArt() }
        .onChange(of: arrival.landed) { _, _ in revealIfReady() }
        .alert("Couldn't Make a Sticker", isPresented: $noArt) {
            Button("OK", role: .cancel) { close() }
        } message: {
            Text("This photo couldn't be made into a sticker. Try another one.")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil },
                                                    set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// The checkerboard card, the photo the open landed on, and the cutout that lifts off it.
    private func stageView(_ side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius(side), style: .continuous)
        let cutout = (useOriginal || !revealed) ? nil : art?.cutout
        return ZStack {
            StickerCheckerboard()
            // The same picture, crop and corners the flying copy lands with, so the hand-over at
            // the landing is invisible. It is also the Original sticker, which is this crop.
            Image(uiImage: item.photo)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipped()
                .opacity(cutout == nil ? 1 : 0)
            if let cutout {
                Image(uiImage: cutout)
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.06)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: cutout != nil)
    }

    private func chrome(insets: UIEdgeInsets, stage: CGRect, size: CGSize) -> some View {
        ZStack {
            // Top: the glass X (back to the library) and the page's name.
            HStack {
                CloseXButton(diameter: 44) { close() }
                    .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay { Text("New Sticker").font(.headline).foregroundStyle(.white) }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, insets.top + 8)

            statusLine
                .position(x: size.width / 2, y: stage.maxY + 28)

            // Bottom: the switch, then Save, standing on the safe area.
            VStack(spacing: 16) {
                modeSwitch
                saveButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, insets.bottom + 12)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var statusLine: some View {
        if art == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Finding the subject…")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
        } else if art?.cutout == nil {
            Text("No subject was found, so the whole photo will be the sticker.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder private var modeSwitch: some View {
        if art?.cutout != nil {
            Picker("", selection: $useOriginal) {
                Text("Cutout").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        } else {
            // Holds the place, so Save does not move when the switch arrives.
            Color.clear.frame(height: 32)
        }
    }

    private var saveButton: some View {
        Button { save() } label: {
            ZStack {
                if saving {
                    ProgressView().tint(.black)
                } else {
                    Text("Save Sticker").font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(art == nil || saving)
        .opacity(art == nil ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.2), value: art == nil)
    }

    /// Flies home into the tile when there is one (the drag's pipeline, `MediaDismissHost`).
    @ViewBuilder private var dismissHost: some View {
        if let key = item.sourceKey {
            MediaDismissHost(
                canBegin: { arrival.landed && !saving },
                // The photo, not the cutout: it goes back into a tile that shows the photo.
                media: {
                    guard let r = Self.stageRect() else { return nil }
                    return (r, art?.rounded ?? item.photo)
                },
                onHideContent: { dismissing = $0 },
                targetRect: { MediaOpenRects.liveRect(key) },
                targetId: { key },
                clipRect: { MediaOpenRects.liveViewRect(MediaOpenRects.key(.sticker, "grid")) },
                closeToken: closeToken,
                onDismiss: { instantDismiss() },
                copyFromMediaFrame: true)
        }
    }

    // MARK: Actions

    /// X (owner 2026-10-17): back to the photo library, not out of the flow.
    private func close() {
        if item.sourceKey != nil { closeToken += 1 } else { dismiss() }
    }

    /// The copy IS the animation, so the cover goes without its own slide.
    private func instantDismiss() {
        MediaPresentGate.noteDismissed()
        withoutPresentationAnimation { dismiss() }
    }

    private func makeArt() async {
        guard art == nil else { return }
        let cg = item.cg
        var made = await Task.detached(priority: .userInitiated) { StickerArtMaker.makeArt(cg) }.value
        // 2026-10-17 (owner: his sticker came out as the whole photo): when Vision's mask finds
        // nothing, ask VisionKit's subject lift — the one the Photos app uses — before giving up.
        if let a = made, a.cutout == nil, let lifted = await StickerArtMaker.visionKitLift(cg) {
            let outlined = await Task.detached(priority: .userInitiated) { StickerArtMaker.outlined(lifted) }.value
            made = StickerArt(cutout: outlined, rounded: a.rounded)
        }
        guard let made else { noArt = true; return }
        art = made
        revealIfReady()
    }

    /// The cutout lifts off the photo once BOTH the photo has landed and the cutout is ready, a
    /// beat apart, so the landing itself is never a swap.
    private func revealIfReady() {
        guard !revealed, arrival.landed, art != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { revealed = true }
    }

    private func save() {
        guard let art, !saving else { return }
        let image = (useOriginal ? nil : art.cutout) ?? art.rounded
        guard let png = image.pngData() else {
            saveError = "The sticker couldn't be saved. Try again."
            return
        }
        saving = true
        do {
            _ = try StickerStore.shared.addMine(png: png, emoji: "🙂")
        } catch {
            saving = false
            saveError = "The sticker couldn't be saved. Check your free space and try again."
            return
        }
        // A short note that it worked (owner 2026-10-18), over the chat it lands back in.
        StickerCreatorDoor.close { StickerSavedNote.show() }
    }
}

/// The transparency backdrop: a quiet dark checkerboard, the convention for "nothing here".
private struct StickerCheckerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 14
            let cols = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
            var path = Path()
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
                }
            }
            ctx.fill(path, with: .color(.white.opacity(0.05)))
        }
        .background(Color(white: 0.1))
    }
}

// MARK: - Making the art (off the main thread, except VisionKit)

private enum StickerArtMaker {
    static let side: CGFloat = 512
    /// The sticker's white outline, in pixels of the 512 art (about 3 pt in a chat).
    static let outline: CGFloat = 12

    /// The photo upright (orientation applied) and at most `maxPixel` on its long side.
    static func normalized(_ image: UIImage, maxPixel: CGFloat = 2048) -> CGImage? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return nil }
        let s = min(1, maxPixel / max(w, h))
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// VisionKit subject lifting (iOS 17+), on the phone. Nil when it finds no subject.
    @MainActor static func visionKitLift(_ cg: CGImage) async -> UIImage? {
        guard ImageAnalyzer.isSupported else { return nil }
        let ui = UIImage(cgImage: cg)
        let analyzer = ImageAnalyzer()
        let config = ImageAnalyzer.Configuration([.visualLookUp])
        guard let analysis = try? await analyzer.analyze(ui, configuration: config) else { return nil }
        let interaction = ImageAnalysisInteraction()
        interaction.analysis = analysis
        let subjects = await interaction.subjects
        guard !subjects.isEmpty else { return nil }
        return try? await interaction.image(for: subjects)
    }

    static func makeArt(_ image: CGImage) -> StickerArt? {
        let rounded = roundedSquare(image)
        guard let rounded else { return nil }
        return StickerArt(cutout: liftSubject(image), rounded: rounded)
    }

    /// Vision's foreground instance mask (iOS 17+), every instance, cropped to them.
    static func liftSubject(_ image: CGImage) -> UIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty,
              let buffer = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                        croppedToInstancesExtent: true)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext(options: nil).createCGImage(ci, from: ci.extent) else { return nil }
        return outlined(UIImage(cgImage: cg))
    }

    /// ⛔ THE STICKER OUTLINE — owner 2026-10-18 (Save page redesign): the cutout gets the soft white
    /// edge a sticker has, and what the page shows is what is saved. Scaled to sit inside 512 × 512
    /// with room for the edge, keeping its aspect, transparent around it. The edge is the subject's
    /// own silhouette grown by `outline` (drawn in a ring of offsets, then filled white), under it.
    static func outlined(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return image }
        let pad = outline + 2
        let inner = side - 2 * pad
        let scale = min(inner / w, inner / h)
        let fitted = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let canvas = CGSize(width: fitted.width + 2 * pad, height: fitted.height + 2 * pad)
        let at = CGRect(origin: CGPoint(x: pad, y: pad), size: fitted)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let silhouette = renderer.image { ctx in
            image.draw(in: at)
            for (count, radius) in [(24, outline), (12, outline / 2)] {
                for k in 0..<count {
                    let a = CGFloat(k) / CGFloat(count) * 2 * .pi
                    image.draw(in: at.offsetBy(dx: cos(a) * radius, dy: sin(a) * radius))
                }
            }
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas), blendMode: .sourceIn)
        }
        return renderer.image { _ in
            silhouette.draw(at: .zero)
            image.draw(in: at)
        }
    }

    /// The middle square of the photo, 512 px, with rounded corners (transparent outside them).
    static func roundedSquare(_ image: CGImage) -> UIImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(w, h)
        guard s > 0, let crop = image.cropping(to: CGRect(x: ((w - s) / 2).rounded(), y: ((h - s) / 2).rounded(),
                                                         width: s, height: s))
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.14).addClip()
            UIImage(cgImage: crop).draw(in: rect)
        }
    }
}

/// "Sticker saved": a glass pill under the status bar for a moment, then gone. Not a banner and not
/// a sound; it only confirms the tap did something.
@MainActor enum StickerSavedNote {
    static func show(_ text: String = "Sticker saved") {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let pill = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        pill.isUserInteractionEnabled = false
        pill.clipsToBounds = true
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)))
        icon.tintColor = .systemGreen
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: pill.contentView.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: pill.contentView.centerYAnchor),
        ])
        let size = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let w = size.width + 32, h: CGFloat = 44
        pill.frame = CGRect(x: (window.bounds.width - w) / 2, y: window.safeAreaInsets.top + 8, width: w, height: h)
        pill.layer.cornerRadius = h / 2
        window.addSubview(pill)
        pill.alpha = 0
        pill.transform = CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            pill.alpha = 1
            pill.transform = .identity
        }
        UIView.animate(withDuration: 0.25, delay: 1.8, options: [.curveEaseIn], animations: {
            pill.alpha = 0
            pill.transform = CGAffineTransform(translationX: 0, y: -12)
        }, completion: { _ in pill.removeFromSuperview() })
    }
}
