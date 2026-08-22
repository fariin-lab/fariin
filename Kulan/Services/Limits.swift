import Foundation

// Production limits — single source of truth on the client. Anything that protects data integrity
// or prevents abuse is ALSO enforced server-side (Firestore rules / Cloud Functions) so a modified
// client can't bypass it; these client values give instant UX (disable/trim/explain before a write).
// Mirror of functions/limits + firestore.rules — keep the three in sync.
enum Limits {
    // Chat
    static let pinnedMessagesPerChat = 3
    /// Photos or videos in one album message. Picking more starts another album rather than hiding the
    /// remainder behind a "+N" badge — 12 pictures ship as 10 + 2. Matches the ceiling the mosaic layout
    /// draws, so a sent album is always fully visible.
    static let albumMaxItems = 10
    static let pinnedChats = 3
    static let forwardChatsAtOnce = 5
    static let mediaPerMessage = 32   // raised for parity with standard messengers (user request; was 30)
    // ALL FOUR OF THESE NOW MATCH THE STORAGE RULES, and every one of them used to lie.
    //
    // The app accepted a file, spent time compressing it, uploaded the whole thing, and only THEN
    // the server refused it — with "User does not have permission", which mentions nothing about
    // size and sends you looking at auth. The owner hit it on an 18 second video and it took the
    // error message being printed at all (added the same day) to find the cause.
    //
    // The gaps were not small: files were allowed at EIGHTY TIMES what the server would take.
    //   file   2 GB  -> 25 MB     video  64 MB -> 25 MB
    //   story  100 MB -> 25 MB    photo  20 MB ->  8 MB
    // The story rule was also raised 10 -> 25 MB on the other side, because a 90 second story video
    // at 540p is about 17 MB and could never have fitted.
    //
    // If one of these changes, change storage.rules with it. A limit the client believes and the
    // server does not is worse than either number alone.
    static let fileUploadBytes = 25 * 1024 * 1024                  // 25 MB — storage.rules chat/
    static let videoMessageBytes = 25 * 1024 * 1024                // 25 MB — storage.rules chat/
    static let voiceNoteSeconds: TimeInterval = 30 * 60           // 30 min
    static let editWindowSeconds: TimeInterval = 15 * 60          // 15 min
    static let deleteForEveryoneSeconds: TimeInterval = 48 * 3600 // 48 h
    static let blockedUsers = 1000

    // Stories
    static let storiesPer24h = 50
    static let storyExpiryHours = 24
    static let storyUploadBytes = 25 * 1024 * 1024               // 25 MB — storage.rules stories/
    /// How long ONE story can be. 90s is the reference app's status-feature number and the owner's spec (2026-08-04).
    /// A longer pick is no longer truncated to this — it is SPLIT into consecutive segments, each its
    /// own story, so nothing the user chose is thrown away.
    static let storyVideoSeconds = 90
    /// How long a pick may be before we refuse it outright: ten minutes, which at 90s a segment is
    /// seven stories. Past that the split stops being a story and starts being a film.
    static let storyVideoPickSeconds = 600
    static let storyCaptionChars = 700

    // Groups
    static let groupMembers = 1024
    static let groupAdmins = 20
    static let groupNameChars = 100
    static let groupDescChars = 512

    // Profile
    /// ⚠️ MUST MATCH `USERNAME_MIN` in functions-username. The server is the one that counts; this
    /// copy only decides when the Done button lights up, so a disagreement shows as a button you can
    /// press that then fails.
    ///
    /// FOUR, not three (raised 2026-08-10) and deliberately not another mainstream messenger's five: Somali given names
    /// are very often exactly four letters — Ubah, Amal, Deeq, Muna, Asha, Iqra, Nimo, Hani, Suad —
    /// and a five-character floor would refuse a large share of this app's users their own first
    /// name. The reasoning in full sits beside the server constant.
    static let usernameMinChars = 4
    static let usernameMaxChars = 30
    static let bioChars = 140
    static let profilePhotoBytes = 8 * 1024 * 1024              // 8 MB — storage.rules profiles/
    static let usernameChangesPer30Days = 2

    // Anti-spam (rate limits enforced in Cloud Functions)
    static let reportsPerDay = 10

    /// ⛔ A ONE-PARAGRAPH FIELD, TIDIED AND THEN MEASURED. Shared by the Bio and by a contact's
    /// private Note, because they had the same hole and a second copy of this rule would be a second
    /// thing to keep right (owner 2026-08-22, reported once for each field).
    ///
    /// ⚠️ THE HOLE: a character ceiling does not bound a field whose blanks are characters.
    /// `.lineLimit(1...5)` caps the BOX and never the string, so Return could spend the whole budget
    /// on nothing and the page that renders it — which clamps no lines — drew the entire empty
    /// column. Every whitespace becomes a space, runs of blanks become one blank, and only what
    /// survives is measured against the ceiling. Measuring first would let a hundred blank lines
    /// truncate the words somebody actually typed.
    ///
    /// ⚠️ ONE TRAILING BLANK SURVIVES, and it has to: a space is its own keystroke and arrives alone,
    /// so collapsing it would make it impossible to type a space between two words.
    ///
    /// ⚠️ USE IT FROM A BINDING'S SETTER, NOT FROM `onChange`. `onChange` runs after the value is
    /// stored and the view laid out, so the newline is really inserted first — the field grows, the
    /// form scrolls to follow the caret, and the rewrite then shrinks it and scrolls back. That
    /// down-then-up was a reported bug in its own right.
    static func oneParagraph(_ raw: String, max limit: Int) -> String {
        var s = String(raw.map { $0.isWhitespace ? " " : $0 })   // isWhitespace covers newlines too
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.count > limit ? String(s.prefix(limit)) : s
    }
}
