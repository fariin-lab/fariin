import SwiftUI
import MapKit

// The story editor's STICKER TRAY — his 2026-08-16 request, redesigned the same day against the
// reference tray he photographed: a search field across the top, a wrapping cloud of actions under
// it, the stickers below that, and a row of categories along the bottom with Recent first.
//
// IT IS A TRAY, NOT A SCREEN. Everything it does hands one finished thing back to the editor and
// closes; it owns no editing state and never touches the canvas. That is what keeps the promise he
// attached to the request — "do not redesign or change the existing Story Editor UI" — enforceable
// rather than merely intended: the editor gained one button and four callbacks.
//
// ⚠️ LINK AND LOCATION ARE PUSHED INSIDE THIS SHEET, NOT RAISED AS A SECOND ONE. Asking for a sheet
// while the one underneath it is still going down is the oldest way to get a screen that silently
// never appears — this app has paid for it before (see `AddStorySheet`'s note on the picker). A push
// cannot race a dismissal because nothing is dismissed.
//
// ⚠️ EVERY SURFACE IN HERE IS APPLE'S GLASS, NOT A GREY WE PAINTED (his 2026-08-16 note on the
// shipped tray: "make it real liquid glass for apple design, bottom tabs real liquid capsule tabs").
// The first build of this tray drew a `tertiarySystemFill` search well, solid white pills, and a
// `.ultraThinMaterial` strip with `Circle().fill(.white.opacity(0.18))` behind the chosen category.
// Every one of those is an OPAQUE WASH, which is the single thing Apple's material never is, and it
// is the same mistake the camera's mode switch was reported for five times — the note above
// `modePicker` in `StoryCameraView` is the long version and it is worth reading before touching
// anything below.
//
// What that note settled, applied here:
//   · the selected thing is a piece of glass, never a capsule drawn on glass;
//   · one material per place — a glass track carrying a second glass pill is what resolves to flat
//     grey and reads as moulded plastic, so the bottom row carries no track at all;
//   · `GlassEffectContainer` + a shared `glassEffectID` is what makes the selection MELT from one
//     category to the next instead of fading in place. That melt is the "liquid" in liquid glass.
//
// The app is iOS 26 only (`project.yml`), so none of this is fenced behind `#available` — the
// legacy branches everywhere else in the app are dead weight this file does not inherit.

/// The stickers this phone has reached for lately, newest first.
///
/// Deliberately the same shape as `GifRecents` next door (a list of urls in `UserDefaults`, capped),
/// because it is the same idea and a second design for it would be a second thing to keep right. The
/// artwork is not stored — `GifBytesCache` already holds the bytes of anything drawn once, so a
/// recent sticker costs a URL and redraws from disk.
enum StickerRecents {
    private static let key = "story.sticker.recents"
    private static let cap = 24

    static func all() -> [GiphyService.Gif] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let url = d["url"] as? String else { return nil }
            return GiphyService.Gif(id: "recent-\(url)", url: url,
                                    width: d["w"] as? Double ?? 200,
                                    height: d["h"] as? Double ?? 200)
        }
    }

    static func note(_ g: GiphyService.Gif) {
        var raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        raw.removeAll { ($0["url"] as? String) == g.url }
        raw.insert(["url": g.url, "w": g.width, "h": g.height], at: 0)
        if raw.count > cap { raw = Array(raw.prefix(cap)) }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

/// One tab along the bottom of the tray.
///
/// ⚠️ THE FIRST ONE IS NOT A SEARCH TERM. Recent is answered from this phone; every other tab is a
/// query to the sticker endpoint. Keeping that difference in the type rather than in an `if` at the
/// call site is what stops "recent" ever being sent to Giphy as a word.
enum StickerTab: Identifiable, Equatable {
    case recent
    /// ⛔ OURS. The seven drawings that ship inside the app — see `BuiltInStickers`. It is the only
    /// tab that works with no signal, and the only one whose contents nobody can change under us.
    case builtIn
    /// ⚠️ THE FIRST VALUE IS AN SF SYMBOL NAME NOW, NOT AN EMOJI — his 2026-08-17 "use real sticker
    /// icons, don't use emoji".
    ///
    /// Emoji in a tab row are somebody else's artwork rendered at somebody else's weight: they do not
    /// take the tint, they do not match the clock beside them, and they read as content rather than
    /// as controls. A symbol is drawn by the system in the app's own weight and sits beside `clock`
    /// as one set, which is what the row was always trying to be.
    ///
    /// ⚠️ AND THEY ARE NOT PACK THUMBNAILS, WHICH IS WHAT HIS REFERENCE SHOWS. That row draws the
    /// first sticker of each installed PACK, and we have no packs — the tray is a search endpoint,
    /// so a category has no artwork of its own to show. Real pack icons need the sticker system he
    /// has to supply the drawings for; symbols are what is honest until then.
    case term(String, String)   // SF Symbol name, the query behind it

    var id: String {
        switch self {
        case .recent: return "recent"
        case .builtIn: return "builtIn"
        case .term(let icon, _): return icon
        }
    }
    var query: String? {
        switch self {
        case .recent: return nil
        case .builtIn: return nil
        case .term(_, let q): return q
        }
    }

    /// The endpoint's own trending, which is what "popular" means here — an empty query.
    static let popular: StickerTab = .term("flame.fill", "")

    /// Trending leads the searched tabs, because a tray that opens on somebody's own history is
    /// empty on the first day and full of one joke by the third.
    static let all: [StickerTab] = [
        .recent,
        // SECOND, not first: the clock is where somebody looks for what they just used, and our own
        // pack is what is worth finding when that is empty. Ahead of trending because trending is
        // somebody else's and needs the network.
        .builtIn,
        popular,
        .term("face.smiling.fill", "laughing"),
        .term("heart.fill", "love"),
        .term("party.popper.fill", "party"),
        .term("hand.wave.fill", "hello"),
        .term("hands.sparkles.fill", "thank you"),
        .term("moon.zzz.fill", "tired"),
        .term("sparkles", "sparkle"),
        .term("hand.thumbsup.fill", "yes"),
        .term("drop.fill", "crying"),
    ]
}

struct StoryStickerSheet: View {
    /// A sticker was chosen. The editor downloads it, takes a frame and places it — the tray does not
    /// know what a canvas is.
    var onSticker: (GiphyService.Gif) -> Void
    var onLink: (URL) -> Void
    var onPlace: (String, CLLocationCoordinate2D) -> Void
    var onTime: () -> Void

    /// HOW THIS TRAY CLOSES ITSELF, handed in by whoever put it up.
    ///
    /// ⚠️ `@Environment(\.dismiss)` IS NOT ENOUGH ANY MORE AND THIS IS NOT A STYLE CHOICE. The tray
    /// is no longer a system `.sheet` — it is `StoryTraySheet`'s own panel, hosted inside a
    /// container we present — and the dismiss action in that arrangement has no sheet of its own to
    /// take down. Nil keeps the old behaviour exactly, so this view is still correct in a `.sheet`
    /// if it is ever put back in one.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    /// The one namespace the bottom row's glass lives in. It has to be declared on the view that
    /// OWNS both the container and the elements, or the selection has nothing to melt across.
    @Namespace private var glass

    /// Every "I am finished, take me away" in this file goes through here, so there is one answer to
    /// how the tray closes rather than five call sites each guessing.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var route: [Route] = []
    /// ⚠️ ALWAYS POPULAR, NOT "RECENT IF THERE IS ONE" — his 2026-08-17 correction, second time of
    /// asking: "always default tab is popular".
    ///
    /// The first pass at this opened on Recent whenever the phone had any history at all, which is
    /// still a tray that opens on a handful of stickers already used rather than on something to
    /// choose from. Recent is one tap away and it is where you go deliberately. Popular is the
    /// endpoint's own trending, it is never empty, and it is cached for the life of the app — so this
    /// is also the only opening tab that costs no round trip on a second open.
    @State private var tab: StickerTab = .popular
    @State private var query = ""
    @State private var stickers: [GiphyService.Gif] = []
    @State private var loading = false
    @State private var searchTask: Task<Void, Never>?
    /// The trending page, held for the life of the app. It is the first thing most trays show and
    /// re-fetching it on every open is a network round trip in front of a screen already seen.
    @MainActor private static var trendingCache: [GiphyService.Gif] = []

    private enum Route: Hashable { case link, place }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $route) {
            VStack(spacing: 0) {
                searchField
                ScrollView {
                    VStack(spacing: 18) {
                        // The actions stand down while you are searching, exactly as the reference
                        // does: a search is a search FOR A STICKER, and a row of things that are not
                        // stickers is only in front of the results.
                        if !searching { actions }
                        grid
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                tabBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .link:  LinkStickerScreen { url in close(); onLink(url) }
                case .place: PlaceStickerScreen { name, coord in close(); onPlace(name, coord) }
                }
            }
        }
        // ALWAYS DARK, like every other story surface (his standing rule). A tray that opens over a
        // photograph and turns pale on a light-mode phone is the same complaint he photographed on
        // the picker.
        .storyAlwaysDark()
        .task(id: tab.id) { if !searching { await load() } }
    }

    // MARK: Search

    /// ⚠️ THE SYSTEM'S OWN SEARCH FIELD, OUT OF THE SYSTEM'S OWN PARTS — and not `.searchable`.
    /// `.searchable` belongs to a navigation bar and this tray has none; asking for one would raise a
    /// whole navigation chrome above the tray to hold a single field.
    ///
    /// The well is real `glassEffect`, not the `tertiarySystemFill` it was. That fill is what UIKit
    /// drew for a search bar BEFORE iOS 26; on 26 UIKit draws the same bar as glass, so naming the
    /// old colour was following the system one release too late. Glass here also means the field
    /// picks up the photograph behind the tray instead of sitting on it as a grey rectangle.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text("Search").foregroundStyle(.secondary))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .submitLabel(.search)
            if searching {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        // Debounced for the same reason every other search in this app is: a request per keystroke
        // is a request per keystroke.
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await load()
            }
        }
    }

    // MARK: The actions

    /// ⚠️ THREE PILLS, NOT FIFTEEN, AND THE MISSING TWELVE ARE MISSING ON PURPOSE. The tray he
    /// photographed carries Music, Poll, Questions, Countdown, Add Yours, Frames, Photostrip,
    /// Cutouts, Avatar, a hashtag and a mention. Not one of those exists in this app. A pill that
    /// opens nothing is worse than no pill — it is a promise the screen cannot keep, and he would
    /// find every one of them by tapping it. What is here is what works. The LAYOUT is the
    /// reference's, so the row grows on its own as more is built, with nothing to rearrange.
    private var actions: some View {
        // The three of them are ONE glass system, not three glass blobs that happen to be near each
        // other — the same reason the chat composer wraps its `+` and its field in a container. The
        // 4pt is deliberately well under the 10pt gap: a container's spacing is the distance at
        // which shapes start to blend into one another, and three pills melting into a puddle is
        // not what this row is.
        GlassEffectContainer(spacing: 4) {
            StickerFlowLayout(spacing: 10, lineSpacing: 10) {
                actionPill("mappin.and.ellipse", "Location", .red) { route.append(.place) }
                actionPill("link", "Link", .blue) { route.append(.link) }
                actionPill("clock", "Time", .orange) { close(); onTime() }
            }
        }
        .padding(.horizontal, 16)
    }

    /// ⚠️ APPLE'S OWN BUTTON, NOT OURS WEARING APPLE'S MATERIAL. `.buttonStyle(.glass)` is the whole
    /// control — the material, the capsule, the press-in highlight, the way it dims when the sheet
    /// goes behind something — and none of it is ours to keep right.
    ///
    /// The previous version was a solid white capsule with black lettering, and the note here argued
    /// for it: glass takes its colour from what is under it, which is the wrong property for a
    /// control over somebody's photograph. That was a real point about a control sitting ON the
    /// picture. These do not — they sit on the tray, which is itself glass, so what is under them is
    /// a settled surface and the lettering only has to survive that. White lettering on it does.
    ///
    /// The glyph keeps its colour. A tint inside a glass button is Apple's own pattern (every row of
    /// their share sheet does it) and it is the one thing that makes the three readable at a glance.
    private func actionPill(_ symbol: String, _ title: String,
                            _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 4)
            .frame(height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }

    // MARK: The stickers

    private var grid: some View {
        VStack(spacing: 0) {
            if stickers.isEmpty {
                if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if searching {
                    Text("No stickers found.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if tab == .recent {
                    Text("Stickers you use will show up here.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(stickers) { s in cell(s) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func cell(_ s: GiphyService.Gif) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            // `fill: false` and no placeholder — a sticker is cut out, so anything behind it is a box
            // around it and anything cropped off it is the shape it was cut into. See
            // `AnimatedGifView`, which also has to be told to accept the size it is offered.
            //
            // ⛔ OURS ARE NOT FETCHED. `sticker://` is our own scheme and handing it to the animated
            // view would send it to the network as a url, which it is not. See `BuiltInStickers`.
            .overlay {
                if let own = BuiltInStickers.image(s.url) {
                    Image(uiImage: own).renderingMode(.original).resizable().scaledToFit()
                } else {
                    AnimatedGifView(url: s.url, fill: false, placeholder: .clear)
                }
            }
            // ⚠️ THE SECOND HALF OF "the stickers are overlapping each other". An overlay is NOT
            // clipped to what it overlays, so a representable reporting more than its square drew
            // exactly what it asked for — over its neighbours.
            .clipped()
            // The tap lives on a pure-SwiftUI layer ABOVE the animated view: a gesture on the
            // UIKit-backed view itself can silently never fire, because the touch lands in its
            // UIImageView. Same reason the GIF picker does it this way.
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture {
                        StickerRecents.note(s)
                        close()
                        onSticker(s)
                    }
            }
    }

    // MARK: The bottom row

    /// ⚠️ THE CAPSULE TABS — his order, and the row where the old wash was worst.
    ///
    /// There is no track. The row is transparent and the tray's own glass shows through it, because
    /// a glass strip carrying a second glass capsule is two materials over one place and both
    /// resolve to flat grey — that is the moulded plastic he photographed on the camera switch five
    /// times, and the answer there was Apple's own segmented glass: the track carries nothing, and
    /// the selected segment is the single piece of glass that slides.
    ///
    /// So exactly one element is real glass — the chosen category — and it carries a CONSTANT
    /// `glassEffectID`. Constant, not `t.id`: an id per tab makes eleven separate elements that can
    /// only fade, while one id worn by whichever tab is chosen is ONE element that moves, and a
    /// glass element moving inside a `GlassEffectContainer` melts out of where it was and into where
    /// it is going. That melt is the whole request.
    ///
    /// The unselected ten still carry `.glassEffect(.identity)` rather than nothing, so the view
    /// tree is the same shape whichever tab is on — `Theme.liquidGlass(enabled:)` takes the same
    /// route and for the same reason. A branch that adds and removes the modifier would hand the
    /// container a different set of elements every tap, which is the one thing that stops the melt.
    private var tabBar: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(StickerTab.all) { t in
                        let on = tab == t && !searching
                        Button {
                            query = ""      // a tab is a different question from a search
                            tab = t
                        } label: {
                            Group {
                                if case .recent = t {
                                    Image(systemName: "clock").font(.system(size: 17, weight: .semibold))
                                } else if case .builtIn = t {
                                    // ⛔ A REAL PACK THUMBNAIL, WHICH THE NOTE ON `StickerTab` SAID WE COULD NOT
                                    // HAVE. It could not, then: the tray was a search endpoint and a category has
                                    // no artwork of its own. This tab is a PACK, so it can be drawn the way his
                                    // reference draws every tab — the first sticker in it.
                                    Image(uiImage: BuiltInStickers.image(BuiltInStickers.gifs[0].url) ?? UIImage())
                                        .renderingMode(.original)
                                        .resizable().scaledToFit()
                                        .frame(width: 27, height: 27)
                                } else if case .term(let icon, _) = t {
                                    // The same size and weight as the clock beside it: one row of
                                    // controls drawn by the system, not a clock and ten pictures.
                                    Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 40)
                            .glassEffect(on ? Glass.regular.interactive() : Glass.identity, in: Capsule())
                            .glassEffectID(on ? Self.selectionID : nil, in: glass)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 56)
        // The glass follows the tap on a spring rather than a curve, because it is a physical thing
        // arriving somewhere — the same feel Apple gives their own tab selection.
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: tab)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: searching)
    }

    /// One id, worn by whichever tab is selected. See `tabBar`.
    private static let selectionID = "sticker.tab.selection"

    // MARK: Loading

    private func load() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            loading = true
            let found = await GiphyService.shared.searchStickers(q)
            loading = false
            stickers = found
            return
        }
        if case .recent = tab {
            stickers = StickerRecents.all()
            return
        }
        // No network, no loading state, no empty message: the pack is in the binary.
        if case .builtIn = tab {
            stickers = BuiltInStickers.gifs
            return
        }
        let isTrending = tab.query?.isEmpty ?? false
        if isTrending, !Self.trendingCache.isEmpty { stickers = Self.trendingCache; return }
        loading = true
        let found = await GiphyService.shared.searchStickers(tab.query ?? "")
        loading = false
        if isTrending { Self.trendingCache = found }
        stickers = found
    }
}

/// THE PILLS WRAP, AND EACH ROW IS CENTRED — the reference's tag cloud, as a real layout rather than
/// a stack of `HStack`s with hand-counted contents.
///
/// A `Layout` and not a grid, because these are all different widths: "Link" and "Location" cannot
/// share a column without one of them being padded out to the other's size, and that padding is
/// exactly what makes a hand-built version look built. This measures each pill, fills a row until the
/// next one will not fit, and centres what it has — so it rearranges itself on a narrow phone, at a
/// larger text size, and again when a fourth action is added, with nothing to update.
struct StickerFlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, _ maxWidth: CGFloat) -> [Row] {
        var out: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let widthWithIt = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, widthWithIt > maxWidth {
                out.append(row)
                row = Row(indices: [i], width: size.width, height: size.height)
            } else {
                row.indices.append(i)
                row.width = widthWithIt
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { out.append(row) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rs = rows(subviews, maxWidth)
        let height = rs.reduce(0) { $0 + $1.height } + CGFloat(max(0, rs.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? (rs.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}

// MARK: - Link

/// "Enter link", and nothing else on the screen.
///
/// ⚠️ IT COMPLETES THE SCHEME RATHER THAN DEMANDING ONE. Nobody types `https://`, and refusing
/// `fariin.com` because of it would be an error message about punctuation. `NSDataDetector` is the
/// same judge the caption already uses for links, so what counts as a link is one answer app-wide.
/// THE HEADER THE TWO PUSHED PAGES WEAR, IN PLACE OF THE NAVIGATION BAR THEY USED TO GET.
///
/// ⚠️ HIS 2026-08-17 SCREENSHOT, WITH THE WHOLE TOP OF THE PAGE CIRCLED. The tray hosts its content
/// with no container safe area — it has to, or the tab row would float 34pt up from a panel that
/// already ends at the screen's edge — so a real navigation bar was laid out at the panel's literal
/// top edge. That is underneath the grabber, which the tray draws OVER the content at y=8, and inside
/// the panel's own 32pt corner, which cut the back button in half.
///
/// The root page never showed the problem because it hides the navigation bar and its search field
/// carries `.padding(.top, 16)` — enough to clear the grabber. This is that same 16, so the two pages
/// and the root all start their content on the same line.
private struct TrayPushHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

private struct LinkStickerScreen: View {
    var onDone: (URL) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    /// The last frame this page reported. Two agreeing readings at rest mean the push has landed —
    /// see the note on the geometry hook below, which is what raises the keyboard.
    @State private var lastFrame: CGRect = .null

    private var resolved: URL? { StoryLinkSticker.url(from: text) }

    var body: some View {
        VStack(spacing: 0) {
            TrayPushHeader(title: "Link")
            linkForm
        }
        // The bar this replaces. Hidden on the pushed pages for the same reason it is hidden on the
        // root: it has nowhere to be laid out inside a panel with no safe area of its own.
        .toolbar(.hidden, for: .navigationBar)
    }

    private var linkForm: some View {
        VStack(spacing: 18) {
            TextField("", text: $text,
                      prompt: Text("Enter link").foregroundStyle(.white.opacity(0.4)))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { if let u = resolved { onDone(u) } }
                .focused($focused)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                // ⚠️ APPLE'S OWN FIELD, NOT GLASS — his 2026-08-17 "follow Apple's guide, rounded,
                // no glass, a normal input bar".
                //
                // Glass is a material for something floating OVER content. This field is content: it
                // sits on a plain page inside the tray with nothing behind it to refract, so the
                // effect had nothing to do and resolved to the grey slab he photographed. Apple's
                // own text entry is a fill in a rounded shape, and `tertiarySystemFill` is the fill
                // they use for exactly this — it is also what a search field wears, so this page and
                // the tray's own search bar are the same object at last.
                .background(Color(.tertiarySystemFill), in: Capsule())

            Button { if let u = resolved { onDone(u) } } label: {
                Text("Add link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(resolved == nil ? Color.white.opacity(0.4) : .black)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(resolved == nil ? Color.white.opacity(0.12) : Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(resolved == nil)

            Spacer(minLength: 0)
        }
        .padding(20)
        // ⚠️ THE KEYBOARD WAITS FOR THE PUSH TO FINISH — his 2026-08-17 "when I click Location or
        // Link the page comes in laggy".
        //
        // `onAppear` raised it on the same frame the push started, and inside a sheet that is three
        // motions at once: the page slides in, the keyboard slides up, and the sheet itself has to
        // grow from its 0.8 detent to make room for the keyboard. The stutter is those three
        // fighting for the same frames, not the page being slow to build — there is one text field
        // on it.
        //
        // ⛔ AND A TIMER WAS THE WRONG WAY TO WAIT — his 2026-08-18 screenshot: the keyboard arriving
        // from the RIGHT-HAND SIDE of the screen, half off it, mid-slide.
        //
        // This is a `NavigationStack`, so the push is a real UIKit transition, and a field that takes
        // first responder while one is running makes the KEYBOARD PART OF THAT TRANSITION: it slides
        // in horizontally with the page instead of up from the bottom. 0.35s was the push's nominal
        // length measured against a sleep that starts when the page appears, which is when the push
        // STARTS — so it lands in the last frames of the animation and races it. Some opens won, and
        // the ones that lost are what he photographed.
        //
        // So it waits for the thing itself rather than for a number. A pushed page slides in from the
        // right, so its own frame is the transition: while it moves, `minX` is positive; when the
        // push has landed, it is zero and stays zero. Two agreeing readings at rest is the signal,
        // and it cannot race a duration it does not depend on.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { f in
            guard !focused else { return }
            if f.minX <= 0.5, f == lastFrame { focused = true }
            lastFrame = f
        }
    }
}

// MARK: - Location

/// Search for a place and pick it.
///
/// `MKLocalSearch` rather than `MKLocalSearchCompleter`: the completer returns strings that then need
/// a second search to turn into coordinates, and a sticker with no coordinates is a label. This asks
/// the question whose answer is the thing being placed.
///
/// ⛔ IT ASKS FOR LOCATION NOW, AND THE NOTE THAT SAID IT NEVER WOULD IS GONE ON HIS 2026-08-18
/// ORDER: "the location sheet now looks empty, make it like image 2" — a list of places around you
/// the moment it opens, which is a question that cannot be answered without knowing where you are.
///
/// The old reasoning was that raising the system prompt to put a name on a photograph is a price
/// nobody agreed to pay. Two things answer it. The app already asks for exactly this permission to
/// share a location in a chat, so this is not a new prompt on this phone, it is the same one. And a
/// refusal costs nothing: the page falls back to being what it was, a search field, so the feature
/// still works for somebody who says no.
///
/// `MKLocalSearch` rather than `MKLocalSearchCompleter` for the typed search, and
/// `MKLocalPointsOfInterestRequest` for the nearby list — the one MapKit call that means "what is
/// around this point" without a search string to invent.
private struct PlaceStickerScreen: View {
    var onDone: (String, CLLocationCoordinate2D) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var nearby: [MKMapItem] = []
    /// ⚠️ `nearby.isEmpty` ALONE IS NOT A GUARD. The cached fix and the fresh one can both call in
    /// before either search has answered, and two `MKLocalSearch`es for the same place is the one
    /// thing that would make this slower rather than faster.
    @State private var nearbyInFlight = false
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool
    @StateObject private var fetcher = LocationFetcher()

    /// The typed search wins while there is one; otherwise the page shows what is around you.
    private var shown: [MKMapItem] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 ? results : nearby
    }

    var body: some View {
        VStack(spacing: 0) {
            TrayPushHeader(title: "Location")
            TextField("", text: $query,
                      prompt: Text("Search location").foregroundStyle(.white.opacity(0.4)))
                .focused($focused)
                .autocorrectionDisabled()
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                // The same field as the Link screen, and for the same reason — see the note there.
                .background(Color(.tertiarySystemFill), in: Capsule())
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            List {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    Button {
                        guard let c = item.placemark.location?.coordinate else { return }
                        onDone(Self.name(of: item), c)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.name(of: item))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                            if let sub = Self.subtitle(of: item), !sub.isEmpty {
                                Text(sub).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay { if searching, shown.isEmpty { ProgressView().tint(.white) } }
        }
        .toolbar(.hidden, for: .navigationBar)
        // ⚠️ NO KEYBOARD ON ARRIVAL ANY MORE, and that is half of his "it looks empty". The Link page
        // raises one because a link can only be typed; this page has a list to read, and a keyboard
        // over an empty list is a screen with nothing on it. The field is one tap away for anyone who
        // does want to type.
        // ⛔ THE CACHED FIX FIRST, AND THAT IS THE WHOLE OF HIS "make fast".
        //
        // The page was waiting on `requestLocation()`, which goes and acquires a NEW fix: seconds
        // outdoors, many more indoors or on a weak signal, and the spinner he circled is that wait
        // rather than MapKit being slow. iOS is already holding the last fix any app on the phone
        // asked for, and for "what is near me" a fix from a minute ago is the same answer — so the
        // search starts off THAT, immediately, and the fresh one only ever refines it.
        //
        // A coarser target for the fresh one too: a list of places is answered from wifi and cell
        // towers, which do not wait for a GPS lock. The map picker keeps metres, and this changes
        // nothing there — see `LocationFetcher.request(accuracy:)`.
        .task {
            if let c = fetcher.cached { await loadNearby(c) }
            fetcher.request(accuracy: kCLLocationAccuracyKilometer)
        }
        .onChange(of: fetcher.location?.latitude) { _, _ in
            guard let c = fetcher.location else { return }
            Task { await loadNearby(c) }
        }
        // Debounced, for the same reason the sticker search is: a request per keystroke is a request
        // per keystroke, and MapKit rate-limits.
        .onChange(of: query) { _, q in
            task?.cancel()
            task = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                await search(q)
            }
        }
    }

    private func search(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        let found = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        searching = false
        guard !Task.isCancelled else { return }
        results = found
    }

    /// What is around this point. ⚠️ NOT A SEARCH WITH AN INVENTED WORD IN IT — asking for
    /// "restaurant" or "cafe" would answer a question nobody asked and would rank a coffee shop above
    /// the street somebody is standing on. `MKLocalPointsOfInterestRequest` is the call that means
    /// "everything of interest near here", which is what the list is for.
    ///
    /// 1500m: far enough to fill a screen in a quiet place, near enough that the top of the list is
    /// somewhere you could point at.
    private func loadNearby(_ c: CLLocationCoordinate2D) async {
        // One fill. The cached fix usually gets here first and the fresh one finds the answer already
        // on screen — a second GPS callback is not a new question, and re-running would replace a
        // list somebody may already be reading.
        guard nearby.isEmpty, !nearbyInFlight else { return }
        nearbyInFlight = true
        searching = true
        let request = MKLocalPointsOfInterestRequest(center: c, radius: 1500)
        let found = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        nearbyInFlight = false
        searching = false
        guard !Task.isCancelled else { return }
        nearby = found
    }

    private static func name(of item: MKMapItem) -> String {
        item.name ?? item.placemark.locality ?? "Location"
    }
    private static func subtitle(of item: MKMapItem) -> String? {
        let p = item.placemark
        return [p.locality, p.administrativeArea, p.country].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - What a link sticker is made of

enum StoryLinkSticker {
    /// The typed text as a real URL, or nil. Bare domains count, because that is how people type
    /// them — the same rule the caption's own link detection follows.
    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return nil }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let m = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              m.range.length == (t as NSString).length,
              let url = m.url else { return nil }
        return url
    }

    /// What the chip says: the host without its `www.`, which is what a link sticker is for — the
    /// full URL is unreadable at sticker size and is not the thing being shown off.
    static func label(for url: URL) -> String {
        let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        return host.uppercased()
    }
}
