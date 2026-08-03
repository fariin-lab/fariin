import Foundation

/// The one answer to "does this person have a profile photo, and may I see it?" — available
/// SYNCHRONOUSLY, on the first frame, without a fetch.
///
/// WHY IT EXISTS. The profile page must choose between the tall photo header and the classic circle
/// before it draws anything, and it must never change its mind afterwards (owner, 2026-08-03: "no
/// flickering, switching, or delayed updates"). Every earlier rule asked a question whose answer
/// could arrive late or be wrong:
///
///  · **"is the url non-empty?"** — the urls a profile is opened with come from MIRRORS: the
///    conversation document, a call record, a story group. A mirror can hold a url after the photo
///    behind it is gone, so somebody with no picture opened with the tall header.
///  · **"is the bitmap already cached?"** — false for every photo that was only just set, so a
///    freshly changed picture fell back to the circle.
///  · **"did the download succeed?"** — an answer that arrives seconds after the page does, which is
///    the layout visibly rearranging itself. Worse, the failure was written to disk, and a failed
///    download means "offline" at least as often as it means "gone": one bad moment downgraded that
///    person to the circle permanently on this device, with nothing that could ever undo it.
///
/// So the question is put to the users document, the only authority on whether somebody has a photo,
/// and the answer is kept here where it can be read without waiting. `ProfileStore` records into the
/// index every time it reads a user — every conversation it builds, every profile opened, every
/// group member — so by the time a profile can be tapped the answer is normally already in hand.
///
/// THE INVARIANT THAT MAKES IT ROBUST: **the circle photo decides.** The poster is a second crop of
/// the same photograph, so it cannot exist without one. A record with an empty `photoUrl` is a person
/// with no picture no matter what its `posterUrl` still says — which heals, with no migration, every
/// account left holding a stale poster by the remove-photo bug this shipped with.
///
/// The photo AUDIENCE is stored alongside, because the header's real question is "may I see it", and
/// that setting lives in the same document. Reading it from here removes the last input that used to
/// land late enough to move the layout.
enum ProfilePhotoIndex {

    /// What the header needs to know about one person. Small on purpose — this is not a profile
    /// cache, it is the answer to one question.
    struct Facts: Codable {
        var photo: String
        var poster: String
        /// Raw `Audience` for the "photo" key. Empty = the default, everyone.
        var audience: String
    }

    /// What to draw, decided in full.
    struct Header {
        /// Draw the tall photo layout. False means the classic circle, with its own empty state.
        let hasPhoto: Bool
        /// The circle's url. nil when there is nothing to draw or nothing I am allowed to see.
        let photoUrl: String?
        /// The tall crop, falling back to the circle's photo when they only ever had one.
        let posterUrl: String?
    }

    // MARK: - Reading

    /// The header's whole decision, from the authority when we have it and from the url we were
    /// handed when we do not. Synchronous, so a view can call it in its initialiser.
    ///
    /// - Parameters:
    ///   - uid: whose profile this is. Empty (your own story's "me_me" route) falls back to the urls.
    ///   - fallbackPhoto: the circle url this screen was opened with — a mirror, possibly stale.
    ///   - fallbackPoster: the tall url this screen was opened with, if the entry point had one.
    ///   - iAmContact: `PrivacyPrefs.isContact` for this uid, passed in so this type stays free of
    ///     the conversation repository.
    static func header(uid: String, fallbackPhoto: String?, fallbackPoster: String?,
                       iAmContact: Bool) -> Header {
        if let f = facts(uid) {
            // Authoritative. The circle decides; the poster is only ever a nicer crop of it.
            guard !f.photo.isEmpty else { return Header(hasPhoto: false, photoUrl: nil, posterUrl: nil) }
            guard allowsPhoto(f.audience, iAmContact: iAmContact) else {
                return Header(hasPhoto: false, photoUrl: nil, posterUrl: nil)
            }
            return Header(hasPhoto: true,
                          photoUrl: f.photo,
                          posterUrl: f.poster.isEmpty ? f.photo : f.poster)
        }
        // Never met this person's document. The url we were handed is the best fact available, and
        // it is right whenever the mirror is fresh — which the remove-photo fix now keeps it.
        let photo = (fallbackPhoto?.isEmpty == false) ? fallbackPhoto : nil
        guard let photo else { return Header(hasPhoto: false, photoUrl: nil, posterUrl: nil) }
        let poster = (fallbackPoster?.isEmpty == false) ? fallbackPoster : photo
        return Header(hasPhoto: true, photoUrl: photo, posterUrl: poster)
    }

    static func facts(_ uid: String) -> Facts? {
        guard !uid.isEmpty else { return nil }
        return store[uid]
    }

    /// The same rule `PrivacyPrefs.allows` applies, kept here so the index can answer on its own.
    /// Anything unrecognised means everyone, matching the app's default everywhere else.
    private static func allowsPhoto(_ audience: String, iAmContact: Bool) -> Bool {
        switch audience {
        case "contacts": return iAmContact
        case "nobody":   return false
        default:         return true
        }
    }

    // MARK: - Writing

    /// Record what a users document actually says. Called by `ProfileStore` on every read, so the
    /// index fills itself from work the app was already doing.
    static func record(uid: String, photo: String?, poster: String?, privacy: [String: String]) {
        guard !uid.isEmpty else { return }
        let next = Facts(photo: photo ?? "",
                         poster: poster ?? "",
                         audience: privacy["photo"] ?? "")
        // A same-value write would rewrite the defaults file on every profile read.
        if let old = store[uid], old.photo == next.photo, old.poster == next.poster,
           old.audience == next.audience { return }
        store[uid] = next
        // Bounded: this is a convenience cache, not a database. Dropping entries costs one
        // fall-back-to-the-url open, never a wrong answer that sticks.
        if store.count > 400 { store = Dictionary(uniqueKeysWithValues: store.prefix(300)) }
        persist()
    }

    /// Forget everything. Sign-out only: the next account must not inherit the last one's answers.
    static func reset() {
        store = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Storage

    private static let key = "profilePhotoIndex"
    private static var store: [String: Facts] = load()

    private static func load() -> [String: Facts] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Facts].self, from: data) else { return [:] }
        return decoded
    }

    private static func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
