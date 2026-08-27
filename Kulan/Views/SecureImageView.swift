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
    /// THE INLINE THUMBNAIL, already decoded. Beats the hash whenever there is one: it is an actual
    /// small photo rather than a sketch of one, and it came inside the message, so it is ready
    /// before this view has asked the network for anything. Callers pass `message.previewImage`,
    /// which already resolves thumbnail-then-hash — the hash below stays for the places that have
    /// only that (a message sent before the thumbnail existed).
    var placeholderImage: UIImage? = nil
    // Chat photo bubbles pass true: the photos auto-download POLICY can hold the download
    // until tapped (blur + arrow shown). Everything already cached is untouched.
    var gated: Bool = false
    /// Opt in to the synchronous first-frame disk read. ONLY for small images (a link preview
    /// thumbnail, a document tile). A chat photo must not use it: decoding one on the main thread
    /// is exactly the scroll hitch the async path exists to avoid.
    var smallSync: Bool = false

    @State private var image: UIImage?
    @State private var failed = false
    @State private var waitingTap = false
    @State private var userRequested = false
    /// ⛔ THE DOWNLOAD'S OWN STATE, NOT A TIMER — his instruction 2026-08-27, and the reference's
    /// model exactly. Their `CVAttachmentProgressView` has four:
    ///
    ///     case none              — nothing is drawn
    ///     case tapToDownload     — the affordance
    ///     case unknownProgress   — a spinner, until the size is known
    ///     case progress(Float)   — a real ring, driven by bytes
    ///
    /// and they pick between them from the attachment's state: `.none/.failed → tapToDownload`,
    /// `.enqueuedOrDownloading → progress` when the byte count is known and `unknownProgress` when it
    /// is not. Ours is the same four, expressed as the two flags this view already had plus these:
    /// `downloading` says the bytes are moving RIGHT NOW, and `progress` is nil until the response
    /// says how many there are. Both are cleared on every path out of `load()`, so the indicator
    /// cannot outlive the download that owns it.
    @State private var downloading = false
    @State private var progress: Double?

    var body: some View {
        // Synchronous memory-cache read so an already-cached image renders on the FIRST frame
        // (the async path caused a one-frame skeleton flash even on a pure memory hit).
        // Memory is empty on every launch, so a small image that IS on disk still had nothing to
        // draw on its first frame and appeared a beat late (owner report on link previews).
        let shown = image ?? (smallSync ? DiskImageCache.shared.smallImageSync(imageUrl)
                                        : DiskImageCache.shared.memoryImage(imageUrl))
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
            } else if let preview = placeholderImage ?? placeholderHash.flatMap({ BlurHash.decode($0) }) {
                // Placeholder chain, best first: the inline thumbnail is a real (tiny) photo carried
                // inside the message, and the blurhash is a ~28-char sketch of one. Either beats a
                // grey skeleton while the bytes download.
                // ⛔ THE INDICATOR BELONGS ON THIS BRANCH TOO, and its absence here is the bug he
                // reported: "I see the placeholder but no loading indicator while it downloads."
                // Every photo of his carries a blurhash or an inline thumbnail, so every photo takes
                // THIS branch — and it only ever overlaid the tap affordance, never the spinner. The
                // shimmer at the bottom of this chain was the only progress this view had, and it is
                // on the branch that runs when there is nothing to draw, which for his messages is
                // never.
                Image(uiImage: preview).resizable().scaledToFill()
                    .overlay { stateOverlay }
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

    /// The reference's four states, chosen in their order of precedence: an affordance beats a
    /// spinner, and a finished picture draws neither (this whole overlay only exists while `shown`
    /// is nil).
    @ViewBuilder private var stateOverlay: some View {
        if waitingTap {
            downloadBadge
        } else if downloading {
            if let p = progress {
                progressRing(p)          // theirs: `progress(Float)`
            } else {
                unknownProgressSpinner   // theirs: `unknownProgress`
            }
        }
    }

    /// Their `CircularProgressView`: a ring that fills with the bytes, on a pill of dimmed backdrop
    /// so it reads on a light photo as well as a dark one. Starts at the top and turns clockwise.
    private func progressRing(_ p: Double) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.45)).frame(width: 44, height: 44)
            Circle().stroke(.white.opacity(0.3), lineWidth: 2.5).frame(width: 26, height: 26)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, p)))
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 26, height: 26)
                .animation(.linear(duration: 0.15), value: p)
        }
    }

    /// Before the response has said how big the file is there is no honest fraction to draw, so this
    /// is a plain spinner rather than a ring guessing at one — the same split theirs makes.
    private var unknownProgressSpinner: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45)).frame(width: 44, height: 44)
            ProgressView().progressViewStyle(.circular).tint(.white)
        }
    }

    private var downloadBadge: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 34))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.55))
    }

    private func load() async {
        // ⛔ ALREADY HERE MEANS NO INDICATOR, EVER. Both cache hits return before `downloading` is
        // ever set, so a photo the phone already holds draws on its first frame with nothing over it
        // — his requirement, and the reference's `.none` state.
        // Sync memory hit → instant (and clears any stale image left on a reused cell).
        if let mem = DiskImageCache.shared.memoryImage(imageUrl) { image = mem; failed = false; return }
        // Cell reuse: the url changed → drop the previous image so we never show the WRONG photo.
        image = nil; failed = false; progress = nil
        // Disk hit → show instantly, no network or decrypt.
        if let cached = await DiskImageCache.shared.image(for: imageUrl) { image = cached; return }
        // Photos auto-download policy: hold the network fetch until tapped.
        if gated, !userRequested, !AutoDownloadPrefs.allowedNow(.photos) {
            waitingTap = true
            return
        }
        guard let url = URL(string: imageUrl) else { return }
        // ⛔ THE INDICATOR IS RAISED HERE AND DROPPED ON EVERY WAY OUT. Past this line a request is
        // genuinely in flight, which is the only thing that should ever put a spinner on screen.
        downloading = true
        defer { downloading = false; progress = nil }
        do {
            // ⛔ THE SIZE GATE AND THE PROGRESS COME FROM THE SAME PLACE: the response. Nothing in a
            // message says how many bytes its photo is — `fileSize` exists only for documents, and
            // `EncMeta` carries keys, not lengths — so unlike the reference, which reads the size off
            // its attachment pointer before it asks for anything, we can only learn it from the
            // download itself. `totalBytesExpectedToWrite` arrives with the FIRST progress callback,
            // before the body has meaningfully transferred, so an over-limit photo is dropped after
            // its headers rather than after its megabytes.
            let probe = ImageDownloadProbe(
                limit: MediaAutoDownloader.photoAutoBytes,
                // A tap is consent: once he has asked for this picture, its size stops mattering.
                enforceLimit: gated && !userRequested)
            // ⚠️ THROUGH THE BINDING, NOT THE VIEW. URLSession calls the delegate on its own queue,
            // and this view is a struct — capturing it in an escaping callback captures a COPY whose
            // `@State` writes go nowhere. The projected binding is the handle that still points at
            // the live storage, and the hop puts the write on the main thread where SwiftUI needs it.
            let progressBinding = $progress
            probe.onProgress = { p in
                DispatchQueue.main.async { progressBinding.wrappedValue = p }
            }
            let (fileURL, _) = try await MediaSession.shared.download(from: url, delegate: probe)
            if probe.exceededLimit {
                // Not a failure — the picture is fine, it is just bigger than we download unasked.
                // Same destination as the policy hold above: the Download affordance.
                waitingTap = true
                return
            }
            let data = try Data(contentsOf: fileURL)
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
            // ⚠️ A CANCEL IS NOT A FAILURE. Refusing an over-limit photo cancels its task, and that
            // surfaces here as a thrown error — without this the picture would wear the broken-image
            // triangle instead of the Download button it is actually waiting behind.
            if waitingTap { return }
            failed = true
        }
    }
}

/// ⛔ WHERE THE REAL PROGRESS COMES FROM. `URLSession.data(from:)` hands back one finished blob and
/// says nothing on the way, which is why this view could only ever show a shimmer that meant "still
/// working" rather than anything about the download. The download API's delegate reports every
/// chunk, so the ring is drawn from bytes actually received.
///
/// ⚠️ IT ALSO ENFORCES THE SIZE CEILING, and it has to be done from in here rather than up front:
/// `totalBytesExpectedToWrite` is only known once the response lands, and the first callback carries
/// it. Cancelling there costs the headers and nothing else.
///
/// `@unchecked Sendable` because URLSession calls these on its own queue: `exceededLimit` is written
/// only here and read only after the await has returned, and `onProgress` hops to the main thread
/// itself before touching anything SwiftUI owns.
private final class ImageDownloadProbe: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let enforceLimit: Bool
    private(set) var exceededLimit = false
    var onProgress: ((Double?) -> Void)?

    init(limit: Int64, enforceLimit: Bool) {
        self.limit = limit
        self.enforceLimit = enforceLimit
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if enforceLimit, totalBytesExpectedToWrite > 0, totalBytesExpectedToWrite > limit {
            exceededLimit = true
            downloadTask.cancel()
            return
        }
        // A server that sends no Content-Length leaves this at -1, and there is no honest fraction to
        // draw from that — nil is the reference's `unknownProgress`, and the view shows a spinner.
        onProgress?(totalBytesExpectedToWrite > 0
                    ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                    : nil)
    }

    /// Required by the protocol. The async `download(from:delegate:)` hands the file back as its
    /// return value and manages its lifetime, so there is deliberately nothing to do here.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
