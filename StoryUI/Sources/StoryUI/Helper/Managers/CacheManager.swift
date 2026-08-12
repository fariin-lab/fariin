//
//  CacheManager.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 30.04.2022.
//

@preconcurrency import AVFoundation

public enum Result<T> {
    case success(T)
    case failure(String)
}

/// App-side seeding: the story UPLOADER holds the exact bytes its download URL will return, so it
/// can put them where `CacheManager.loadVideo` looks and the just-posted story plays with zero
/// network instead of re-downloading its own upload. Public because the poster lives in the app
/// target; CacheManager itself stays internal.
public enum StoryVideoSeed {
    public static func seed(_ data: Data, for remoteURL: URL) {
        guard data.count > 4096 else { return }   // below isUsableCacheFile's floor it would only wedge the cache
        // Same home as every other story file now — see `StoryStorage`. The seed and the reader have
        // to agree on the directory or a just-posted story re-downloads its own upload.
        let dir = StoryStorage.directory("VideoCache")
        let file = dir.appendingPathComponent(CacheManager.cacheFileName(for: remoteURL))
        try? data.write(to: file, options: .atomic)
    }
}

/// The same idea for a PICTURE, and it exists for one case in particular: a url whose bytes are not
/// on any server.
///
/// ⚠️ URLCache ALONE IS NOT A PLACE TO KEEP SOMETHING YOU CANNOT RE-FETCH. It is an LRU cache the
/// system prunes whenever it likes, and `ImageLoader`'s own header says so ("survives app relaunches,
/// unlike URLCache, which evicts"). For a real Storage url an eviction costs a re-download and
/// nothing else. The UPLOADING PLACEHOLDER is not a real url — the app invents
/// `https://fariin.local/uploading-<uuid>.jpg` and seeds the composed poster under it — so an
/// eviction there has nowhere to fall back to and no network that could answer. The card goes blank
/// for the rest of the upload, which is exactly the window the placeholder exists to fill.
///
/// Writing both means the lookup order in `ImageLoader` (URLCache, then `StoryDiskCache`) always has
/// a second answer. Same bytes in both, so whichever one replies the picture is identical.
public enum StoryImageSeed {
    public static func seed(_ data: Data, for url: URL, mimeType: String = "image/jpeg") {
        guard !data.isEmpty else { return }
        let resp = URLResponse(url: url, mimeType: mimeType,
                               expectedContentLength: data.count, textEncodingName: nil)
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data),
                                            for: URLRequest(url: url))
        StoryDiskCache.store(data, for: url)
    }
}

final class CacheManager: NSObject {

    private let fileManager = FileManager.default

    // Firebase-style download URLs percent-encode the whole object path into ONE component
    // ("stories%2Fid%2Fvideo.mp4"); lastPathComponent DECODES it back to a string WITH slashes,
    // so using it as a filename pointed into directories that don't exist — the cache move threw
    // and every remote video spun forever. Flatten to a single safe, unique-per-object name.
    static func cacheFileName(for url: URL) -> String {
        let raw = url.lastPathComponent.isEmpty ? String(url.absoluteString.hashValue) : url.lastPathComponent
        return raw.replacingOccurrences(of: "/", with: "_")
    }

    /// A CACHED VIDEO COUNTS ONLY IF THERE ARE BYTES IN IT.
    ///
    /// Existence used to be the whole test, and that is a permanent wedge: a download killed
    /// mid-move, or an error body written to disk, leaves a file that EXISTS. Every later open then
    /// "finds" it, hands AVPlayer something it cannot play, and — because the only thing that ever
    /// takes the spinner down is playback STARTING — the story wheels forever and never downloads
    /// again. One bad moment on the network and that story is dead on this device for good.
    static func isUsableCacheFile(_ file: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 4096   // no real video is this small; a truncated file or an error page is
    }

    /// The usable cache file for this url, or nil. The synchronous question `startVideo` asks to
    /// decide whether the veil carries a spinner (bytes are actually missing) or only a cover (the
    /// clip is on disk). The reference app keys its loading shimmer on exactly this — whether the media is
    /// fetched — never on player readiness, which is why a cached story there never shows a loading
    /// state at all. Same name, same directory, same size floor as `loadVideo`: two answers that
    /// could drift apart would put the wheel back on cached clips.
    /// Stop every speculative transfer still running. The viewer is gone, so nothing in flight was
    /// asked for by anybody who is still looking — and until this existed there was no way to say so
    /// anywhere in the app: close a ring after reaching its last item and the phone kept pulling the
    /// whole lookahead, 15 to 25MB, with the app back in a chat list.
    static func cancelAllDownloads() { VideoDownloads.cancelAll() }

    static func cachedFileIfUsable(for url: URL) -> URL? {
        let file = StoryStorage.directory("VideoCache").appendingPathComponent(cacheFileName(for: url))
        guard FileManager.default.fileExists(atPath: file.path), isUsableCacheFile(file) else { return nil }
        return file
    }

    /// `speculative`: this video is being fetched for a story nobody has asked to watch yet, so it
    /// stands down on a metered or Low Data Mode connection. WITHOUT THIS THE RULE WAS BACKWARDS.
    /// `StoryPrefetcher.warmImage` already refused to pull a 200 KB photo on a constrained network
    /// while `warmVideo` went straight through this method and happily pulled sixteen megabytes,
    /// because a bare `downloadTask(with: url)` carries no request configuration at all. On the
    /// expensive mobile data a lot of this app's users are on, that was the single most costly
    /// thing the app did without being asked.
    /// `allowsCellular`: whether a SPECULATIVE fetch may go out over mobile data. Off by default —
    /// the blanket refusal this parameter replaces. The story lookahead turns it on for the next
    /// clip or two, because a video you are two taps away from is barely a guess; everything else
    /// speculative stays on Wi-Fi. Low Data Mode is refused either way: that switch is the person
    /// telling the system to spend nothing it does not have to.
    ///
    /// `onTask`: the download, handed back so the caller can cancel it if the reason for wanting it
    /// goes away. A cancelled speculative download is data not spent on a story that was skipped.
    func loadVideo(from url: URL, speculative: Bool = false, allowsCellular: Bool = false,
                   onTask: ((URLSessionTask) -> Void)? = nil,
                   completion: @escaping (Result<URL>) -> Void) {
        switch createCacheDirectory() {
        case .success(let cacheDirectory):
            let videoFileName = Self.cacheFileName(for: url)
            let destinationUrl = cacheDirectory.appendingPathComponent(videoFileName)

            if fileManager.fileExists(atPath: destinationUrl.path) {
                if Self.isUsableCacheFile(destinationUrl) {
                    // A HIT ON THE MAIN THREAD ANSWERS ON THE MAIN THREAD, NOW. The unconditional
                    // hop cost a fully-downloaded clip one guaranteed runloop turn behind the
                    // loading veil — a spinner frame for a video that was already on disk (his
                    // "already i downloaded but still is loading"). Off-main callers keep the hop.
                    if Thread.isMainThread {
                        completion(.success(destinationUrl))
                    } else {
                        DispatchQueue.main.async { completion(.success(destinationUrl)) }
                    }
                } else {
                    // Clear the wedge, then fetch it properly.
                    try? fileManager.removeItem(at: destinationUrl)
                    downloadAndCacheVideo(from: url, to: destinationUrl, speculative: speculative,
                                          allowsCellular: allowsCellular, onTask: onTask,
                                          completion: completion)
                }
            } else {
                // ⚠️ THE ARGUMENTS BELONG HERE MOST OF ALL. This is the branch taken when the file
                // is NOT on disk — which is EVERY prefetch that actually downloads anything. It was
                // left passing the defaults (`allowsCellular: false`, `onTask: nil`) while the
                // wedge-retry branch above got them, so the whole cellular lookahead was inert (the
                // request refused mobile data no matter what the prefetcher asked for) and
                // `StoryPrefetcher.running` stayed empty, leaving `cancelStaleWindow` with nothing
                // to cancel. Both features read as working in their own files and did nothing.
                downloadAndCacheVideo(from: url, to: destinationUrl, speculative: speculative,
                                      allowsCellular: allowsCellular, onTask: onTask,
                                      completion: completion)
            }
        case .failure(let error):
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }
}

extension FileManager: @unchecked @retroactive Sendable {}

/// ⚠️ ONE DOWNLOAD PER URL, FOR THE WHOLE PROCESS — and this is where the wasted mobile data went.
///
/// `CacheManager` had no in-flight registry at all. The only dedup lived in `StoryPrefetcher.claim`,
/// which guards the PREFETCHER'S OWN instance, while `VideoLoader` builds a `CacheManager` of its
/// own. So arriving at a story whose lookahead was still running found no file on disk and started a
/// SECOND full download of the same clip — which is the normal case, since the lookahead exists
/// precisely to be running when you get there. A 6MB clip cost 12MB, and when the two finished
/// together they raced over the same destination path: the loser's `moveItem` threw, reported
/// failure, and the live player then streamed the remote url a third time.
///
/// Joining instead of starting also fixes a quieter one. The old completion began
/// `guard let self else { return }`, and `self` was the per-view `CacheManager` — so closing the
/// viewer mid-download meant the bytes were paid for in full and then dropped on the floor without
/// ever being written. Nothing here belongs to a view, so a download always finishes into the cache.
private enum VideoDownloads {
    private static let lock = NSLock()
    private static var waiting: [URL: [(Result<URL>) -> Void]] = [:]
    private static var tasks: [URL: URLSessionTask] = [:]

    /// TRUE if this caller should start the transfer; FALSE if it merely joined one already running.
    static func join(_ url: URL, _ completion: @escaping (Result<URL>) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            return false
        }
        waiting[url] = [completion]
        return true
    }

    static func remember(_ url: URL, task: URLSessionTask) {
        lock.lock(); tasks[url] = task; lock.unlock()
    }

    /// Every joiner gets the same answer, once, on the main thread.
    static func finish(_ url: URL, _ result: Result<URL>) {
        lock.lock()
        let callbacks = waiting.removeValue(forKey: url) ?? []
        tasks.removeValue(forKey: url)
        lock.unlock()
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }

    /// Stop everything still in flight. The viewer is gone; nothing running was asked for by anyone
    /// who is still looking.
    static func cancelAll() {
        lock.lock()
        let running = tasks
        tasks.removeAll()
        waiting.removeAll()
        lock.unlock()
        running.values.forEach { $0.cancel() }
    }
}


private extension CacheManager {

    /// `StoryStorage` owns the location now, along with the file protection, the backup exclusion and
    /// the one-time move off `Caches`. The body this replaces created `Caches/VideoCache`, which iOS
    /// reclaims under storage pressure and does not carry across an app update — his "when i update
    /// the app story chache i loss". The seeder (`StoryVideoSeed`) asks the same helper for the same
    /// name, because a seeder and a reader that disagree about the directory means a just-posted
    /// story re-downloads its own upload.
    func createCacheDirectory() -> Result<URL> {
        .success(StoryStorage.directory("VideoCache"))
    }

    func downloadAndCacheVideo(from url: URL, to destinationUrl: URL, speculative: Bool,
                               allowsCellular: Bool = false,
                               onTask: ((URLSessionTask) -> Void)? = nil,
                               completion: @escaping (Result<URL>) -> Void) {
        // ⚠️ JOIN, DO NOT START A SECOND ONE. A caller that arrives while this url is already coming
        // down is added to the waiting list and answered with everybody else. It is deliberately NOT
        // handed the task: the one who started it owns cancelling it, so a speculative warm cannot
        // cancel a download the live player has since joined.
        guard VideoDownloads.join(url, completion) else { return }
        let backgroundQueue = DispatchQueue.global(qos: .background)

        backgroundQueue.async { [weak self] in
            // THE SHARED SESSION, WITH NO DELEGATE OF OUR OWN. This used to build a fresh URLSession
            // per download and hand it a delegate whose entire job was
            //     URLCredential(trust: challenge.protectionSpace.serverTrust!)
            // and that force unwrap is the build 454 crash. `serverTrust` is nil for every challenge
            // that is not a server-trust one — a proxy, a captive portal, a basic-auth or
            // client-certificate challenge — so on those networks the app died in a Swift trap
            // (EXC_BREAKPOINT) the moment a story video started downloading.
            //
            // It was also accepting ANY certificate without evaluating it, which is a
            // man-in-the-middle hole rather than a feature. Deleting it restores URLSession's own
            // TLS validation, which is correct for the plain HTTPS these files come from — and each
            // download no longer leaks a session that is never invalidated.
            let session = URLSession.shared
            // A REQUEST, NOT A BARE URL. `downloadTask(with: url)` builds a default request that
            // ignores every network policy, which is why the speculative flag had nowhere to live.
            var request = URLRequest(url: url)
            if speculative {
                // On a refused connection the task simply fails and the story loads when you reach
                // it, which is exactly where we were before prefetching existed — no worse, just not
                // expensive.
                //
                // ⚠️ BOTH LINES, NOT JUST THE FIRST. `allowsConstrainedNetworkAccess` refuses Low
                // Data Mode, which hardly anybody has on; `allowsExpensiveNetworkAccess` is the one
                // that refuses CELLULAR. With only the first set this read as a mobile-data guard
                // and was not one, and a speculative clip is the biggest thing the app fetches
                // without being asked. See StoryPrefetcher.warmVideo.
                //
                // Low Data Mode is still an unconditional no. Cellular is now the CALLER's decision
                // (`allowsCellular`), because "speculative" covers two very different bets: the next
                // clip in a story you are already watching, and a clip for somebody whose ring you
                // have not touched. Only the first one is worth mobile data.
                request.allowsConstrainedNetworkAccess = false
                request.allowsExpensiveNetworkAccess = allowsCellular
                // Background service type, which matters most on exactly the connection this is
                // now allowed onto: the system yields it to the clip actually being watched rather
                // than racing it for the same bandwidth.
                request.networkServiceType = .background
            }
            // NO `self` ANYWHERE IN HERE. The completion belongs to the registry, not to whichever
            // view happened to ask first — see `VideoDownloads`. A viewer closing mid-transfer used
            // to throw away a clip that had already been paid for in full.
            let task = session.downloadTask(with: request) { (tempLocalUrl, response, error) in
                if let error = error {
                    VideoDownloads.finish(url, .failure("Error downloading video: \(error.localizedDescription)"))
                    return
                }

                guard let tempLocalUrl = tempLocalUrl,
                      let response = response as? HTTPURLResponse,
                      response.statusCode == 200
                else {
                    VideoDownloads.finish(url, .failure("Error: Invalid response or no data"))
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: destinationUrl.path) {
                        try FileManager.default.removeItem(at: destinationUrl)
                    }
                    try FileManager.default.moveItem(at: tempLocalUrl, to: destinationUrl)
                    VideoDownloads.finish(url, .success(destinationUrl))
                } catch {
                    VideoDownloads.finish(url, .failure("Error moving video file to cache: \(error.localizedDescription)"))
                }
            }
            VideoDownloads.remember(url, task: task)
            onTask?(task)
            task.resume()
        }
    }
}


// The URLSessionDelegate that used to live here is gone on purpose — see downloadAndCacheVideo.
// It force-unwrapped `serverTrust`, which crashed the app on any non-server-trust challenge, and it
// accepted every certificate it was shown. URLSession's default handling is both safer and correct.
