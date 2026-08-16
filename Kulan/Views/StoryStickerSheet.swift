import SwiftUI
import MapKit

// The story editor's STICKER TRAY — his 2026-08-16 request, with the reference tray photographed
// beside it: a sheet at about 60% of the screen, Featured actions across the top, a grid of stickers
// under them, and a row of categories along the bottom with Recent first.
//
// IT IS A TRAY, NOT A SCREEN. Everything it does hands one finished thing back to the editor and
// closes; it owns no editing state and never touches the canvas. That is what keeps the promise he
// attached to the request — "do not redesign or change the existing Story Editor UI" — enforceable
// rather than merely intended: the editor gained one button and three callbacks.
//
// ⚠️ LINK AND LOCATION ARE PUSHED INSIDE THIS SHEET, NOT RAISED AS A SECOND ONE. Asking for a sheet
// while the one underneath it is still going down is the oldest way to get a screen that silently
// never appears — this app has paid for it before (see `AddStorySheet`'s note on the picker). A push
// cannot race a dismissal because nothing is dismissed.

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

    @Environment(\.dismiss) private var dismiss
    @State private var route: [Route] = []
    @State private var tab: StickerTab = .recent
    @State private var stickers: [GiphyService.Gif] = []
    @State private var loading = false
    /// The trending page, held for the life of the app. It is the first thing most trays show and
    /// re-fetching it on every open is a network round trip in front of a screen already seen.
    @MainActor private static var trendingCache: [GiphyService.Gif] = []

    private enum Route: Hashable { case link, place }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack(path: $route) {
            VStack(spacing: 0) {
                featured
                Divider().overlay(Color.white.opacity(0.12))
                grid
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
        .task(id: tab.id) { await load() }
    }

    // MARK: Featured

    /// LINK and LOCATION, which are the two he asked for by name.
    ///
    /// ⚠️ NO WEATHER CHIP. His words were "Weather (if already supported by the existing design)",
    /// and it is not: a temperature means a location permission, a weather provider and an Apple
    /// entitlement, none of which this app has. A chip reading 26°C without any of that would be a
    /// picture of a feature.
    private var featured: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                featureChip("link", "LINK") { route.append(.link) }
                featureChip("mappin.and.ellipse", "LOCATION") { route.append(.place) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private func featureChip(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .liquidGlass(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: The stickers

    private var grid: some View {
        ScrollView {
            if stickers.isEmpty {
                // Recent is empty on the first day and that is not an error, so it says so rather
                // than spinning at something that will never arrive.
                if !loading, tab == .recent {
                    Text("Stickers you use will show up here.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 48)
                }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(stickers) { s in cell(s) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func cell(_ s: GiphyService.Gif) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            // `fill: false` and no placeholder — a sticker is cut out, so anything behind it is a
            // box around it and anything cropped off it is the shape it was cut into. See
            // `AnimatedGifView`.
            .overlay { AnimatedGifView(url: s.url, fill: false, placeholder: .clear) }
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

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(StickerTab.all) { t in
                    Button { tab = t } label: {
                        Group {
                            if case .recent = t {
                                Image(systemName: "clock").font(.system(size: 17, weight: .semibold))
                            } else if case .term(let face, _) = t {
                                Text(face).font(.system(size: 20))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background { if tab == t { Circle().fill(Color.white.opacity(0.18)) } }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
        .frame(height: 60)
        .background(.ultraThinMaterial)
    }

    // MARK: Loading

    private func load() async {
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
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button { if let u = resolved { onDone(u) } } label: {
                Text("Add link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(resolved == nil ? Color.white.opacity(0.4) : .black)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(resolved == nil ? Color.white.opacity(0.12) : Color.white,
                                in: Capsule())
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
/// `MKLocalSearch` rather than `MKLocalSearchCompleter`: the completer returns strings that then
/// need a second search to turn into coordinates, and a sticker with no coordinates is a label. This
/// asks the question whose answer is the thing being placed.
///
/// ⚠️ NO LOCATION PERMISSION IS ASKED FOR. A search works without one — results are simply not
/// sorted by how near they are — and raising the system prompt to put a name on a photograph is a
/// price nobody agreed to pay. If he wants "places near me" it is a permission and its own decision.
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
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .overlay {
                if searching, results.isEmpty { ProgressView().tint(.white) }
            }
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        // Debounced, for the same reason the GIF search is: a request per keystroke is a request per
        // keystroke, and MapKit rate-limits.
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
