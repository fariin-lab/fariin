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
    /// INLINE = the panel that takes the keyboard's place, rather than a page of its own.
    ///
    /// Read from their source before building it (2026-08-13, on his "read telegram first"): their
    /// composer has ONE input mode at a time — `.text` is the keyboard, `.stickers` is this — and one
    /// accessory button that flips between them (`accessoryItemButtonPressed`: mode `.keyboard`
    /// switches back to `.text`, mode `.stickers` calls `openStickers()`). The panel is sized
    /// `keyboardHeight + predictiveInputHeight` for the device, which is why it lands in exactly the
    /// keyboard's slot rather than near it.
    ///
    /// So this view drops its page chrome when inline: no navigation stack, no title, no X — a
    /// panel is not a screen. ⚠️ And `dismiss()` must never fire in this mode: there is no
    /// presentation to close, so the environment's dismiss would reach the CHAT and pop it.
    var inline = false
    /// Inline only: the magnifier opens the full picker as a sheet, because searching wants a
    /// keyboard and the panel is standing in the keyboard's place — see `inlineTopRow`.
    var onSearch: (() -> Void)? = nil
    /// Inline only: is the grid scrolled to its top? The expand drag reads it — see the panel's
    /// gesture in ThreadView. A drag only becomes an expand when the grid has nowhere left to go,
    /// which is how their direction lock and their scroll view avoid fighting over one finger.
    var atTop: Binding<Bool>? = nil
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
    @MainActor static var trendingCache: [GiphyService.Gif] = []

    var body: some View {
        if inline { inlineBody } else { pageBody }
    }

    /// The keyboard-slot panel: the mood row, the grid, and a search field where the keyboard's own
    /// bottom row would be. Same grid, same loader, same picks — only the chrome differs.
    private var inlineBody: some View {
        VStack(spacing: 0) {
            inlineTopRow
            ScrollView {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<2, id: \.self) { col in
                        LazyVStack(spacing: 4) {
                            ForEach(masonryColumns[col]) { g in gifCell(g) }
                        }
                    }
                }
                .padding(6)
            }
            .scrollDismissesKeyboard(.immediately)
            .onScrollGeometryChange(for: Bool.self,
                                    of: { $0.contentOffset.y <= 0.5 },
                                    action: { _, top in atTop?.wrappedValue = top })
            // FLOATING, THE WAY THE ATTACHMENT SOURCES FLOAT (his call, 2026-08-14: "make it like
            // the one you did on the plus photos"). A bottom inset rather than a row: the grid keeps
            // its full height and takes the bar's height as content inset, so nothing is hidden at
            // rest and the GIFs pass UNDER the glass while you scroll.
            //
            // The moods sit at the bottom in a panel, where the keyboard's own bottom row is and
            // where the thumb already is. At the top they were where the eye lands, competing with
            // the GIFs for the first look.
            .safeAreaInset(edge: .bottom, spacing: 0) { floatingMoodBar }
        }
        // ⚠️ A PANEL IN THE KEYBOARD'S SLOT NEEDS THE KEYBOARD'S SURFACE (his 571 screenshot: the
        // search row and the strip under it showing the chat wallpaper straight through). It had no
        // background of its own, so everything that was not a GIF was a hole. The keyboard it stands
        // in for is opaque, and so is this.
        .background(Color(uiColor: .secondarySystemBackground))
        .task {
            if gifs.isEmpty, !Self.trendingCache.isEmpty { gifs = Self.trendingCache }
            let fresh = await GiphyService.shared.search("")
            if !fresh.isEmpty {
                Self.trendingCache = fresh
                if query.trimmingCharacters(in: .whitespaces).isEmpty, category == .trending { gifs = fresh }
            }
        }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }

    /// SEARCH IS A BUTTON HERE, NOT A FIELD (his reference: "if you tap search it opens a full sheet
    /// for search"). A field at the bottom of the panel was the wrong shape twice over — typing in it
    /// raises the keyboard, and the keyboard is the thing this panel replaced, so the two fight over
    /// one slot. The magnifier hands the job to the full picker, which has a navigation stack and can
    /// hold a real search bar.
    private var inlineTopRow: some View {
        HStack(spacing: 10) {
            Button { onSearch?() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            // Required by Giphy's terms wherever their results are shown.
            Text("GIPHY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var pageBody: some View {
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
            .navigationTitle("GIF")
            .navigationBarTitleDisplayMode(.inline)
            // SOLID header (owner's 416 report: "can see scrolling the gifts" through the glass).
            // iOS 26 glasses every title bar by default; on this sheet the grid slid visibly
            // behind the X / title / chips, so the whole top reads as one opaque white card.
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
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
                    if query.trimmingCharacters(in: .whitespaces).isEmpty, category == .trending { gifs = fresh }
                }
            }
        }
    }

    // One exit for every pick: remember it for the Recently-used row, hand it over, close.
    private func pick(_ g: GiphyService.Gif) {
        GifRecents.note(g)
        onPick(g)
        // ⚠️ NOT INLINE. As a panel there is no presentation of its own to close, and the
        // environment's dismiss would travel up and pop the CHAT. The panel also stays open on
        // purpose — sending several GIFs in a row is the whole point of it being a keyboard.
        if !inline { dismiss() }
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

    /// The panel's mood bar: the same buttons, on one piece of glass, floating over the grid. The
    /// page version keeps the plain pinned row — it has a navigation bar over it and a second
    /// floating shape under that would be one too many.
    private var floatingMoodBar: some View {
        categoryButtons
            .padding(.horizontal, 6).padding(.vertical, 4)
            .liquidGlass(Capsule())
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    private var categoryRow: some View {
        categoryButtons
            .padding(.horizontal, 10).padding(.vertical, 6)
            // Opaque under the pinned row, or the grid shows through while scrolling beneath it.
            .background(Color(uiColor: .systemBackground))
    }

    private var categoryButtons: some View {
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
