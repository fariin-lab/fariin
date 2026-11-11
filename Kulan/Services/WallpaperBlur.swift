import CoreImage
import SwiftUI
import UIKit

// ⛔ THE SURFACE BEHIND AN INCOMING BUBBLE ON A WALLPAPER, AND IT IS NOT A MATERIAL.
//
// Read from the reference app's source on 2026-08-23, after two rounds of "the bubble colour and
// glass are not the same" that a live material could never have answered. Their `ConversationStyle`
// CHOOSES a blur effect for an incoming bubble on a wallpaper — but their message component never
// hands that effect to a visual-effect view. When the fill is `.blur`, the bubble becomes their
// `CVWallpaperBlurView`: one image of the whole wallpaper, rendered once, Gaussian-blurred, washed
// with colour, and every bubble shows the SLICE of that image that sits underneath it. The recipe
// is `WallpaperBlurProviderImpl.wallpaperBlurState`, ported below number for number.
//
// That is why theirs looks the way it does and a material does not: the +0.4 exposure and the two
// white washes in light mode make a bubble far whiter than `systemThinMaterial`, and the 80% black
// wash in dark mode makes one far darker and steadier than `systemUltraThinMaterial`. Same family
// of idea — the wallpaper showing through — different picture.
//
// ⚠️ NOT iOS 26 GLASS. Checked, because the header and composer in their screenshots clearly are:
// `UIGlassEffect` is on their header, bottom panel, input toolbar, toasts and pickers. No bubble
// file uses it. The bubble is this image on every iOS version.

/// One blurred-and-washed picture of the wallpaper, and where it sits on screen.
///
/// `frame` is in WINDOW coordinates — the wallpaper fills the window behind a chat, so every slice
/// is worked out by converting this frame into the bubble's own space. Identity is what the
/// Equatable compares: two states are the same picture only if they are the same object.
@MainActor final class WallpaperBlurState: Equatable {
    let image: UIImage
    let frame: CGRect
    /// Whose wallpaper this is — the slice uses it to find the chat's live anchor view, because the
    /// state outlives any one visit to the chat (it is cached) and a view reference must not.
    let cid: String
    let id: UInt
    /// The picture this state shows (wallpaper, theme, size): the per-chat state is reused while
    /// this still matches, so the identity the rows key on only moves when the picture does.
    let key: String

    private static var counter: UInt = 0

    fileprivate init(image: UIImage, frame: CGRect, cid: String, key: String) {
        self.image = image
        self.frame = frame
        self.cid = cid
        self.key = key
        Self.counter &+= 1
        self.id = Self.counter
    }

    nonisolated static func == (l: WallpaperBlurState, r: WallpaperBlurState) -> Bool { l === r }
}

@MainActor enum WallpaperBlur {
    // ⛔ NOTHING HERE RENDERS OR WAITS ON THE MAIN THREAD DURING A CHAT OPEN (perf audit 2026-11-11,
    // L2/E8). Before, the first open of a wallpaper chat drew the wallpaper with `ImageRenderer`,
    // then sat on a semaphore while Core Image blurred it, inside ThreadView's body, during the
    // push; the header made a second full-screen render at screen scale in `viewDidLayoutSubviews`.
    // Both caches were emptied wholesale at four entries, so a theme flip brought it all back.
    //
    // Now, the way the reference app prepares its wallpaper: the picture is made on a worker thread
    // and handed to the screen when ready; until then the bubbles wear the material fallback and
    // the header shows the live wallpaper through. Pictures are keyed by WALLPAPER (not chat), theme
    // and size, so every chat on the same wallpaper shares one; kept in memory under a byte budget
    // (least recently used goes first) and on disk, so after the first time a wallpaper is seen it
    // is a file read on a worker thread, preloaded at launch for the most recent few.

    /// Per chat: the state it was last handed (reused while its key still matches).
    private static var states: [String: WallpaperBlurState] = [:]
    private static var blurImages = WallpaperImageLRU(byteLimit: 16 << 20)
    private static var headerImages = WallpaperImageLRU(byteLimit: 20 << 20)
    private static var headerDarkTop: [String: Bool] = [:]
    private static var inFlight = Set<String>()
    /// Read by `state(for:)` so a SwiftUI body that got nil re-evaluates when the picture lands.
    private static let ready = WallpaperPictureReady()
    private static var backdropCache: [String: UIUserInterfaceStyle] = [:]
    private static let backdropDefaultsKey = "wallpaperBlur.backdrop.v1"

    /// One picture's identity: kind ("b" blur, "h" header, "hd" header text), the wallpaper's own
    /// stored id, the theme and the size. The chat is NOT in it: two chats on one wallpaper share.
    fileprivate static func pictureKey(_ kind: String, _ w: ChatWallpaper, dark: Bool, size: CGSize,
                                       extra: String = "") -> String {
        "\(kind)|\(w.stored)|\(dark ? 1 : 0)|\(Int(size.width))x\(Int(size.height))\(extra)"
    }

    /// What can be drawn without SwiftUI (photo, plain colour) is drawn on a worker thread; the
    /// themes are SwiftUI views and are rendered on the main thread, after the push.
    private static func source(for w: ChatWallpaper) -> WallpaperSource {
        switch w {
        case .photo(let id):
            if let img = WallpaperStore.shared.libraryImage(id) { return .photo(img) }
            return .rendered
        case .color(let hex): return .color(hex)
        default: return .rendered
        }
    }

    fileprivate static func insertPreloaded(_ image: UIImage, key: String) {
        if key.hasPrefix("b|") {
            if blurImages.get(key) == nil { blurImages.put(image, for: key) }
        } else if key.hasPrefix("h|") {
            if headerImages.get(key) == nil { headerImages.put(image, for: key) }
        }
    }

    /// THE INTERFACE STYLE THE HEADER'S TEXT NEEDS over this chat's wallpaper: `.dark` (light text)
    /// when the band under the navigation bar is dark, `.light` when it is bright, `.unspecified`
    /// when there is no wallpaper and the app's own appearance is the right answer.
    ///
    /// ⛔ THE NAME VANISHED ON A BLACK WALLPAPER — owner, 2026-08-25, screenshot: "name and subtitle
    /// like last seen, if I use a black wallpaper no one can see". The header carries the reference
    /// app's mechanism for this, a 10pt glass probe behind the avatar whose light/dark trait is meant
    /// to follow the picture beneath and flip the labels; on his phone it did not fire, and a
    /// mechanism that answers "sometimes" is not an answer for the one label a chat cannot do
    /// without. This is the deterministic one: read the picture, measure the band the header sits
    /// on, decide. The probe stays as the fallback for a chat with no wallpaper.
    ///
    /// Relative luminance with the gamma undone (the number contrast is actually defined on, see
    /// `ProfilePalette`), averaged over the top 150pt: the status bar, the bar, the header. The whole
    /// band rather than a point, so a dark picture with one bright highlight does not flip the text.
    /// Cached per chat, theme and wallpaper version like the blur itself.
    static func headerBackdrop(for cid: String, dark: Bool) -> UIUserInterfaceStyle {
        let store = WallpaperStore.shared
        guard store.hasWallpaper(for: cid) else { return .unspecified }
        // A moving wallpaper says itself whether its top is dark (nothing still to measure).
        if case .animated(let id) = store.wallpaper(for: cid), let a = AnimatedWallpapers.find(id) {
            return a.topIsDark(dark) ? .dark : .light
        }
        let frame = windowFrame
        guard frame.width > 1, frame.height > 1 else { return .unspecified }
        let w = store.wallpaper(for: cid)
        let key = pictureKey("hd", w, dark: dark, size: frame.size)
        if let hit = backdropCache[key] { return hit }
        // Saved across launches (perf audit 2026-11-11, L2): the answer for a wallpaper never
        // changes, so only the first time a wallpaper is ever seen pays the measure below.
        var saved = UserDefaults.standard.dictionary(forKey: backdropDefaultsKey) as? [String: Int] ?? [:]
        if let raw = saved[key], let style = UIUserInterfaceStyle(rawValue: raw) {
            backdropCache[key] = style
            return style
        }
        // The first time: measured now, because the header's text must be right on its first frame.
        let picture: UIImage?
        switch source(for: w) {
        case .rendered: picture = renderWallpaper(cid: cid, dark: dark, size: frame.size)
        case let s: picture = WallpaperPictureWork.draw(s, size: frame.size, band: min(150, frame.height),
                                                        scale: 1, darkScrim: false, dim: 0)
        }
        guard let picture else { return .unspecified }
        let band = CGRect(x: 0, y: 0, width: picture.size.width, height: min(150, picture.size.height))
        // Owner, 2026-10-10: "light wallpaper -> dark text, dark wallpaper -> white text". The switch
        // was at 0.4, so medium-light wallpapers kept white text that barely read. Now whichever text
        // has the HIGHER contrast wins: white's ratio is 1.05/(L+0.05), black's (L+0.05)/0.05, and they
        // are equal at L ~ 0.179.
        let style: UIUserInterfaceStyle = WallpaperPictureWork.averageLuminance(of: picture, in: band) < 0.179 ? .dark : .light
        if backdropCache.count >= 32 { backdropCache.removeAll() }
        backdropCache[key] = style
        if saved.count >= 64 { saved.removeAll() }
        saved[key] = style.rawValue
        UserDefaults.standard.set(saved, forKey: backdropDefaultsKey)
        return style
    }
}

/// The work that runs off the main thread: drawing a photo or colour wallpaper, the blur, the
/// measures, and the disk cache. Nothing in here touches UIKit views or the stores.
enum WallpaperPictureWork {
    /// Their blur radius. Twenty at 1× — the image is rendered in points, not pixels, exactly as
    /// theirs is (`renderAsImage(opaque: true, scale: 1)`), so this number means the same thing.
    static let radius: CGFloat = 20

    /// A photo or plain-colour wallpaper drawn the way `ChatWallpaperBackground` draws it: the photo
    /// fills the `size` box centred (`scaledToFill` in a frame of that size), then the dark-mode
    /// scrim and the owner's dimness when asked. Only the top `band` points are kept. Thread-safe
    /// (`UIGraphicsImageRenderer` and `UIImage.draw` may run on any thread).
    static func draw(_ source: WallpaperSource, size: CGSize, band: CGFloat, scale: CGFloat,
                     darkScrim: Bool, dim: Double) -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let canvas = CGSize(width: size.width, height: min(size.height, max(1, band)))
        let full = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            switch source {
            case .photo(let img):
                guard img.size.width > 0, img.size.height > 0 else { return }
                let s = max(size.width / img.size.width, size.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
                if darkScrim {
                    UIColor(white: 0, alpha: 0.20).setFill()
                    ctx.fill(full)
                }
            case .color(let hex):
                UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                        blue: CGFloat(hex & 0xff) / 255, alpha: 1).setFill()
                ctx.fill(full)
            case .rendered:
                return
            }
            if dim > 0 {
                UIColor(white: 0, alpha: CGFloat(min(WallpaperDim.max, dim))).setFill()
                ctx.fill(full, blendMode: .normal)
            }
        }
    }

    /// The header copy's "is its top dark" (`ChatHeaderBlurView`): the top strip's average colour.
    static func topIsDark(_ image: UIImage, topHeight: CGFloat, threshold: CGFloat) -> Bool {
        guard let cg = image.cgImage else { return false }
        let strip = CGRect(x: 0, y: 0, width: cg.width,
                           height: min(cg.height, Int(topHeight * image.scale)))
        guard let top = cg.cropping(to: strip) else { return false }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(top, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let lum = (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255
        return lum < threshold
    }

    // MARK: Disk

    /// One folder per app build, so a theme redrawn in an update is never served from an old file.
    static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return base.appendingPathComponent("wallpaper-pictures-\(build)", isDirectory: true)
    }()

    static func url(for key: String) -> URL {
        let name = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(key.hashValue)
        return folder.appendingPathComponent(name + ".jpg")
    }

    /// The scale a header picture was drawn at, from its key's "|sN" tail; 1 for everything else.
    static func scale(ofKey key: String) -> CGFloat {
        guard key.hasPrefix("h|"), let r = key.range(of: "|s", options: .backwards),
              let n = Double(key[r.upperBound...]) else { return 1 }
        return CGFloat(n)
    }

    /// Read and DECODED here, so the main thread only ever gets a ready bitmap.
    static func load(_ key: String) -> UIImage? {
        let u = url(for: key)
        guard let data = try? Data(contentsOf: u),
              let img = UIImage(data: data, scale: scale(ofKey: key)) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return img.preparingForDisplay() ?? img
    }

    static func save(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    /// Mean relative luminance of `rect` in `image`, 0 (black) to 1 (white). The band is drawn down
    /// into a 4×4 bitmap with high-quality interpolation, which is a box average of the pixels, then
    /// the sixteen samples are linearised and averaged. Cheap enough to run once per wallpaper.
    static func averageLuminance(of image: UIImage, in rect: CGRect) -> CGFloat {
        guard let cg = image.cgImage else { return 0.5 }
        let scale = CGFloat(cg.width) / max(1, image.size.width)
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
        guard let band = cg.cropping(to: pixelRect) else { return 0.5 }
        let n = 4
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.interpolationQuality = .high
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: n, height: n))
        func lin(_ v: UInt8) -> CGFloat {
            let c = CGFloat(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var total: CGFloat = 0
        for i in 0..<(n * n) {
            let r = lin(px[i * 4]), g = lin(px[i * 4 + 1]), b = lin(px[i * 4 + 2])
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / CGFloat(n * n)
    }
}

/// What a wallpaper is drawn from: a photo or a colour (drawn off the main thread), or a SwiftUI
/// theme view (`ImageRenderer`, main thread only).
enum WallpaperSource {
    case photo(UIImage)
    case color(UInt)
    case rendered
}

/// Bumped when a picture lands; see `WallpaperBlur.ready`.
@Observable final class WallpaperPictureReady {
    var tick = 0
}

/// Pictures in memory under a byte budget; the least recently used goes first. Main thread only.
struct WallpaperImageLRU {
    let byteLimit: Int
    private var items: [String: UIImage] = [:]
    private var order: [String] = []
    private var bytes = 0

    init(byteLimit: Int) { self.byteLimit = byteLimit }

    private static func cost(_ i: UIImage) -> Int {
        guard let cg = i.cgImage else { return Int(i.size.width * i.size.height * i.scale * i.scale * 4) }
        return cg.bytesPerRow * cg.height
    }

    mutating func get(_ key: String) -> UIImage? {
        guard let hit = items[key] else { return nil }
        if order.last != key, let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        return hit
    }

    mutating func put(_ image: UIImage, for key: String) {
        if let old = items[key] {
            bytes -= Self.cost(old)
            order.removeAll { $0 == key }
        }
        items[key] = image
        order.append(key)
        bytes += Self.cost(image)
        // The newest always stays, even alone over budget: it is the one on screen.
        while bytes > byteLimit, order.count > 1 {
            let gone = order.removeFirst()
            if let g = items.removeValue(forKey: gone) { bytes -= Self.cost(g) }
        }
    }
}

@MainActor extension WallpaperBlur {
    /// ⛔ **BACK ON — OWNER, 2026-09-02, SAME DAY IT WAS SWITCHED OFF: "Plz restore my custom blur i
    /// dont like it apple type".**
    ///
    /// This flag existed for exactly one working day. The system-material version shipped in build
    /// 724 that morning, he saw it on his phone, and he wanted this back. **That is the answer to a
    /// question this file's neighbours have now flipped THREE times** — do not offer him a material
    /// again without a fresh screenshot from him asking for one.
    ///
    /// ⚠️ **THIS FLAG AND THE RETURN IN `Theme.receivedSurface` ARE A PAIR.** On alone changes
    /// nothing you can see, because the surface decision would not ask for a slice. The other on
    /// alone gives every bubble the flat grey, because it would ask and be handed nil. Both, or
    /// neither. That is why it was left as a flag rather than deleted, and it is what made the
    /// restore a two-line change instead of a revert.
    ///
    /// ⚠️ **WHAT DID NOT COME BACK WITH IT: the rim.** His words were "dont tuch stack thin Line
    /// only Restore the custom blur" — the white-in-both-themes stroke from the morning STAYS. The
    /// surface and the stroke were one commit and are two decisions, and he kept one of them.
    static let enabled = true

    /// The state for this chat, or nil when no picture is wanted: no wallpaper, or Reduce
    /// Transparency on (theirs shows the plain theme background then, and so do we — see
    /// `Theme.receivedSurface`). The picture is keyed by wallpaper, theme and size and shared by
    /// every chat on that wallpaper. A miss returns nil (the bubbles wear the material fallback for
    /// those frames) and starts the picture off the main thread; when it lands, `ready` moves and
    /// the body that asked runs again and gets it. Never a render or a wait on the main thread here.
    static func state(for cid: String, dark: Bool, frame: CGRect) -> WallpaperBlurState? {
        guard enabled else { return nil }
        let store = WallpaperStore.shared
        // The wallpaper going AWAY is the same staleness the other way round: an off-screen bubble
        // would go on showing a slice of a picture the chat no longer has. Same broadcast, emptied.
        // A moving wallpaper has no still picture to cut slices from (owner 2026-11-06): no state,
        // so `Theme.receivedSurface` gives the live material blur, which follows the motion.
        guard !UIAccessibility.isReduceTransparencyEnabled,
              store.hasWallpaper(for: cid),
              !store.wallpaper(for: cid).isAnimated,
              frame.width > 1, frame.height > 1
        else {
            WallpaperBlurSliceView.clear(cid)
            return nil
        }
        _ = ready.tick   // observed: a body that got nil here re-runs when the picture lands
        let wallpaper = store.wallpaper(for: cid)
        let key = pictureKey("b", wallpaper, dark: dark, size: frame.size)
        if let hit = states[cid], hit.key == key, hit.frame == frame {
            // ⛔ A CACHE HIT MUST BROADCAST TOO, AND NOT DOING SO IS THE LIGHT/DARK BUG — owner,
            // 2026-08-24: "I change light mode to dark, the bubbles and the pin, time and
            // disappearing badges don't understand which mode I picked until I leave the page and
            // come back."
            //
            // ⚠️ IT ONLY BIT ON THE WAY BACK, WHICH IS WHY IT LOOKED RANDOM. Going light → dark is a
            // MISS: a picture is rendered and `adopt` below hands it to every slice already on
            // screen. Going dark → light again is a HIT, and this line used to return the old picture
            // straight to the caller without telling a single live slice about it — so every badge
            // and every incoming bubble went on wearing the wash of the mode he had just left.
            // Leaving the chat and coming back rebuilt them all, which is exactly the workaround he
            // described.
            //
            // The note under `adopt` already says a row is NOT rebuilt merely because its signature
            // changed, and that broadcasting is what covers the rows nobody rebuilds. That reasoning
            // applies whether the picture was made just now or half a minute ago.
            WallpaperBlurSliceView.adopt(hit)
            return hit
        }
        guard let image = blurImages.get(key) else {
            prepareBlur(cid: cid, wallpaper: wallpaper, dark: dark, size: frame.size, key: key)
            return nil
        }
        let state = WallpaperBlurState(image: image, frame: frame, cid: cid, key: key)
        // States are light (the image is shared through `blurImages`); a handful of chats.
        if states.count >= 16 { states.removeAll() }
        states[cid] = state
        // ⛔ EVERY LIVE SLICE OF THIS CHAT TAKES THE NEW PICTURE AT ONCE — his 2026-08-23 "I change
        // the wallpaper and some bubbles still have the old one", with two teal bubbles left over
        // from the previous wallpaper among a screenful of correct ones.
        //
        // ⚠️ A ROW IS NOT REBUILT JUST BECAUSE ITS SIGNATURE CHANGED. `NativeMessageList` diffs the
        // signatures against `indexPathsForVisibleItems` and refreshes only those — then writes
        // `lastRowSigs = rowSignatures` for ALL of them, so a row that was off screen at that instant
        // is recorded as up to date without ever having been rebuilt, and nothing asks again. Its
        // bubble goes on holding the state it was born with, which is the old picture.
        //
        // Broadcasting is the right shape here rather than a fix to that diff: the picture is a
        // SINGLETON per chat, so "every slice of this cid shows this image" is simply true, and it
        // holds however a given slice got on screen. A slice whose cell IS rebuilt gets the same
        // object through `updateUIView` anyway, so the two paths cannot disagree.
        WallpaperBlurSliceView.adopt(state)
        return state
    }

    // MARK: - The anchor

    /// ⛔ THE SLICES ARE POSITIONED AGAINST THIS VIEW, NOT AGAINST THE WINDOW — his 2026-08-23
    /// "profile → All Media → back and the bubbles lose their colour" screenshot, and a shortcut of
    /// mine the reference app deliberately does not take.
    ///
    /// Converting from the window is only right while the chat is sitting still AT the window's
    /// origin. Coming back from a pushed screen, the chat re-enters the hierarchy mid-slide; every
    /// slice repositions at that moment (`didMoveToWindow`), bakes the transition's offset into its
    /// frame, and nothing runs afterwards to correct it because nothing scrolled. The image ends up
    /// shifted sideways: short bubbles fall entirely outside it and go CLEAR — his "using background
    /// color" — and wide ones show a displaced dark patch beside themselves.
    ///
    /// The reference converts from a reference view INSIDE the conversation screen
    /// (`convert(referenceView.bounds, from: referenceView)`), so the bubble and the wallpaper slide
    /// together and the conversion cancels the slide at every instant. `WallpaperAnchor` is ours: an
    /// inert view laid exactly over the chat's wallpaper, registered per chat. Weak values, so a
    /// closed chat cleans up after itself.
    private static let anchors = NSMapTable<NSString, UIView>(keyOptions: .copyIn,
                                                              valueOptions: .weakMemory)

    static func registerAnchor(_ view: UIView, for cid: String) {
        anchors.setObject(view, forKey: cid as NSString)
    }

    static func anchor(for cid: String) -> UIView? {
        anchors.object(forKey: cid as NSString)
    }

    /// Where a full-screen chat's wallpaper sits once settled: the window. `ChatWallpaperBackground`
    /// is drawn `.ignoresSafeArea()` behind the whole screen. This is the SIZE the picture is made
    /// at, and the positioning fallback for a slice whose chat has no live anchor.
    static var windowFrame: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window?.bounds ?? UIScreen.main.bounds
    }

    // MARK: - Rendering

    /// How much of the wallpaper's top the header copy holds. The header view is
    /// `max(minHeight 100, safe top + 34)` tall, so 240pt covers every phone with room to spare;
    /// the old full-screen copy at screen scale was about 12 MB for the 150pt that ever showed.
    static let headerBand: CGFloat = 240

    /// What the header asks for: no copy wanted, one on its way, or the copy and whether its top is
    /// dark (`ChatHeaderBlurView` lowers its alpha over a dark top).
    enum HeaderPicture {
        case none
        case pending
        case ready(UIImage, darkTop: Bool)
    }

    /// The chat's wallpaper as it stands on screen, UNBLURRED and at screen scale, for the chat
    /// header (`ChatHeaderBlurView`): the reference app's header over a wallpaper is a copy of the
    /// wallpaper itself, lined up with it and faded out, so messages dissolve into the picture.
    /// `.none` when the chat has no picture. Made once per wallpaper, theme, size and dimness, off
    /// the main thread (a theme view renders on the main thread after the push); `.pending` until
    /// then, and `.headerPictureReady` is posted when it lands.
    static func headerPicture(for cid: String, dark: Bool, size: CGSize,
                              darkTopHeight: CGFloat, darkLuminance: CGFloat) -> HeaderPicture {
        let store = WallpaperStore.shared
        // A moving wallpaper: no still copy behind the header (it would freeze over the motion).
        guard store.hasWallpaper(for: cid), !store.wallpaper(for: cid).isAnimated,
              size.width > 1, size.height > 1 else { return .none }
        let wallpaper = store.wallpaper(for: cid)
        let dim = UserDefaults.standard.double(forKey: WallpaperDim.key)
        let scale = UIScreen.main.scale
        let key = pictureKey("h", wallpaper, dark: dark, size: size,
                             extra: "|d\(Int((dim * 100).rounded()))|s\(Int(scale))")
        if let hit = headerImages.get(key) {
            let darkTop = headerDarkTop[key]
                ?? WallpaperPictureWork.topIsDark(hit, topHeight: darkTopHeight, threshold: darkLuminance)
            headerDarkTop[key] = darkTop
            return .ready(hit, darkTop: darkTop)
        }
        guard !inFlight.contains(key) else { return .pending }
        inFlight.insert(key)
        let src = source(for: wallpaper)
        let band = min(size.height, headerBand)
        let finish: @MainActor (UIImage?, Bool) -> Void = { image, darkTop in
            inFlight.remove(key)
            guard let image else { return }
            headerImages.put(image, for: key)
            if headerDarkTop.count >= 32 { headerDarkTop.removeAll() }
            headerDarkTop[key] = darkTop
            NotificationCenter.default.post(name: .headerPictureReady, object: nil)
        }
        WallpaperBlurRender.run {
            if let disk = WallpaperPictureWork.load(key) {
                let darkTop = WallpaperPictureWork.topIsDark(disk, topHeight: darkTopHeight, threshold: darkLuminance)
                Task { @MainActor in finish(disk, darkTop) }
                return
            }
            if case .rendered = src {
                Task { @MainActor in
                    // A SwiftUI theme can only be rendered here; after the push, not inside it.
                    try? await Task.sleep(for: .milliseconds(400))
                    let image = renderHeader(cid: cid, dark: dark, size: size, band: band, scale: scale)
                    guard let image else { finish(nil, false); return }
                    WallpaperBlurRender.run {
                        let darkTop = WallpaperPictureWork.topIsDark(image, topHeight: darkTopHeight, threshold: darkLuminance)
                        WallpaperPictureWork.save(image, key: key)
                        Task { @MainActor in finish(image, darkTop) }
                    }
                }
                return
            }
            let image = WallpaperPictureWork.draw(src, size: size, band: band, scale: scale,
                                                  darkScrim: dark, dim: dim)
            var darkTop = false
            if let image {
                darkTop = WallpaperPictureWork.topIsDark(image, topHeight: darkTopHeight, threshold: darkLuminance)
                WallpaperPictureWork.save(image, key: key)
            }
            Task { @MainActor in finish(image, darkTop) }
        }
        return .pending
    }

    /// The header copy of a SwiftUI theme: the full-screen wallpaper, top `band` points kept.
    private static func renderHeader(cid: String, dark: Bool, size: CGSize, band: CGFloat,
                                     scale: CGFloat) -> UIImage? {
        let view = ChatWallpaperBackground(cid: cid, pictureSize: size)
            .frame(width: size.width, height: size.height)
            .frame(width: size.width, height: band, alignment: .top)
            .clipped()
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// The blurred picture for `key`, made off the main thread: from disk when this wallpaper was
    /// seen before; else drawn (photo, colour) or rendered on the main thread after the push (a
    /// theme), then blurred on the worker. Lands in `blurImages` and moves `ready`.
    private static func prepareBlur(cid: String, wallpaper: ChatWallpaper, dark: Bool, size: CGSize, key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let src = source(for: wallpaper)
        let finish: @MainActor (UIImage?) -> Void = { image in
            inFlight.remove(key)
            guard let image else { return }
            blurImages.put(image, for: key)
            ready.tick &+= 1
        }
        WallpaperBlurRender.run {
            if let disk = WallpaperPictureWork.load(key) {
                Task { @MainActor in finish(disk) }
                return
            }
            if case .rendered = src {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard let picture = renderWallpaper(cid: cid, dark: dark, size: size) else { finish(nil); return }
                    WallpaperBlurRender.run {
                        let out = WallpaperPictureWork.blurred(picture, dark: dark)
                        if let out { WallpaperPictureWork.save(out, key: key) }
                        Task { @MainActor in finish(out) }
                    }
                }
                return
            }
            let picture = WallpaperPictureWork.draw(src, size: size, band: size.height, scale: 1,
                                                    darkScrim: false, dim: 0)
            let out = picture.flatMap { WallpaperPictureWork.blurred($0, dark: dark) }
            if let out { WallpaperPictureWork.save(out, key: key) }
            Task { @MainActor in finish(out) }
        }
    }

    /// The wallpaper as the chat draws it, at 1×, WITHOUT the photo scrim. Theirs blurs the
    /// undimmed content view and does the darkening in the wash below; blurring a scrim in first
    /// would darken twice.
    private static func renderWallpaper(cid: String, dark: Bool, size: CGSize) -> UIImage? {
        // `pictureSize` is the size being rendered at, so this picture is cropped exactly the way
        // the chat's own wallpaper is — the slices the bubbles show are cut from the picture that
        // is actually on screen. Passing it explicitly rather than letting the container decide is
        // what keeps the two in step if either size ever changes.
        let view = ChatWallpaperBackground(cid: cid, includesScrim: false, pictureSize: size)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

extension Notification.Name {
    /// A chat header's wallpaper copy finished (`WallpaperBlur.headerPicture`).
    static let headerPictureReady = Notification.Name("WallpaperBlur.headerPictureReady")
}

extension WallpaperPictureWork {
    /// Their `withGaussianBlur(radius:colorOverlays:vibrancy:exposureAdjustment:)`, filter for
    /// filter, in the order they run it: clamp → blur → each wash → vibrance → exposure.
    /// Runs on the render thread (`WallpaperBlurRender.run`), never the main thread.
    static func blurred(_ source: UIImage, dark: Bool) -> UIImage? {
        guard let cg = source.cgImage else { return nil }
        let input = CIImage(cgImage: cg)

        // Clamped first so the blur has pixels to read past the edge; without it the border of a
        // blurred image fades to transparent and every edge bubble goes pale.
        guard let clamp = CIFilter(name: "CIAffineClamp", parameters: [
            kCIInputImageKey: input,
            kCIInputTransformKey: NSValue(cgAffineTransform: .identity),
        ]), let clamped = clamp.outputImage else { return nil }

        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: clamped,
            kCIInputRadiusKey: radius,
        ]), var out = blur.outputImage else { return nil }

        // THE WASHES, AND THESE ARE THE NUMBERS THAT MAKE IT LOOK LIKE THEIRS.
        // Light: white at 40% laid over the top, then white at 16% as a lighten blend.
        // Dark: black at 80% laid over the top (their default, with the wallpaper dimmed), then a
        // mid grey at 4% as a darken blend. The second pass in each is small and deliberate.
        let washes: [(UIColor, String)] = dark
            ? [(UIColor(white: 0, alpha: 0.8), "CISourceAtopCompositing"),
               (UIColor(white: 0.5, alpha: 0.04), "CIDarkenBlendMode")]
            : [(UIColor(white: 1, alpha: 0.4), "CISourceAtopCompositing"),
               (UIColor(white: 1, alpha: 0.16), "CILightenBlendMode")]
        for (color, mode) in washes {
            guard let gen = CIFilter(name: "CIConstantColorGenerator", parameters: [
                kCIInputColorKey: CIColor(color: color),
            ]), let wash = gen.outputImage,
            let comp = CIFilter(name: mode, parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputImageKey: wash,
            ]), let next = comp.outputImage else { return nil }
            out = next
        }

        if let vib = CIFilter(name: "CIVibrance", parameters: [
            kCIInputImageKey: out, kCIInputAmountKey: 0.2,
        ]), let next = vib.outputImage { out = next }

        if let exp = CIFilter(name: "CIExposureAdjust", parameters: [
            kCIInputImageKey: out, kCIInputEVKey: 0.4,
        ]), let next = exp.outputImage { out = next }

        // Cropped back to the source's extent: the clamp made it infinite.
        // ONE context for the app (2026-09-27, the first chat open after launch): a `CIContext` is
        // expensive to build and this made a fresh one on every chat open, on the main thread.
        guard let result = wallpaperBlurContext.createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: 1, orientation: .up)
    }
}

// MARK: - The slice

/// One bubble's window onto the blurred wallpaper. The image view inside is the size of the whole
/// wallpaper and is placed so that the part under THIS view is the part that shows, which is the
/// reference app's `imageViewFrame = convert(referenceView.bounds, from: referenceView)`.
///
/// ⚠️ REPOSITIONED ON EVERY SCROLL TICK, AND THAT IS NOT OPTIONAL. A cell that scrolls does not get
/// `layoutSubviews`; the list moves it by changing its own offset. Left alone, a slice would carry
/// the patch of wallpaper it was born over up and down the screen. Theirs calls
/// `updateScrollingContent` on every visible cell per scroll; `repositionAll()` is ours, called from
/// the message list's `scrollViewDidScroll`. Every live slice registers itself for it weakly.
///
/// Not a visual-effect view, and that is the other half of why this replaced one: an image view
/// SNAPSHOTS. The long-press lift copies the bubble with `snapshotView`, which cannot render a blur
/// and came up empty or dead over the previous approach; a slice comes up exactly as drawn.
///
/// ⚠️ **AND THAT TRADE IS NOW GOING THE OTHER WAY — OWNER, 2026-09-02.** He asked for the system's
/// own blur, which means the lift is a snapshot of a `UIVisualEffectView` again. The mechanism is
/// `NativeMessageList.bubbleSource`, `resizableSnapshotView(afterScreenUpdates: false)`. It was
/// reported once before, when the material shipped the first time, and it was never proven — the
/// note in the memory file says do not fix it blind, and it is still unfixed. If an incoming bubble
/// lifts with no background under a long press, this is why, and the fix is at that call site, not
/// here.
@MainActor final class WallpaperBlurSliceView: UIView {
    private static let live = NSHashTable<WallpaperBlurSliceView>.weakObjects()

    /// Called per scroll tick by whoever owns the scrolling — see the note above.
    static func repositionAll() {
        for v in live.allObjects { v.reposition() }
    }

    /// The send glide is played by Core Animation, not scroll ticks (`NativeMessageList.startSendGlide`),
    /// so a slice is placed for where the list will be. This gives every slice inside `root` the
    /// glide's own keyframes (additive `position.y`, the same values as the list's), which keep the
    /// picture still on the screen while its bubble slides. `animation` nil removes them.
    static func followGlide(in root: UIView, animation: CAAnimation?, key: String) {
        for v in live.allObjects where v.isDescendant(of: root) {
            if let animation { v.imageView.layer.add(animation, forKey: key) }
            else { v.imageView.layer.removeAnimation(forKey: key) }
        }
    }

    /// Every live slice inside `root`, for a cell the list has just PLACED (see
    /// `MessageRowCell.apply(_:)`). A cell is configured before the list hands it its frame, so the
    /// `reposition` inside `BubbleFillView.apply` measures the cell where it USED to be: a recycled
    /// cell that went out of the screen, or a fresh one not placed yet. The image is the size of the
    /// screen, so a cell measured off the screen carries an image that misses the bubble entirely
    /// once it lands, and only the rim is left. A scroll tick corrects it; a list at rest never does.
    static func reposition(in root: UIView) {
        for v in live.allObjects where v.isDescendant(of: root) {
            guard !v.isHidden, v.window != nil else { continue }
            // Device evidence for the next test: which of the two empty-bubble states this was.
            // Debug builds only (release audit 2026-11-10): this runs per cell while a chat scrolls.
            #if DEBUG
            if v.state == nil {
                NSLog("[WPSlice] visible slice has no picture (state nil)")
            } else if !v.imageView.frame.intersects(v.bounds) {
                NSLog("[WPSlice] slice was off its picture before placement, corrected")
            }
            #endif
            v.reposition()
        }
    }

    /// The picture for a chat changed: every live slice of THAT chat takes it, on screen or not.
    /// See the note at the call site in `WallpaperBlur.state(for:dark:frame:)` for why this is a
    /// broadcast and not something each row is trusted to pick up.
    static func adopt(_ new: WallpaperBlurState) {
        for v in live.allObjects where v.state?.cid == new.cid && v.state !== new {
            v.state = new
        }
    }

    /// This chat has no picture any more — wallpaper removed, or Reduce Transparency switched on.
    static func clear(_ cid: String) {
        for v in live.allObjects where v.state?.cid == cid { v.state = nil }
    }

    private let imageView = UIImageView()
    private let maskShape = CAShapeLayer()
    /// Their `strokeLayer`, construction and all: the bubble path stroked at 2 hairlines, sitting
    /// inside the masked view so the outer half is clipped and ONE physical pixel of rim survives
    /// on the inside of the edge. Drawn only on the UIKit path (`maskPath != nil`) — the SwiftUI
    /// bubbles draw their rim as a `strokeBorder` overlay because only the site knows the shape.
    private let strokeShape = CAShapeLayer()

    var state: WallpaperBlurState? {
        didSet {
            guard state !== oldValue else { return }
            imageView.image = state?.image
            // With no picture there is nothing to rim either: the bubble is a flat colour now and
            // the surface underneath it will say so on the next rebuild.
            strokeShape.isHidden = state == nil || maskPath == nil
            reposition()
        }
    }

    /// The bubble's outline in THIS view's coordinates. Nil leaves the slice unmasked, which is
    /// right for the SwiftUI bubbles: they clip the whole bubble themselves, background included.
    var maskPath: UIBezierPath? {
        didSet { applyMask() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // The image is at 1× and the frame it is given is the wallpaper's own size, so this is an
        // identity draw; it is only named so a rounding error cannot ask for aspect fitting.
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        strokeShape.fillColor = nil
        strokeShape.lineWidth = 2 * Theme.bubbleRimWidth
        layer.addSublayer(strokeShape)   // added after the image view → above it; the mask clips both
        // The rim colour is baked to a CGColor, so a light↔dark switch has to re-resolve it by hand.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: WallpaperBlurSliceView, _) in
            self.applyStrokeColor()
        }
        Self.live.add(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyStrokeColor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        strokeShape.strokeColor = UIColor(Theme.bubbleRim(dark)).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reposition()
        applyMask()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reposition()
    }

    func reposition() {
        guard let state, window != nil else { return }
        // No implicit animation: this runs every scroll frame, and a 0.25s ease on each would leave
        // the wallpaper lagging behind the bubble it is supposed to be under.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Against the chat's own anchor when it is live and on this window — transition-proof, see
        // `WallpaperBlur.registerAnchor`. The window fallback only serves a slice drawn somewhere
        // its chat's wallpaper is not (which today is nowhere: the previews take the material).
        if let ref = WallpaperBlur.anchor(for: state.cid), ref.window === window {
            imageView.frame = convert(ref.bounds, from: ref)
        } else {
            imageView.frame = convert(state.frame, from: nil)
        }
        CATransaction.commit()
    }

    private func applyMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let maskPath {
            maskShape.frame = bounds
            maskShape.path = maskPath.cgPath
            layer.mask = maskShape
            strokeShape.frame = bounds
            strokeShape.path = maskPath.cgPath
            applyStrokeColor()
            strokeShape.isHidden = false
        } else {
            layer.mask = nil
            strokeShape.isHidden = true
        }
        CATransaction.commit()
    }
}

/// The slice, for the SwiftUI bubbles. Sized by whatever `.background` hands it and clipped by the
/// bubble's own `clipShape` after, so it carries no mask of its own.
struct WallpaperBlurSlice: UIViewRepresentable {
    let state: WallpaperBlurState

    func makeUIView(context: Context) -> WallpaperBlurSliceView {
        let v = WallpaperBlurSliceView()
        v.state = state
        return v
    }

    func updateUIView(_ v: WallpaperBlurSliceView, context: Context) {
        v.state = state
        v.reposition()
    }
}

// MARK: - The anchor view

/// Inert and invisible; its only job is to BE somewhere — laid exactly over a chat's wallpaper so
/// the slices have a coordinate space that travels with the screen. Registered on every window
/// attach (a nav pop re-adds the chat's view), and each attach repositions every live slice, so the
/// first frame after a return is already right.
private final class WallpaperAnchorView: UIView {
    var cid: String = "" {
        didSet { if window != nil { WallpaperBlur.registerAnchor(self, for: cid) } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !cid.isEmpty else { return }
        WallpaperBlur.registerAnchor(self, for: cid)
        WallpaperBlurSliceView.repositionAll()
    }
}

/// Rides as an overlay on the chat's `ChatWallpaperBackground` — and ONLY the chat's. The previews
/// draw the same wallpaper view elsewhere at other sizes; anchoring one of those would point every
/// slice in the real chat at it.
struct WallpaperAnchor: UIViewRepresentable {
    let cid: String

    func makeUIView(context: Context) -> UIView {
        let v = WallpaperAnchorView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.cid = cid
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        (v as? WallpaperAnchorView)?.cid = cid
    }
}

/// See `blurred`: built once, reused for every chat's wallpaper blur. Thread-safe per Core Image.
private let wallpaperBlurContext = CIContext(options: nil)

/// ⛔ THE RENDER RUNS ON ITS OWN THREAD WITH A BIG STACK — owner, 2026-10-29, build 1058: "if i open
/// that channel it keeps crashing". The crash log was EXC_BAD_ACCESS, "Thread stack size exceeded",
/// inside `createCGImage` → Core Image's recursive tile render → Metal texture setup, called from
/// `state(for:)` in the middle of ThreadView's body during the navigation push. The main thread's
/// stack is small and was already deep in SwiftUI's graph update; the render's own frames pushed it
/// over. Only chats WITH a wallpaper reach this, and every open after a relaunch is a cache miss, so
/// that chat crashed every time.
///
/// ⚠️ STILL ITS OWN 8 MB THREAD, AND NOBODY WAITS FOR IT ANY MORE (perf audit 2026-11-11, E8). The
/// caller used to block on a semaphore for the whole render, inside the push. Now the work is
/// handed over and the result comes back to the main thread by itself (`WallpaperBlur.prepareBlur`).
/// Not a GCD queue: their worker threads have a 512 KB stack, the very thing the crash above was.
enum WallpaperBlurRender {
    static func run(_ work: @escaping @Sendable () -> Void) {
        let worker = Thread { work() }
        worker.stackSize = 8 << 20
        worker.qualityOfService = .userInitiated
        worker.start()
    }
}

/// ⛔ WARMED AT LAUNCH, OFF THE MAIN THREAD — owner, 2026-09-27, the first chat opened after launch
/// still late. A global is created on first use, so the context above, its Metal setup and the
/// compiled blur kernels were all paid on the main thread inside the first chat's push. One tiny blur
/// here pays them in the background while the chat list is on screen.
///
/// Since 2026-11-11 it also reads the most recently used wallpaper pictures back from disk, decoded,
/// so the first wallpaper chat after a relaunch finds its blur in memory and opens with it at once,
/// and it trims the folder (old builds' folders go, and only the newest files are kept).
enum WallpaperBlurWarmup {
    nonisolated static func run() {
        WallpaperBlurRender.run {
            let box = CGRect(x: 0, y: 0, width: 8, height: 8)
            let img = CIImage(color: .black).cropped(to: box).clampedToExtent()
                .applyingGaussianBlur(sigma: 20).cropped(to: box)
            _ = wallpaperBlurContext.createCGImage(img, from: box)
            preload()
        }
    }

    private static func preload() {
        let fm = FileManager.default
        let folder = WallpaperPictureWork.folder
        let parent = folder.deletingLastPathComponent()
        if let siblings = try? fm.contentsOfDirectory(atPath: parent.path) {
            for name in siblings where name.hasPrefix("wallpaper-pictures-") && name != folder.lastPathComponent {
                try? fm.removeItem(at: parent.appendingPathComponent(name))
            }
        }
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { u -> (URL, Date) in
            (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (u, _) in dated.dropFirst(40) { try? fm.removeItem(at: u) }
        var blurs = 0, headers = 0
        for (u, _) in dated.prefix(40) {
            guard let key = u.deletingPathExtension().lastPathComponent.removingPercentEncoding else { continue }
            let isBlur = key.hasPrefix("b|"), isHeader = key.hasPrefix("h|")
            guard (isBlur && blurs < 4) || (isHeader && headers < 2) else { continue }
            guard let image = WallpaperPictureWork.load(key) else { continue }
            if isBlur { blurs += 1 } else { headers += 1 }
            Task { @MainActor in WallpaperBlur.insertPreloaded(image, key: key) }
            if blurs >= 4, headers >= 2 { break }
        }
    }
}
