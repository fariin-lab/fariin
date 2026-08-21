import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

// ⛔ TEMPORARY: THIS NOW COMPILES INTO TESTFLIGHT. It was wrapped in `#if DEBUG` and it is not any
// more, because the owner takes the website screenshots on his own phone through TestFlight and
// there was no way to put this data in front of him there.
//
// TURNING IT OFF IS ONE LINE: set `reachableInRelease` to false below and the sign-up screen stops
// recognising the demo username in every build. DO THAT BEFORE THE APP STORE SUBMISSION. A
// shipping messenger should not carry a username that fills itself with invented conversations,
// however well hidden it is.
//
// The visible "Preview demo" button on the login screen is deliberately still `#if DEBUG`, so no
// tester ever sees a way in. The only door is typing the demo username at sign-up.
//
// A cloud simulator can't do Firebase Storage uploads, so real media can't be sent or fetched
// there. This fills the repos with FULLY LOCAL demo data (own + friends' stories, plus a set of
// chats with text, photos, voice notes and files) so the app can be previewed in a browser.
// Triggered by the demo login (username "apple") in onboarding.
//
// ---------------------------------------------------------------------------------------------
// 2026-08-21: THE CONTENT OF THIS FILE IS NOW MARKETING MATERIAL, NOT SCRATCH DATA.
//
// The website needs screenshots of the app, and the screenshots we had were unusable because
// they were full of things typed to nobody: chats called "x test", captions reading "Story B
// (wide)", "Contract-final.pdf", "bro I just found the best shawarma place". Every one of those
// ends up on a public page the moment somebody photographs this screen.
//
// So the demo now reads as a real person's phone: Somali names, Somali conversations, plausible
// times. If you change anything in here, ask one question first — would this look right on the
// front page of the website? If the answer is no, it does not belong in this file any more.
//
// WHAT THE WEBSITE NEEDS PHOTOGRAPHED, and where it comes from:
//   1. the chat list                     -> the Chats tab, straight after login
//   2. the Hooyo conversation            -> open Hooyo. Voice note is in there.
//   3. the Ayaan conversation            -> open Ayaan Warsame. Photo is in there.
//   4. a call running                    -> NOT here. Calls are live, shoot a real one.
//   5. a story open                      -> tap Cabdi's ring.
//
// REAL PHOTOGRAPHS. Every picture below is drawn in code, which is fine for testing layout and
// wrong for a website: a gradient with a word on it does not read as a photograph. Drop real
// JPEGs into the asset catalogue with these names and they are used instead, with no code change:
//
//      demo-photo-wedding    the photo sent in the Ayaan chat
//      demo-story-cabdi      Cabdi's story
//      demo-story-mine       your own story
//      demo-face-hooyo       profile pictures, one per person
//      demo-face-ayaan
//      demo-face-cabdi
//      demo-face-khadra
//
// Anything missing falls back to the drawn version, so the demo never breaks for want of an image.
// ---------------------------------------------------------------------------------------------
enum DemoMode {
    /// ⛔ The whole switch. False and the demo login stops working in every build, debug included.
    /// Set it false before submitting to the App Store. See the note above.
    static let reachableInRelease = true

    // A plain flag the repos can read synchronously from anywhere; written once on the main actor.
    nonisolated(unsafe) static var active = false
    // The signed-in uid, captured at activate() from the SAME source the app renders with
    // (AuthService.shared.uid). Using a mismatched id here made every chat row resolve to "You".
    nonisolated(unsafe) static var meUid = "demo-me"

    @MainActor
    static func activate() {
        active = true
        // Firebase-free demo: Auth.auth().currentUser is nil in the sim, so we FORCE a fixed uid
        // and set it as the app's current user. Every screen resolves `me` from
        // AuthService.shared.uid, so this makes names and isMe render correctly.
        let me = "demo-me"
        meUid = me
        AuthService.shared.uid = me
        let now = Date()

        // Stories. Mine first, then the two people who have posted today.
        let myStory    = story("demo-story-mine",  .systemIndigo, .systemBlue,  "Maanta")
        let cabdiStory = story("demo-story-cabdi", .systemBlue,   .systemTeal,  "Habeenkii Muqdisho")
        let khadraStory = story("demo-story-khadra", .systemPink, .systemOrange, "Casarkii")

        // Profile portraits. Built here so the chat list and the story rings hand the same url to
        // the poster header, and so the whole set exists before any row asks for it.
        let mePhoto     = profilePhoto("demo-face-me",     "me",     .systemIndigo, .systemPurple, "K")
        let hooyoPhoto  = profilePhoto("demo-face-hooyo",  "hooyo",  .systemOrange, .systemYellow, "H")
        let ayaanPhoto  = profilePhoto("demo-face-ayaan",  "ayaan",  .systemBlue,   .systemCyan,   "A")
        let cabdiPhoto  = profilePhoto("demo-face-cabdi",  "cabdi",  .systemGreen,  .systemTeal,   "C")
        let khadraPhoto = profilePhoto("demo-face-khadra", "khadra", .systemPink,   .systemRed,    "K")

        StoriesRepository.shared.mine = StoryGroup(
            authorUid: me, name: "You", photoUrl: mePhoto,
            stories: [
                Story(id: "demo-s1", authorUid: me, createdAt: now.addingTimeInterval(-2700),
                      expiresAt: now.addingTimeInterval(21 * 3600), mediaUrl: myStory,
                      allowsReplies: true, caption: "Maanta"),
            ], lastViewedAt: nil, isMine: true)

        StoriesRepository.shared.others = [
            StoryGroup(authorUid: "demo-cabdi", name: "Cabdi", photoUrl: cabdiPhoto,
                       stories: [Story(id: "demo-c1", authorUid: "demo-cabdi",
                                       createdAt: now.addingTimeInterval(-7200),
                                       expiresAt: now.addingTimeInterval(16 * 3600),
                                       mediaUrl: cabdiStory, allowsReplies: true,
                                       caption: "Habeenkii Muqdisho")],
                       lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo-khadra", name: "Khadra", photoUrl: khadraPhoto,
                       stories: [Story(id: "demo-k1", authorUid: "demo-khadra",
                                       createdAt: now.addingTimeInterval(-14400),
                                       expiresAt: now.addingTimeInterval(9 * 3600),
                                       mediaUrl: khadraStory, allowsReplies: true)],
                       lastViewedAt: nil, isMine: false),
        ]

        // The chat list, top to bottom. The preview strings are written the way ChatService itself
        // writes them, markers and all, so the row renders exactly as a real one does.
        //
        // Hooyo carries 2 unread. That is deliberate: the badge is half of what makes a chat list
        // look like somebody's phone rather than a screenshot of an empty app.
        ConversationsRepository.shared.conversations = [
            chat("demo-hooyo",  me, "demo-hooyo",  "Hooyo",         now.addingTimeInterval(-260),
                 "Ma soo gaadhay guriga?", hooyoPhoto, unread: 2),
            chat("demo-ayaan",  me, "demo-ayaan",  "Ayaan Warsame", now.addingTimeInterval(-2100),
                 "I will call you after Maghrib", ayaanPhoto),
            chat("demo-cabdi",  me, "demo-cabdi",  "Cabdi",         now.addingTimeInterval(-8000),
                 "🎤 Voice message · 0:14", cabdiPhoto),
            chat("demo-khadra", me, "demo-khadra", "Khadra",        now.addingTimeInterval(-12000),
                 "📷 Photo", khadraPhoto),
            chat("demo-ilhan",  me, "demo-ilhan",  "Ilhan",         now.addingTimeInterval(-93000),
                 "Mahadsanid walaal", ""),
            // Deliberately LEFT WITHOUT A PHOTO, so the preview also shows the other half of the
            // rule: no picture means the classic coloured circle, never an empty poster.
            chat("demo-faarax", me, "demo-faarax", "Faarax",        now.addingTimeInterval(-176400),
                 "Berri ma is aragnaa?", ""),
        ]
        ConversationsRepository.shared.hasLoaded = true
    }

    private static func chat(_ id: String, _ me: String, _ other: String, _ name: String, _ at: Date,
                             _ last: String, _ photo: String, unread: Int = 0) -> Conversation {
        var data: [String: Any] = [
            "users": [me, other],
            "names": [other: name, me: "You"],
            // Without this every demo person is a coloured letter, so the preview could never show
            // the poster header at all — it needs a real photo before it will draw.
            "photos": [other: photo],
            "lastSender": other,
            "lastMessage": last,
            "updatedAt": Timestamp(date: at),
        ]
        if unread > 0 { data["unreadCount"] = [me: unread] }
        return Conversation(id: id, data: data)
    }

    // MARK: - The conversations

    /// The full (plaintext) conversation shown when a demo chat is opened.
    static func messages(for cid: String) -> [Message] {
        let me = meUid
        let n = Date()
        func t(_ s: Double) -> Date { n.addingTimeInterval(s) }

        switch cid {

        // The one the website leads with. Read it out loud before changing a word of it: a mother
        // asking her son whether he got home, and a voice note back because typing is slower than
        // talking. The last two are hers and unanswered, which is what the 2 on the badge means.
        case "demo-hooyo":
            return history(cid, me: me, other: "demo-hooyo", endingAt: t(-9000)) + [
                Message(demoId: "\(cid)-0", from: "demo-hooyo", "Salaam walaal, sidee tahay?", t(-600)),
                Message(demoId: "\(cid)-1", from: me, "Waan fiicanahay hooyo, adiga?", t(-540)),
                Message(demoAudio: "\(cid)-2", from: me, data: silence(seconds: 14),
                        duration: 14, waveform: voicePattern, t(-500)),
                Message(demoId: "\(cid)-3", from: "demo-hooyo", "Waan ku xiisay", t(-320)),
                Message(demoId: "\(cid)-4", from: "demo-hooyo", "Ma soo gaadhay guriga?", t(-260)),
            ]

        // The one with a photograph in it. Drop demo-photo-wedding into the asset catalogue and
        // this becomes a real picture of a real day instead of a coloured rectangle.
        case "demo-ayaan":
            return history(cid, me: me, other: "demo-ayaan", endingAt: t(-40000)) + [
                Message(demoId: "\(cid)-0", from: "demo-ayaan", "Subax wanaagsan", t(-33000)),
                Message(demoId: "\(cid)-1", from: me, "Subax wanaagsan walaal", t(-32800)),
                Message(demoId: "\(cid)-2", from: "demo-ayaan", "Sawirkii aroostii ma i soo dirtay?", t(-9000)),
                Message(demoImage: "\(cid)-3", from: me,
                        data: photoData("demo-photo-wedding", .systemIndigo, .systemBlue, "Aroos"),
                        w: 1080, h: 1350, t(-8800)),
                Message(demoId: "\(cid)-4", from: "demo-ayaan", "Mashallah, aad ayay u quruxsan tahay", t(-8600)),
                Message(demoId: "\(cid)-5", from: me, "Mahadsanid", t(-8400)),
                Message(demoId: "\(cid)-6", from: "demo-ayaan", "I will call you after Maghrib", t(-2100)),
            ]

        case "demo-cabdi":
            return [
                Message(demoId: "\(cid)-0", from: me, "Cabdi, ma maqashay warkii?", t(-12000)),
                Message(demoId: "\(cid)-1", from: "demo-cabdi", "Haa, waan maqlay", t(-11800)),
                Message(demoId: "\(cid)-2", from: "demo-cabdi", "Sug, cod ayaan kuu dirayaa", t(-8200)),
                Message(demoAudio: "\(cid)-3", from: "demo-cabdi", data: silence(seconds: 14),
                        duration: 14, waveform: voicePattern, t(-8000)),
            ]

        case "demo-khadra":
            return [
                Message(demoId: "\(cid)-0", from: "demo-khadra", "Cuntada caawa waa mid macaan", t(-12400)),
                Message(demoImage: "\(cid)-1", from: "demo-khadra",
                        data: photoData("demo-photo-dinner", .systemOrange, .systemRed, "Casho"),
                        w: 1200, h: 900, t(-12000)),
            ]

        case "demo-ilhan":
            return [
                Message(demoId: "\(cid)-0", from: me, "Ilhan, buugga waan kuu keenay", t(-94000)),
                Message(demoId: "\(cid)-1", from: "demo-ilhan", "Runtii?", t(-93600)),
                Message(demoId: "\(cid)-2", from: me, "Haa, berri ayaan ku siin doonaa", t(-93200)),
                Message(demoId: "\(cid)-3", from: "demo-ilhan", "Mahadsanid walaal", t(-93000)),
            ]

        case "demo-faarax":
            return [
                Message(demoId: "\(cid)-0", from: "demo-faarax", "Kaalay kubbadda", t(-178000)),
                Message(demoId: "\(cid)-1", from: me, "Saacadda meeqa?", t(-177600)),
                Message(demoId: "\(cid)-2", from: "demo-faarax", "Shanta galabnimo", t(-177000)),
                Message(demoId: "\(cid)-3", from: "demo-faarax", "Berri ma is aragnaa?", t(-176400)),
            ]

        default:
            return []
        }
    }

    /// Deterministic history above the curated tail: clustered senders, varied lengths, occasional
    /// hour-plus gaps, so cluster spacing and date pills render like a real chat when you scroll up.
    ///
    /// These lines used to be English filler and they are Somali now for one reason: anybody
    /// photographing this screen might scroll, and whatever is on screen when they do ends up on
    /// the website. There is no part of this file that is safe to leave as scratch text.
    private static func history(_ cid: String, me: String, other: String, endingAt: Date) -> [Message] {
        let lines = [
            "Salaam", "Ma nabad baa?", "Waa nabad, adiga?", "Waan fiicanahay alxamdulillah",
            "Xaggee tahay?", "Guriga ayaan joogaa", "Goorma ayaad imanaysaa?",
            "Waan soo socdaa, wax yar sug", "Waa hagaag",
            "Reerka sidee yihiin?", "Dhammaantood waa fiican yihiin, mahadsanid",
            "Hooyo ma salaantay?", "Haa, shalay ayaan la hadlay",
            "Waqtiga halkan waa duhur, halkaas?", "Habeen ayaa noo ah",
            "Waan ku soo wacayaa markaan shaqada ka baxo",
            "Iska daa, subax ayaan kuu soo diri doonaa", "Waa yahay",
            "Mahadsanid walaal", "Adaa mudan", "Insha Allah",
            "Nabad gelyo", "Habeen wanaagsan", "Subax wanaagsan",
            "Ma i maqlaysaa?", "Haa, si fiican", "Codku wuu go'ay",
            "Ku soo wac mar kale", "Waan soo wacayaa", "Ok",
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

    // MARK: - Voice notes

    /// A believable waveform. Not random: a real voice note starts quiet, has two or three loud
    /// runs where the sentence is, and trails off. A flat or noisy bar chart reads as fake at a
    /// glance and this bubble is going on the website.
    private static let voicePattern: [Int] = [
        12, 22, 38, 55, 71, 64, 48, 33, 26, 41,
        62, 84, 92, 78, 59, 44, 31, 24, 37, 58,
        76, 88, 69, 51, 35, 28, 45, 66, 43, 21,
    ]

    /// Silence, as a real WAV. The bubble only needs the duration and the waveform to draw, but a
    /// zero-byte blob turns the play button into a crash the first time somebody taps it, and the
    /// person taking the screenshots will tap it.
    private static func silence(seconds: Double) -> Data {
        let rate = 8000, channels = 1, bits = 16
        let frames = Int(Double(rate) * seconds)
        let dataBytes = frames * channels * bits / 8
        var d = Data()
        func le32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(channels)
        le32(rate); le32(rate * channels * bits / 8); le16(channels * bits / 8); le16(bits)
        d.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        d.append(Data(count: dataBytes))
        return d
    }

    // MARK: - Pictures: a real one if there is one, a drawn one if there is not

    /// JPEG bytes for a photo message. Looks for a real image in the asset catalogue first, so
    /// dropping a photograph in under the right name replaces the drawn stand-in with no code
    /// change. See the note at the top of this file for the names.
    private static func photoData(_ assetName: String, _ c1: UIColor, _ c2: UIColor, _ label: String,
                                  _ size: CGSize = CGSize(width: 1080, height: 1350)) -> Data {
        if let real = UIImage(named: assetName), let data = real.jpegData(compressionQuality: 0.9) {
            return data
        }
        return drawn(c1, c2, label, size: size, fontSize: 110)
            .jpegData(compressionQuality: 0.85) ?? Data()
    }

    /// A story image, cached under a local URL. The story viewer reads URLCache first, so this
    /// renders with no network and no Firebase. Real image wins if one is present.
    private static func story(_ assetName: String, _ c1: UIColor, _ c2: UIColor, _ label: String) -> String {
        let urlStr = "https://fariin.local/\(assetName).jpg"
        guard !cached.contains(assetName), let url = URL(string: urlStr) else { return urlStr }
        cached.insert(assetName)
        let size = CGSize(width: 1080, height: 1920)
        let img = UIImage(named: assetName) ?? drawn(c1, c2, label, size: size, fontSize: 120)
        if let data = img.jpegData(compressionQuality: 0.85) {
            let resp = URLResponse(url: url, mimeType: "image/jpeg",
                                   expectedContentLength: data.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data),
                                                for: URLRequest(url: url))
        }
        return urlStr
    }

    /// A square portrait, stored WHERE THE REAL PHOTO PATH LOOKS FOR IT.
    ///
    /// `story(_:)` puts its images in URLCache, which is where the story viewer reads. Profile
    /// photos are read somewhere else entirely: AvatarView seeds itself synchronously from
    /// DiskImageCache, and the poster header reads the same store. A demo photo living only in
    /// URLCache is invisible to both, so it goes in both.
    ///
    /// The drawn fallback is blobs, not a plain gradient. A flat gradient blurs to itself, so the
    /// progressive fade at the bottom of the poster would be impossible to judge — there has to be
    /// detail for it to destroy.
    private static func profilePhoto(_ assetName: String, _ key: String,
                                     _ c1: UIColor, _ c2: UIColor, _ initial: String) -> String {
        let urlStr = "https://fariin.local/pp-\(key).jpg"
        guard !cached.contains("pp-\(key)"), let url = URL(string: urlStr) else { return urlStr }
        cached.insert("pp-\(key)")
        let size = CGSize(width: 900, height: 900)
        let img = UIImage(named: assetName) ?? UIGraphicsImageRenderer(size: size).image { ctx in
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

    private static var cached = Set<String>()

    /// The stand-in: a gradient with a word on it. Only ever seen when the matching real image is
    /// not in the bundle.
    private static func drawn(_ c1: UIColor, _ c2: UIColor, _ text: String,
                              size: CGSize, fontSize: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let p = NSMutableParagraphStyle(); p.alignment = .center
            (text as NSString).draw(in: CGRect(x: 0, y: size.height / 2 - fontSize * 0.7,
                                               width: size.width, height: fontSize * 2),
                                    withAttributes: [.foregroundColor: UIColor.white,
                                                     .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                                                     .paragraphStyle: p])
        }
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
    // Voice note — renders the waveform + duration from local bytes, same as an optimistic send.
    init(demoAudio id: String, from authorId: String, data: Data,
         duration: Double, waveform: [Int], _ createdAt: Date) {
        self.id = id; self.authorId = authorId; self.text = ""
        self.reactions = [:]; self.createdAt = createdAt
        self.type = "audio"; self.localAudioData = data
        self.duration = duration; self.waveform = waveform
    }
    // Document message — shows the file name + size chip (demo:// url, no real download).
    init(demoFile id: String, from authorId: String, name: String, size: Int, _ createdAt: Date) {
        self.id = id; self.authorId = authorId; self.text = ""
        self.reactions = [:]; self.createdAt = createdAt
        self.type = "file"; self.fileUrl = "demo://\(name)"; self.fileName = name; self.fileSize = size
    }
}
