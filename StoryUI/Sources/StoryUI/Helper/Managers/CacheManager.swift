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

    /// `speculative`: this video is being fetched for a story nobody has asked to watch yet, so it
    /// stands down on a metered or Low Data Mode connection. WITHOUT THIS THE RULE WAS BACKWARDS.
    /// `StoryPrefetcher.warmImage` already refused to pull a 200 KB photo on a constrained network
    /// while `warmVideo` went straight through this method and happily pulled sixteen megabytes,
    /// because a bare `downloadTask(with: url)` carries no request configuration at all. On the
    /// expensive mobile data a lot of this app's users are on, that was the single most costly
    /// thing the app did without being asked.
    func loadVideo(from url: URL, speculative: Bool = false, completion: @escaping (Result<URL>) -> Void) {
        switch createCacheDirectory() {
        case .success(let cacheDirectory):
            let videoFileName = Self.cacheFileName(for: url)
            let destinationUrl = cacheDirectory.appendingPathComponent(videoFileName)

            if fileManager.fileExists(atPath: destinationUrl.path) {
                if Self.isUsableCacheFile(destinationUrl) {
                    DispatchQueue.main.async {
                        completion(.success(destinationUrl))
                    }
                } else {
                    // Clear the wedge, then fetch it properly.
                    try? fileManager.removeItem(at: destinationUrl)
                    downloadAndCacheVideo(from: url, speculative: speculative, completion: completion)
                }
            } else {
                downloadAndCacheVideo(from: url, speculative: speculative, completion: completion)
            }
        case .failure(let error):
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }
}

extension FileManager: @unchecked @retroactive Sendable {}

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

    func downloadAndCacheVideo(from url: URL, speculative: Bool, completion: @escaping (Result<URL>) -> Void) {
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
                // Same two lines StoryPrefetcher.warmImage already used for photos. On a constrained
                // connection the task simply fails and the story loads when you reach it, which is
                // exactly where we were before prefetching existed — no worse, just not expensive.
                request.allowsConstrainedNetworkAccess = false
                request.networkServiceType = .background
            }
            let task = session.downloadTask(with: request) { [weak self] (tempLocalUrl, response, error) in
                guard let self else { return }

                if let error = error {
                    DispatchQueue.main.async { completion(.failure("Error downloading video: \(error.localizedDescription)")) }
                    return
                }

                guard let tempLocalUrl = tempLocalUrl,
                      let response = response as? HTTPURLResponse,
                      response.statusCode == 200
                else {
                    DispatchQueue.main.async { completion(.failure("Error: Invalid response or no data")) }
                    return
                }

                switch self.createCacheDirectory() {
                case .success(let cacheDirectory):
                    let videoFileName = Self.cacheFileName(for: url)
                    let destinationUrl = cacheDirectory.appendingPathComponent(videoFileName)

                    do {
                        if FileManager.default.fileExists(
                            atPath: destinationUrl.path
                        ) {
                            try FileManager.default.removeItem(at: destinationUrl)
                        }

                        try FileManager.default.moveItem(
                            at: tempLocalUrl,
                            to: destinationUrl
                        )

                        DispatchQueue.main.async {
                            completion(.success(destinationUrl))
                        }

                    } catch {
                        DispatchQueue.main.async { completion(.failure("Error moving video file to cache: \(error.localizedDescription)")) }
                    }
                case .failure(let error):
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
            task.resume()
        }
    }
}


// The URLSessionDelegate that used to live here is gone on purpose — see downloadAndCacheVideo.
// It force-unwrapped `serverTrust`, which crashed the app on any non-server-trust challenge, and it
// accepted every certificate it was shown. URLSession's default handling is both safer and correct.
