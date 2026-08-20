//
//  CacheAsyncImage.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 1.05.2022.
//

import SwiftUI

/// ⛔ THE APP'S OWN PICTURE CACHE, LENT TO THIS PACKAGE.
///
/// StoryUI is a separate module and cannot see `DiskImageCache`, so this avatar used to know only
/// `URLCache.shared` — a cache nothing else in the app writes to. Every profile photo the app has
/// ever loaded, including the one it seeds the instant you change your own picture, was invisible
/// here. The owner's report is exactly that: the picture is right there in Settings, and the story
/// header still draws a grey disc and then goes to the network for a file it already has.
///
/// The app installs these at launch. Nil is a working configuration — it just means no shared cache.
public enum StoryUIImages {
    /// MEMORY ONLY, AND SYNCHRONOUS. The first frame has to be able to ask: one frame of grey is a
    /// visible flash on a header that appears with the story.
    public static var cachedNow: ((String) -> UIImage?)?
    /// Memory, then disk. Costs a frame on a disk hit, still far cheaper than the network.
    public static var cached: ((String) async -> UIImage?)?
    /// Hand back what was downloaded, so the next surface to ask gets a hit instead of a fetch.
    public static var store: ((UIImage, Data, String) -> Void)?
}

struct CacheAsyncImage: View {
    private let urlString: String?
    /// Seeded synchronously so a cached photo is on screen in the FIRST frame, with no grey at all.
    @State private var image: UIImage?

    init(urlString: String?) {
        self.urlString = urlString
        _image = State(initialValue: urlString.flatMap { StoryUIImages.cachedNow?($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.8)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        // ⚠️ `.task(id:)`, NOT A MODEL BUILT IN `init`. This used to hold an `@ObservedObject`
        // constructed in the initialiser, and this view's parent re-renders on the progress tick —
        // twenty times a second — so it built a fresh model, dropped the image it had, and started
        // another download, twenty times a second, for the whole story. `.task(id:)` runs once per
        // url and is cancelled with the view.
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        if image != nil { return }                                   // the sync seed already won
        if let shared = await StoryUIImages.cached?(urlString) {      // the app's cache, memory+disk
            image = shared
            return
        }
        if let hit = URLCache.shared.cachedResponse(for: .init(url: url)),
           let ui = UIImage(data: hit.data) {
            image = ui
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            // ⚠️ A 404 PAGE IS NOT A PHOTOGRAPH. Without this test the error body was written into
            // URLCache as if it were the picture, `UIImage(data:)` then answered nil for it, and the
            // avatar stayed grey for the life of the process with the cache refusing to re-fetch.
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let ui = UIImage(data: data) else { return }
            URLCache.shared.storeCachedResponse(.init(response: response, data: data),
                                                for: .init(url: url))
            StoryUIImages.store?(ui, data, urlString)
            image = ui
        } catch {
            // Cancelled or offline. Nothing to draw and nothing to remember: the next appearance
            // asks again, which is the behaviour a failed avatar should have.
        }
    }
}
