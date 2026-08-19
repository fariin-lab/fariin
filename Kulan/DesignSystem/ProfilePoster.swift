import SwiftUI
import UIKit

// MARK: - Which header a profile draws

/// Profile header style, chosen in Settings ▸ Privacy & Security ▸ Profile Layout.
///
/// Modern is the default AND the fallback for any unrecognised stored value, which is what makes
/// "the default must always be Modern Header" true for accounts that upgrade into this build with
/// nothing written under this key yet.
enum ProfileLayoutStyle: String, CaseIterable, Identifiable {
    case modern, classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modern:  return "Modern Header"
        case .classic: return "Classic Circle Profile"
        }
    }

    var blurb: String {
        switch self {
        case .modern:  return "The profile photo fills the top of the page."
        case .classic: return "A round profile picture above the name."
        }
    }

    static let storageKey = "profileLayout"

    /// THE ONLY WAY TO ASK WHICH HEADER TO DRAW. Never read the stored string directly.
    ///
    /// While `Flags.profileLayoutChoice` is off, this answers `.modern` whatever is stored. That is
    /// not belt-and-braces: anyone who picked Classic in build 437 or 439 has "classic" written on
    /// their device, and hiding the row without this would strand them on the old header with the
    /// switch back no longer on screen.
    static func resolved(_ raw: String) -> ProfileLayoutStyle {
        guard Flags.profileLayoutChoice else { return .modern }
        return ProfileLayoutStyle(rawValue: raw) ?? .modern
    }

    /// For code that is not a View. Views should use @AppStorage so they redraw on a change.
    static var current: ProfileLayoutStyle {
        resolved(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

/// The poster's shape, in ONE place, because the header draws it and the cropper has to promise it.
/// If these two ever disagree, what you framed is not what you get.
enum PosterGeometry {
    /// Height as a multiple of width. 4:5 — TALLER THAN THE SCREEN IS WIDE (owner, 2026-08-02:
    /// "update Image Size higher make it how long you need").
    ///
    /// The height is not decoration. The photo now has to reach past the name and behind the round
    /// actions, because there is no second copy of it underneath any more: the picture itself is the
    /// background all the way down. A square stopped at the name and left the rest to a duplicate.
    static let aspect: CGFloat = 1.25

    /// The name rides up over the photo, at this distance above the photo's own square point.
    static let nameLift: CGFloat = 44

    /// Fraction of the photo's HEIGHT where the blur begins — the top of the name, which is where
    /// the owner drew the line. Everything above it stays sharp.
    static func blurStart(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0.7 }
        return max(0, min(1, (width - nameLift) / (width * aspect)))
    }
}

extension View {
    /// Progressive blur down the bottom of this view — the concept from Variablur
    /// (github.com/daprice/Variablur), run through our own single-purpose shader.
    ///
    /// TWO PASSES, horizontal then vertical, because a Gaussian is separable: a true 2D blur costs
    /// samples squared while two 1D passes cost samples doubled and land on the same picture. That is
    /// what makes it affordable on a header that moves while you scroll.
    ///
    /// - Parameter startFraction: where the blur begins, as a fraction of the view's height.
    /// - Parameter radius: the radius reached at the very bottom.
    func posterFadeBlur(startFraction: CGFloat, radius: CGFloat, maxSamples: Int = 10) -> some View {
        visualEffect { content, geo in
            let startY = Float(geo.size.height * startFraction)
            let r = Float(radius)
            let s = Float(maxSamples)
            let offset = CGSize(width: radius, height: radius)
            return content
                .layerEffect(
                    ShaderLibrary.default.posterFadeBlur(
                        .boundingRect, .float(startY), .float(r), .float(s), .float(0)),
                    maxSampleOffset: offset)
                .layerEffect(
                    ShaderLibrary.default.posterFadeBlur(
                        .boundingRect, .float(startY), .float(r), .float(s), .float(1)),
                    maxSampleOffset: offset)
        }
    }
}

/// The old `PosterPhoto` lived here: a guess about whether a url had a picture behind it, made from
/// whether the bitmap happened to be cached and then corrected by whether the download succeeded. It
/// is gone. Both halves could answer after the page had drawn, so both could rearrange the layout
/// under the reader, and its record of failures was written to disk — where "you were offline once"
/// became "this person has no photo", permanently. The header now asks [ProfilePhotoIndex], which
/// answers from the users document, synchronously, and never changes its mind mid-visit.

// MARK: - What the poster needs to know about a photo

/// A profile photo, sampled once and kept, for the two readings the header needs.
///
/// The luma readings are how bright the photo is where text sits, so the name can be dark on a pale
/// picture and light on a dark one. Guessing white loses badly on a bright photo, and the fix for
/// that must not be a black box behind the text.
///
/// `wash` — a 32×48 downscale — WAS the page background under the name, back when the header was two
/// images: the sharp photo on top of a stretched copy of itself. That is gone; the photo is taller
/// now and is its own background all the way down (owner: "dont use dubblecate image"). The tiny
/// bitmap is kept only because the luma readings are taken from it, and it costs one draw per photo.
final class PosterTone {
    let wash: UIImage
    let nameBandLuma: Double   // brightness of the strip the name sits on, 0 = black, 1 = white
    let topBandLuma: Double    // brightness up where the toolbar sits

    /// The threshold sits above the midpoint deliberately: white text carries a soft shadow and
    /// survives a mid-grey photo, where dark text on the same photo does not.
    var namePrefersDarkText: Bool { nameBandLuma > 0.66 }
    var topPrefersDarkText: Bool { topBandLuma > 0.66 }

    private init(wash: UIImage, nameBandLuma: Double, topBandLuma: Double) {
        self.wash = wash
        self.nameBandLuma = nameBandLuma
        self.topBandLuma = topBandLuma
    }

    private static let cache = NSCache<NSString, PosterTone>()

    /// Already sampled? Any view can ask — the toolbar's story badge needs the reading without
    /// owning the photo. nil until a header has loaded that photo once.
    static func cached(for url: String?) -> PosterTone? {
        guard let url, !url.isEmpty else { return nil }
        return cache.object(forKey: url as NSString)
    }

    static func sample(_ image: UIImage, for url: String) -> PosterTone? {
        if let hit = cache.object(forKey: url as NSString) { return hit }
        guard let tone = build(image) else { return nil }
        cache.setObject(tone, forKey: url as NSString)
        return tone
    }

    private static func build(_ image: UIImage) -> PosterTone? {
        let w = 32, h = 48
        guard let cg = image.cgImage else { return nil }

        // The same centre aspect-fill crop the header draws, so the wash sits under the photo
        // instead of sliding against it.
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let want = CGFloat(w) / CGFloat(h)
        let src = (sw / sh > want)
            ? CGRect(x: (sw - sh * want) / 2, y: 0, width: sh * want, height: sh)
            : CGRect(x: 0, y: (sh - sw / want) / 2, width: sw, height: sw / want)
        guard let crop = cg.cropping(to: src.integral) else { return nil }

        // Our own buffer, not `&array`: a pointer taken with & is only valid for the call it is
        // passed to, and CGContext keeps it for its whole life.
        let count = w * h * 4
        let px = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        px.initialize(repeating: 0, count: count)
        defer { px.deallocate() }

        guard let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }

        // Row 0 of a bitmap context's buffer is the TOP row of the image it makes.
        func luma(_ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(Double(h) * from)), b = min(h, Int(Double(h) * to))
            guard b > a else { return 0.5 }
            var sum = 0.0
            for y in a..<b {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
                }
            }
            return sum / (Double((b - a) * w) * 255)
        }

        // The name rides just above the square photo's bottom edge, which is two thirds of the way
        // down this crop; the toolbar sits in the top tenth.
        return PosterTone(wash: UIImage(cgImage: out),
                          nameBandLuma: luma(0.56, 0.72),
                          topBandLuma: luma(0.02, 0.16))
    }
}

// MARK: - The header itself

/// The immersive profile header: the photo edge to edge across the top of the page, dissolving into
/// a soft wash of its own colours, with the name and the round actions sitting on that wash.
///
/// THE JOIN IS THE WHOLE POINT. Three layers, each one gone before the next has to take over:
///   1. the page colour, which the caller already draws behind everything;
///   2. the wash — the same photo, tiny and stretched, solid behind the photo and fading out over
///      the tail below it;
///   3. the sharp photo, solid down to 62% of its height and clear by its own bottom edge.
/// At every height the pixels above and below are the same colours, because layers 2 and 3 are the
/// same picture. A hard-edged image sitting on a flat page is what draws a line across the screen;
/// this cannot, because nothing in it has an edge to draw.
///
/// The caller supplies the text block and the action row, so one header serves a person's profile
/// and a group's without either one bending the other out of shape.
struct ProfilePosterHeader<Caption: View, Actions: View>: View {
    let name: String
    let photoUrl: String?
    /// Coordinate space of the enclosing ScrollView — the pull-to-stretch reads its own offset in it.
    let scrollSpace: String
    /// The photo's rect in GLOBAL coordinates, so a full-screen viewer can fly out of exactly it.
    var onPhotoRect: (CGRect) -> Void = { _ in }
    /// Raw scroll offset of the header, for whatever the page fades against it (the nav bar title).
    var onScroll: (CGFloat) -> Void = { _ in }
    var onTap: () -> Void = {}
    /// Drop the sharp photo while a viewer is flying out of it, so there is one picture on screen
    /// and not the same one twice.
    var photoHidden: Bool = false
    /// Run the photo up under the status bar and the nav bar. TRUE inside a ScrollView, where a view
    /// may draw outside its own box. FALSE inside a List, where rows clip — there the photo would be
    /// sliced off at the row's top edge, so it starts below the bars instead.
    var bleedUnderBars: Bool = true
    /// How much page inset to undo so the photo reaches both screen edges. A ScrollView page insets
    /// its content by 16; a List row with `listRowInsets(EdgeInsets())` already has none.
    var edgeBleed: CGFloat = 16
    /// Air between the caption and the action row. ZERO when there is no action row — Settings uses
    /// this header without call, video or mute buttons, and the gap would otherwise sit there as
    /// unexplained empty space under the name.
    var actionsTopSpacing: CGFloat = 18
    /// The colour the photo ARRIVES AT. Every page this header sits on is the grouped background.
    var fadeInto: Color = Color(uiColor: .systemGroupedBackground)
    /// An image to draw INSTEAD of fetching one. For previewing a photo that has been cropped but
    /// not yet saved — there is no url to load, and the whole point of the preview is to show it
    /// before it exists anywhere.
    var localImage: UIImage? = nil
    @ViewBuilder var caption: (Color) -> Caption
    @ViewBuilder var actions: () -> Actions

    @State private var image: UIImage?
    @State private var tone: PosterTone?
    @State private var width: CGFloat
    @State private var contentTop: CGFloat
    @State private var topLocked = false
    @State private var stretch: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    init(name: String, photoUrl: String?, scrollSpace: String,
         onPhotoRect: @escaping (CGRect) -> Void = { _ in },
         onScroll: @escaping (CGFloat) -> Void = { _ in },
         onTap: @escaping () -> Void = {},
         photoHidden: Bool = false,
         bleedUnderBars: Bool = true,
         edgeBleed: CGFloat = 16,
         actionsTopSpacing: CGFloat = 18,
         fadeInto: Color = Color(uiColor: .systemGroupedBackground),
         localImage: UIImage? = nil,
         @ViewBuilder caption: @escaping (Color) -> Caption,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.name = name
        self.photoUrl = photoUrl
        self.scrollSpace = scrollSpace
        self.onPhotoRect = onPhotoRect
        self.onScroll = onScroll
        self.onTap = onTap
        self.photoHidden = photoHidden
        self.bleedUnderBars = bleedUnderBars
        self.edgeBleed = edgeBleed
        self.actionsTopSpacing = actionsTopSpacing
        self.fadeInto = fadeInto
        self.localImage = localImage
        self.caption = caption
        self.actions = actions

        // FIRST-FRAME SEEDS from the window, corrected by measurement a frame later. Starting both
        // at zero would draw one frame of nothing at the top of a pushed screen, which is the kind
        // of flash this page has been burned by before.
        let win = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .max(by: { $0.bounds.width < $1.bounds.width })
        // `width` is the CONTENT width this header is handed, which is the screen less the page's
        // inset on both sides — `photoSide` adds the bleed back to reach the screen edges.
        _width = State(initialValue: (win?.bounds.width ?? 393) - edgeBleed * 2)
        _contentTop = State(initialValue: bleedUnderBars ? (win?.safeAreaInsets.top ?? 59) + 44 : 0)

        // The avatar for this person is almost always already decoded (chat list, chat header), so
        // the poster opens holding the real photo rather than a colour that swaps a frame later.
        // Memory AND disk, like AvatarView: memory alone is empty on a cold launch, which left the
        // header showing its fallback colour for a frame before the photo arrived.
        if let localImage {
            // Handed the picture directly — a preview of something not saved yet. Nothing to fetch.
            _image = State(initialValue: localImage)
        } else if let u = photoUrl, !u.isEmpty {
            let warm = DiskImageCache.shared.smallImageSync(u)
            _image = State(initialValue: warm)
            _tone = State(initialValue: PosterTone.cached(for: u)
                          ?? warm.flatMap { PosterTone.sample($0, for: u) })
        }
    }

    /// The name rides up over the photo's bottom edge, as in the reference.
    /// From `PosterGeometry`, so the number that places the name is the same number the blur starts
    /// on and the same number the cropper promises.
    private var nameLift: CGFloat { PosterGeometry.nameLift }

    /// The photo is as wide as the SCREEN: the content width this header was given, plus the page
    /// inset it bleeds back out over on each side.
    private var photoSide: CGFloat { width + edgeBleed * 2 }

    /// And TALLER than it is wide, so one picture can be the background for the whole header —
    /// behind the name and behind the buttons — instead of handing over to a copy of itself.
    private var photoHeight: CGFloat { photoSide * PosterGeometry.aspect }

    /// Their initial, for the no-bitmap state. Same rule as `AvatarView`, so the letter you see in a
    /// list and the letter you see here are always the same one.
    private var initial: String {
        let c = name.trimmingCharacters(in: .whitespaces).first
        return c.map { String($0).uppercased() } ?? "?"
    }

    /// White on a dark photo, near-black on a bright one. Not a fixed colour, and not a box.
    private var onPhotoText: Color {
        (tone?.namePrefersDarkText ?? false) ? Color.black.opacity(0.88) : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            photoSpacer
            caption(onPhotoText)
                .padding(.top, -nameLift)
                .padding(.horizontal, 8)
                // A shadow, never a plate: it lifts the text off a busy photo without putting a
                // shape behind it, and it costs nothing on a photo that is already dark.
                .shadow(color: .black.opacity(tone?.namePrefersDarkText == true ? 0 : 0.35), radius: 8, y: 1)
            actions()
                .padding(.top, actionsTopSpacing)
        }
        .padding(.bottom, 6)
        // THE BLEED LIVES ON THE ARTWORK, NEVER ON THIS FRAME. Widening the header itself widens
        // the page's VStack — a stack grows to fit its widest child — and the page's own 16pt inset
        // then pushes everything sideways: a strip of empty page down one edge and the photo running
        // off the other. A background does not change the size of what it sits behind, which is the
        // only reason this can reach both screen edges without moving anything.
        .background(alignment: .top) { layers }
        .task(id: photoUrl) { await load() }
    }

    /// Reserves the square the photo occupies, less the strip that lives behind the bars. Invisible
    /// on purpose: the artwork is drawn in `layers`, so the page's flow layout and the picture can
    /// never fight each other.
    ///
    /// The height is the measured WIDTH, which is what makes it a square on every iPhone with no
    /// hardcoded number. Stated outright rather than left to `aspectRatio`, because scrolling
    /// content is proposed an unspecified height and a ratio has nothing to divide in that case.
    private var photoSpacer: some View {
        Color.clear
            .frame(height: photoSide)          // square: as tall as the page is wide
            .padding(.top, -contentTop)        // …less the strip that lives behind the bars
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                guard r.width > 0 else { return }
                width = r.width
                // At rest this is exactly the distance from the top of the SCREEN to the top of the
                // scroll content, which is the amount the photo has to be pulled up by. Captured
                // once: re-reading it while scrolling would drag the photo along with the finger
                // instead of letting it scroll away.
                if bleedUnderBars, !topLocked, r.minY > 0 { contentTop = r.minY; topLocked = true }
                // The photo's full square in global coords — wider than this box by the bleed on
                // each side, and its bottom edge is this box's bottom.
                onPhotoRect(CGRect(x: r.minX - edgeBleed, y: r.maxY - photoSide,
                                   width: photoSide, height: photoSide))
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(scrollSpace)).minY } action: { v in
                stretch = max(0, v)   // positive only while the scroll rubber-bands
                onScroll(v)
            }
    }

    /// ONE PICTURE. No second copy underneath (owner: "dont use dubblecate image… use orginal").
    ///
    /// There used to be two layers: the sharp photo, and beneath it a tiny stretched copy of the
    /// same photo tinted toward the page colour, to carry the colour down past the name. It worked,
    /// and it was still two images pretending to be one — the copy had none of the detail, so where
    /// the sharp one gave out you were looking at a smear that did not match what was above it.
    ///
    /// Now the photo is simply TALLER than the screen is wide and runs the whole height of the
    /// header, behind the name and behind the buttons, blurring further the lower it goes and giving
    /// out only at the very bottom. The background under the name IS the photograph, not an
    /// impression of it.
    private var layers: some View {
        photoLayer
            // Out over the page's inset to both screen edges. Safe here and nowhere else: this is
            // inside a background, so it cannot change the size of the header or of the page.
            .padding(.horizontal, -edgeBleed)
            .allowsHitTesting(false)   // the spacer owns the tap; the artwork must never swallow one
    }

    private var photoLayer: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // A LARGE AVATAR, NOT A SLAB. This state is reached whenever the bitmap is not here
                // YET (a photo just set on another device, a cold launch, no signal) — and it used to
                // be flat colour, which looked broken enough that the page would rather rearrange its
                // whole layout than show it. That rearranging was the bug. Their letter on their own
                // two colours — the same pair `AvatarView` fills their circle with, so it is the same
                // person either way — is a legitimate thing to look at, so the header can simply hold
                // its shape until the picture arrives.
                LinearGradient(colors: AvatarPalette.gradient(for: name),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Text(initial)
                            .font(.system(size: photoSide * 0.34, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            // The letter sits where a face would, not in the middle of a frame whose
                            // lower third is behind the name.
                            .offset(y: -photoHeight * 0.12)
                    }
            }
        }
        .frame(width: photoSide, height: photoHeight)
        .clipped()
        // THE PHOTO NEVER STOPS, IT ONLY LOSES ITS DETAIL. Fading a picture to a colour still ends
        // in a colour and the eye finds the line where it quit — reported twice. Blurring means the
        // bottom of the photo IS the background: same colours, same place, without the detail. It
        // begins at the top of the name, where the owner drew the line.
        .posterFadeBlur(startFraction: PosterGeometry.blurStart(width: photoSide), radius: 40)
        // IT ARRIVES AT THE PAGE COLOUR. It used to fade to TRANSPARENT and let the page show
        // through, and a linear alpha ramp has a visible end — the eye finds the point where the
        // change stops, which is the line he could still feel. Painting the page's own colour over
        // the photo instead means the bottom row of pixels IS the page: there is no boundary left to
        // find, because the two are the same colour before they meet.
        //
        // THE CURVE IS SMOOTHERSTEP NOW, SAMPLED, NOT HAND-PLACED STOPS. The old five stops ended
        // with a straight 0.82→1.0 segment whose slope was still nonzero AT the photo's bottom edge
        // — a ramp that stops dead is exactly what the eye catches, and on a dark photo against the
        // light page that was the hard cut he circled. Smootherstep's derivative is ZERO at both
        // ends: the veil starts imperceptibly, does its work in the middle, and has already gone
        // flat before the photo runs out (full page colour at 97% of the run, so the last stretch
        // is pure page and the photo's boundary crosses nothing). Twelve samples keep SwiftUI's
        // between-stop linear interpolation below anything a screen can show.
        //
        // No scrim and no darkening anywhere in this: the veil is the page's own colour, so a dark
        // photo is gently LIFTED toward the page and a pale one barely changes — both ends of his
        // "must work with light and dark photos" for free, in both colour schemes.
        .overlay(
            LinearGradient(stops: {
                let s = PosterGeometry.blurStart(width: photoSide)
                let end = s + max(0.0001, 1 - s) * 0.97
                var stops: [Gradient.Stop] = []
                for i in 0...12 {
                    let t = Double(i) / 12.0
                    let eased = t * t * t * (t * (t * 6 - 15) + 10)   // smootherstep: 6t⁵−15t⁴+10t³
                    stops.append(.init(color: fadeInto.opacity(eased),
                                       location: s + (end - s) * CGFloat(t)))
                }
                stops.append(.init(color: fadeInto, location: 1))
                return stops
            }(), startPoint: .top, endPoint: .bottom)
        )
        // Insurance only: by here the pixels are already the page colour, so this can never show as
        // an edge — it just guarantees the very last row cannot differ if the page is ever repainted.
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.96),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        // SCALE, never a frame change: resizing re-measures every frame of a pull, scaling is one
        // GPU transform. Anchored at the bottom so the top grows up by exactly the rubber-band
        // distance and fills the gap the scroll just opened above it.
        .scaleEffect(1 + stretch / max(photoHeight, 1), anchor: .bottom)
        // Up behind the status bar and the nav bar, from the top of the SCREEN.
        .offset(y: -contentTop)
        .opacity(photoHidden ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: image != nil)
    }

    /// FETCH THE PICTURE. It reports nothing back, on purpose.
    ///
    /// There used to be an `onPhotoResolved` here, and the profile page hung its LAYOUT on it: no
    /// picture behind the url meant fall back to the circle. That is the flicker, and it is not
    /// fixable from inside this function, because "the download failed" and "there is no photo" are
    /// not the same fact — the first is usually a train tunnel. Whether somebody has a photo is a
    /// question about their users document, and [ProfilePhotoIndex] answers it before this view is
    /// ever built. All that is left here is loading an image, and holding the person's letter until
    /// it arrives.
    private func load() async {
        if localImage != nil { return }      // handed the picture directly — nothing to fetch
        if let warm = image {                // already seeded from the cache in init
            noteAdaptive(warm)
            return
        }
        guard let s = photoUrl, !s.isEmpty, let url = URL(string: s) else { image = nil; tone = nil; return }
        if let cached = await DiskImageCache.shared.image(for: s) {
            image = cached
            tone = PosterTone.sample(cached, for: s)
            noteAdaptive(cached)
            ProfilePhotoIndex.noteLoad(s, ok: true)
            return
        }
        if let (data, _) = try? await MediaSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            image = ui
            tone = PosterTone.sample(ui, for: s)
            noteAdaptive(ui)
            ProfilePhotoIndex.noteLoad(s, ok: true)
            return
        }
        // A FACT ABOUT A URL, not a signal about this layout — the distinction that matters here.
        // Nothing reads this to decide what THIS view does; it is filed for the next profile that
        // has to answer "circle or big photo" before it draws. The old `onPhotoResolved` fed the
        // live layout from this same moment, which is why the header rearranged itself seconds
        // after you opened it.
        ProfilePhotoIndex.noteLoad(s, ok: false)
    }

    /// Hand the page its colours, off the bitmap this header is already holding.
    ///
    /// It lives here because this is the one place in the app that reliably has a profile photo
    /// decoded; the page that wears the colours does not own the download. `extract` returns
    /// immediately — the reading happens on its own queue, is cached per url, and refuses to start
    /// a second read of a photo it is already reading. So this costs a dictionary lookup on every
    /// path except the first sight of a new photo.
    private func noteAdaptive(_ ui: UIImage) {
        guard let s = photoUrl, !s.isEmpty else { return }
        ProfilePalette.extract(ui, for: s)
    }
}

// MARK: - The round actions

/// One of the circular actions under the name. Liquid Glass lives HERE and nowhere else on the page
/// (owner's rule), so the buttons read as controls floating on the photo while every card below them
/// stays an ordinary opaque card.
///
/// Each button claims an equal share of the row rather than sitting on a hand-tuned gap, so five
/// stay symmetric and a profile that honestly shows four (no in-chat search when you arrived from a
/// story) or three (your own, which cannot call itself) is still balanced instead of bunched.
struct PosterActionIcon: View {
    let icon: String        // an "ic_*" asset from our own set, or an SF Symbol name
    /// 60pt, the owner's number off a device photo. The glyph is a fraction of it rather than a
    /// second number to remember, so the circle and what is inside it can never fall out of step.
    var diameter: CGFloat = 60

    var body: some View {
        Group {
            if icon.hasPrefix("ic_") {
                Image(icon).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
            } else {
                Image(systemName: icon).font(.system(size: diameter * 0.36, weight: .medium))
            }
        }
        .foregroundStyle(.primary)
        .frame(width: diameter, height: diameter)
        // LIQUID GLASS, AND ONLY HERE. These circles sit on the photograph, where glass has
        // something to refract and where the owner's standing rule puts it; the cards further down
        // the page sit on a flat colour and are flat themselves. One page, two surfaces, and the
        // line between them is "is it on the picture".
        .liquidGlass(Circle(), interactive: true)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stories, on the poster

/// The story indicator for the poster header, in place of the ring the round avatar used to carry.
///
/// Up to three thumbnails overlapping to the right with the first one on top, then the REAL count in
/// words beside them — so seven stories show three circles and "7 Stories" rather than seven circles
/// or a lie about how many there are. It lives in the middle of the toolbar, between Back and Edit,
/// because that is the one strip of the photo nothing else occupies.
struct StoryStackBadge: View {
    let group: StoryGroup
    var textColor: Color = .white
    /// `MediaOpenRects` key for the story flight, or empty for none.
    ///
    /// ⚠️ IT GOES ON THE FIRST CIRCLE, NOT ON THE BADGE. The badge is a row of overlapping circles
    /// PLUS a "3 Stories" label, so its own rectangle is wide and short — registering that would tell
    /// the flight to land the story in a 130x30 stadium and call it a circle, because the radius test
    /// only sees half the SHORT side. The leftmost circle is both a true circle and the story that
    /// actually opens first, which makes it the honest anchor twice over.
    var rectKey: String = ""

    /// The diameter of one circle in the stack. Public because the flight's landing shape is derived
    /// from it and a second copy of this number is how a shape drifts.
    static let circleSize: CGFloat = 30

    /// The first three in play order: tapping opens the story, and the leftmost circle on top is the
    /// one that opens first.
    private var shown: [Story] { Array(group.stories.prefix(3)) }

    private var countLabel: String {
        let n = group.stories.count
        return n == 1 ? "1 Story" : "\(n) Stories"
    }

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: -11) {   // overlap; each circle covers the left edge of the next
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                    AvatarView(name: group.name, photoUrl: s.previewUrl, size: Self.circleSize)
                        .overlay { Circle().strokeBorder(ring(for: s), lineWidth: 2) }
                        .modifier(MediaRectReporter(id: i == 0 ? rectKey : "", scope: .storyRow,
                                                    cornerRadius: Self.circleSize / 2))
                        .zIndex(Double(shown.count - i))
                }
            }
            Text(countLabel).font(.subheadline.weight(.semibold)).foregroundStyle(textColor)
        }
        .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
    }

    /// The app's own story rule, per story rather than per person: watched goes quiet, unwatched
    /// keeps the colour. Grey would vanish against a photo, so watched is a soft white instead.
    private func ring(for s: Story) -> AnyShapeStyle {
        let seen = StoryPrefs.isStorySeen(s.id) || s.createdAt <= (group.lastViewedAt ?? .distantPast)
        return seen
            ? AnyShapeStyle(Color.white.opacity(0.6))
            : AnyShapeStyle(LinearGradient(colors: [.pink, .orange, .yellow],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
