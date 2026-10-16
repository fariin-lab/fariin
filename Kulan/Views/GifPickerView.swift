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
    /// ⛔ INSIDE THE ATTACH SHEET — owner 2026-10-15, with a picture: "the same as Location: GIF opens
    /// in the sheet, a back button top left goes back to the photos". Embedded, this is a layer of the
    /// attach sheet (ThreadView `attachGif`): the grid edge to edge, the mood row floating at the
    /// bottom, a glass back top-left and search top-right. Loading, recents, favourites, the masonry
    /// and the cells are the same code as the full page.
    var embedded: Bool = false
    var onBack: (() -> Void)? = nil
    var onWantsFullHeight: (() -> Void)? = nil
    @State private var searching = false
    /// Drives `NativeSearchField` (a UIKit field, so a plain flag rather than @FocusState).
    @State private var searchFocused = false
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked = false   // 2026-09-24 decision D-composer-5: see `pick`
    @State private var gifs: [GiphyService.Gif] = []
    @State private var searchTask: Task<Void, Never>?   // debounce: don't hit Giphy on every keystroke
    @State private var category: GifCategory = .trending
    /// The last Giphy fetch came back with nothing (no network, or nothing matched). See `refresh`.
    @State private var fetchCameBackEmpty = false

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
        if embedded { embeddedBody } else { pageBody }
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
                // A search or mood with no network used to leave a blank page with nothing on it
                // (audit, 2026-09-24). A typed search says there were no results; a mood or
                // Trending is never legitimately empty, so it says it could not load.
                if fetchCameBackEmpty, gifs.isEmpty {
                    let q = query.trimmingCharacters(in: .whitespaces)
                    Group {
                        if q.isEmpty {
                            ContentUnavailableView("Could not load", systemImage: "wifi.slash")
                        } else {
                            ContentUnavailableView.search(text: q)
                        }
                    }
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
            // ⛔ INLINE, AND WITHOUT THIS LINE THERE IS AN EMPTY WHITE BAND UNDER THE HEADER — owner,
            // 2026-08-24, circled. Nothing draws that band: with no display mode stated, iOS uses the
            // LARGE title layout and reserves the large-title strip beneath the bar. The title here is
            // a `.principal` toolbar item, so that reserved strip has nothing in it and renders as a
            // gap between "Choose GIF" and the mood pills. Inline is the layout this header was drawn
            // for anyway — one bar, title centred in it.
            .navigationBarTitleDisplayMode(.inline)
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
                    ToolbarItem(placement: .topBarLeading) { CloseXButton(diameter: 44) { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { CloseXButton(diameter: 44) { dismiss() } }
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
            .task { await loadFirst() }
        }
    }

    /// Paint INSTANTLY from the cached trending page, then refresh quietly behind it. The old
    /// version opened EMPTY and made every open wait for the network.
    private func loadFirst() async {
        if gifs.isEmpty, !Self.trendingCache.isEmpty { gifs = Self.trendingCache }
        let fresh = await GiphyService.shared.search("")
        if !fresh.isEmpty {
            Self.trendingCache = fresh
            Self.saveTrendingToDisk(fresh)
            if query.trimmingCharacters(in: .whitespaces).isEmpty, category == .trending { gifs = fresh }
        } else if gifs.isEmpty, category == .trending {
            fetchCameBackEmpty = true   // opened offline with nothing cached
        }
    }

    // MARK: - Inside the attach sheet

    private var embeddedBody: some View {
        // ⛔ APPLE'S OWN BAR ON TOP, A SYSTEM BAR BELOW — owner 2026-10-15, two pictures: "the header
        // uses a custom blur, use the native iOS 26 blur", and for the mood bar "content inside the
        // safe area is app content; the bar is system chrome, edge-attached".
        //
        // TOP: a real navigation bar (title, X, search as toolbar items). Its iOS 26 scroll-edge
        // blur is the system's, drawn by the system; the hand-made header with its own material
        // and fade is gone, and so is the `safeAreaBar` the system effect did not show under.
        //
        // BOTTOM: the mood capsule (the media tabs' look) sits in its own strip UNDER the grid, on
        // the sheet's background. The GIFs end above it and never pass beneath it.
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    emptyStates
                    // Room at the screen's sides (owner 2026-10-15: "the GIFs touch left and right").
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(0..<2, id: \.self) { col in
                            LazyVStack(spacing: 6) {
                                ForEach(masonryColumns[col]) { g in gifCell(g) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                categoryRow
                    .padding(.top, 8)
            }
            .navigationTitle(searching ? "" : "Choose GIF")
            .navigationBarTitleDisplayMode(.inline)
            // ⛔ APPLE'S SEARCH FIELD, FULL WIDTH, WITH THE ROUND X BESIDE IT — owner 2026-10-16, with
            // the system sticker search as the picture: "use native". The bar goes while searching and
            // this row takes its place: `UISearchTextField` itself (the system's magnifier, placeholder
            // and clear button, left-aligned) and the app's one glass X that ends the search.
            .toolbar(searching ? .hidden : .visible, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if searching {
                    HStack(spacing: 10) {
                        NativeSearchField(text: $query, placeholder: "Search GIFs", focused: $searchFocused)
                            .frame(height: 48)
                        CloseXButton(diameter: 48) {
                            searchFocused = false
                            query = ""
                            withAnimation(.easeInOut(duration: 0.2)) { searching = false }
                        }
                        .accessibilityLabel("Close search")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                }
            }
            .toolbar {
                if !searching {
                    // An X that closes the sheet (owner 2026-10-15), not a back chevron.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onBack?() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { searching = true }
                            onWantsFullHeight?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { searchFocused = true }
                        } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search GIFs")
                    }
                }
            }
        }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)   // 300ms debounce
                if Task.isCancelled { return }
                await refresh()
            }
        }
        .task { await loadFirst() }
    }

    /// The empty / offline / no-result pages, shared by both layouts.
    @ViewBuilder private var emptyStates: some View {
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
        if fetchCameBackEmpty, gifs.isEmpty {
            let q = query.trimmingCharacters(in: .whitespaces)
            Group {
                if q.isEmpty {
                    ContentUnavailableView("Could not load", systemImage: "wifi.slash")
                } else {
                    ContentUnavailableView.search(text: q)
                }
            }
            .padding(.top, 40)
        }
    }

    // One exit for every pick: remember it for the Recently-used row, hand it over, close.
    private func pick(_ g: GiphyService.Gif) {
        // 2026-09-24 decision D-composer-5: one send per open, like PollComposerSheet.sent. A second
        // tap during the dismiss animation sent a second GIF.
        guard !picked else { return }
        picked = true
        GifRecents.note(g)
        onPick(g)
        // Embedded, the attach sheet closes itself (its owner hides it); `dismiss` here would reach
        // past the sheet to whatever presented the chat.
        if !embedded { dismiss() }
    }

    // ONE loader for every state: a typed search wins; otherwise the selected mood. Recent is
    // local (the device's own sent list) — instant, no network; Trending = "".
    private func refresh() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        // The two local tabs answer from the device, so they are instant and work offline.
        if q.isEmpty, category == .recent {
            fetchCameBackEmpty = false
            gifs = GifRecents.all()
            return
        }
        if q.isEmpty, category == .favorites {
            fetchCameBackEmpty = false
            gifs = GifFavorites.all()
            return
        }
        let results = await GiphyService.shared.search(q.isEmpty ? category.term : q)
        if !Task.isCancelled { gifs = results; fetchCameBackEmpty = results.isEmpty }
    }

    private var categoryRow: some View { categoryButtons.floatingGlass() }

    private var categoryButtons: some View {
        HStack(spacing: 0) {
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
                    // ⛔ THE MEDIA TABS' LOOK — owner 2026-10-15, a picture of the Media / Files / Voice
                    // bar: "make the bottom bar look like this". Same pieces as `MediaTabBar`: the
                    // chosen one on the system's selected-segment fill in a capsule, its glyph in the
                    // label colour, the rest in the secondary label colour; no accent tint.
                    Image(systemName: c.icon)
                        .font(.system(size: 17, weight: category == c ? .semibold : .regular))
                        .foregroundStyle(category == c ? Color(uiColor: .label) : Color(uiColor: .secondaryLabel))
                        .frame(maxWidth: .infinity).frame(height: 42 - 8)
                        .background {
                            if category == c {
                                Capsule().fill(Color(uiColor: .tertiarySystemFill))
                            }
                        }
                        .contentShape(Capsule())
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

private extension View {
    /// The mood row's own glass capsule where it floats over the grid (the search layout).
    /// The media tabs' capsule (`MediaTabBar`): 4pt around the pill, 42pt tall, glass, 16pt in from
    /// the screen's sides.
    func floatingGlass() -> some View {
        padding(4)
            .frame(height: 42)
            .liquidGlass(Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }
}

/// The system's own search field (`UISearchTextField`): magnifier, left-aligned placeholder, clear
/// button, the iOS 26 capsule. Owner 2026-10-16 ("use native"). `focused` raises and drops the
/// keyboard; typing writes `text`.
struct NativeSearchField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool

    func makeUIView(context: Context) -> UISearchTextField {
        let f = UISearchTextField()
        f.placeholder = placeholder
        f.returnKeyType = .search
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateUIView(_ f: UISearchTextField, context: Context) {
        if f.text != text { f.text = text }
        if focused, !f.isFirstResponder { DispatchQueue.main.async { f.becomeFirstResponder() } }
        if !focused, f.isFirstResponder { f.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeSearchField
        init(_ p: NativeSearchField) { parent = p }
        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }
        func textFieldShouldReturn(_ f: UITextField) -> Bool { f.resignFirstResponder(); return true }
        func textFieldDidBeginEditing(_ f: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ f: UITextField) { if parent.focused { parent.focused = false } }
    }
}
