import Foundation

// The URLSession chat MEDIA is fetched through.
//
// `URLSession.shared` cannot be configured, and its default is to fail a request the instant the
// radio has nothing: in a lift, on a train, or on the 2G edge of a cell, a photo download returns
// "not connected" immediately and the bubble goes to its failed state while the signal is two
// seconds from coming back. `waitsForConnectivity` inverts that. The task parks until the system
// says a path exists, then runs, so the user sees a photo that is still loading rather than one
// that gave up.
//
// NOT used for API calls (auth, Giphy search, link previews). Those SHOULD fail fast: a request
// that silently parks for an hour is worse than an error the caller can retry or ignore.
enum MediaSession {
    static let shared: URLSession = {
        let c = URLSessionConfiguration.default
        // Park instead of failing when there is no path to the network.
        c.waitsForConnectivity = true
        // Per-request stall limit. Generous, because 2G is slow, not broken.
        c.timeoutIntervalForRequest = 60
        // Total lifetime of one download INCLUDING the connectivity wait. The system default is
        // seven days, which for a foreground photo is indistinguishable from a hang; an hour is
        // long enough to survive a tunnel or a flight and short enough to eventually surface.
        c.timeoutIntervalForResource = 3600
        // Our own DiskImageCache/VideoCache/AudioCache own media caching, and these payloads are
        // ENCRYPTED blobs. Letting URLCache keep a second copy wastes disk on bytes that are
        // useless without the key.
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
}
