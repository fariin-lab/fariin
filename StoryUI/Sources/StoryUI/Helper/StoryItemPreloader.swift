//
// AVPlayerItems built and warmed for stories you have not reached yet.
//

import Foundation
import AVFoundation

/// WHY A PREFETCHED VIDEO STILL BEGAN WITH A PAUSE.
///
/// `StoryPrefetcher` puts the next three clips on disk while you watch the current one, which
/// removes the download. It does not remove everything else. Arriving at the story still meant
/// building an `AVURLAsset`, parsing the container, loading its tracks, creating an `AVPlayerItem`,
/// handing it to the player and waiting for the pipeline to fill — and all of that happens after you
/// have already asked to see it, so it is all visible as a wait.
///
/// This does that work in advance too. By the time the story is on screen its item exists, its
/// duration and tracks are loaded, and its first frames are decoded, so `replaceCurrentItem` is
/// followed by a frame rather than by a beat of black.
///
/// One reference app prepares its next items the same way (building its player ahead of the
/// item being shown); the other keeps a small pool of prepared players around the current index. The
/// principle both share is that arriving at a story should be the moment it APPEARS, not the moment
/// the work starts.
enum StoryItemPreloader {

    /// Small on purpose. These hold decoded video buffers, so a generous pool costs real memory for
    /// stories the person may never reach. Three matches the prefetcher's lookahead.
    private static let capacity = 3

    private static let lock = NSLock()
    private static var ready: [(key: String, item: AVPlayerItem)] = []
    private static var inFlight = Set<String>()

    /// Prepare `url` if it is not prepared already. Safe to call repeatedly; does nothing when the
    /// clip is not on disk yet, because streaming a not-yet-needed story is the opposite of the point.
    static func warm(_ url: URL) {
        let key = url.absoluteString
        lock.lock()
        let known = ready.contains { $0.key == key } || inFlight.contains(key)
        if !known { inFlight.insert(key) }
        lock.unlock()
        guard !known else { return }

        Task.detached(priority: .utility) {
            defer { lock.lock(); inFlight.remove(key); lock.unlock() }
            let asset = AVURLAsset(url: url)
            // Load what the player would otherwise block on at presentation time. If the asset is
            // not playable there is nothing to prepare and the live path will fall back to
            // streaming, which is what it already does.
            guard let playable = try? await asset.load(.isPlayable), playable else { return }
            _ = try? await asset.load(.duration)
            _ = try? await asset.load(.tracks)
            let item = AVPlayerItem(asset: asset)
            // A frame's worth is all that is wanted here: enough that the first picture is instant,
            // not enough to hold whole clips in memory for stories nobody opens.
            item.preferredForwardBufferDuration = 2
            await MainActor.run { store(key: key, item: item) }
        }
    }

    /// The prepared item for this url, handed over and removed. Removed rather than shared because an
    /// `AVPlayerItem` belongs to one player at a time: handing the same instance out twice is how you
    /// get a story that plays in the wrong place or refuses to play at all.
    static func take(_ url: URL) -> AVPlayerItem? {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        guard let i = ready.firstIndex(where: { $0.key == key }) else { return nil }
        return ready.remove(at: i).item
    }

    static func clear() {
        lock.lock(); ready.removeAll(); lock.unlock()
    }

    private static func store(key: String, item: AVPlayerItem) {
        lock.lock(); defer { lock.unlock() }
        guard !ready.contains(where: { $0.key == key }) else { return }
        ready.append((key, item))
        // Oldest out first: the window moves forward, so the ones prepared longest ago are the ones
        // furthest behind.
        while ready.count > capacity { ready.removeFirst() }
    }
}
