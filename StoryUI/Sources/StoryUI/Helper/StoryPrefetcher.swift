//
// Download the stories you are about to reach, while you are watching the one in front of you.
//

import Foundation
import UIKit

/// WHY STORIES FEEL SLOW, AND WHAT SIGNAL DOES ABOUT IT.
///
/// Nothing was downloaded until you arrived at it, so every single story began with a wait. The owner
/// put it exactly right: the good apps download the next one in the background while you are still
/// watching this one, so you never meet a loading state at all.
///
/// Signal's rule, read from `StoryContextViewController.swift`:
///
///   :737  private static let subsequentItemsToLoad = 3
///   :738  ensureSubsequentItemsDownloaded()
///   :747  while subsequentItems.count < subsequentItemsToLoad { ...contextAfter... }
///   :762  subsequentItems.forEach { $0.startAttachmentDownloadIfNecessary() }
///   :498  called whenever the current message changes
///
/// Three things worth copying and we copy all three. It runs on EVERY item change, not just when a
/// person's stories end. It keeps THREE ahead, not one, so a fast tapper stays in front of the
/// network. And when the person you are watching has fewer than three left, it carries on into the
/// NEXT PERSON's stories, which is the moment a story viewer is most likely to stall, because
/// crossing to somebody new is where there is nothing warm at all.
///
/// It also runs off the main thread, which matters more here than it looks: this fires while a story
/// is playing and a video is decoding.
public enum StoryPrefetcher {

    /// Signal's number.
    public static let lookahead = 3

    private static let lock = NSLock()
    private static var inFlight = Set<String>()
    private static let queue = DispatchQueue(label: "fariin.story.prefetch", qos: .utility)

    /// Warm everything from `index` onwards, up to `lookahead` items, out of the flattened list of
    /// every story in the viewer in the order they will be watched. Flattened ACROSS people on
    /// purpose, so the last story of one person warms the first of the next.
    public static func prefetch(from index: Int, in stories: [Story]) {
        guard index >= 0, !stories.isEmpty else { return }
        let end = min(stories.count, index + 1 + lookahead)
        guard index + 1 < end else { return }
        let upcoming = Array(stories[(index + 1)..<end])
        queue.async {
            for story in upcoming {
                // The poster first and always. It is a few KB, it is what the blurred loading state
                // draws, and having it means the story can never open on nothing.
                warmImage(story.previewURL)
                // Then the media itself, which is the part that removes the wait. EACH KIND INTO THE
                // CACHE ITS OWN READER ACTUALLY LOOKS IN, which is the thing to get right here. A
                // photo is read from `StoryDiskCache` by ImageLoader. A video is NOT: VideoLoader
                // hands the url to `CacheManager`, which downloads it to a file and plays the file,
                // and AVPlayer never consults URLCache at all. Warming the wrong one would look like
                // it worked and download everything twice.
                switch story.config.mediaType {
                case .video: warmVideo(story.mediaURL)
                default:     warmImage(story.mediaURL)
                }
            }
        }
    }

    /// True once this photo's bytes are where `ImageLoader` looks for them.
    public static func isWarm(_ urlString: String?) -> Bool {
        guard let urlString, let url = URL(string: urlString) else { return false }
        return FileManager.default.fileExists(atPath: StoryDiskCache.path(url).path)
    }

    /// Videos go through the same `CacheManager` the player uses, so a prefetched clip and a clip you
    /// waited for are the same file in the same place. It already skips a download when the file is
    /// there and already throws away a truncated one, so there is nothing to re-implement.
    /// ONE instance, held for the life of the app. A `CacheManager()` made on the spot would go out
    /// of scope the moment `loadVideo` returned, and it is the one holding the download.
    private static let videoCache = CacheManager()

    private static func warmVideo(_ urlString: String?) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        guard claim(urlString) else { return }
        videoCache.loadVideo(from: url) { result in
            release(urlString)
            // ON DISK IS ONLY HALF OF IT. Building the asset, parsing the container, loading the
            // tracks and filling the render pipeline all still happen when you ARRIVE unless they are
            // done in advance, and all of it is visible as a wait. See StoryItemPreloader.
            if case .success(let file) = result { StoryItemPreloader.warm(file) }
        }
    }

    private static func warmImage(_ urlString: String?) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        guard !isWarm(urlString), claim(urlString) else { return }

        var request = URLRequest(url: url)
        // This is speculative work for something the person has not asked to see yet, so it stands
        // down on a metered or Low Data Mode connection. The story still plays; it just loads when
        // you reach it, which is where we were before.
        request.allowsConstrainedNetworkAccess = false
        request.networkServiceType = .background

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { release(urlString) }
            guard let data, !data.isEmpty else { return }
            // `.atomic`, so a download cut off half way leaves no file rather than a truncated one
            // that a player would choke on.
            StoryDiskCache.store(data, for: url)
            // Photos are also read straight out of URLCache on the instant path, so seed that too.
            // A video is played from the file and never asks URLCache, so it does not need this.
            if let response, data.count < 12 * 1024 * 1024 {
                URLCache.shared.storeCachedResponse(.init(response: response, data: data),
                                                    for: .init(url: url))
            }
        }.resume()
    }

    /// One download per url at a time. Without this a fast tapper re-requests the same story three or
    /// four times over as the window slides forward, which is worse than not prefetching at all on
    /// exactly the weak connection where it matters most. Returns false if somebody already has it.
    private static func claim(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight.contains(key) { return false }
        inFlight.insert(key)
        return true
    }

    private static func release(_ key: String) {
        lock.lock(); inFlight.remove(key); lock.unlock()
    }
}
