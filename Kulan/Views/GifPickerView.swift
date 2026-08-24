import SwiftUI

// Custom GIF picker (our own design) — searches Giphy via GiphyService and shows an animated
// grid. The small "Powered by GIPHY" attribution is required by Giphy's free terms.
// The GIFs this account actually sends, newest first — the "Recently used" row (user reference:
// every big sticker/GIF panel has one). Local to the device, capped, deduped by url.
enum GifRecents {
    private static let key = "gifRecents.v1"
    private static let cap = 24

    static func all() -> [GiphyService.Gif] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { d in
            guard let url = d["u"] as? String else { return nil }
            return GiphyService.Gif(id: "recent-\(url)", url: url,
                                    width: d["w"] as? Double ?? 1, height: d["h"] as? Double ?? 1)
        }
    }

    static func note(_ g: GiphyService.Gif) {
        var list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [])
            .filter { ($0["u"] as? String) != g.url }
        list.insert(["u": g.url, "w": g.width, "h": g.height], at: 0)
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
    }

    /// Take one back out. Recents fill themselves without being asked, so there has to be a way to
    /// say "not that one" — otherwise a GIF you sent once by mistake sits in the row for good.
    static func forget(_ url: String) {
        let list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [])
            .filter { ($0["u"] as? String) != url }
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// GIFs you keep on purpose, as opposed to the ones you happen to have sent. Same store shape as
/// recents, and local for the same reason — but the ORDER is oldest first, because a favourite is
/// something you go back to and a row that reshuffles under your finger every time you use it is
/// not a shelf, it is another recents row.
enum GifFavorites {
    private static let key = "gifFavorites.v1"
    private static let cap = 60

    static func all() -> [GiphyService.Gif] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { d in
            guard let url = d["u"] as? String else { return nil }
            return GiphyService.Gif(id: "fav-\(url)", url: url,
                                    width: d["w"] as? Double ?? 1, height: d["h"] as? Double ?? 1)
        }
    }

    static func contains(_ url: String) -> Bool {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [])
            .contains { ($0["u"] as? String) == url }
    }

    static func add(_ g: GiphyService.Gif) {
        var list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [])
        guard !list.contains(where: { ($0["u"] as? String) == g.url }) else { return }
        list.append(["u": g.url, "w": g.width, "h": g.height])
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
    }

    static func remove(_ url: String) {
        let list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [])
            .filter { ($0["u"] as? String) != url }
        UserDefaults.standard.set(list, forKey: key)
    }
}

struct GifPickerView: View {
    let onPick: (GiphyService.Gif) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var gifs: [GiphyService.Gif] = []
    @State private var searchTask: Task<Void, Never>?   // debounce: don't hit Giphy on every keystroke
    @State private var category: GifCategory = .trending

    // The mood row — the standard GIF-picker categories (Giphy's own concept, every big messenger
    // has a version), drawn OUR way: our icons, accent tint, no copied glyph set. Each chip is a
    // ready-made search; Trending is the browse default.
    private enum GifCategory: CaseIterable {
        case favorites, recent, trending, happy, love, sad, party, thumbsUp
        var icon: String {
            switch self {
            case .favorites: return "star.fill"
            case .recent: return "clock"
            case .trending: return "flame"
            case .happy: return "face.smiling"
            case .love: return "heart"
            case .sad: return "cloud.rain"
            case .party: return "party.popper"
            case .thumbsUp: return "hand.thumbsup"
            }
        }
        var term: String {
            switch self {
            case .favorites, .recent, .trending: return ""
            case .happy: return "happy"
            case .love: return "love"
            case .sad: return "sad"
            case .party: return "party"
            case .thumbsUp: return "thumbs up"
            }
        }
    }

    // The last trending page, kept for the app's lifetime: the picker PAINTS INSTANTLY on reopen
    // (user: "when I tap GIF it takes a bit late to load") and refreshes quietly behind it.
    //
    // ⚠️ AND ACROSS LAUNCHES NOW, on disk. Kept only in memory it died with the app, so the FIRST
    // tap of every session was the slow one all over again — which is the tap people actually
    // notice. It is a list of public Giphy urls and sizes: nothing private, nothing that needs
    // decrypting, and it is stale-safe because the refresh below overwrites it every time.
    @MainActor static var trendingCache: [GiphyService.Gif] = loadTrendingFromDisk()

    private static let trendingDefault = "giphy.trending.v1"

    private static func loadTrendingFromDisk() -> [GiphyService.Gif] {
        guard let raw = UserDefaults.standard.array(forKey: trendingDefault) as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let id = d["id"] as? String, let url = d["url"] as? String,
                  let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
            return GiphyService.Gif(id: id, url: url, width: w, height: h)
        }
    }

    /// Bounded on purpose: one screen's worth is what "paints instantly" needs, and the refresh
    /// behind it brings the rest.
    private static func saveTrendingToDisk(_ gifs: [GiphyService.Gif]) {
        let raw = gifs.prefix(40).map { ["id": $0.id, "url": $0.url, "w": $0.width, "h": $0.height] }
        UserDefaults.standard.set(Array(raw), forKey: trendingDefault)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Recents live on their OWN clock tab (owner's 416 idea: heavy GIF use would let
                // the old top row eat the whole main page). Empty state until something is sent.
                if category == .recent, gifs.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No recent GIFs", systemImage: "clock",
                                           description: Text("GIFs you send will appear here."))
                        .padding(.top, 40)
                }
                if category == .favorites, gifs.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "star",
                                           description: Text("Hold a GIF and choose Add to Favourites."))
                        .padding(.top, 40)
                }
                // Masonry (standard style): 2 columns, each GIF at its OWN natural aspect ratio,
                // added to whichever column is currently shorter — no fixed card that stretches them.
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<2, id: \.self) { col in
                        LazyVStack(spacing: 4) {
                            ForEach(masonryColumns[col]) { g in gifCell(g) }
                        }
                    }
                }
                .padding(6)
            }
            // The mood row pins under the title; the grid scrolls beneath it. Search stays at the
            // bottom (native iOS 26 placement — the owner's pick over the reference's top bar).
            .safeAreaInset(edge: .top, spacing: 0) { categoryRow }
            .searchable(text: $query, prompt: "Search GIFs")
            .onChange(of: query) { _, _ in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)   // 300ms debounce
                    if Task.isCancelled { return }
                    await refresh()
                }
            }
            // NO WHITE BAND AT THE TOP (his 573 screenshot, crossed out four times). It was made
            // opaque on his own 416 report — "can see scrolling the gifts" — but that report was
            // about the CHIPS sliding against the grid behind them, and the chips left the bar
            // tonight: they are a floating capsule now, over the GIFs on purpose.
            //
            // What is left up there is a close button that carries its own glass circle, so the bar
            // itself has nothing to paint for. The title goes with the band: neither reference names
            // its picker, and a word floating over moving GIFs is the very thing the 416 report was
            // about.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // ⛔ THE TITLE IS BACK, ON HIS WORD — owner, 2026-08-24: "in the GIF page header add
                // the text Choose GIF". That reverses the note directly above, which took it out
                // because neither reference names its picker and a word over moving GIFs was close
                // to the complaint that removed the opaque bar. His newer word stands; the reasoning
                // is left there so the reversal is visible rather than looking like a mistake.
                //
                // The band stays hidden either way — this is a title on the glass, not a bar.
                ToolbarItem(placement: .principal) {
                    Text("Choose GIF")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                // Hide the toolbar's own glass so CloseXButton's circle isn't double-wrapped (iOS 26).
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { CloseXButton { dismiss() } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Subtle inline attribution (required by Giphy's terms) — no `.bar` material band, which
                // drew a hard border line above the search bar.
                Text("Powered by GIPHY")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
            }
            .task {
                // Paint INSTANTLY from the cached trending page, then refresh quietly behind it.
                // The old version opened EMPTY and made every open wait for the network.
                if gifs.isEmpty, !Self.trendingCache.isEmpty { gifs = Self.trendingCache }
                let fresh = await GiphyService.shared.search("")
                if !fresh.isEmpty {
                    Self.trendingCache = fresh
                    Self.saveTrendingToDisk(fresh)
                    if query.trimmingCharacters(in: .whitespaces).isEmpty, category == .trending { gifs = fresh }
                }
            }
        }
    }

    // One exit for every pick: remember it for the Recently-used row, hand it over, close.
    private func pick(_ g: GiphyService.Gif) {
        GifRecents.note(g)
        onPick(g)
        dismiss()
    }

    // ONE loader for every state: a typed search wins; otherwise the selected mood. Recent is
    // local (the device's own sent list) — instant, no network; Trending = "".
    private func refresh() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        // The two local tabs answer from the device, so they are instant and work offline.
        if q.isEmpty, category == .recent {
            gifs = GifRecents.all()
            return
        }
        if q.isEmpty, category == .favorites {
            gifs = GifFavorites.all()
            return
        }
        let results = await GiphyService.shared.search(q.isEmpty ? category.term : q)
        if !Task.isCancelled { gifs = results }
    }

    private var categoryRow: some View {
        HStack(spacing: 4) {
            ForEach(GifCategory.allCases, id: \.self) { c in
                Button {
                    guard category != c else { return }
                    category = c
                    searchTask?.cancel()
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchTask = Task { await refresh() }
                    } else {
                        query = ""   // clearing re-runs the loader through onChange, under this mood
                    }
                } label: {
                    Image(systemName: c.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(category == c ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background {
                            if category == c {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        // FLOATING GLASS, NOT AN OPAQUE STRIP (his call, 2026-08-14, with the corner magnified: the
        // one thing to keep from the panel experiment). It used to paint `systemBackground` across
        // the full width, because a transparent pinned row let the grid show through raw while it
        // scrolled. Glass answers that better than paint does — it blurs what passes under it, which
        // is what makes it read as floating ABOVE the GIFs rather than as a lid on top of them.
        //
        // Same treatment as the attachment sources bar and the media tabs: the control is the
        // surface, and it is the only surface.
        .padding(.horizontal, 6).padding(.vertical, 5)
        .liquidGlass(Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.15), value: category)
    }

    // Split the results into 2 balanced columns: each GIF goes to the currently-shorter column
    // (heights measured in "rows per unit width" = height/width), so the waterfall stays even.
    private var masonryColumns: [[GiphyService.Gif]] {
        var cols: [[GiphyService.Gif]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for g in gifs {
            let unitH = (g.width > 0 && g.height > 0) ? CGFloat(g.height / g.width) : 1
            let i = heights[0] <= heights[1] ? 0 : 1
            cols[i].append(g)
            heights[i] += unitH
        }
        return cols
    }

    // One GIF cell sized to its natural aspect (fills the column width, height follows the ratio).
    private func gifCell(_ g: GiphyService.Gif) -> some View {
        let ratio = (g.width > 0 && g.height > 0) ? CGFloat(g.width / g.height) : 1
        return Color.clear
            .aspectRatio(ratio, contentMode: .fit)   // aspect box that fills the column width
            .overlay { AnimatedGifView(url: g.url) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Tap lives on a pure-SwiftUI overlay ABOVE the gif: a gesture on the UIKit-backed
            // view itself can silently never fire (touches fall into the UIImageView).
            .overlay {
                Color.clear.contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { pick(g) }
            }
            // Long press = the native menu, on the SwiftUI layer rather than the UIKit gif view.
            // A gesture attached to the animated view itself can silently never fire, because the
            // touch lands in its UIImageView — the same reason the tap lives on an overlay.
            .contextMenu {
                let favourite = GifFavorites.contains(g.url)
                Button {
                    favourite ? GifFavorites.remove(g.url) : GifFavorites.add(g)
                    refreshLocalTab()
                } label: {
                    Label(favourite ? "Remove from Favourites" : "Add to Favourites",
                          systemImage: favourite ? "star.slash" : "star")
                }
                // Only where it means something. Offering "Remove from Recent" while browsing
                // Trending would be a button that silently does nothing to what you are looking at.
                if category == .recent {
                    Button(role: .destructive) {
                        GifRecents.forget(g.url)
                        refreshLocalTab()
                    } label: {
                        Label("Remove from Recent", systemImage: "clock.badge.xmark")
                    }
                }
            }
    }

    /// Redraw immediately after editing a local list, but only when the list being edited is the one
    /// on screen — re-running the loader on Trending would throw away the page for no reason.
    private func refreshLocalTab() {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if category == .favorites { gifs = GifFavorites.all() }
        else if category == .recent { gifs = GifRecents.all() }
    }
}
