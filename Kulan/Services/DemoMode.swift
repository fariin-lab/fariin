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
        let aImg = cache("demo-a", .systemPurple, .systemBlue, "Story A")
        let bImg = cache("demo-b", .systemPink, .systemRed, "Story B (wide)", wide: true)   // landscape → tests fit+blur
        let cImg = cache("demo-c", .systemTeal, .systemIndigo, "Story C")
        // More OWN-story shapes (user request): square + 4:3 — both letterbox like a real
        // half-height photo, so the blur bars (never black!) are verifiable in the preview.
        let dImg = cache("demo-d", .systemGreen, .systemYellow, "Story D (square)", size: CGSize(width: 1080, height: 1080))
        let eImg = cache("demo-e", .systemOrange, .systemBrown, "Story E (4:3)", size: CGSize(width: 1440, height: 1080))
        let aishaImg = cache("demo-aisha", .systemPink, .systemOrange, "Aisha")
        let omarImg = cache("demo-omar", .systemTeal, .systemGreen, "Omar")

        // My own story (3 items) — open it, tap to reach B or C, then swipe up: the viewers sheet must
        // open centred on the SAME story.
        StoriesRepository.shared.mine = StoryGroup(
            authorUid: me, name: "You", photoUrl: nil,
            stories: [
                Story(id: "demo-s1", authorUid: me, createdAt: now.addingTimeInterval(-3600),
                      expiresAt: now.addingTimeInterval(20 * 3600), mediaUrl: aImg, allowsReplies: true,
                      caption: "Story A — swipe up to see who viewed"),
                Story(id: "demo-s2", authorUid: me, createdAt: now.addingTimeInterval(-1500),
                      expiresAt: now.addingTimeInterval(22 * 3600), mediaUrl: bImg, allowsReplies: true,
                      caption: "Story B"),
                Story(id: "demo-s3", authorUid: me, createdAt: now.addingTimeInterval(-600),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: cImg, allowsReplies: true,
                      caption: "Story C"),
                Story(id: "demo-s4", authorUid: me, createdAt: now.addingTimeInterval(-300),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: dImg, allowsReplies: true,
                      caption: "Story D — square, bars must be BLUR"),
                Story(id: "demo-s5", authorUid: me, createdAt: now.addingTimeInterval(-120),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: eImg, allowsReplies: true,
                      caption: "Story E — 4:3, bars must be BLUR"),
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

        // Demo chat rows with real (plaintext) previews. In demo mode the previews + the opened
        // conversation both render straight from these strings — no E2EE (see decodedLast + start()).
        ConversationsRepository.shared.conversations = [
            chat("demo-c1", me, "demo-aisha", "Aisha", now.addingTimeInterval(-240),  "For sure, call me around 2 😊"),
            chat("demo-c2", me, "demo-omar",  "Omar",  now.addingTimeInterval(-3600), "Sounds good, see you there 👍"),
            chat("demo-c3", me, "demo-sara",  "Sara",  now.addingTimeInterval(-9000), "Haha that's hilarious 😂"),
            chat("demo-c4", me, "demo-yusuf", "Yusuf", now.addingTimeInterval(-86400),"Thanks for the help earlier!"),
            chat("demo-c5", me, "demo-lina",  "Lina",  now.addingTimeInterval(-172800),"Let's catch up this weekend"),
        ]
        ConversationsRepository.shared.hasLoaded = true
    }

    private static func chat(_ id: String, _ me: String, _ other: String, _ name: String, _ at: Date, _ last: String) -> Conversation {
        Conversation(id: id, data: [
            "users": [me, other],
            "names": [other: name, me: "You"],
            "lastSender": other,
            "lastMessage": last,
            "updatedAt": Timestamp(date: at),
        ])
    }

    // The full (plaintext) conversation shown when a demo chat is opened. Rendered directly by
    // ThreadRepository in demo mode — no Firestore, no decryption.
    static func messages(for cid: String) -> [Message] {
        let me = Auth.auth().currentUser?.uid ?? "demo-me"
        let n = Date()
        func t(_ s: Double) -> Date { n.addingTimeInterval(s) }
        func them(_ uid: String, _ lines: [(String, String, Double)]) -> [Message] {
            lines.enumerated().map { i, l in
                Message(demoId: "\(cid)-\(i)", from: l.0 == "me" ? me : uid, l.1, t(l.2))
            }
        }
        switch cid {
        case "demo-c1":
            return them("demo-aisha", [
                ("aisha", "Heyy! Did you see the new update? 👀", -7200),
                ("me",    "Yesss it looks so clean 🔥", -7100),
                ("aisha", "Right?? The stories part is my favourite", -7000),
                ("me",    "Same. The blur on the cards is so smooth now", -6800),
                ("aisha", "Wanna test the voice notes later?", -3600),
                ("me",    "For sure 😊", -3400),
                ("aisha", "For sure, call me around 2 😊", -240),
            ])
        case "demo-c2":
            return them("demo-omar", [
                ("omar", "Yo, still on for football tomorrow?", -9000),
                ("me",   "Definitely. 5pm at the usual pitch?", -8900),
                ("omar", "Perfect. I'll bring the ball", -8800),
                ("me",   "Nice, I'll grab drinks after 🥤", -3700),
                ("omar", "Sounds good, see you there 👍", -3600),
            ])
        case "demo-c3":
            return them("demo-sara", [
                ("sara", "You will NOT believe what happened today", -12000),
                ("me",   "go on 👀", -11900),
                ("sara", "I walked into the glass door at work 🤦‍♀️", -11800),
                ("me",   "NO WAY 😂😂", -11700),
                ("sara", "Everyone saw. I wanted to disappear", -9100),
                ("me",   "Haha that's hilarious 😂", -9000),
            ])
        case "demo-c4":
            return them("demo-yusuf", [
                ("yusuf", "Hey, do you have the notes from the meeting?", -90000),
                ("me",    "Yeah one sec, sending them over", -89900),
                ("me",    "📄 Meeting-notes.pdf", -89800),
                ("yusuf", "Thanks for the help earlier!", -86400),
            ])
        case "demo-c5":
            return them("demo-lina", [
                ("lina", "It's been ages! How are you?", -180000),
                ("me",   "I know! Doing great, super busy though", -179900),
                ("lina", "Let's catch up this weekend", -172800),
            ])
        default:
            return []
        }
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

// Plaintext text message for the demo conversations (no E2EE — text is set directly for display).
extension Message {
    init(demoId: String, from authorId: String, _ text: String, _ createdAt: Date) {
        self.id = demoId
        self.authorId = authorId
        self.text = text
        self.reactions = [:]
        self.createdAt = createdAt
    }
}
#endif
