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

    /// For code that is not a View. Views should use @AppStorage so they redraw on a change.
    static var current: ProfileLayoutStyle {
        ProfileLayoutStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .modern
    }
}

// MARK: - What the poster needs to know about a photo

/// A profile photo reduced to the two things the poster header needs, sampled once and kept.
///
/// `wash` is the page background under the name and the buttons: a 32×48 downscale of the photo
/// which the display stretches back up into a soft haze. It is a DOWNSCALE and not a Gaussian blur
/// on purpose — a real blur of a full-size photo costs milliseconds on every frame the header moves,
/// and once stretched across a whole header the two are indistinguishable. Being the SAME photo is
/// the point: the sharp image can dissolve into it with no colour shift at all, which is what makes
/// the join invisible rather than merely soft.
///
/// The luma readings are how bright the photo is where text sits, so the name can be dark on a pale
/// picture and light on a dark one. Guessing white loses badly on a bright photo, and the fix for
/// that must not be a black box behind the text.
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
        if let u = photoUrl, !u.isEmpty {
            let warm = DiskImageCache.shared.memoryImage(for: u)
            _image = State(initialValue: warm)
            _tone = State(initialValue: PosterTone.cached(for: u)
                          ?? warm.flatMap { PosterTone.sample($0, for: u) })
        }
    }

    /// The name rides up over the photo's bottom edge, as in the reference.
    private let nameLift: CGFloat = 44

    /// The photo is as wide as the SCREEN: the content width this header was given, plus the page
    /// inset it bleeds back out over on each side.
    private var photoSide: CGFloat { width + edgeBleed * 2 }

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
                .padding(.top, 18)
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

    /// The artwork, drawn from the top of the SCREEN rather than the top of the content, so the
    /// photo runs under the status bar and the nav bar the way the reference does.
    ///
    /// The GeometryReader is how the wash learns where this header ENDS. Nothing is drawn outside
    /// that box: a fixed tail would either overflow — which a List row clips, turning the fade into
    /// the exact hard line this design exists to remove — or fall short and leave a band of colour
    /// with an edge on it. Reading the height means the fade always lands on the header's own bottom
    /// edge, and a long bio simply gives it further to travel.
    private var layers: some View {
        GeometryReader { g in
            let total = contentTop + g.size.height   // screen top → this header's bottom
            ZStack(alignment: .top) {
                washLayer(total: total)
                sharpLayer
            }
            .frame(width: photoSide, height: total, alignment: .top)
            .offset(y: -contentTop)
        }
        // Out over the page's inset to both screen edges. Safe here and nowhere else: this is
        // inside a background, so it cannot change the size of the header or of the page.
        .padding(.horizontal, -edgeBleed)
        .allowsHitTesting(false)   // the spacer owns the tap; the artwork must never swallow one
    }

    /// Same photo, tiny and stretched, tinted toward the page. Dark mode deepens it, light mode
    /// lightens it, and both readings come from the photo itself rather than from a palette.
    private func washLayer(total: CGFloat) -> some View {
        Group {
            if let tone {
                Image(uiImage: tone.wash).resizable().interpolation(.high)
            } else {
                LinearGradient(colors: AvatarPalette.gradient(for: name),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: photoSide, height: total)
        .overlay(scheme == .dark ? Color.black.opacity(0.30) : Color.white.opacity(0.34))
        // Solid everywhere the photo is, then gone by the bottom of the header.
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: min(1, photoSide / max(total, 1))),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        // SCALE, never a frame change: resizing re-measures every frame of a pull, scaling is one
        // GPU transform. Anchored at the bottom so the top grows up by exactly the rubber-band
        // distance and fills the gap the scroll just opened above it.
        .scaleEffect(1 + stretch / max(total, 1), anchor: .bottom)
    }

    private var sharpLayer: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: AvatarPalette.gradient(for: name),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: photoSide, height: photoSide)
        .clipped()
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.62),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .scaleEffect(1 + stretch / max(photoSide, 1), anchor: .bottom)
        .opacity(photoHidden ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: image != nil)
    }

    private func load() async {
        guard let s = photoUrl, !s.isEmpty, let url = URL(string: s) else { image = nil; tone = nil; return }
        if let cached = await DiskImageCache.shared.image(for: s) {
            image = cached
            tone = PosterTone.sample(cached, for: s)
            return
        }
        if let (data, _) = try? await MediaSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            image = ui
            tone = PosterTone.sample(ui, for: s)
        }
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
                    AvatarView(name: group.name, photoUrl: s.previewUrl, size: 30)
                        .overlay { Circle().strokeBorder(ring(for: s), lineWidth: 2) }
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
