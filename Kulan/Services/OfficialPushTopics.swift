import Foundation
import FirebaseMessaging

// WHICH NOTIFICATIONS THIS PHONE HAS AGREED TO HEAR FROM THE OFFICIAL CHANNEL.
//
// The channel is PULLED, not pushed: one announcement document that every phone reads, and the
// phone decides whether it is for them. Nothing about that changes here. What changes is that the
// phone now also gets knocked on, because until this existed an announcement only arrived while the
// app happened to be open and listening, so a security alert could sit unseen for days.
//
// A push cannot be filtered after it leaves, so the decision of WHO hears it has to be made before
// it is sent. That is exactly what a topic is: the phone puts its own hand up. Two families, and the
// difference between them is a promise the app makes out loud:
//
//   ann_*  news, features, release notes, maintenance. The channel is muted for everybody by
//          default and the welcome message says "we are here to share important updates, not spam
//          your notifications". So this phone is not in these topics at all until somebody turns
//          the bell on, and steps straight back out when they turn it off. Mute is not a filter
//          applied on arrival; it is not being on the list.
//
//   sec_*  security alerts. Chat Info promises these arrive even if the chat is BLOCKED, so they
//          cannot hang off the bell. This phone stays in them for as long as the account is signed
//          in and notifications are on at all.
//
// Country is the phone's own region setting, the same value `Announcement.reaches` already targets
// on, so a country send knocks on the same doors it would have shown itself to. There is no
// equivalent for a partial rollout or a minimum build: both need something only the phone knows, so
// the server sends nothing for those and the compose screen says so before you send.
enum OfficialPushTopics {
    /// What we last told Firebase. Without this a phone that changes its region would sit in the old
    /// country's topic forever, because unsubscribing needs the name of a topic nobody remembers.
    private static let joinedKey = "official.push.topics"

    /// The app-wide Show Notifications switch. Read here too: turning it off has to mean silence
    /// from this chat as well, and topics survive a token being dropped.
    private static var notificationsAllowed: Bool {
        UserDefaults.standard.object(forKey: "notif.push") as? Bool ?? true
    }

    private static var countrySuffix: String? {
        guard let code = Locale.current.region?.identifier.uppercased(),
              code.count == 2, code.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        return code
    }

    /// The topics this phone should be in right now.
    private static func wanted(muted: Bool, signedIn: Bool) -> Set<String> {
        guard signedIn, notificationsAllowed else { return [] }
        var topics: Set<String> = ["sec_all"]
        if let country = countrySuffix { topics.insert("sec_c_\(country)") }
        guard !muted else { return topics }
        topics.insert("ann_all")
        if let country = countrySuffix { topics.insert("ann_c_\(country)") }
        return topics
    }

    /// Join what is missing, leave what is no longer wanted, remember the result.
    ///
    /// Safe to call as often as it likes: the difference against what we last joined is what gets
    /// sent, so a launch that changes nothing costs nothing. It is called from the state listener,
    /// which fires on launch, on every mute change, and on a mute made from the account's other
    /// phone.
    static func sync(muted: Bool, signedIn: Bool = true) {
        let defaults = UserDefaults.standard
        let joined = Set(defaults.stringArray(forKey: joinedKey) ?? [])
        let target = wanted(muted: muted, signedIn: signedIn)
        guard joined != target else { return }

        for topic in target.subtracting(joined) {
            Messaging.messaging().subscribe(toTopic: topic) { error in
                if let error { print("official push: could not join \(topic):", error) }
            }
        }
        for topic in joined.subtracting(target) {
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if let error { print("official push: could not leave \(topic):", error) }
            }
        }
        // Written even if a call above fails. The alternative is retrying forever on a topic Firebase
        // has already dropped, and the next sync re-derives the whole set anyway.
        defaults.set(Array(target), forKey: joinedKey)
    }

    /// Sign-out, account switch, or the app-wide notification switch going off. The next account on
    /// this phone must not inherit the last one's alerts.
    static func leaveAll() {
        sync(muted: true, signedIn: false)
    }
}
