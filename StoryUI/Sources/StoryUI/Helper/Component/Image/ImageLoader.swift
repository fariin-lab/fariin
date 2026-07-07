//
//  ImageLoader.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Combine
import UIKit
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

// The story exactly as it renders FULL SCREEN — photo + its real material bars, one image.
// Captured whenever a fit story is displayed; the host app's viewers-sheet cards render THIS
// (the original blur, guaranteed) instead of re-building fill+material at card size, which
// reads as a different, darker blur (heavier relative blur + dimming at small sizes).
public enum StoryCompositeCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 180 * 1024 * 1024   // screen-sized composites are ~12MB each @3x
        return c
    }()
    public static func image(for url: String) -> UIImage? { cache.object(forKey: url as NSString) }
    static func store(_ img: UIImage, for url: String) {
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        cache.setObject(img, forKey: url as NSString, cost: cost)
        // Cards showing the placeholder re-check the cache on this signal.
        NotificationCenter.default.post(name: Notification.Name("storySnapshotReady"), object: url)
    }
}

// Renders a story's full-screen composite (photo + native material bars) EXACTLY as the viewer
// renders it — offscreen, behind the app's content — and photographs it into the cache. This is
// the iOS app-switcher pattern: the system never scales a live blur; it snapshots the rendered
// result and scales the picture. Cards built from these snapshots are pixel-native by definition.
@MainActor
public enum StorySnapshotFactory {
    private static var inFlight = Set<String>()

    // contentHeight: the height the LIVE viewer gives the media (screen minus the owner-footer
    // strip). The offscreen render must match it exactly or the photo centres ~20pt differently
    // than the morphing real story and the card jumps at hand-off (audit M1).
    public static func warm(urlString: String, contentHeight: CGFloat) {
        guard !urlString.isEmpty,
              StoryCompositeCache.image(for: urlString) == nil,
              !inFlight.contains(urlString),
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }
        inFlight.insert(urlString)
        let loader = ImageLoader()
        // Mirror the LIVE media frame exactly: the own-story media view is contentHeight tall
        // (screen minus the Views/Delete footer strip — audit-verified from the mineOnly
        // VStack layout), NOT full screen. Rendering at the wrong height centred fit-photos
        // ~43pt differently and the centre card's photo JUMPED at every hand-off.
        let mediaFrame = CGRect(x: 0, y: 0, width: window.bounds.width,
                                height: min(contentHeight, window.bounds.height))
        loader.frame = mediaFrame
        window.insertSubview(loader, at: 0)   // behind the root view — never user-visible
        loader.loadImageWithUrl(urlString) {
            // One committed frame so the material composites, then photograph.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let bounds = window.bounds
                var rendered = false
                let img = UIGraphicsImageRenderer(bounds: bounds).image { ctx in
                    UIColor.black.setFill()
                    ctx.fill(bounds)
                    rendered = loader.drawHierarchy(in: mediaFrame, afterScreenUpdates: true)
                }
                loader.removeFromSuperview()
                inFlight.remove(urlString)
                // Only cache real renders: a failed drawHierarchy leaves the black canvas, and a
                // loader that never got its image has nothing to show (audit M2).
                if rendered, loader.imageView.image != nil {
                    StoryCompositeCache.store(img, for: urlString)
                }
            }
        }
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
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let shimmer = ShimmerView()
    // The frozen fill+blur composite while the viewers sheet scales the story (see freezeBlur).
    private var frozenBlur: UIImageView?

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
        blurView.frame = bounds
        imageView.frame = bounds
        shimmer.frame = bounds
        frozenBlur?.frame = bounds
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

    private func apply(_ image: UIImage?) {
        imageView.image = image
        backgroundImageView.image = image
        decideContentMode()        // fixed for this image; never recomputed on layout/drag
        if image != nil {
            scheduleCompositeCapture()
            installFreezeIfReady()   // sheet engaged + fresh image (carousel jump) → frozen backdrop now
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

        // Reused for a different story (carousel jump mid-sheet): the previous story's FROZEN
        // blur overlay must never survive under the new photo (audit C1 — story A's bars were
        // showing beneath story B). Drop the stale overlay ONLY — the sheet is still engaged,
        // so freezeWanted stays set and apply() re-freezes the new image the moment it lands.
        frozenBlur?.removeFromSuperview()
        frozenBlur = nil
        blurView.isHidden = false

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
       addSubview(blurView)   // heavy Gaussian blur over the fill copy

       // Foreground: the photo at its TRUE aspect ratio — aspect-FIT so a square/landscape is never
       // cropped/zoomed. The empty top/bottom become the zoomed + blurred backdrop above (user prefers
       // this resize+blur look over Instagram's center-crop fill).
       imageView.contentMode = .scaleAspectFit
       imageView.clipsToBounds = true
       addSubview(imageView)

       shimmer.isHidden = true
       addSubview(shimmer)

       // Viewers-sheet pull-up: freeze/unfreeze the blurred backdrop (posted by the host app).
       NotificationCenter.default.addObserver(self, selector: #selector(freezeBlur),
                                              name: Notification.Name("storyFreezeBlur"), object: nil)
       NotificationCenter.default.addObserver(self, selector: #selector(unfreezeBlur),
                                              name: Notification.Name("storyUnfreezeBlur"), object: nil)
   }
}

// MARK: - Blur freeze (viewers-sheet pull-up)
extension ImageLoader {
    // A LIVE material re-computes itself as the story scales down, rendering the fit-image bars far
    // darker/flatter than they looked full screen (user spec: "keep the exact blur from before the
    // pull-up — never generate a new one"). Freezing rasterizes the CURRENT on-screen appearance
    // (fill + material composite) into plain pixels and hides the live blur: frozen pixels scale
    // like a photograph, identical at every size. Unfreeze restores the live material at full screen.
    // The sheet is engaged and every current/future image should carry a frozen backdrop.
    // Set by storyFreezeBlur, cleared by storyUnfreezeBlur; apply() re-freezes on image load
    // (a one-shot timer missed slow-loading carousel jumps — audit finding 3).
    static var freezeWanted = false

    @objc private func freezeBlur() {
        Self.freezeWanted = true
        installFreezeIfReady()
    }

    func installFreezeIfReady() {
        guard Self.freezeWanted, frozenBlur == nil,
              imageView.image != nil, imageView.contentMode == .scaleAspectFit,
              bounds.width > 0 else { return }
        // Prefer the already-captured screen-space composite: rasterizing NOW fails subtly when
        // the view sits under a live transform (the sheet has it scaled after a carousel jump —
        // the material misrenders darker). The cached capture is the correct vivid original.
        let cached = imageURL.flatMap { StoryCompositeCache.image(for: $0.absoluteString) }
        guard var img = cached ?? rasterizeComposite() else { return }
        // The cached composite is SCREEN-space (taller than this media view by the footer
        // strip). Squashing it into bounds shifted every bar up and squeezed the baked black
        // strip into a visible "extra bar" at the card's bottom (audit finding 1) — crop the
        // composite to this view's own region instead, pixel 1:1.
        if img.size.height > bounds.height + 1, let cg = img.cgImage {
            let pxW = CGFloat(cg.width)
            let pxH = min(CGFloat(cg.height), bounds.height * img.scale)
            if let cropped = cg.cropping(to: CGRect(x: 0, y: 0, width: pxW, height: pxH)) {
                img = UIImage(cgImage: cropped, scale: img.scale, orientation: .up)
            }
        }
        let iv = UIImageView(image: img)
        iv.frame = bounds
        iv.contentMode = .scaleToFill
        insertSubview(iv, aboveSubview: blurView)
        blurView.isHidden = true
        frozenBlur = iv
    }

    // The container's blur samples only its own fill subview, so drawing the hierarchy captures
    // the material composite correctly. Every capture also feeds StoryCompositeCache so the
    // viewers-sheet cards can render the ORIGINAL blur for this story.
    private func rasterizeComposite() -> UIImage? {
        guard bounds.width > 0, window != nil,
              imageView.image != nil,
              imageView.contentMode == .scaleAspectFit   // full-bleed stories have no bars
        else { return nil }
        let shimmerWasHidden = shimmer.isHidden
        shimmer.isHidden = true
        let img = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        shimmer.isHidden = shimmerWasHidden
        // The CACHE entry is SCREEN-SPACE: the story exactly as the full screen shows it, drawn
        // at this view's true on-screen position into a screen-sized black canvas. The host's
        // card windows are computed in screen coordinates, and the media view may be inset from
        // the screen edges — caching only the media bounds shifted the photo inside the card
        // (the "image jumping up" hand-off). Skip while mid-page-slide (x offset) or scaled.
        let origin = convert(CGPoint.zero, to: nil)
        if let url = imageURL?.absoluteString,
           abs(origin.x) < 1, abs(origin.y) < 2, transform == .identity {
            let screen = window?.bounds ?? UIScreen.main.bounds
            let full = UIGraphicsImageRenderer(bounds: screen).image { ctx in
                UIColor.black.setFill()
                ctx.fill(screen)
                img.draw(in: CGRect(origin: origin, size: bounds.size))
            }
            StoryCompositeCache.store(full, for: url)
        }
        return img
    }

    // Capture the full-screen composite shortly after a fit image is shown (view settled,
    // material rendered). Cheap, once per story per session (cache hit skips it).
    private func scheduleCompositeCapture() {
        guard imageView.contentMode == .scaleAspectFit,
              let url = imageURL?.absoluteString,
              StoryCompositeCache.image(for: url) == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let current = self.imageURL?.absoluteString, current == url,
                  StoryCompositeCache.image(for: url) == nil else { return }
            _ = self.rasterizeComposite()
        }
    }

    @objc private func unfreezeBlur() {
        Self.freezeWanted = false
        frozenBlur?.removeFromSuperview()
        frozenBlur = nil
        blurView.isHidden = false
    }
}
