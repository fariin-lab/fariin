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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(gifs) { g in
                        AnimatedGifView(url: g.url)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            // Tap lives on a pure-SwiftUI overlay: a gesture attached to the
                            // UIKit-backed gif view itself can silently never fire (hit-testing
                            // falls into the UIImageView, which doesn't accept touches).
                            .overlay {
                                Color.clear.contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .onTapGesture { onPick(g); dismiss() }
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
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 5) {
                    Text("POWERED BY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text("GIPHY").font(.system(size: 12, weight: .heavy)).foregroundStyle(.primary)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .task { if gifs.isEmpty { gifs = await GiphyService.shared.search("") } }
        }
    }
}
