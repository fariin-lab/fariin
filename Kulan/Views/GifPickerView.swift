import SwiftUI

// Custom GIF picker (our own design) — searches Giphy via GiphyService and shows an animated
// grid. The small "Powered by GIPHY" attribution is required by Giphy's free terms.
struct GifPickerView: View {
    let onPick: (GiphyService.Gif) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var gifs: [GiphyService.Gif] = []
    @State private var searchTask: Task<Void, Never>?   // debounce: don't hit Giphy on every keystroke

    var body: some View {
        NavigationStack {
            ScrollView {
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
            .searchable(text: $query, prompt: "Search GIFs")
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)   // 300ms debounce
                    if Task.isCancelled { return }
                    let results = await GiphyService.shared.search(q)
                    if !Task.isCancelled { gifs = results }
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
            .task { if gifs.isEmpty { gifs = await GiphyService.shared.search("") } }
        }
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
                    .onTapGesture { onPick(g); dismiss() }
            }
    }
}
