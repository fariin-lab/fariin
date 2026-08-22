import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

// TESTFLIGHT AND DEBUG, NEVER THE APP STORE. This was wrapped in `#if DEBUG`, which put it in no
// build the owner can run: the TestFlight lane builds Release and he has no Mac. `DemoStoryMedia`
// already hit this and already fixed it properly, so `isAvailable` below just borrows its answer.
// Nothing here needs anybody to remember to flip a switch before submitting.
//
// HOW HE ACTUALLY REACHES IT: Settings, "Demo chats". Six local chats appear in his own list next
// to his real ones, he takes the pictures, he switches it off. He never signs out and his account
// is never touched. The demo LOGIN below still exists for the browser simulator, but it is the long
// way round on a phone, because the username screen only appears after a real sign-in succeeds.
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
// REAL PHOTOGRAPHS. Anything missing falls back to a drawing — a gradient with the name and an
// elapsed-second counter painted on it, which is fine for checking layout and useless for the
// website screenshots this exists to produce. Drop a JPEG into the asset catalogue under the name
// the code asks for and it is used instead, with no code change.
//
// ⚠️ THIS COMMENT USED TO LIST THE NAMES AND THE LIST WAS WRONG. It named seven; the code reaches
// for more than twenty, and the three it missed (`demo-story-khadra`, `demo-face-me`,
// `demo-photo-dinner`) stayed as gradients through a whole round of "the photos are done". A list
// maintained by hand next to code that keeps growing is a list that lies. Ask the source instead:
//
//   comm -23 <(grep -o '"demo-\(story\|face\|photo\)-[a-z0-9-]*"' Kulan/Services/DemoMode.swift \
//                | tr -d '"' | sort -u) \
//            <(ls -d Kulan/Resources/Assets.xcassets/demo-*.imageset \
//                | sed 's|.*/||;s|\.imageset||' | sort)
//
// Anything it prints is a picture the demo wants and does not have.
//
// WHAT MAY GO IN HERE. The owner's own AI-made images can show people, because there is no real
// person in them to clear. Bought or free stock may NOT be used for a face: the licence covers the
// photograph, not the human being in it, and these end up on a public marketing page. Everything
// sourced from Pexels here is deliberately scenery and objects.
// ---------------------------------------------------------------------------------------------
enum DemoMode {
    /// Debug or TestFlight, NEVER the App Store. Borrowed wholesale from `DemoStoryMedia`, which
    /// already had to solve exactly this and solved it correctly: the receipt name is the honest
    /// test for "this build came from TestFlight", and it needs nobody to remember to flip a switch
    /// before submitting. Do not replace this with a hand-set Bool.
    static var isAvailable: Bool { DemoStoryMedia.isAvailable }

    /// THE ONE HE ACTUALLY USES. A switch in Settings turns this on and six demo chats appear in
    /// his own chat list, next to his real ones. He stays signed in, nothing is written anywhere,
    /// and turning it off puts the list back.
    ///
    /// This exists because the other door — sign out, sign up, type the demo username — is behind a
    /// screen that only appears AFTER a real sign-in succeeds. Reaching it means making a second
    /// Apple or Google account, which is an absurd price for looking at demo data on your own phone.
    nonisolated(unsafe) static var chatsInjected = false

    /// The six rows, built once when the switch goes on and held here.
    ///
    /// They are CACHED rather than rebuilt per call for one reason that is not performance:
    /// `withDemoChats` is called from `ConversationsRepository.publish`, and that class is not
    /// main-actor isolated. Building the rows needs the signed-in uid and draws the fallback
    /// portraits with UIKit, so it has to happen on the main actor, at the moment of the tap.
    /// Reading a finished array afterwards needs no isolation at all.
    nonisolated(unsafe) static var demoChats: [Conversation] = []

    /// The story-row half of the same switch, cached for exactly the same reason: `StoriesService`
    /// builds the row off the main actor, and making these needs UIKit to draw the fallback art.
    /// Built at the tap, read anywhere afterwards.
    ///
    /// The times inside are fixed at the moment the switch goes on. That is correct rather than
    /// merely convenient — a story row whose ages recomputed on every rebuild would drift out of
    /// step with the "N hours ago" already on screen.
    nonisolated(unsafe) static var demoStories: [StoryGroup] = []

    /// Whether a conversation id belongs to the demo set. Everything downstream asks THIS rather
    /// than the global `active` flag, so a demo chat and a real chat can sit in one list without the
    /// demo rules leaking onto the real one. Get this wrong and every real preview renders as
    /// ciphertext.
    static func isDemoConversation(_ cid: String) -> Bool { cid.hasPrefix("demo-") }

    /// Turn the switch on: build the rows now, on the main actor, while there is a uid to build
    /// them against. Off clears them, so nothing is left holding memory or waiting to reappear.
    @MainActor
    static func setChats(_ on: Bool) {
        demoChats = on ? demoConversations() : []
        demoStories = on ? demoStoryPeople() : []
        chatsInjected = on
    }

    /// Called from `ConversationsRepository.publish`. A no-op unless the switch is on, so it costs
    /// one Bool check on the hot path. It has to live there rather than at the toggle, because the
    /// live Firestore listener reassigns the whole array on every snapshot and would otherwise wipe
    /// the demo rows a second after they appeared.
    static func withDemoChats(_ convs: [Conversation]) -> [Conversation] {
        guard chatsInjected, !demoChats.isEmpty else { return convs }
        return demoChats + convs.filter { !isDemoConversation($0.id) }
    }

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
        //
        // FOUR EACH, NOT ONE. A single story per person leaves the viewer with no progress bar
        // segments at the top — which is the one piece of chrome that says "story" rather than
        // "photo" — and it makes tapping through impossible to demonstrate. Four gives a real
        // segmented bar and something to advance to.
        let myStory    = story("demo-story-mine",  .systemIndigo, .systemBlue,  "Maanta")
        let myStory2   = story("demo-story-mine-2", .systemOrange, .systemRed,  "Qorrax dhac")
        let myStory3   = story("demo-story-mine-3", .systemIndigo, .systemPurple, "Habeenkii")
        let myStory4   = story("demo-story-mine-4", .systemGray,  .systemBlue,  "Roob")
        // The owner's own image, AI-made, so there is no real person in it and nothing to clear.
        // First in his list on purpose: it is what appears the instant you tap his ring, which is
        // the frame a screenshot is actually taken of.
        let cabdiStory = story("demo-story-cabdi", .systemBlue,   .systemTeal,  "Habeenkii Muqdisho")
        let cabdiStory2 = story("demo-story-cabdi-2", .systemOrange, .systemYellow, "Duurka")
        let cabdiStory3 = story("demo-story-cabdi-3", .systemBrown, .systemOrange, "Geeljire")
        let cabdiStory4 = story("demo-story-cabdi-4", .systemTeal, .systemBlue,  "Masaajidka")
        let cabdiStory5 = story("demo-story-cabdi-5", .systemBrown, .systemOrange, "Waddada")
        let khadraStory = story("demo-story-khadra", .systemPink, .systemOrange, "Casarkii")
        let khadraStory2 = story("demo-story-khadra-2", .systemGreen, .systemYellow, "Suuqa")
        let khadraStory3 = story("demo-story-khadra-3", .systemYellow, .systemOrange, "Bacaadka")
        let khadraStory4 = story("demo-story-khadra-4", .systemTeal, .systemGreen, "Xeebta")

        // Profile portraits. Built here so the chat list and the story rings hand the same url to
        // the poster header, and so the whole set exists before any row asks for it.
        let mePhoto     = profilePhoto("demo-face-me",     "me",     .systemIndigo, .systemPurple, "K")
        let cabdiPhoto  = profilePhoto("demo-face-cabdi",  "cabdi",  .systemGreen,  .systemTeal,   "C")
        let khadraPhoto = profilePhoto("demo-face-khadra", "khadra", .systemPink,   .systemRed,    "K")

        StoriesRepository.shared.mine = StoryGroup(
            authorUid: me, name: "You", photoUrl: mePhoto,
            // Oldest first. The viewer plays them in array order, so a shuffled list would run the
            // evening shot before the afternoon one and the timestamps would read backwards.
            stories: [
                Story(id: "demo-s1", authorUid: me, createdAt: now.addingTimeInterval(-19800),
                      expiresAt: now.addingTimeInterval(18 * 3600), mediaUrl: myStory,
                      allowsReplies: true, caption: "Maanta"),
                Story(id: "demo-s2", authorUid: me, createdAt: now.addingTimeInterval(-12600),
                      expiresAt: now.addingTimeInterval(20 * 3600), mediaUrl: myStory2,
                      allowsReplies: true, caption: "Qorrax dhac"),
                Story(id: "demo-s3", authorUid: me, createdAt: now.addingTimeInterval(-6300),
                      expiresAt: now.addingTimeInterval(22 * 3600), mediaUrl: myStory3,
                      allowsReplies: true),
                Story(id: "demo-s4", authorUid: me, createdAt: now.addingTimeInterval(-2700),
                      expiresAt: now.addingTimeInterval(23 * 3600), mediaUrl: myStory4,
                      allowsReplies: true, caption: "Roob"),
            ], lastViewedAt: nil, isMine: true)

        StoriesRepository.shared.others = [
            StoryGroup(authorUid: "demo-cabdi", name: "Cabdi", photoUrl: cabdiPhoto,
                       stories: [
                        Story(id: "demo-c1", authorUid: "demo-cabdi",
                              createdAt: now.addingTimeInterval(-25200),
                              expiresAt: now.addingTimeInterval(13 * 3600),
                              mediaUrl: cabdiStory, allowsReplies: true, caption: "Habeenkii Muqdisho"),
                        Story(id: "demo-c2", authorUid: "demo-cabdi",
                              createdAt: now.addingTimeInterval(-18000),
                              expiresAt: now.addingTimeInterval(15 * 3600),
                              mediaUrl: cabdiStory2, allowsReplies: true, caption: "Duurka"),
                        Story(id: "demo-c3", authorUid: "demo-cabdi",
                              createdAt: now.addingTimeInterval(-10800),
                              expiresAt: now.addingTimeInterval(17 * 3600),
                              mediaUrl: cabdiStory3, allowsReplies: true, caption: "Geeljire"),
                        Story(id: "demo-c4", authorUid: "demo-cabdi",
                              createdAt: now.addingTimeInterval(-5400),
                              expiresAt: now.addingTimeInterval(19 * 3600),
                              mediaUrl: cabdiStory4, allowsReplies: true),
                        Story(id: "demo-c5", authorUid: "demo-cabdi",
                              createdAt: now.addingTimeInterval(-3600),
                              expiresAt: now.addingTimeInterval(20 * 3600),
                              mediaUrl: cabdiStory5, allowsReplies: true, caption: "Waddada"),
                       ], lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo-khadra", name: "Khadra", photoUrl: khadraPhoto,
                       stories: [
                        Story(id: "demo-k1", authorUid: "demo-khadra",
                              createdAt: now.addingTimeInterval(-28800),
                              expiresAt: now.addingTimeInterval(8 * 3600),
                              mediaUrl: khadraStory, allowsReplies: true, caption: "Casarkii"),
                        Story(id: "demo-k2", authorUid: "demo-khadra",
                              createdAt: now.addingTimeInterval(-21600),
                              expiresAt: now.addingTimeInterval(10 * 3600),
                              mediaUrl: khadraStory2, allowsReplies: true, caption: "Suuqa"),
                        Story(id: "demo-k3", authorUid: "demo-khadra",
                              createdAt: now.addingTimeInterval(-14400),
                              expiresAt: now.addingTimeInterval(12 * 3600),
                              mediaUrl: khadraStory3, allowsReplies: true),
                        Story(id: "demo-k4", authorUid: "demo-khadra",
                              createdAt: now.addingTimeInterval(-9000),
                              expiresAt: now.addingTimeInterval(14 * 3600),
                              mediaUrl: khadraStory4, allowsReplies: true, caption: "Xeebta"),
                       ], lastViewedAt: nil, isMine: false),
        ]

        ConversationsRepository.shared.conversations = demoConversations()
        ConversationsRepository.shared.hasLoaded = true
    }

    /// ⭐ THE SAME STORIES, FOR THE SETTINGS SWITCH RATHER THAN THE FULL DEMO LOGIN.
    ///
    /// `activate()` above is the takeover: it replaces the whole app with a demo, and it is reached
    /// only by signing out. The switch in Settings does something much smaller — it injects rows
    /// into the real account — and it injected CHATS ONLY. So Cabdi and Khadra existed in the chat
    /// list with their photographs while the story row above them showed a different, older set of
    /// demo people with drawn placeholders. Different names, different faces, same screen.
    ///
    /// This hands the story row the same two people the chat list already has.
    ///
    /// `mine` is deliberately NOT touched. The owner has a real story of his own, and replacing it
    /// with a demo one to take a screenshot of his own app would be the wrong trade.
    @MainActor
    static func demoStoryPeople(now: Date = Date()) -> [StoryGroup] {
        let cabdiPhoto  = profilePhoto("demo-face-cabdi",  "cabdi",  .systemGreen, .systemTeal, "C")
        let khadraPhoto = profilePhoto("demo-face-khadra", "khadra", .systemPink,  .systemRed,  "K")
        func s(_ n: Int, _ uid: String, _ asset: String, _ ago: Double, _ caption: String?) -> Story {
            Story(id: "demo-\(uid)-\(n)", authorUid: uid,
                  createdAt: now.addingTimeInterval(-ago),
                  expiresAt: now.addingTimeInterval(24 * 3600 - ago),
                  mediaUrl: story(asset, .systemBlue, .systemTeal, caption ?? ""),
                  // `Story.caption` is a plain String, not an optional. The nil here means "no
                  // caption on this one", which on the model is the empty string.
                  allowsReplies: true, caption: caption ?? "")
        }
        return [
            StoryGroup(authorUid: "demo-cabdi", name: "Cabdi", photoUrl: cabdiPhoto, stories: [
                s(1, "demo-cabdi", "demo-story-cabdi",   25200, "Habeenkii Muqdisho"),
                s(2, "demo-cabdi", "demo-story-cabdi-2", 18000, "Duurka"),
                s(3, "demo-cabdi", "demo-story-cabdi-3", 10800, "Geeljire"),
                s(4, "demo-cabdi", "demo-story-cabdi-4",  5400, nil),
                s(5, "demo-cabdi", "demo-story-cabdi-5",  3600, "Waddada"),
            ], lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo-khadra", name: "Khadra", photoUrl: khadraPhoto, stories: [
                s(1, "demo-khadra", "demo-story-khadra",   28800, "Casarkii"),
                s(2, "demo-khadra", "demo-story-khadra-2", 21600, "Suuqa"),
                s(3, "demo-khadra", "demo-story-khadra-3", 14400, nil),
                s(4, "demo-khadra", "demo-story-khadra-4",  9000, "Xeebta"),
            ], lastViewedAt: nil, isMine: false),
        ]
    }

    /// The chat list, top to bottom. The preview strings are written the way ChatService itself
    /// writes them, markers and all, so each row renders exactly as a real one does.
    ///
    /// Hooyo carries 2 unread. That is deliberate: the badge is half of what makes a chat list look
    /// like somebody's phone rather than a screenshot of an empty app.
    ///
    /// Built fresh on every call because the times are relative to now — a list built at launch and
    /// kept would drift to "3h" while he is still lining up the shot.
    @MainActor
    static func demoConversations() -> [Conversation] {
        // Whoever is signed in. In the injected case that is his real uid, so the demo rows sit in
        // his own list correctly and every bubble resolves to the right side; in the full takeover
        // there is no Firebase user and it falls back to "demo-me".
        let signedIn = AuthService.shared.uid ?? ""
        let me = signedIn.isEmpty ? meUid : signedIn
        meUid = me
        let now = Date()
        let hooyoPhoto  = profilePhoto("demo-face-hooyo",  "hooyo",  .systemOrange, .systemYellow, "H")
        let ayaanPhoto  = profilePhoto("demo-face-ayaan",  "ayaan",  .systemBlue,   .systemCyan,   "A")
        let cabdiPhoto  = profilePhoto("demo-face-cabdi",  "cabdi",  .systemGreen,  .systemTeal,   "C")
        let khadraPhoto = profilePhoto("demo-face-khadra", "khadra", .systemPink,   .systemRed,    "K")
        // THE ONE NAME IN THIS LIST THAT IS NOT SOMALI, and it is there on purpose. Every other row
        // is family or a friend back home; this app is for people living far from the people they
        // love, which means their list also has the colleague, the classmate, the neighbour where
        // they actually live. A demo of six Somali names would show only half of that life.
        let linneaPhoto = profilePhoto("demo-face-linnea", "linnea", .systemGreen,  .systemMint,   "L")
        let ilhanPhoto  = profilePhoto("demo-face-ilhan",  "ilhan",  .systemPurple, .systemPink,   "I")
        return [
            chat("demo-hooyo",  me, "demo-hooyo",  "Hooyo",         now.addingTimeInterval(-260),
                 "Ma soo gaadhay guriga?", hooyoPhoto, unread: 2),
            chat("demo-ayaan",  me, "demo-ayaan",  "Ayaan Warsame", now.addingTimeInterval(-2100),
                 "I will call you after Maghrib", ayaanPhoto),
            chat("demo-cabdi",  me, "demo-cabdi",  "Cabdi",         now.addingTimeInterval(-8000),
                 "🎤 Voice message · 0:14", cabdiPhoto),
            chat("demo-khadra", me, "demo-khadra", "Khadra",        now.addingTimeInterval(-12000),
                 "📷 Photo", khadraPhoto),
            chat("demo-linnea", me, "demo-linnea", "Linnea",        now.addingTimeInterval(-26000),
                 "See you at the library at 4?", linneaPhoto),
            // Not a face, and that is not a compromise. A soft toy, a cup, a view: this is what a
            // great many real profile pictures actually are, and a list where all seven are portraits
            // would be the unrealistic one.
            chat("demo-ilhan",  me, "demo-ilhan",  "Ilhan",         now.addingTimeInterval(-93000),
                 "Mahadsanid walaal", ilhanPhoto),
            // ⛔ THE LAST ONE STAYS WITHOUT A PHOTO ON PURPOSE — do not "finish" this by giving him
            // one. Somebody with no picture is the commonest row in any real chat list, and the
            // coloured letter circle is a piece of the design that has to be visible in a screenshot
            // too. Six with pictures and one without is the honest ratio.
            chat("demo-faarax", me, "demo-faarax", "Faarax",        now.addingTimeInterval(-176400),
                 "Berri ma is aragnaa?", ""),
        ]
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

        // IN ENGLISH, AND THAT IS THE POINT OF HER. The rest of this list is Somali because it is
        // family and friends back home. This is the classmate where he actually lives, and the
        // language switches with the person — which is exactly how the app gets used and something
        // a screenshot of six Somali names could never show.
        case "demo-linnea":
            return [
                Message(demoId: "\(cid)-0", from: "demo-linnea", "Did you finish the reading?", t(-28000)),
                Message(demoId: "\(cid)-1", from: me, "Almost. Two chapters left", t(-27600)),
                Message(demoId: "\(cid)-2", from: "demo-linnea", "Same. Coffee first though", t(-27200)),
                Message(demoId: "\(cid)-3", from: me, "Always", t(-26800)),
                Message(demoId: "\(cid)-4", from: "demo-linnea", "See you at the library at 4?", t(-26000)),
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
