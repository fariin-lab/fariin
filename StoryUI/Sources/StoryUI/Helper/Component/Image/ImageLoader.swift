//
//  ImageLoader.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Combine
import UIKit
import CoreImage
import CryptoKit

// Persistent disk cache for story images — survives app relaunches (unlike URLCache, which evicts).
// Keyed by a STABLE hash of the URL path (String.hashValue is randomized per process, so unusable;
// we ignore the volatile Firebase ?token query so the same file always maps to the same file on disk).
enum StoryDiskCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("StoryImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func key(_ url: URL) -> String {
        let base = (url.scheme ?? "") + (url.host ?? "") + url.path
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func path(_ url: URL) -> URL { dir.appendingPathComponent(key(url)) }
    static func image(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: path(url)) else { return nil }
        return UIImage(data: data)
    }
    static func store(_ data: Data, for url: URL) {
        try? data.write(to: path(url), options: .atomic)
    }
}

// Shimmering skeleton placeholder (instead of a spinner) while an image is fetched — feels faster.
final class ShimmerView: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 1)
        let dark = UIColor(white: 0.14, alpha: 1).cgColor
        let light = UIColor(white: 0.26, alpha: 1).cgColor
        gradient.colors = [dark, light, dark]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.5, 1]
        layer.addSublayer(gradient)
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-1.0, -0.5, 0.0]
        anim.toValue = [1.0, 1.5, 2.0]
        anim.duration = 1.15
        anim.repeatCount = .infinity
        gradient.add(anim, forKey: "shimmer")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
}

final class ImageLoader: UIView {

    // MARK: Public Properties
    var imageURL: URL?
    // Round ONLY the bottom two corners of the whole card (photo + blur backdrop) in UIKit. A SwiftUI
    // .clipShape doesn't clip the UIVisualEffectView blur (it composites separately and spills past the
    // mask), so the friend reply-bar card stayed square; a UIKit corner mask clips the blur reliably.
    var bottomCornerRadius: CGFloat = 0 { didSet { applyCornerMask() } }
    // Foreground: the photo at its TRUE aspect ratio — never stretched/cropped (Instagram/WhatsApp).
    var imageView = UIImageView()
    // Background: a zoomed + blurred copy of the same photo that fills the empty top/bottom.
    private let backgroundImageView = UIImageView()
    private let shimmer = ShimmerView()

    // MARK: - Initializers
    init() {
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundImageView.frame = bounds
        imageView.frame = bounds
        shimmer.frame = bounds
        applyCornerMask()
        // NB: the fit/fill decision is NOT recomputed here — it's fixed once per image in apply(),
        // so a swipe-down's transient bounds changes can never flip it (that flip was the "shaking").
    }

    // Round the bottom two corners of THIS view (which clips every subview, blur included).
    private func applyCornerMask() {
        layer.cornerRadius = bottomCornerRadius
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.masksToBounds = bottomCornerRadius > 0
    }

    // Fill edge-to-edge (no blur) vs aspect-FIT + blurred backdrop, decided ONCE per image against
    // the STABLE screen aspect (NOT the live view bounds). The bounds jitter as the card scales/offsets
    // during a swipe-down, and keying off them made the photo flip fit<->fill every frame = the
    // "shaking". The screen aspect never changes, so the decision is rock-stable through any drag.
    private func decideContentMode() {
        guard let img = imageView.image, img.size.width > 0 else { return }
        let imgAspect = img.size.height / img.size.width
        let screen = UIScreen.main.bounds
        let screenAspect = screen.height / screen.width
        // Fill when the image is at least as TALL as the screen. Text/colour statuses are rendered
        // taller than any phone (2.5:1), so they always fill full-bleed on every device; real photos
        // are shorter than the screen → aspect-FIT + blurred backdrop (the look the user prefers).
        imageView.contentMode = imgAspect >= screenAspect - 0.02 ? .scaleAspectFill : .scaleAspectFit
    }

    // Baked backdrops cached by URL: URL identity is stable across re-applies and viewer rebuilds
    // (the upload handoff), unlike object identity which silently dropped bakes before.
    private static let bakeCache = NSCache<NSString, UIImage>()

    private func apply(_ image: UIImage?) {
        imageView.image = image
        decideContentMode()        // fixed for this image; never recomputed on layout/drag
        guard let image else { backgroundImageView.image = nil; return }
        let key = (imageURL?.absoluteString ?? "") as NSString
        if key.length > 0, let hit = Self.bakeCache.object(forKey: key) {
            backgroundImageView.image = hit
            return
        }
        backgroundImageView.image = nil   // plain black only while the very first bake runs (ms)
        let url = imageURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let baked = Self.bakedBackdrop(image)
            DispatchQueue.main.async {
                if key.length > 0 { Self.bakeCache.setObject(baked, forKey: key) }
                guard let self, self.imageURL == url else { return }
                self.backgroundImageView.image = baked
            }
        }
    }

    // Downscale → gaussian σ16 → slight desaturation → ~50% near-black veil: a material-matched
    // approximation of the old systemThickMaterialDark look, as a plain image (fades cleanly).
    // Keep in sync with the host's StoryBlurBake so story bars == sheet-card bars.
    private static func bakedBackdrop(_ img: UIImage) -> UIImage {
        let targetW: CGFloat = 240
        let scale = targetW / max(1, img.size.width)
        let size = CGSize(width: targetW, height: max(1, img.size.height * scale))
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        var base = small
        if let ci = CIImage(image: small) {
            var work = ci.clampedToExtent().applyingGaussianBlur(sigma: 16).cropped(to: ci.extent)
            if let desat = CIFilter(name: "CIColorControls", parameters: [
                kCIInputImageKey: work, kCIInputSaturationKey: 0.9
            ])?.outputImage { work = desat }
            let ctx = CIContext(options: nil)
            if let cg = ctx.createCGImage(work, from: work.extent) { base = UIImage(cgImage: cg) }
        }
        return UIGraphicsImageRenderer(size: size).image { c in
            base.draw(in: CGRect(origin: .zero, size: size))
            UIColor.black.withAlphaComponent(0.5).setFill()
            c.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func showShimmer(_ show: Bool) {
        shimmer.isHidden = !show
        if show { bringSubviewToFront(shimmer) }
    }

    func loadImageWithUrl(_ url: String?, imageIsLoaded: @escaping () -> Void) {

        guard let validatedUrl = url else {
            print("url error")
            imageIsLoaded()   // still mark ready → the story auto-advances instead of freezing forever
            return
        }

        if imageURL == URL(string: validatedUrl) {
            return
        }

        imageURL = URL(string: validatedUrl)

        guard let imageURL else { imageIsLoaded(); return }   // malformed URL → don't freeze the progress bar

        // stop video if it's playing before image request
        NotificationCenter.default.post(name: .stopVideo, object: nil)

        // 1) Memory (URLCache) — instant.
        if let cachedResponse = URLCache.shared.cachedResponse(for: .init(url: imageURL)),
           let img = UIImage(data: cachedResponse.data) {
            DispatchQueue.main.async { [weak self] in
                self?.showShimmer(false)
                self?.apply(img)
                imageIsLoaded()
            }
            return
        }

        // 2) Disk — instant on revisit / relaunch (persistent, the big-apps behaviour).
        if let disk = StoryDiskCache.image(imageURL) {
            DispatchQueue.main.async { [weak self] in
                self?.showShimmer(false)
                self?.apply(disk)
                imageIsLoaded()
            }
            return
        }

        // 3) Network — show the shimmer skeleton (not a spinner) while it downloads.
        apply(nil)
        showShimmer(true)

        let requestedURL = imageURL   // capture: if the view is reused mid-download, drop this stale result
        URLSession.shared.dataTask(
            with: imageURL,
            completionHandler: { [weak self] (data, response, error) in
            guard let self else { return }
            if error != nil {
                print(error as Any)
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            guard let data,
                  let response,
                  let image = UIImage(data: data)
            else {
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: .init(url: imageURL))
            StoryDiskCache.store(data, for: imageURL)   // persist to disk → instant next time

            DispatchQueue.main.async {
                self.showShimmer(false)
                guard self.imageURL == requestedURL else { imageIsLoaded(); return }   // reused → don't show stale photo
                self.apply(image)
                imageIsLoaded()
            }
        }).resume()
    }

}
// MARK: - Private Funcs
private extension ImageLoader {
   func setupImageView() {
       backgroundColor = .black
       // WhatsApp/Instagram for non-9:16 photos: a zoomed + heavily-blurred copy of the SAME image fills the
       // whole screen behind, so the empty top/bottom become a blurred color-matched backdrop (no black bars).
       backgroundImageView.contentMode = .scaleAspectFill
       backgroundImageView.clipsToBounds = true
       addSubview(backgroundImageView)
       // NO live UIVisualEffectView over the fill: live blur breaks while its opacity animates, so
       // the viewers-sheet crossfades flashed the raw bright fill (finding 2a). The backdrop is a
       // PRE-BAKED material-matched blur set in apply() — pixel-stable through any fade.

       // Foreground: the photo at its TRUE aspect ratio — aspect-FIT so a square/landscape is never
       // cropped/zoomed. The empty top/bottom become the zoomed + blurred backdrop above (user prefers
       // this resize+blur look over Instagram's center-crop fill).
       imageView.contentMode = .scaleAspectFit
       imageView.clipsToBounds = true
       addSubview(imageView)

       shimmer.isHidden = true
       addSubview(shimmer)
   }
}
