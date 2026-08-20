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
        /// The tiny base64 cover that travels with the record — see `UserProfile.photoThumb`.
        /// OPTIONAL, because this file is persisted: the synthesized decoder does not apply property
        /// defaults, so a non-optional here would make every record written before it existed fail
        /// to decode and quietly empty the index.
        var thumb: String?
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
        /// The base64 cover to draw while the real picture is still coming. Nil means fall back to
        /// the letter, which is the only honest thing left to show.
        let thumb: String?
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
        let none = Header(hasPhoto: false, photoUrl: nil, posterUrl: nil, thumb: nil)
        // Which urls this person is described by. The record wins when we have it; otherwise the
        // urls this screen was handed, which are right whenever the mirror is fresh.
        let photo: String?
        let poster: String?
        var thumb: String?
        if let f = facts(uid) {
            guard allowsPhoto(f.audience, iAmContact: iAmContact) else { return none }
            // The circle decides. The poster is a second crop of the same photograph and cannot
            // exist without one, so an empty photoUrl is a person with no picture whatever a
            // leftover posterUrl still says.
            photo = f.photo.isEmpty ? nil : f.photo
            poster = f.poster.isEmpty ? nil : f.poster
            thumb = (f.thumb?.isEmpty == false) ? f.thumb : nil
        } else {
            photo = (fallbackPhoto?.isEmpty == false) ? fallbackPhoto : nil
            poster = (fallbackPoster?.isEmpty == false) ? fallbackPoster : nil
        }
        // A URL IS NOT A PICTURE. This is the half that was missing, and it is what put the big
        // header on somebody who plainly has none (owner, on 448, about an account whose record
        // still names a photo that is not there any more: "no profile picture user still is using
        // large… if user non profile picture use circle profile, that's").
        guard let photo, hasPicture(photo) else { return none }
        // Same test for the tall crop: a dead poster url falls back to the circle photo rather than
        // drawing a letter where a face should be.
        let usablePoster: String
        if let poster, hasPicture(poster) { usablePoster = poster } else { usablePoster = photo }
        return Header(hasPhoto: true, photoUrl: photo, posterUrl: usablePoster, thumb: thumb)
    }

    /// IS THERE A PICTURE BEHIND THIS URL — answered now, without a fetch.
    ///
    /// Three certainties and one assumption:
    ///  · no url at all → no.
    ///  · **the bytes are on this device** → yes. `isCached` is an in-memory index check, not a file
    ///    probe and not a decode, so this is free to ask on any frame.
    ///  · **a load already came back empty for this exact url** → no. Learned from the avatars: the
    ///    chat list, the calls list and the story row all draw this same url long before a profile
    ///    can be tapped, so the answer is normally in hand by then.
    ///  · anything else → yes, assume it is real. This is the photo somebody has JUST set, which is
    ///    a url this device has never downloaded — calling that "no photo" is the opposite bug, and
    ///    it was reported too ("this bug only occurs after setting a new profile picture").
    static func hasPicture(_ url: String?) -> Bool {
        guard let u = url, !u.isEmpty else { return false }
        if DiskImageCache.shared.isCached(u) { return true }
        return !failedURLs.contains(u)
    }

    /// What happened when something tried to draw this url. Called by every avatar in the app.
    ///
    /// DELIBERATELY NOT PERSISTED. Its predecessor wrote failures to disk, and since a failed
    /// download means "you were in a tunnel" as often as it means "the photo is gone", one bad
    /// moment demoted somebody to a circle permanently, on that device, with nothing that could
    /// undo it. In memory only: the worst a wrong answer can cost is one launch, and a success is
    /// remembered anyway — by the bytes themselves, in the cache.
    static func noteLoad(_ url: String?, ok: Bool) {
        guard let u = url, !u.isEmpty else { return }
        if ok { failedURLs.remove(u) } else { failedURLs.insert(u) }
    }

    private static var failedURLs = Set<String>()

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
    static func record(uid: String, photo: String?, poster: String?, thumb: String? = nil,
                       privacy: [String: String]) {
        guard !uid.isEmpty else { return }
        let next = Facts(photo: photo ?? "",
                         poster: poster ?? "",
                         thumb: thumb,
                         audience: privacy["photo"] ?? "")
        // A same-value write would rewrite the defaults file on every profile read.
        if let old = store[uid], old.photo == next.photo, old.poster == next.poster,
           old.thumb == next.thumb, old.audience == next.audience { return }
        store[uid] = next
        // Bounded: this is a convenience cache, not a database. Dropping entries costs one
        // fall-back-to-the-url open, never a wrong answer that sticks.
        // `prefix` on a Dictionary yields LABELLED (key:value:) pairs, which is not what
        // `uniqueKeysWithValues:` takes — hence the map back to a plain pair.
        if store.count > 400 {
            store = Dictionary(uniqueKeysWithValues: store.prefix(300).map { ($0.key, $0.value) })
        }
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
