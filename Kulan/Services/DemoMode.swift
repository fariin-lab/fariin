#if DEBUG
import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

// DEBUG / PREVIEW ONLY — never compiled into Release (TestFlight / App Store).
//
// A cloud simulator (Appetize) can't do Firebase Storage uploads, so real media can't be sent or
// fetched there. This fills the repos with FULLY LOCAL demo data (own + friends' stories, plus a
// set of chats with text/photos/files/links) so the app can be previewed in the browser. Triggered
// by the demo login (username "apple") in onboarding.
enum DemoMode {
    // A plain flag the repos can read synchronously from anywhere; written once on the main actor.
    nonisolated(unsafe) static var active = false
    // The signed-in uid, captured at activate() from the SAME source the app renders with
    // (AuthService.shared.uid). Using a mismatched id here made every chat row resolve to "You".
    nonisolated(unsafe) static var meUid = "demo-me"

    @MainActor
    static func activate() {
        active = true
        // Firebase-free demo: Auth.auth().currentUser is nil in the Appetize sim, so we FORCE a
        // fixed uid and set it as the app's current user. Every screen resolves `me` from
        // AuthService.shared.uid, so this makes names ("Kasim" not "You") and isMe render correctly.
        let me = "demo-me"
        meUid = me
        AuthService.shared.uid = me
        let now = Date()

        // Own stories (visually distinct so the "sheet opens centred on the swiped story" is verifiable).
        let aImg = cache("demo-a", .systemPurple, .systemBlue, "Story A")
        let bImg = cache("demo-b", .systemPink, .systemRed, "Story B (wide)", wide: true)
        let cImg = cache("demo-c", .systemTeal, .systemIndigo, "Story C")
        let dImg = cache("demo-d", .systemGreen, .systemYellow, "Story D (square)", size: CGSize(width: 1080, height: 1080))
        let eImg = cache("demo-e", .systemOrange, .systemBrown, "Story E (4:3)", size: CGSize(width: 1440, height: 1080))
        let kasimImg = cache("demo-kasim-s", .systemBlue, .systemPurple, "Kasim")
        let aminImg = cache("demo-amin-s", .systemTeal, .systemGreen, "Amin")

        // Profile portraits. Built here so both the chat list and the story rings hand the same url
        // to the poster header, and so the whole set exists before any row asks for it.
        let mePhoto    = profilePhoto("me",    .systemIndigo, .systemPurple, "K")
        let kasimPhoto = profilePhoto("kasim", .systemBlue,   .systemCyan,   "K")
        let aminPhoto  = profilePhoto("amin",  .systemTeal,   .systemGreen,  "A")
        let amranPhoto = profilePhoto("amran", .systemOrange, .systemPink,   "A")
        let aishaPhoto = profilePhoto("aisha", .systemPink,   .systemRed,    "A")

        StoriesRepository.shared.mine = StoryGroup(
            authorUid: me, name: "You", photoUrl: mePhoto,
            stories: [
                Story(id: "demo-s1", authorUid: me, createdAt: now.addingTimeInterval(-3600),
                      expiresAt: now.addingTimeInterval(20 * 3600), mediaUrl: aImg, allowsReplies: true,
                      caption: "Story A — swipe up to see who viewed"),
                Story(id: "demo-s2", authorUid: me, createdAt: now.addingTimeInterval(-1500),
                      expiresAt: now.addingTimeInterval(22 * 3600), mediaUrl: bImg, allowsReplies: true, caption: "Story B"),
                Story(id: "demo-s3", authorUid: me, createdAt: now.addingTimeInterval(-600),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: cImg, allowsReplies: true, caption: "Story C"),
                Story(id: "demo-s4", authorUid: me, createdAt: now.addingTimeInterval(-300),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: dImg, allowsReplies: true, caption: "Story D — square"),
                Story(id: "demo-s5", authorUid: me, createdAt: now.addingTimeInterval(-120),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: eImg, allowsReplies: true, caption: "Story E — 4:3"),
            ], lastViewedAt: nil, isMine: true)

        StoriesRepository.shared.others = [
            StoryGroup(authorUid: "demo-kasim", name: "Kasim", photoUrl: kasimPhoto,
                       stories: [Story(id: "demo-k1", authorUid: "demo-kasim", createdAt: now.addingTimeInterval(-7200),
                                       expiresAt: now.addingTimeInterval(16 * 3600), mediaUrl: kasimImg, allowsReplies: true)],
                       lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo-amin", name: "Amin", photoUrl: aminPhoto,
                       stories: [Story(id: "demo-am1", authorUid: "demo-amin", createdAt: now.addingTimeInterval(-5000),
                                       expiresAt: now.addingTimeInterval(17 * 3600), mediaUrl: aminImg, allowsReplies: true)],
                       lastViewedAt: nil, isMine: false),
        ]

        // Demo chat rows (real plaintext previews; the opened conversation renders straight from
        // messages(for:) below — no Firestore, no decryption).
        ConversationsRepository.shared.conversations = [
            chat("demo-kasim", me, "demo-kasim", "Kasim", now.addingTimeInterval(-240),  "Perfect, thanks 🙏", kasimPhoto),
            chat("demo-amin",  me, "demo-amin",  "Amin",  now.addingTimeInterval(-3600), "📄 Contract-final.pdf", aminPhoto),
            chat("demo-amran", me, "demo-amran", "Amran", now.addingTimeInterval(-9000), "😂 that clip is gold", amranPhoto),
            chat("demo-aisha", me, "demo-aisha", "Aisha", now.addingTimeInterval(-86400),"Let's catch up this weekend", aishaPhoto),
            // Deliberately LEFT WITHOUT A PHOTO, so the preview also shows the other half of the rule:
            // no picture means the classic circle, never an empty poster.
            chat("demo-omar",  me, "demo-omar",  "Omar",  now.addingTimeInterval(-172800),"Sounds good, see you there 👍", ""),
        ]
        ConversationsRepository.shared.hasLoaded = true
    }

    private static func chat(_ id: String, _ me: String, _ other: String, _ name: String, _ at: Date,
                             _ last: String, _ photo: String) -> Conversation {
        Conversation(id: id, data: [
            "users": [me, other],
            "names": [other: name, me: "You"],
            // Without this every demo person is a coloured letter, so the preview could never show
            // the poster header at all — it needs a real photo before it will draw (owner: "the
            // preview demo chats add profile picture").
            "photos": [other: photo],
            "lastSender": other,
            "lastMessage": last,
            "updatedAt": Timestamp(date: at),
        ])
    }

    /// A square portrait for a demo person, stored WHERE THE REAL PHOTO PATH LOOKS FOR IT.
    ///
    /// `cache(_:)` puts its images in URLCache, which is where the story viewer reads. Profile photos
    /// are read somewhere else entirely: AvatarView seeds itself synchronously from DiskImageCache,
    /// and the poster header reads the same store. A demo photo living only in URLCache is invisible
    /// to both, so it goes in both. (The header no longer DECIDES anything from the cache — that was
    /// `PosterPhoto`, now replaced by [ProfilePhotoIndex] — but it still draws from it, and a demo
    /// contact whose bitmap is missing would show their letter on a full-size poster.)
    ///
    /// Blobs, not a plain gradient. A flat gradient blurs to itself, so the progressive fade at the
    /// bottom of the poster would be impossible to judge — there has to be detail for it to destroy.
    private static func profilePhoto(_ key: String, _ c1: UIColor, _ c2: UIColor, _ initial: String) -> String {
        let urlStr = "https://fariin.local/pp-\(key).jpg"
        guard !cached.contains("pp-\(key)"), let url = URL(string: urlStr) else { return urlStr }
        cached.insert("pp-\(key)")
        let size = CGSize(width: 900, height: 900)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // Something for the blur to eat.
            let blobs: [(CGFloat, CGFloat, CGFloat, UIColor)] = [
                (0.28, 0.30, 0.30, .white), (0.72, 0.22, 0.18, .black),
                (0.60, 0.68, 0.34, .white), (0.18, 0.78, 0.22, .black),
            ]
            for (x, y, r, c) in blobs {
                ctx.cgContext.setFillColor(c.withAlphaComponent(0.16).cgColor)
                ctx.cgContext.fillEllipse(in: CGRect(x: size.width * (x - r / 2), y: size.height * (y - r / 2),
                                                     width: size.width * r, height: size.height * r))
            }
            let p = NSMutableParagraphStyle(); p.alignment = .center
            (initial as NSString).draw(in: CGRect(x: 0, y: size.height / 2 - 190, width: size.width, height: 400),
                                       withAttributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.92),
                                                        .font: UIFont.systemFont(ofSize: 300, weight: .heavy),
                                                        .paragraphStyle: p])
        }
        if let data = img.jpegData(compressionQuality: 0.9) {
            DiskImageCache.shared.store(img, data: data, for: urlStr)
            let resp = URLResponse(url: url, mimeType: "image/jpeg",
                                   expectedContentLength: data.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data),
                                                for: URLRequest(url: url))
        }
        return urlStr
    }

    // The full (plaintext) conversation shown when a demo chat is opened — text, photos, files, links.
    static func messages(for cid: String) -> [Message] {
        let me = meUid
        let n = Date()
        func t(_ s: Double) -> Date { n.addingTimeInterval(s) }
        switch cid {
        case "demo-kasim":
            // 60 generated history bubbles BEFORE the curated tail — enough depth to genuinely test
            // scrolling, history paging feel, cluster spacing, and date pills in the browser preview.
            return history(cid, me: me, other: "demo-kasim", endingAt: t(-9000)) + [
                Message(demoId: "\(cid)-0", from: "demo-kasim", "Bro did you finish the design? 👀", t(-8000)),
                Message(demoId: "\(cid)-1", from: me, "Almost! Sending you a preview now", t(-7900)),
                Message(demoImage: "\(cid)-2", from: me,
                        data: imageData(.systemIndigo, .systemBlue, "Preview"), w: 1080, h: 1350, t(-7850)),
                Message(demoId: "\(cid)-3", from: "demo-kasim", "🔥🔥 that looks so clean", t(-7700)),
                Message(demoId: "\(cid)-4", from: "demo-kasim",
                        "Here's the reference I mentioned https://dribbble.com/shots/popular", t(-4000)),
                Message(demoId: "\(cid)-5", from: me, "Perfect, thanks 🙏", t(-240)),
            ]
        case "demo-amin":
            return [
                Message(demoId: "\(cid)-0", from: "demo-amin", "Did the contract come through?", t(-9000)),
                Message(demoId: "\(cid)-1", from: me, "Yep, just signed it. Sending over", t(-8900)),
                Message(demoFile: "\(cid)-2", from: me, name: "Contract-final.pdf", size: 248_000, t(-8800)),
                Message(demoId: "\(cid)-3", from: "demo-amin", "Got it, legend 🙌", t(-8700)),
                Message(demoImage: "\(cid)-4", from: "demo-amin",
                        data: imageData(.systemGreen, .systemTeal, "Office"), w: 1200, h: 900, t(-6000)),
                Message(demoId: "\(cid)-5", from: "demo-amin", "New office is ready, come by 👆", t(-5900)),
                Message(demoId: "\(cid)-6", from: me,
                        "Nice! Details here https://maps.app.goo.gl/office", t(-3700)),
                Message(demoFile: "\(cid)-7", from: "demo-amin", name: "Contract-final.pdf", size: 248_000, t(-3600)),
            ]
        case "demo-amran":
            return [
                Message(demoId: "\(cid)-0", from: "demo-amran", "You HAVE to see this 😂", t(-12000)),
                Message(demoImage: "\(cid)-1", from: "demo-amran",
                        data: imageData(.systemPink, .systemOrange, "LOL"), w: 900, h: 1200, t(-11900)),
                Message(demoId: "\(cid)-2", from: me, "hahaha where did you find this 😭", t(-11700)),
                Message(demoId: "\(cid)-3", from: "demo-amran",
                        "Full video https://youtube.com/watch?v=demo", t(-11000)),
                Message(demoId: "\(cid)-4", from: me, "sending to everyone lol", t(-10000)),
                Message(demoId: "\(cid)-5", from: "demo-amran", "😂 that clip is gold", t(-9000)),
            ]
        case "demo-aisha":
            return [
                Message(demoId: "\(cid)-0", from: "demo-aisha", "It's been ages! How are you?", t(-180000)),
                Message(demoId: "\(cid)-1", from: me, "I know! Doing great, super busy though", t(-179900)),
                Message(demoImage: "\(cid)-2", from: "demo-aisha",
                        data: imageData(.systemPurple, .systemPink, "Trip"), w: 1080, h: 1080, t(-100000)),
                Message(demoId: "\(cid)-3", from: "demo-aisha", "Let's catch up this weekend", t(-86400)),
            ]
        case "demo-omar":
            return [
                Message(demoId: "\(cid)-0", from: "demo-omar", "Yo, still on for football tomorrow?", t(-190000)),
                Message(demoId: "\(cid)-1", from: me, "Definitely. 5pm at the usual pitch?", t(-189900)),
                Message(demoId: "\(cid)-2", from: "demo-omar", "Perfect. I'll bring the ball", t(-180000)),
                Message(demoId: "\(cid)-3", from: "demo-omar", "Sounds good, see you there 👍", t(-172800)),
            ]
        default:
            return []
        }
    }

    // 60 deterministic history messages ending just before `endingAt`: clustered senders (runs of 2-4),
    // varied lengths (one-worders up to multi-line), occasional hour-plus gaps so cluster spacing and
    // time grouping render like a real chat. Pure text — the point is scroll depth, not media.
    private static func history(_ cid: String, me: String, other: String, endingAt: Date) -> [Message] {
        let lines = [
            "hey", "you around?", "yeah what's up", "check this out when you get a sec",
            "lol no way 😂", "I told you it would work", "ok ok you were right",
            "did you watch the game last night? that last goal was unreal, I was screaming",
            "haha same, the whole building heard me",
            "send me the file when you can", "on it", "done ✅", "you're the best 🙌",
            "what time tomorrow?", "let's say 6", "works for me",
            "bro I just found the best shawarma place, we HAVE to go — the garlic sauce alone is worth the trip across town, I'm not even exaggerating",
            "say less, I'm in", "🤝", "wait actually can we do thursday instead?",
            "thursday's fine", "cool cool", "how's the family?", "all good alhamdulillah, yours?",
            "same same", "ok gotta run, talk later", "later 👋", "yo", "??", "one sec",
        ]
        var out: [Message] = []
        var time = endingAt.addingTimeInterval(-36000)   // ~10h of history before the curated tail
        for i in 0..<60 {
            // Sender clusters: runs of 2-4 from the same side (varied by index math, deterministic).
            let run = 2 + (i / 4) % 3
            let from = ((i / run) % 2 == 0) ? other : me
            // Occasional big gaps → time/cluster breaks; otherwise a quick back-and-forth cadence.
            time = time.addingTimeInterval(i % 9 == 0 ? 3600 : Double(90 + (i % 5) * 45))
            out.append(Message(demoId: "\(cid)-h\(i)", from: from, lines[i % lines.count], time))
        }
        return out
    }

    // MARK: - Local image rendering (gradient + label → JPEG bytes / cached URL)

    // Raw JPEG bytes for a demo photo message (goes straight into Message.localImageData, so it
    // renders with NO Firebase — the image bubble shows localImageData directly).
    private static func imageData(_ c1: UIColor, _ c2: UIColor, _ text: String,
                                  _ size: CGSize = CGSize(width: 1080, height: 1350)) -> Data {
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let p = NSMutableParagraphStyle(); p.alignment = .center
            (text as NSString).draw(in: CGRect(x: 0, y: size.height / 2 - 80, width: size.width, height: 220),
                                    withAttributes: [.foregroundColor: UIColor.white,
                                                     .font: UIFont.systemFont(ofSize: 110, weight: .heavy),
                                                     .paragraphStyle: p])
        }
        return img.jpegData(compressionQuality: 0.85) ?? Data()
    }

    private static var cached = Set<String>()
    // Draw a gradient + label, store it in URLCache under a local URL — the story viewer reads
    // URLCache first, so story images render with no network/Firebase.
    private static func cache(_ key: String, _ c1: UIColor, _ c2: UIColor, _ text: String,
                              wide: Bool = false, size explicitSize: CGSize? = nil) -> String {
        let urlStr = "https://fariin.local/\(key).jpg"
        guard !cached.contains(key), let url = URL(string: urlStr) else { return urlStr }
        cached.insert(key)
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

// Plaintext demo messages (no E2EE — fields set directly for display).
extension Message {
    init(demoId: String, from authorId: String, _ text: String, _ createdAt: Date) {
        self.id = demoId; self.authorId = authorId; self.text = text
        self.reactions = [:]; self.createdAt = createdAt
    }
    // Photo message — renders from localImageData (no download/decryption).
    init(demoImage id: String, from authorId: String, data: Data, w: Double, h: Double, _ createdAt: Date) {
        self.id = id; self.authorId = authorId; self.text = ""
        self.reactions = [:]; self.createdAt = createdAt
        self.type = "image"; self.localImageData = data; self.width = w; self.height = h
    }
    // Document message — shows the file name + size chip (demo:// url, no real download).
    init(demoFile id: String, from authorId: String, name: String, size: Int, _ createdAt: Date) {
        self.id = id; self.authorId = authorId; self.text = ""
        self.reactions = [:]; self.createdAt = createdAt
        self.type = "file"; self.fileUrl = "demo://\(name)"; self.fileName = name; self.fileSize = size
    }
}
#endif
