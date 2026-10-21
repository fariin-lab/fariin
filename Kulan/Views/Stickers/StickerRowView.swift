import UIKit
import ImageIO
import Lottie

// ⛔ A STICKER IN THE CHAT LIST — owner 2026-10-17. Drawn on a plain CALayer, no SwiftUI: a SwiftUI
// repeatForever animation near the text field deadlocked on iOS 26 (BUILD 959), so every moving
// sticker here is Core Animation / ImageIO only.
//
//   • the first frame is decoded off the main thread and shown at once (downsampled to the box);
//   • an animated one plays through `CGAnimateImageDataWithBlock`, which decodes one frame at a time
//     instead of holding them all, and ONLY while the row is on screen (`setOnScreen`, driven by the
//     list's willDisplay / didEndDisplaying) and in a window;
//   • built-in art comes from this phone's pack; if the pack lacks the file, the public copy on
//     fariin.com (cached on disk like any picture);
//   • a sticker I made is a sealed PNG: decrypted like a photo, kept in `DiskImageCache` as PNG so
//     the alpha survives, and the same bytes serve "Save to Favorites".
//   • ⛔ an animated .tgs (owner 2026-10-21) is not a picture: its bytes are unzipped and decoded off
//     the main thread (`TGSSticker`) and `TGSFramePlayer` draws its frames off the main thread into
//     `art`, playing on the same terms (on screen, in a window, not hidden). Not a LottieAnimationView:
//     the owner's second lag report ("the reference app's stickers have no lag").
final class RowStickerView: UIView {
    private let art = CALayer()
    private var key: String?            // what is on screen (or loading)
    private var bytes: Data?            // the loaded file, for the animator
    private var animated = false
    private var onScreen = true
    private var playing = false
    private var generation = 0          // bumped on every change; a stale load or animator stops
    /// A .tgs sticker (owner 2026-10-21): the decoded animation, its cache key and its player.
    private var tgs: LottieAnimation?
    private var tgsKey = ""
    private var live: TGSFramePlayer?
    /// Owner 2026-10-18: a sticker still downloading or decoding was an empty gap in the chat. The
    /// shimmer holds its place until the first frame is up; a sticker already seen never shows it.
    private let skeleton = SkeletonShimmerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        art.contentsGravity = .resizeAspect
        art.masksToBounds = false
        layer.addSublayer(art)
        addSubview(skeleton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.frame = bounds
        art.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.commit()
        skeleton.frame = bounds.insetBy(dx: 4, dy: 4)
        skeleton.layer.cornerRadius = min(16, skeleton.bounds.width * 0.18)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    func configure(_ s: Sticker, url: String?, enc: EncMeta?, cid: String, localData: Data?) {
        let k = "\(s.id)|\(url ?? "")"
        guard k != key else { updatePlayback(); return }
        // The same .tgs sticker, now uploaded: keep the playing view (see the note just below).
        if let old = key, old.hasPrefix("\(s.id)|"), tgs != nil {
            key = k
            updatePlayback()
            return
        }
        // ⛔ THE SAME STICKER, NOW UPLOADED (owner 2026-10-18, build 969: "after the upload it flashes").
        // A sent sticker is drawn from its local PNG with no link, then the server copy arrives WITH
        // the link: a new key, so the row reset to the shimmer and loaded the same picture again. Same
        // sticker and the picture already up: keep it, file it under the new key too, and move on.
        if let old = key, old.hasPrefix("\(s.id)|"), let have = bytes, let shown = art.contents {
            key = k
            Self.bytesCache.setObject(have as NSData, forKey: k as NSString, cost: have.count)
            if CFGetTypeID(shown as CFTypeRef) == CGImage.typeID {
                Self.firstCache.setObject(shown as! CGImage, forKey: k as NSString)
            }
            updatePlayback()
            return
        }
        reset()
        key = k
        animated = s.animated
        let gen = generation
        let px = max(bounds.width, bounds.height, MessageRowLayout.stickerSide) * (UIScreen.main.scale)

        // ⛔ NO BLANK BEAT ON A ROW ALREADY SEEN — owner 2026-10-17: opening a chat, every sticker
        // vanished for a moment and came back. Each new cell started empty and waited on a load +
        // decode. The first frame and the bytes are kept in memory, so a known sticker is on the
        // very first frame; only one never shown before still loads.
        // Then by the sticker alone ("id|", what the local pending copy was filed under), so a new row
        // for the same sent sticker also starts with its picture instead of the shimmer.
        let bare = "\(s.id)|" as NSString
        // A .tgs already decoded (owner 2026-10-21): on the first frame too.
        let tgsKey = "row:\(s.id)"
        if let anim = TGSSticker.cached(tgsKey) {
            bytes = (Self.bytesCache.object(forKey: k as NSString) ?? Self.bytesCache.object(forKey: bare)).map { $0 as Data }
            showTGS(anim, key: tgsKey)
            return
        }
        if let first = Self.firstCache.object(forKey: k as NSString) ?? Self.firstCache.object(forKey: bare),
           let data = Self.bytesCache.object(forKey: k as NSString) ?? Self.bytesCache.object(forKey: bare) {
            bytes = data as Data
            CATransaction.begin(); CATransaction.setDisableActions(true)
            art.contents = first
            CATransaction.commit()
            updatePlayback()
            return
        }

        // Owner 2026-10-18: a sticker just sent wore a grey box for a beat. Its art is on the phone and
        // loads in a moment, but the shimmer went up at once and faded over it. Only a load that is
        // still running after a short wait shows the shimmer; a fast one never does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == gen, self.art.contents == nil, self.tgs == nil else { return }
            self.skeleton.setActive(true)
        }
        Task { @MainActor [weak self] in
            guard let data = await Self.load(s, url: url, enc: enc, cid: cid, localData: localData) else {
                // Nothing came: no shimmer forever over an empty box.
                if let self, self.generation == gen { self.skeleton.setActive(false) }
                return
            }
            if TGSSticker.isTGS(data) {
                // Decoded into TGSSticker's cache off the main thread; only a yes/no crosses back.
                let ok = await Task.detached(priority: .userInitiated) { TGSSticker.animation(data: data, key: tgsKey) != nil }.value
                Self.bytesCache.setObject(data as NSData, forKey: k as NSString, cost: data.count)
                guard let self, self.generation == gen else { return }
                guard ok, let anim = TGSSticker.cached(tgsKey) else { self.skeleton.setActive(false); return }
                self.bytes = data
                self.showTGS(anim, key: tgsKey)
                return
            }
            let first = await Task.detached(priority: .userInitiated) { Self.firstFrame(data, maxPixel: px) }.value
            if let first { Self.firstCache.setObject(first, forKey: k as NSString) }
            Self.bytesCache.setObject(data as NSData, forKey: k as NSString, cost: data.count)
            guard let self, self.generation == gen else { return }
            self.bytes = data
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.art.contents = first
            CATransaction.commit()
            self.skeleton.fadeOut()
            self.updatePlayback()
        }
    }

    /// Puts a decoded .tgs up (its first frame, then `updatePlayback` starts it).
    private func showTGS(_ anim: LottieAnimation, key: String) {
        tgs = anim
        tgsKey = key
        live?.stop()
        // Sized to the row's box in pixels; a row not laid out yet uses the sticker's usual size.
        let side = max(bounds.width, bounds.height)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let p = TGSFramePlayer(anim: anim, key: key, pixel: Int((side > 0 ? side : 160) * scale),
                               fps: 60, target: art)
        live = p
        p.prime()
        skeleton.fadeOut()
        updatePlayback()
    }

    /// First frames and bytes of stickers already shown (see `configure`). Bounded: ~30MB of bytes.
    private static let firstCache: NSCache<NSString, CGImage> = { let c = NSCache<NSString, CGImage>(); c.countLimit = 120; return c }()
    private static let bytesCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>(); c.totalCostLimit = 30 * 1024 * 1024; return c
    }()

    /// The list says whether this row is on screen; animation runs only while it is.
    func setOnScreen(_ on: Bool) {
        onScreen = on
        updatePlayback()
    }

    func reset() {
        generation += 1
        key = nil; bytes = nil; animated = false; playing = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.contents = nil
        CATransaction.commit()
        tgs = nil
        live?.stop()
        live = nil
        skeleton.setActive(false)
    }

    /// The decrypted bytes behind this row, if it has them (Save to Favorites of a received one).
    var loadedBytes: Data? { bytes }

    /// ⛔ THE LONG-PRESS MENU KEEPS IT MOVING — owner 2026-10-21 ("long-press an animated sticker, it
    /// stops"). The menu lifts a SNAPSHOT of the bubble, which is a still. For an animated sticker
    /// this hands back a second, live player of the same art, started where this one is, to lay over
    /// the snapshot. Nil for a still sticker.
    func liveCopy() -> UIView? {
        if let anim = tgs {
            return TGSFrameView(frame: bounds, anim: anim, key: tgsKey, fps: live?.fps ?? 60,
                                progress: live?.progress ?? 0, still: art.contents)
        }
        guard animated, let data = bytes else { return nil }
        let v = UIView(frame: bounds)
        v.isUserInteractionEnabled = false
        let layer = CALayer()
        layer.frame = v.bounds
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = art.contentsScale
        layer.contents = art.contents
        v.layer.addSublayer(layer)
        // Runs while the copy exists; once the menu closes and lets it go, it stops itself.
        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak v, weak layer] _, image, stop in
            guard v != nil, let layer else { stop.pointee = true; return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
        return v
    }

    private func updatePlayback() {
        if let p = live, tgs != nil {
            let want = onScreen && window != nil && !isHidden
            if want { p.start() } else { p.stop() }
            return
        }
        let want = animated && onScreen && window != nil && bytes != nil && !isHidden
        if want == playing { return }
        playing = want
        generation += want ? 0 : 1      // stopping: the running animator sees a new generation
        guard want, let data = bytes else { return }
        let gen = generation
        // Called on the main queue, one frame at a time. `stop` ends it for good; a later start makes
        // a fresh animator.
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, image, stop in
            guard let self, self.generation == gen, self.playing else { stop.pointee = true; return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.art.contents = image
            CATransaction.commit()
        }
        if status != noErr { playing = false }
    }

    // MARK: - Bytes

    /// Off the main actor: the file read, the download and the decrypt.
    nonisolated private static func load(_ s: Sticker, url: String?, enc: EncMeta?, cid: String, localData: Data?) async -> Data? {
        if let localData { return localData }
        switch s.source {
        case .bundled:
            if let f = await MainActor.run(body: { StickerStore.shared.fileURL(for: s) }),
               let d = try? Data(contentsOf: f) { return d }
            // The pack does not have it (a newer pack than this build): the public copy.
            let u = url ?? StickerSend.publicURL(s)
            if let cached = await DiskImageCache.shared.rawData(for: u) { return cached }
            guard let remote = URL(string: u), remote.scheme == "https",
                  let (d, _) = try? await MediaSession.shared.data(from: remote),
                  CGImageSourceCreateWithData(d as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true
            else { return nil }
            DiskImageCache.shared.storeBytes(d, for: u)
            return d
        case .mine:
            // My own, still on this phone (sent by me, or saved) — no download.
            if let f = await MainActor.run(body: { StickerStore.shared.fileURL(for: s) }),
               let d = try? Data(contentsOf: f) { return d }
            guard let u = url, !u.isEmpty else { return nil }
            if let cached = await DiskImageCache.shared.rawData(for: u) { return cached }
            guard let remote = URL(string: u), let enc,
                  let (cipher, _) = try? await MediaSession.shared.data(from: remote),
                  let png = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: enc),
                  let ui = UIImage(data: png)
            else { return nil }
            DiskImageCache.shared.store(ui, data: png, for: u)
            return png
        }
    }

    /// Frame 0, downsampled to the box, decoded now (not lazily at draw time on the main thread).
    nonisolated private static func firstFrame(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
