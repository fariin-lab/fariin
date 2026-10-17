import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage

// ⛔ MAKE A STICKER FROM A PHOTO — owner 2026-10-17. Pick one photo, lift the subject out of it
// on this phone (Vision's foreground mask, the same on-device model the system Photos lift uses),
// show it, save it to Favorites. NOTHING LEAVES THE PHONE: no upload, no service, no network. When
// the model finds no subject, the photo itself can be kept as a rounded-square sticker instead.
//
// Every step can fail (a broken file, an iCloud photo that will not download, no subject) and each
// failure says so in an alert rather than closing silently.
enum StickerCreatorDoor {
    /// Kept alive while the flow is up (the picker holds its delegate weakly).
    @MainActor fileprivate static var flow: StickerCreatorFlow?

    @MainActor static func present() {
        guard let top = WebLink.topViewController() else { return }
        let f = StickerCreatorFlow()
        flow = f
        f.start(from: top)
    }
}

/// The finished art, at most 512 × 512, transparent where there is no subject.
private struct StickerArt {
    let cutout: UIImage?        // the lifted subject, nil when none was found
    let rounded: UIImage        // the whole photo as a rounded square
}

@MainActor
private final class StickerCreatorFlow: NSObject, PHPickerViewControllerDelegate {
    nonisolated static let side: CGFloat = 512
    private weak var host: UIViewController?

    func start(from top: UIViewController) {
        host = top
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        top.present(picker, animated: true)
    }

    // `nonisolated` + assumeIsolated: the picker calls this on the main thread whether or not the
    // SDK marks the protocol main-actor, and this satisfies the requirement either way.
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        MainActor.assumeIsolated { self.picked(picker, results) }
    }

    private func picked(_ picker: PHPickerViewController, _ results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider else {
            picker.dismiss(animated: true) { self.finish() }
            return
        }
        // The file is only valid inside the callback, so it is read (downsampled) right there.
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
            let image = url.flatMap { Self.downsample($0, maxPixel: 2048) }
            Task { @MainActor in
                guard let image else {
                    picker.dismiss(animated: true) {
                        self.fail("This photo couldn't be opened. Try another one.")
                    }
                    return
                }
                self.process(image, picker: picker)
            }
        }
    }

    private func process(_ image: CGImage, picker: PHPickerViewController) {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        picker.view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: picker.view.centerXAnchor),
                                     spinner.centerYAnchor.constraint(equalTo: picker.view.centerYAnchor)])
        spinner.startAnimating()
        Task {
            let art = await Task.detached(priority: .userInitiated) { Self.makeArt(image) }.value
            spinner.removeFromSuperview()
            guard let art else {
                picker.dismiss(animated: true) { self.fail("This photo couldn't be made into a sticker.") }
                return
            }
            let preview = StickerPreviewController(art: art)
            preview.onDone = { [weak self, weak preview] png in
                guard let self, let preview else { return }
                if let png {
                    do {
                        _ = try StickerStore.shared.addMine(png: png, emoji: "🙂")
                    } catch {
                        preview.dismiss(animated: true) { self.fail("The sticker couldn't be saved. Check your free space and try again.") }
                        return
                    }
                }
                preview.dismiss(animated: true) { self.finish() }
            }
            picker.dismiss(animated: false) {
                preview.modalPresentationStyle = .fullScreen
                (self.host ?? WebLink.topViewController())?.present(preview, animated: true)
            }
        }
    }

    private func fail(_ text: String) {
        let a = UIAlertController(title: "Couldn't Make a Sticker", message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        (WebLink.topViewController() ?? host)?.present(a, animated: true)
        finish()
    }

    private func finish() { StickerCreatorDoor.flow = nil }

    // MARK: - Off the main thread

    /// ImageIO straight from the file, never the full-size bitmap: a 48 MP photo decoded whole is
    /// ~190 MB. HEIC, JPEG and PNG all come through here; orientation is applied.
    nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func makeArt(_ image: CGImage) -> StickerArt? {
        let rounded = roundedSquare(image)
        guard let rounded else { return nil }
        return StickerArt(cutout: liftSubject(image), rounded: rounded)
    }

    /// Vision's foreground instance mask (iOS 17+), every instance, cropped to them.
    nonisolated static func liftSubject(_ image: CGImage) -> UIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty,
              let buffer = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                        croppedToInstancesExtent: true)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext(options: nil).createCGImage(ci, from: ci.extent) else { return nil }
        return fit(UIImage(cgImage: cg))
    }

    /// Scaled to sit inside 512 × 512 keeping its aspect, transparent around it.
    nonisolated static func fit(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return image }
        let scale = min(side / w, side / h)
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The middle square of the photo, 512 px, with rounded corners (transparent outside them).
    nonisolated static func roundedSquare(_ image: CGImage) -> UIImage? {
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

/// The preview: the art centred on plain black, Cancel, the cutout / original choice, Save Sticker.
@MainActor
private final class StickerPreviewController: UIViewController {
    var onDone: ((Data?) -> Void)?
    private let art: StickerArt
    private var useOriginal: Bool
    private let imageView = UIImageView()
    private let note = UILabel()
    private let toggle = UIButton(type: .system)
    private let save = UIButton(type: .system)
    private var saving = false

    init(art: StickerArt) {
        self.art = art
        self.useOriginal = art.cutout == nil
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17)
        cancel.tintColor = .white
        cancel.addAction(UIAction { [weak self] _ in self?.onDone?(nil) }, for: .touchUpInside)

        imageView.contentMode = .scaleAspectFit

        note.textColor = UIColor.white.withAlphaComponent(0.7)
        note.font = .systemFont(ofSize: 15)
        note.textAlignment = .center
        note.numberOfLines = 0
        note.text = art.cutout == nil
            ? "No subject was found in this photo. You can keep the whole photo as a sticker."
            : nil
        note.isHidden = art.cutout != nil

        var tc = UIButton.Configuration.gray()
        tc.cornerStyle = .capsule
        tc.baseForegroundColor = .white
        toggle.configuration = tc
        toggle.isHidden = art.cutout == nil
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.useOriginal.toggle()
            self.refresh()
        }, for: .touchUpInside)

        var sc = UIButton.Configuration.filled()
        sc.cornerStyle = .capsule
        sc.title = "Save Sticker"
        sc.buttonSize = .large
        save.configuration = sc
        save.addAction(UIAction { [weak self] _ in self?.commit() }, for: .touchUpInside)

        for v in [cancel, imageView, note, toggle, save] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            cancel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),

            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),

            note.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 32),
            note.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -32),

            save.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            save.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            save.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

            toggle.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            toggle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        refresh()
    }

    private func refresh() {
        imageView.image = (useOriginal ? nil : art.cutout) ?? art.rounded
        toggle.configuration?.title = useOriginal ? "Use Cutout" : "Use Original"
    }

    private func commit() {
        guard !saving else { return }
        let image = (useOriginal ? nil : art.cutout) ?? art.rounded
        guard let png = image.pngData() else { return }
        saving = true
        save.isEnabled = false
        onDone?(png)
    }
}
