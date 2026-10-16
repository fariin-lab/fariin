import Foundation
import UIKit
import FirebaseAuth
import FirebaseFunctions

// ⛔ OFFICIAL STORIES — owner 2026-10-16: "admins upload stories for the Fariin official chat in the
// admin panel; users view them exactly like normal stories". Fariin is a row in the Stories list
// like a friend, opened in the same viewer, with no reply bar, no heart, no share or repost.
//
// WHO SEES WHAT IS DECIDED ON THE SERVER. The stories live in `officialStories`, which no phone can
// read; `officialStoriesFeed` (functions-admin) answers with only the live stories whose audience
// takes this phone: country, app build, iOS version, or everyone. Those three are what the phone
// says about itself, which is all any server can go on; the point is that nothing outside the
// answer ever reaches the phone.
//
// Nothing is written anywhere when one is watched: Fariin is not an account, so there is no
// receipt to leave and no watermark to keep. Seen is this phone's own (`StoryPrefs`).
@MainActor
final class OfficialStories {
    static let shared = OfficialStories()
    private init() {}

    /// The group the Stories list shows, read by `StoriesRepository.rebuild()` off the main actor,
    /// hence the lock rather than actor isolation.
    nonisolated static var group: StoryGroup? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }
    nonisolated(unsafe) private static var cached: StoryGroup?
    nonisolated private static let lock = NSLock()

    private var lastFetch: Date = .distantPast
    private var fetching = false
    private var expiryTimer: Timer?
    /// The account whose saved answer has been shown this launch.
    private var seededFor: String?

    private static func savedURL(uid: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("official-stories-\(uid).json")
    }
    private static func loadSaved(uid: String) -> [Story]? {
        guard let url = savedURL(uid: uid), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Story].self, from: data)
    }
    private static func save(_ stories: [Story], uid: String) {
        guard let url = savedURL(uid: uid), let data = try? JSONEncoder().encode(stories) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Ask again, unless the last answer is still fresh. Called when the Stories list appears and
    /// when the app comes back to the front; `force` after a story has expired on screen.
    func refresh(force: Bool = false) {
        guard let uid = Auth.auth().currentUser?.uid, !fetching else { return }
        // ⛔ THE LAST ANSWER FIRST — owner 2026-10-16: the Fariin card arrived after the others.
        // Friends' cards come from saved data at once; this one waited for the callable. The last
        // answer is kept on the phone and shown the moment the app asks, expired ones dropped,
        // and the server's reply replaces it as before.
        if seededFor != uid {
            seededFor = uid
            if let saved = Self.loadSaved(uid: uid) { publish(saved, save: false) }
        }
        guard force || Date().timeIntervalSince(lastFetch) > 5 * 60 else { return }
        fetching = true
        Task {
            defer { fetching = false }
            let stories = await fetch()
            guard let stories else { return }   // a failed call keeps what is on screen
            lastFetch = Date()
            publish(stories)
        }
    }

    /// Sign-out: the next account must not inherit this one's answer.
    func reset() {
        expiryTimer?.invalidate(); expiryTimer = nil
        lastFetch = .distantPast
        if let uid = seededFor, let url = Self.savedURL(uid: uid) { try? FileManager.default.removeItem(at: url) }
        seededFor = nil
        Self.lock.lock(); Self.cached = nil; Self.lock.unlock()
    }

    private func fetch() async -> [Story]? {
        let input: [String: Any] = [
            "build": OfficialChannelStore.currentBuild,
            "ios": UIDevice.current.systemVersion,
            "region": Locale.current.region?.identifier.uppercased() ?? "",
        ]
        do {
            let result = try await Functions.functions(region: "me-central1")
                .httpsCallable("officialStoriesFeed").call(input)
            guard let data = result.data as? [String: Any],
                  let rows = data["stories"] as? [[String: Any]] else { return [] }
            return rows.compactMap(Self.story)
        } catch {
            print("official stories: feed failed:", error.localizedDescription)
            return nil
        }
    }

    private static func story(_ r: [String: Any]) -> Story? {
        guard let id = r["id"] as? String, !id.isEmpty,
              let media = r["mediaUrl"] as? String, !media.isEmpty,
              let publish = (r["publishAt"] as? NSNumber)?.doubleValue,
              let expires = (r["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        var s = Story(id: "official-\(id)", authorUid: OfficialChannel.cid,
                      createdAt: Date(timeIntervalSince1970: publish / 1000),
                      expiresAt: Date(timeIntervalSince1970: expires / 1000),
                      mediaUrl: media, allowsReplies: false)
        s.isVideo = (r["kind"] as? String) == "video"
        s.thumbUrl = r["thumbUrl"] as? String ?? ""
        s.caption = r["caption"] as? String ?? ""
        s.duration = (r["duration"] as? NSNumber)?.doubleValue ?? 0
        if let t = r["buttonText"] as? String, !t.isEmpty, let u = r["buttonUrl"] as? String, !u.isEmpty {
            s.buttonText = t; s.buttonUrl = u
        }
        s.audienceLabel = "everyone"
        return s
    }

    private func publish(_ stories: [Story], save: Bool = true) {
        let live = stories.filter { $0.expiresAt > Date() }.sorted { $0.createdAt < $1.createdAt }
        if save, let uid = seededFor { Self.save(live, uid: uid) }
        // Somebody who blocked the Fariin chat has said they do not want its news; stories are news.
        let g: StoryGroup? = live.isEmpty || OfficialChannelStore.shared.state.blocked ? nil
            : StoryGroup(authorUid: OfficialChannel.cid, name: OfficialChannel.name,
                         photoUrl: Self.avatarURL(), stories: live, lastViewedAt: nil, isMine: false)
        Self.lock.lock(); Self.cached = g; Self.lock.unlock()
        StoriesRepository.shared.refreshMyDisplay()   // the list re-reads `group` on its rebuild
        // Off the list the moment the first one runs out, rather than at the next fetch.
        expiryTimer?.invalidate()
        if let next = live.map(\.expiresAt).min() {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow),
                                               repeats: false) { _ in
                Task { @MainActor in OfficialStories.shared.refresh(force: true) }
            }
        }
    }

    /// The official chat's own mark (`welcome-mark`), stored where avatars and the viewer look for
    /// a picture, under a local url nothing on a server answers. Same arrangement as the demo
    /// photos (`DemoMode.profilePhoto`).
    ///
    /// ⛔ SEEDED ON EVERY PUBLISH, NOT ONCE — owner 2026-10-16: the Fariin card and story header lost
    /// the logo. Since the saved answer is shown at launch (a2812610), the first seed ran in the
    /// launch window, before the image caches settle, and a once-per-launch flag never put it back.
    /// The bytes are made once and kept; storing them again is cheap.
    private static var avatarBytes: (UIImage, Data)? = {
        guard let img = UIImage(named: "welcome-mark"), let data = img.jpegData(compressionQuality: 0.9)
        else { return nil }
        return (img, data)
    }()
    private static func avatarURL() -> String {
        let urlStr = "https://fariin.local/official-fariin-avatar.jpg"
        guard let url = URL(string: urlStr), let bytes = avatarBytes else { return urlStr }
        let (img, data) = bytes
        DiskImageCache.shared.store(img, data: data, for: urlStr)
        let resp = URLResponse(url: url, mimeType: "image/jpeg",
                               expectedContentLength: data.count, textEncodingName: nil)
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data),
                                            for: URLRequest(url: url))
        return urlStr
    }
}
