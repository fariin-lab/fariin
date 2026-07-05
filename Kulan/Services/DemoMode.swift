#if DEBUG
import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

// DEBUG / PREVIEW ONLY — never compiled into Release (TestFlight / App Store).
//
// A cloud simulator (Appetize) can't do Firebase Storage uploads, so real stories can't be posted or
// viewed there. This fills the repos with FULLY LOCAL demo data (own + friends' stories with images
// served from URLCache, plus a few chat rows) so the app — and especially the story viewer / viewers
// swipe — can be previewed in the browser. Triggered by the demo login (username "apple") in onboarding.
enum DemoMode {
    // A plain flag the repos can read synchronously from anywhere; written once on the main actor.
    nonisolated(unsafe) static var active = false

    @MainActor
    static func activate() {
        active = true
        let me = Auth.auth().currentUser?.uid ?? "demo-me"
        let now = Date()

        // Three VISUALLY DISTINCT own stories (A/B/C) so the "sheet opens centred on the story you
        // swiped up from" behaviour is actually verifiable in the preview (identical cards hid the bug).
        // OWN stories = REAL photos (user request), every one a DIFFERENT size, so fit/fill and the
        // blur bars are testable with true image content. Lorem Picsum with fixed seeds → the same
        // photo every session; loads over the network (works on Appetize — only Storage uploads fail).
        let aImg = "https://picsum.photos/seed/kulan1/1080/1920"   // tall 9:16 → full-bleed, no bars
        let bImg = "https://picsum.photos/seed/kulan2/1920/1080"   // wide panorama → side/top-bottom bars
        let cImg = "https://picsum.photos/seed/kulan3/1080/1080"   // square → bars
        let dImg = "https://picsum.photos/seed/kulan4/1440/1080"   // 4:3 landscape → bars
        let eImg = "https://picsum.photos/seed/kulan5/1080/1440"   // 3:4 portrait → smaller bars
        let aishaImg = cache("demo-aisha", .systemPink, .systemOrange, "Aisha")
        let omarImg = cache("demo-omar", .systemTeal, .systemGreen, "Omar")

        // My own story (3 items) — open it, tap to reach B or C, then swipe up: the viewers sheet must
        // open centred on the SAME story.
        StoriesRepository.shared.mine = StoryGroup(
            authorUid: me, name: "You", photoUrl: nil,
            stories: [
                Story(id: "demo-s1", authorUid: me, createdAt: now.addingTimeInterval(-3600),
                      expiresAt: now.addingTimeInterval(20 * 3600), mediaUrl: aImg, allowsReplies: true,
                      caption: "A — tall 9:16, full-bleed"),
                Story(id: "demo-s2", authorUid: me, createdAt: now.addingTimeInterval(-1500),
                      expiresAt: now.addingTimeInterval(22 * 3600), mediaUrl: bImg, allowsReplies: true,
                      caption: "B — wide panorama"),
                Story(id: "demo-s3", authorUid: me, createdAt: now.addingTimeInterval(-600),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: cImg, allowsReplies: true,
                      caption: "C — square"),
                Story(id: "demo-s4", authorUid: me, createdAt: now.addingTimeInterval(-300),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: dImg, allowsReplies: true,
                      caption: "D — 4:3 landscape"),
                Story(id: "demo-s5", authorUid: me, createdAt: now.addingTimeInterval(-120),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: eImg, allowsReplies: true,
                      caption: "E — 3:4 portrait"),
            ], lastViewedAt: nil, isMine: true)

        // Friends' stories.
        StoriesRepository.shared.others = [
            StoryGroup(authorUid: "demo-aisha", name: "Aisha", photoUrl: nil,
                       stories: [Story(id: "demo-a1", authorUid: "demo-aisha", createdAt: now.addingTimeInterval(-7200),
                                       expiresAt: now.addingTimeInterval(16 * 3600), mediaUrl: aishaImg, allowsReplies: true)],
                       lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo-omar", name: "Omar", photoUrl: nil,
                       stories: [Story(id: "demo-o1", authorUid: "demo-omar", createdAt: now.addingTimeInterval(-5000),
                                       expiresAt: now.addingTimeInterval(17 * 3600), mediaUrl: omarImg, allowsReplies: true)],
                       lastViewedAt: nil, isMine: false),
        ]

        // Demo chat rows (names + timestamps; message previews are E2EE so they stay blank in demo).
        ConversationsRepository.shared.conversations = [
            chat("demo-c1", me, "demo-aisha", "Aisha", now.addingTimeInterval(-300)),
            chat("demo-c2", me, "demo-omar", "Omar", now.addingTimeInterval(-3600)),
            chat("demo-c3", me, "demo-sara", "Sara", now.addingTimeInterval(-86400)),
        ]
        ConversationsRepository.shared.hasLoaded = true
    }

    private static func chat(_ id: String, _ me: String, _ other: String, _ name: String, _ at: Date) -> Conversation {
        Conversation(id: id, data: [
            "users": [me, other],
            "names": [other: name, me: "You"],
            "lastSender": other,
            "updatedAt": Timestamp(date: at),
        ])
    }

    private static var cached = Set<String>()
    // Draw a gradient + label, store it in URLCache under a local URL. The story viewer (StoryUI's
    // ImageLoader) reads URLCache first, so the image renders with no network/Firebase.
    private static func cache(_ key: String, _ c1: UIColor, _ c2: UIColor, _ text: String,
                              wide: Bool = false, size explicitSize: CGSize? = nil) -> String {
        let urlStr = "https://kulan.local/\(key).jpg"
        guard !cached.contains(key), let url = URL(string: urlStr) else { return urlStr }
        cached.insert(key)
        // `wide` = a landscape image, so the viewer/morph must show the WHOLE image + blur bars (fitBlur),
        // never a cropped zoom — the case the user hit with a panorama. `size` overrides for other
        // letterboxing shapes (square, 4:3) to verify the bars everywhere.
        let size = explicitSize ?? (wide ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920))
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let p = NSMutableParagraphStyle(); p.alignment = .center
            (text as NSString).draw(in: CGRect(x: 0, y: size.height / 2 - 120, width: size.width, height: 320),
                                    withAttributes: [.foregroundColor: UIColor.white,
                                                     .font: UIFont.systemFont(ofSize: 120, weight: .heavy),
                                                     .paragraphStyle: p])
        }
        if let data = img.jpegData(compressionQuality: 0.85) {
            let resp = URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: data.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data), for: URLRequest(url: url))
        }
        return urlStr
    }
}
#endif
