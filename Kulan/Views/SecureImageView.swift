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
    var placeholderHash: String? = nil   // BlurHash → a real blurred preview instead of the gray shimmer
    // Chat photo bubbles pass true: the photos auto-download POLICY can hold the download
    // until tapped (blur + arrow shown). Everything already cached is untouched.
    var gated: Bool = false

    @State private var image: UIImage?
    @State private var failed = false
    @State private var waitingTap = false
    @State private var userRequested = false

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
            } else if let hash = placeholderHash, let blur = BlurHash.decode(hash) {
                // Placeholder chain: a recognizable blur of the ACTUAL photo (decoded from the
                // ~28-char hash that travels in the message) beats a gray skeleton while bytes download.
                Image(uiImage: blur).resizable().scaledToFill()
                    .overlay { if waitingTap { downloadBadge } }
            } else if waitingTap {
                Rectangle().fill(Color.gray.opacity(0.18)).overlay { downloadBadge }
            } else if DiskImageCache.shared.isCached(imageUrl) {
                // ALREADY ON DISK — this is a decode, not a download, so it lands within a frame or two.
                // A shimmer here was actively misleading: it says "waiting on the network" for a file the
                // phone has had for a week, and it fired on EVERY relaunch and every app switch because
                // the only synchronous check available was memory-only. Hold a calm blank instead, so the
                // image simply appears. Skeleton.swift's own contract says the shimmer is for a cold load;
                // this restores that meaning.
                Color.clear
            } else {
                SkeletonFill()   // shimmer skeleton while genuinely downloading
            }
        }
        .onTapGesture {
            // Only intercepts while the policy is holding the download; a loaded image's
            // taps pass through to the bubble's own open-viewer gesture as before.
            if waitingTap { userRequested = true; waitingTap = false; Task { await load() } }
        }
        .allowsHitTesting(waitingTap)   // transparent to taps unless the download is held
        .task(id: imageUrl) { await load() }
    }

    private var downloadBadge: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 34))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.55))
    }

    private func load() async {
        // Sync memory hit → instant (and clears any stale image left on a reused cell).
        if let mem = DiskImageCache.shared.memoryImage(imageUrl) { image = mem; failed = false; return }
        // Cell reuse: the url changed → drop the previous image so we never show the WRONG photo.
        image = nil; failed = false
        // Disk hit → show instantly, no network or decrypt.
        if let cached = await DiskImageCache.shared.image(for: imageUrl) { image = cached; return }
        // Photos auto-download policy: hold the network fetch until tapped.
        if gated, !userRequested, !AutoDownloadPrefs.allowedNow(.photos) {
            waitingTap = true
            return
        }
        guard let url = URL(string: imageUrl) else { return }
        do {
            let (data, _) = try await MediaSession.shared.data(from: url)
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
                // Display + memory-cache a display-BOUNDED bitmap (display-decode buckets: a 12MP photo
                // shouldn't live as a 48MB bitmap per bubble); the ORIGINAL bytes go to disk untouched.
                let bounded = ui.boundedForDisplay()
                // owned: this is a CHAT photo, and once the mailman starts deleting server copies
                // this file is the only one left. It must survive the 250MB trim, Keep Media and
                // Clear Cache, exactly like VideoCache and AudioCache already do.
                DiskImageCache.shared.store(bounded, data: clearBytes, for: imageUrl, owned: true)
                image = bounded
            } else { failed = true }
        } catch {
            failed = true
        }
    }
}
