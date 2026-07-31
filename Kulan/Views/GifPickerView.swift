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
}

struct GifPickerView: View {
    let onPick: (GiphyService.Gif) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var gifs: [GiphyService.Gif] = []
    @State private var recents: [GiphyService.Gif] = []
    @State private var searchTask: Task<Void, Never>?   // debounce: don't hit Giphy on every keystroke
    @State private var category: GifCategory = .trending

    // The mood row — the standard GIF-picker categories (Giphy's own concept, every big messenger
    // has a version), drawn OUR way: our icons, accent tint, no copied glyph set. Each chip is a
    // ready-made search; Trending is the browse default.
    private enum GifCategory: CaseIterable {
        case trending, happy, love, sad, party, thumbsUp
        var icon: String {
            switch self {
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
            case .trending: return ""
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
        NavigationStack {
            ScrollView {
                // RECENTLY USED — instant, local, only while browsing Trending (a search or a
                // mood chip replaces it).
                if !recents.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty, category == .trending {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RECENTLY USED")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(recents) { g in
                                    AnimatedGifView(url: g.url)
                                        .frame(width: 92, height: 92)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .onTapGesture { pick(g) }
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(.top, 6)
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
                // Paint INSTANTLY from what we already have (recents + the cached trending page),
                // then refresh trending quietly behind it. The old version opened EMPTY and made
                // every open wait for the network — the "takes a bit to load" report.
                recents = GifRecents.all()
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
        dismiss()
    }

    // ONE loader for every state: a typed search wins; otherwise the selected mood; Trending = "".
    private func refresh() async {
        let q = query.trimmingCharacters(in: .whitespaces)
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
        .padding(.horizontal, 10).padding(.vertical, 6)
        // Opaque under the pinned row, or the grid shows through while scrolling beneath it.
        .background(Color(uiColor: .systemBackground))
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
    }
}
