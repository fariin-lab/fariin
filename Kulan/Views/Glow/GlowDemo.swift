import SwiftUI
import UIKit

/// GLOW DEMO DATA — his ask, 2026-09-02: "build demo users for admin user only @realwarya … I want
/// to see how it works". Glowers, Glowing, notifications and Glowing stories, all fake, so the
/// whole feature can be walked through on one phone before anybody else has ever given a glow.
///
/// ⛔ TWO GATES, BOTH REQUIRED, AND THE SECOND ONE IS HIS.
///   1. `DemoStoryMedia.isAvailable` — debug or TestFlight, NEVER the App Store. Borrowed from the
///      demo chats switch, which had to solve this and solved it correctly: the receipt name is the
///      honest test for "this build came from TestFlight" and needs nobody to remember to flip a
///      switch before submitting.
///   2. **The signed-in handle is `realwarya`.** His account and no other. Even inside TestFlight,
///      a second tester sees nothing.
///
/// ⚠️ `#if DEBUG` WOULD BE THE WRONG GATE AND THIS APP HAS ALREADY PAID FOR THAT ONCE. TestFlight is
/// a Release build, so a DEBUG gate means the one place he can actually run this is the one place it
/// would not appear. `DemoStoryMedia.isAvailable` is the rule the rest of the app settled on.
///
/// ⚠️ NOTHING IS WRITTEN ANYWHERE. Every value below is built on the phone and lives in memory: no
/// glow edges, no receipts, no documents. So it cannot reach another account, cannot survive a
/// reinstall, and cannot be left behind by forgetting to turn something off. The real screens read
/// these through the same properties they read live data through, so what he sees is the real
/// layout with invented people in it.
@MainActor enum GlowDemo {
    /// His handle, lowercased — the one account this is for.
    private static let ownerHandle = "realwarya"

    /// Both gates. Read by every surface below, so there is one place the answer lives.
    static var isOn: Bool {
        guard DemoStoryMedia.isAvailable else { return false }
        let handle = (ProfileStore.shared.me?.handle ?? "").lowercased()
        return handle == ownerHandle
    }

    // MARK: - The people

    /// Six invented people. Somali names, because that is who uses this app, and the same instinct
    /// the demo chats followed.
    private static let cast: [(id: String, name: String, handle: String)] = [
        ("glowdemo_ayaan",  "Ayaan Warsame",  "ayaan_w"),
        ("glowdemo_iftiin", "Iftiin Cabdi",   "iftiin"),
        ("glowdemo_sagal",  "Sagal Maxamed",  "sagalm"),
        ("glowdemo_hodan",  "Hodan Yuusuf",   "hodan.y"),
        ("glowdemo_deeq",   "Deeq Cali",      "deeqc"),
        ("glowdemo_muna",   "Muna Xasan",     "muna_x"),
    ]

    /// True for somebody who exists only on this device, so nothing tries to open a chat, write a
    /// receipt or fetch a profile for them. Same shape as `StoriesRepository.isDemoAuthor`.
    static func isDemoPerson(_ uid: String) -> Bool { uid.hasPrefix("glowdemo_") }

    private static func person(_ i: Int) -> GlowPerson {
        let c = cast[i % cast.count]
        return GlowPerson(id: c.id, name: c.name, handle: c.handle, photoUrl: nil)
    }

    /// People who glowed me — four of the six.
    static var glowers: [GlowPerson] { (0..<4).map(person) }
    /// People I glowed — two, one of whom also glows me, so the mutual case is on screen.
    static var glowing: [GlowPerson] { [person(0), person(4)] }

    /// The uid sets, for the places that work in ids rather than rows.
    static var glowerIds: Set<String> { Set(glowers.map(\.id)) }
    static var glowingIds: Set<String> { Set(glowing.map(\.id)) }

    // MARK: - The notifications

    /// A mixed feed, on purpose: glows AND loves, spread across the three date groups, so all of
    /// it can be seen — the chips, the grouping, Glow back, and the story thumbnail on a love.
    static var events: [GlowEvent] {
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-86_400 * days) }
        return [
            GlowEvent(id: "d1", person: person(1), kind: .glowed, at: ago(0.2), storyThumb: nil),
            GlowEvent(id: "d2", person: person(2), kind: .loved("❤️"), at: ago(1.1),
                      storyThumb: thumb(2)),
            GlowEvent(id: "d3", person: person(0), kind: .glowed, at: ago(3), storyThumb: nil),
            GlowEvent(id: "d4", person: person(3), kind: .loved("🔥"), at: ago(6),
                      storyThumb: thumb(3)),
            GlowEvent(id: "d5", person: person(2), kind: .glowed, at: ago(12), storyThumb: nil),
            GlowEvent(id: "d6", person: person(5), kind: .loved("😍"), at: ago(21),
                      storyThumb: thumb(1)),
            GlowEvent(id: "d7", person: person(3), kind: .glowed, at: ago(48), storyThumb: nil),
        ]
    }

    // MARK: - The stories

    /// One card per glow person for the Stories tab's Glowing grid.
    static var storyCards: [GlowStoryCard] {
        let people = glowers + glowing.filter { p in !glowerIds.contains(p.id) }
        return people.enumerated().map { i, p in
            GlowStoryCard(person: p, story: story(p.id, i))
        }
    }

    /// Stories for a demo person's own profile and its See All page — three each, so the rail
    /// scrolls and the grid has something to filter.
    static func stories(for uid: String) -> [PostedStory] {
        let seed = abs(uid.hashValue)
        return (0..<3).map { story(uid, seed &+ $0, index: $0) }
    }

    private static func story(_ uid: String, _ seed: Int, index: Int = 0) -> PostedStory {
        let now = Date()
        // The audience cycles so the Posted Stories FILTER has all three kinds to separate.
        let audiences = ["glowers", "friends", "custom"]
        return PostedStory(
            id: "glowdemo_story_\(uid)_\(index)",
            thumbUrl: demoAsset(seed) ?? thumb(seed),
            blurThumb: "",
            createdAt: now.addingTimeInterval(-3600 * Double(3 + index * 5)),
            expiresAt: now.addingTimeInterval(3600 * 20),
            isVideo: index == 1,
            views: [25_600, 45_600, 33_200, 12_100, 8_400, 2_700][abs(seed) % 6],
            audience: audiences[index % audiences.count])
    }

    /// ⛔ THE REAL DEMO PHOTOGRAPHS, NOT A GRADIENT — owner, 2026-09-02: "my preview stories, Glowing
    /// and Friends story, make it real images".
    ///
    /// ⚠️ THE OLD NOTE HERE SAID "no bundled assets" AND THAT WAS SIMPLY NOT TRUE. There are
    /// twenty-five `demo-story-*` images in the catalogue, put there for exactly this and already
    /// used by `DemoMode` for the friends row. This file drew a two-colour gradient instead, so the
    /// Glowing grid — the one screen where the picture IS the reason to tap — was the only place in
    /// the app showing demo people as flat colour.
    ///
    /// ⚠️ STORED WHERE BOTH READERS LOOK, which is why this is not just `UIImage(named:)`. A card
    /// reads through `DiskImageCache` and the story viewer reads through `URLCache`; a picture in
    /// one is invisible to the other. `DemoMode.story` learned this the hard way and its note says
    /// so, so this does the same two writes behind the same unreachable host.
    private static func demoAsset(_ seed: Int) -> String? {
        let names = ["demo-story-ayaan", "demo-story-cabdi", "demo-story-sagal",
                     "demo-story-khadra", "demo-story-linnea", "demo-story-ilhan",
                     "demo-story-ayaan-2", "demo-story-cabdi-3", "demo-story-sagal-2",
                     "demo-story-khadra-2", "demo-story-linnea-2", "demo-story-ilhan-2"]
        let name = names[abs(seed) % names.count]
        let urlStr = "https://fariin.local/\(name).jpg"
        guard let img = UIImage(named: name) else { return nil }
        guard let url = URL(string: urlStr) else { return nil }
        if DiskImageCache.shared.isCached(urlStr) { return urlStr }
        if let data = img.jpegData(compressionQuality: 0.85) {
            DiskImageCache.shared.store(img, data: data, for: urlStr)
            let resp = URLResponse(url: url, mimeType: "image/jpeg",
                                   expectedContentLength: data.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data),
                                                for: URLRequest(url: url))
        }
        return urlStr
    }

    /// A drawn placeholder, kept as the FALLBACK only: an asset that has been renamed or dropped
    /// must still leave a card with something on it rather than a hole.
    private static func thumb(_ seed: Int) -> String {
        let pairs: [(UIColor, UIColor)] = [
            (.systemIndigo, .systemBlue), (.systemPink, .systemRed),
            (.systemTeal, .systemGreen), (.systemOrange, .systemYellow),
            (.systemPurple, .systemPink), (.systemBlue, .systemTeal),
        ]
        let (top, bottom) = pairs[abs(seed) % pairs.count]
        let size = CGSize(width: 360, height: 640)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        guard let data = img.jpegData(compressionQuality: 0.7) else { return "" }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
