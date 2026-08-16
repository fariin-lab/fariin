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
    case term(String, String)   // the chip's face, the query behind it

    var id: String {
        switch self {
        case .recent: return "recent"
        case .term(let face, _): return face
        }
    }
    var query: String? {
        switch self {
        case .recent: return nil
        case .term(_, let q): return q
        }
    }

    /// Trending leads the searched tabs, because a tray that opens on somebody's own history is
    /// empty on the first day and full of one joke by the third.
    static let all: [StickerTab] = [
        .recent,
        .term("🔥", ""),            // empty query = the endpoint's own trending
        .term("😂", "laughing"),
        .term("❤️", "love"),
        .term("🎉", "party"),
        .term("👋", "hello"),
        .term("🙏", "thank you"),
        .term("😴", "tired"),
        .term("✨", "sparkle"),
        .term("👍", "yes"),
        .term("😭", "crying"),
    ]
}

struct StoryStickerSheet: View {
    /// A sticker was chosen. The editor downloads it, takes a frame and places it — the tray does not
    /// know what a canvas is.
    var onSticker: (GiphyService.Gif) -> Void
    var onLink: (URL) -> Void
    var onPlace: (String, CLLocationCoordinate2D) -> Void
    var onTime: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// The one namespace the bottom row's glass lives in. It has to be declared on the view that
    /// OWNS both the container and the elements, or the selection has nothing to melt across.
    @Namespace private var glass
    @State private var route: [Route] = []
    @State private var tab: StickerTab = .recent
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
                case .link:  LinkStickerScreen { url in dismiss(); onLink(url) }
                case .place: PlaceStickerScreen { name, coord in dismiss(); onPlace(name, coord) }
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
                actionPill("clock", "Time", .orange) { dismiss(); onTime() }
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
            .overlay { AnimatedGifView(url: s.url, fill: false, placeholder: .clear) }
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
                        dismiss()
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
                                } else if case .term(let face, _) = t {
                                    Text(face).font(.system(size: 20))
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
private struct LinkStickerScreen: View {
    var onDone: (URL) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var resolved: URL? { StoryLinkSticker.url(from: text) }

    var body: some View {
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
                // Glass, like the tray's own search well. `Color.white.opacity(0.10)` was a grey we
                // painted, and it is the thing this whole pass exists to remove.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

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
        .navigationTitle("Link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }
}

// MARK: - Location

/// Search for a place and pick it.
///
/// `MKLocalSearch` rather than `MKLocalSearchCompleter`: the completer returns strings that then need
/// a second search to turn into coordinates, and a sticker with no coordinates is a label. This asks
/// the question whose answer is the thing being placed.
///
/// ⚠️ NO LOCATION PERMISSION IS ASKED FOR. A search works without one — results are simply not sorted
/// by how near they are — and raising the system prompt to put a name on a photograph is a price
/// nobody agreed to pay. "Places near me" is a permission and its own decision.
private struct PlaceStickerScreen: View {
    var onDone: (String, CLLocationCoordinate2D) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("", text: $query,
                      prompt: Text("Search location").foregroundStyle(.white.opacity(0.4)))
                .focused($focused)
                .autocorrectionDisabled()
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            List {
                ForEach(Array(results.enumerated()), id: \.offset) { _, item in
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
            .overlay { if searching, results.isEmpty { ProgressView().tint(.white) } }
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
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
