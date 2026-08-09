//
// Download the stories you are about to reach, while you are watching the one in front of you.
//

import Foundation
import UIKit
import Network   // NWPathMonitor, for "is this connection the expensive one"

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

    /// HOW MANY VIDEOS AHEAD ON MOBILE DATA. Owner's decision, 2026-08-09: pre-download on cellular
    /// too, so tapping onto a video is smooth the way Telegram is, but keep it tight. Two is the
    /// smallest number that survives a normal tap-tap — the one you are about to reach and the one
    /// after it — while a third is a clip most people never get to.
    ///
    /// Wi-Fi keeps the full `lookahead`. Low Data Mode gets none: that switch is the person telling
    /// the system to spend nothing it does not have to, and guessing is exactly what it means.
    private static let cellularVideoLookahead = 2

    private static let lock = NSLock()
    private static var inFlight = Set<String>()
    /// Speculative downloads currently running, so one for a story that has been passed can be
    /// stopped rather than paid for. `lookahead` marks the ones the viewer's window owns — the row's
    /// first-card warms are not the window's to cancel.
    private static var running: [String: (task: URLSessionTask, lookahead: Bool)] = [:]
    private static let queue = DispatchQueue(label: "fariin.story.prefetch", qos: .utility)

    /// WHAT KIND OF CONNECTION THIS IS. `NWPathMonitor` is the only thing that answers it, and it
    /// answers asynchronously — so until the first update lands the conservative answer stands:
    /// assume the expensive one. Being briefly shallow on Wi-Fi costs a moment of loading; being
    /// briefly deep on cellular costs somebody's data, and only one of those is worth risking.
    private enum Net {
        private static let monitor = NWPathMonitor()
        /// Its own gate, deliberately not the prefetcher's `lock`: this one is taken from the
        /// monitor's queue on every network change, and sharing it would make a path update wait
        /// behind a download bookkeeping call for no reason.
        private static let gate = NSLock()
        private static let watch = DispatchQueue(label: "fariin.story.net")
        private static var expensive = true
        private static var constrained = false
        private static var started = false

        private static func start() {
            gate.lock(); defer { gate.unlock() }
            guard !started else { return }
            started = true
            monitor.pathUpdateHandler = { path in
                gate.lock()
                expensive = path.isExpensive
                constrained = path.isConstrained
                gate.unlock()
            }
            monitor.start(queue: watch)
        }

        static var isExpensive: Bool { start(); gate.lock(); defer { gate.unlock() }; return expensive }
        static var isConstrained: Bool { start(); gate.lock(); defer { gate.unlock() }; return constrained }
    }

    /// Warm everything from `index` onwards, up to `lookahead` items, out of the flattened list of
    /// every story in the viewer in the order they will be watched. Flattened ACROSS people on
    /// purpose, so the last story of one person warms the first of the next.
    public static func prefetch(from index: Int, in stories: [Story]) {
        guard index >= 0, !stories.isEmpty else { return }
        let end = min(stories.count, index + 1 + lookahead)
        guard index + 1 < end else { return }
        let upcoming = Array(stories[(index + 1)..<end])
        queue.async {
            // HOW DEEP THE VIDEO GUESS GOES, decided per call because the connection can change
            // mid-viewing. Posters are unaffected: they are a few KB and worth any connection.
            let videoDepth = Net.isConstrained ? 0
                           : (Net.isExpensive ? cellularVideoLookahead : lookahead)
            // AND STOP PAYING FOR THE ONES BEHIND. This runs on every item change, so a clip warmed
            // for a story that has since been passed — or skipped over by a fast tapper — is no
            // longer wanted, and on mobile data an unwanted download is the whole cost this feature
            // has to justify. Only the window's own downloads are cancelled; the row's first-card
            // warms are somebody else's bet.
            //
            // ⚠️ THE ITEM BEING WATCHED IS KEPT, and it is not in `upcoming`. Its warm was started
            // one call ago, when it was still the next one along, and it can easily be most of the
            // way through at the moment you arrive on it. Cancelling that would throw those bytes
            // away and leave the player to fetch the same clip again from zero — the exact wait
            // this whole feature exists to remove.
            let wanted = Set([stories[index].mediaURL] + upcoming.prefix(videoDepth).map(\.mediaURL))
            cancelStaleWindow(keeping: wanted)
            for (offset, story) in upcoming.enumerated() {
                // The poster first and always. It is a few KB, it is what the blurred loading state
                // draws, and having it means the story can never open on nothing.
                warmImage(story.previewURL, poster: true)
                // Then the media itself, which is the part that removes the wait. EACH KIND INTO THE
                // CACHE ITS OWN READER ACTUALLY LOOKS IN, which is the thing to get right here. A
                // photo is read from `StoryDiskCache` by ImageLoader. A video is NOT: VideoLoader
                // hands the url to `CacheManager`, which downloads it to a file and plays the file,
                // and AVPlayer never consults URLCache at all. Warming the wrong one would look like
                // it worked and download everything twice.
                switch story.config.mediaType {
                case .video:
                    // The clip you are about to reach is worth mobile data; the third one along is
                    // not. See `cellularVideoLookahead`.
                    guard offset < videoDepth else { continue }
                    warmVideo(story.mediaURL, allowsCellular: true, window: true)
                default:     warmImage(story.mediaURL, poster: false)
                }
            }
        }
    }

    /// Cancel the window's running video downloads that are no longer in it.
    private static func cancelStaleWindow(keeping wanted: Set<String>) {
        lock.lock()
        let doomed = running.filter { $0.value.lookahead && !wanted.contains($0.key) }
        for key in doomed.keys { running.removeValue(forKey: key) }
        lock.unlock()
        // Outside the lock: cancelling fires the completion handler, which takes it again.
        for entry in doomed.values { entry.task.cancel() }
    }

    /// THE ONE STORY THE LOOKAHEAD CANNOT REACH: the first one.
    ///
    /// `prefetch(from:in:)` runs inside the viewer, so it can only ever warm what comes AFTER
    /// something you already opened. That leaves the very first tap cold every single time, which is
    /// the tap people judge the app on. Instagram and WhatsApp both warm the front of each ring
    /// while you are still looking at the list.
    ///
    /// Two depths on purpose, because this is speculation and speculation costs somebody's data:
    ///
    /// - The POSTER for every ring passed in. A few KB each, and it is what the card and the opening
    ///   frame draw, so it is the difference between opening onto a picture and opening onto grey.
    /// - The MEDIA for `mediaDepth` rings only. The first ones in the row are the ones actually
    ///   opened; pulling a video for somebody eight cards along that nobody scrolls to is waste.
    ///
    /// Both go through the same warmers as the lookahead, so they land in the same caches, they
    /// dedupe against the same in-flight set, and they stand down on a constrained connection.
    /// Deliberately NOT a `Story`. The caller here is the chat-list story row, which has our own
    /// model and no reason to build StoryUI's — three fields is the whole job.
    public struct Item {
        public let media: String
        public let poster: String?
        public let isVideo: Bool
        public init(media: String, poster: String?, isVideo: Bool) {
            self.media = media; self.poster = poster; self.isVideo = isVideo
        }
    }

    public static func prefetchFirsts(_ firsts: [Item], mediaDepth: Int = 2) {
        guard !firsts.isEmpty else { return }
        queue.async {
            for (i, item) in firsts.enumerated() {
                warmImage(item.poster, poster: true)
                guard i < mediaDepth else { continue }
                if item.isVideo { warmVideo(item.media) } else { warmImage(item.media, poster: false) }
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

    /// ⚠️ THE ROW'S FIRST CARDS STAY ON WI-FI FOR VIDEO, and that is the line between the two bets.
    /// The window above guesses about a story you are two taps from inside a viewer you have already
    /// opened. This one guesses about people whose ring you have not touched at all, several of whom
    /// you will scroll straight past — so its posters keep cellular (a few KB, and they are what the
    /// card draws) and its clips do not.
    ///
    /// ⚠️ CONSTRAINED IS NOT THE SAME AS EXPENSIVE, and only one of them was ever set.
    ///
    /// `allowsConstrainedNetworkAccess = false` refuses LOW DATA MODE. That is a switch almost
    /// nobody has turned on. `allowsExpensiveNetworkAccess = false` is the one that refuses CELLULAR,
    /// which is the connection this file's own comment is worried about ("the expensive mobile data a
    /// lot of this app's users are on"). So the guard read as if it stood down on mobile data and in
    /// practice stood down on nothing: sixteen megabytes of speculative video went out over the data
    /// plan of anybody who was not in Low Data Mode.
    ///
    /// The split below is deliberate rather than a blanket refusal. Standing everything down on
    /// cellular would put the whole app back to opening every story on grey for the majority of its
    /// users, which is the problem the prefetcher exists to solve. A POSTER is a few KB and it is
    /// what the card and the opening frame draw, so it is worth cellular. The MEDIA is megabytes for
    /// something nobody has asked to watch, so it is not.
    /// `allowsCellular`: only the viewer's own next-clip window sets this. `window`: whether this
    /// download belongs to that window, and may therefore be cancelled when the window moves past it.
    private static func warmVideo(_ urlString: String?, allowsCellular: Bool = false,
                                  window: Bool = false) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        guard claim(urlString) else { return }
        videoCache.loadVideo(from: url, speculative: true, allowsCellular: allowsCellular,
                             onTask: { task in
            lock.lock(); running[urlString] = (task, window); lock.unlock()
        }) { result in
            release(urlString)
            lock.lock(); running.removeValue(forKey: urlString); lock.unlock()
            // ON DISK IS ONLY HALF OF IT. Building the asset, parsing the container, loading the
            // tracks and filling the render pipeline all still happen when you ARRIVE unless they are
            // done in advance, and all of it is visible as a wait. See StoryItemPreloader.
            if case .success(let file) = result { StoryItemPreloader.warm(file) }
        }
    }

    /// `poster` is the few-KB cover, and it keeps cellular. Everything else is the story itself and
    /// stands down. See the note on `warmVideo` for why the two are not treated the same.
    private static func warmImage(_ urlString: String?, poster: Bool) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        guard !isWarm(urlString), claim(urlString) else { return }

        var request = URLRequest(url: url)
        // This is speculative work for something the person has not asked to see yet, so it stands
        // down on a metered or Low Data Mode connection. The story still plays; it just loads when
        // you reach it, which is where we were before.
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = poster
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
