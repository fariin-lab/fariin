import SwiftUI
import UIKit

// Downloads the encrypted bytes and decrypts them locally (the server only ever
// stored ciphertext), then caches the decrypted image to memory + disk via
// DiskImageCache — so reopening the chat or relaunching the app loads it INSTANTLY
// from local storage (and it stays viewable offline). Shows a shimmer while loading.
struct SecureImageView: View {
    let imageUrl: String
    let enc: EncMeta?
    let cid: String
    var fill: Bool = true

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        // Synchronous memory-cache read so an already-cached image renders on the FIRST frame
        // (the async path caused a one-frame skeleton flash even on a pure memory hit).
        let shown = image ?? DiskImageCache.shared.memoryImage(imageUrl)
        return ZStack {
            if let shown {
                if fill {
                    Image(uiImage: shown).resizable().scaledToFill()
                } else {
                    Image(uiImage: shown).resizable().scaledToFit()
                }
            } else if failed {
                Rectangle().fill(Color.gray.opacity(0.18))
                    .overlay { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
            } else {
                SkeletonFill()   // shimmer skeleton while loading (replaces the spinner)
            }
        }
        .task(id: imageUrl) { await load() }
    }

    private func load() async {
        // Sync memory hit → instant (and clears any stale image left on a reused cell).
        if let mem = DiskImageCache.shared.memoryImage(imageUrl) { image = mem; failed = false; return }
        // Cell reuse: the url changed → drop the previous image so we never show the WRONG photo.
        image = nil; failed = false
        // Disk hit → show instantly, no network or decrypt.
        if let cached = await DiskImageCache.shared.image(for: imageUrl) { image = cached; return }
        guard let url = URL(string: imageUrl) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            var ui: UIImage?
            var clearBytes: Data?
            if let enc {
                if let clear = await Crypto.shared.decryptBytes(cid, cipher: data, meta: enc) {
                    ui = UIImage(data: clear); clearBytes = clear
                }
            } else {
                ui = UIImage(data: data); clearBytes = data
            }
            if let ui {
                // Display + memory-cache a display-BOUNDED bitmap (Signal's decode buckets: a 12MP photo
                // shouldn't live as a 48MB bitmap per bubble); the ORIGINAL bytes go to disk untouched.
                let bounded = ui.boundedForDisplay()
                DiskImageCache.shared.store(bounded, data: clearBytes, for: imageUrl)   // decrypted, file-protected on disk
                image = bounded
            } else { failed = true }
        } catch {
            failed = true
        }
    }
}
