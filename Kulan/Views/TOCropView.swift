import SwiftUI
import UIKit
import CropViewController

// SwiftUI wrapper around TimOliver/TOCropViewController — the gold-standard iOS cropper
// (pinch-zoom, pan, rotation dial + 90°, aspect ratio presets, reset). We keep our editor flow;
// the crop button presents this. Returns the cropped UIImage to the editor.
struct TOCropView: UIViewControllerRepresentable {
    let image: UIImage
    var circular: Bool = false   // profile photos: a circular move-and-scale crop
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CropViewController {
        let vc = CropViewController(croppingStyle: circular ? .circular : .default, image: image)
        vc.delegate = context.coordinator
        // Circular = a fixed 1:1 profile crop; no ratio picker, just move + scale.
        vc.aspectRatioPickerButtonHidden = circular
        vc.resetAspectRatioEnabled = !circular
        vc.aspectRatioLockEnabled = circular
        vc.toolbarPosition = .bottom

        // Float the whole cropper on a translucent black background so the toolbar's liquid glass
        // has the CROP IMAGE behind it to refract (the library reserves a solid strip for the bar,
        // which is why an unbacked UIGlassEffect just read as a flat dark slab). ~92% black keeps
        // the crop chrome legible while letting a hint of the image bleed through the glass.
        vc.view.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        // Real Apple liquid glass as the toolbar background (the library ships a solid dark bar).
        if #available(iOS 26.0, *) {
            let tb = vc.toolbar
            tb.backgroundColor = .clear
            for sub in tb.subviews where sub is UIVisualEffectView { sub.removeFromSuperview() }   // avoid stacking on re-entry
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.isUserInteractionEnabled = false
            glass.translatesAutoresizingMaskIntoConstraints = false
            // Rounded TOP corners → a floating liquid-glass bar (Apple guideline), not an edge slab.
            glass.layer.cornerRadius = 22
            glass.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            glass.clipsToBounds = true
            tb.insertSubview(glass, at: 0)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: tb.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: tb.trailingAnchor),
                glass.topAnchor.constraint(equalTo: tb.topAnchor),
                glass.bottomAnchor.constraint(equalTo: tb.bottomAnchor),
            ])
        }
        styleButtons(vc)
        return vc
    }

    // Cancel → X glyph, Done → ✅ checkmark (per request). Re-applied in updateUIViewController so the
    // library's own layout pass doesn't reset them back to text.
    private func styleButtons(_ vc: CropViewController) {
        let tb = vc.toolbar
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        tb.cancelTextButton.setTitle(nil, for: .normal)
        tb.cancelTextButton.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        tb.cancelTextButton.tintColor = .white
        tb.doneTextButton.setTitle(nil, for: .normal)
        tb.doneTextButton.setImage(UIImage(systemName: "checkmark", withConfiguration: cfg), for: .normal)
        tb.doneTextButton.tintColor = .systemGreen
    }

    func updateUIViewController(_ vc: CropViewController, context: Context) { styleButtons(vc) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CropViewControllerDelegate {
        let parent: TOCropView
        init(_ parent: TOCropView) { self.parent = parent }

        func cropViewController(_ cropViewController: CropViewController,
                                didCropToImage image: UIImage,
                                withRect cropRect: CGRect, angle: Int) {
            parent.onDone(image)
        }
        func cropViewController(_ cropViewController: CropViewController, didFinishCancelled cancelled: Bool) {
            parent.onCancel()
        }
    }
}
