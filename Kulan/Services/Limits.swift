import Foundation

// Production limits — single source of truth on the client. Anything that protects data integrity
// or prevents abuse is ALSO enforced server-side (Firestore rules / Cloud Functions) so a modified
// client can't bypass it; these client values give instant UX (disable/trim/explain before a write).
// Mirror of functions/limits + firestore.rules — keep the three in sync.
enum Limits {
    // Chat
    /// Characters in one typed message. His call, 2026-08-27, after asking what the big apps do:
    /// the reference app's own number. The other one's 4,096 was refused as too tight for pasted
    /// text.
    ///
    /// ⚠️ THE REASON IS THE CHAT SCREEN, NOT THE DATABASE. Firestore's own ceiling is 1 MB a
    /// document, which after encryption is somewhere near 700,000 characters — so the write is not
    /// what breaks first. The message list MEASURES and DRAWS every line of a bubble, on both
    /// phones, so one pasted wall of text freezes the conversation for whoever opens it. A cap is
    /// cheaper than a special case in the layout.
    ///
    /// ⛔ NOT A TRUNCATION OF WHAT IS SENT. It stops the field accepting more; nothing typed is ever
    /// cut, which is the distinction he drew when he had the 20-line "Read more" collapse removed
    /// the same day.
    /// ⛔ 6,400 IN THE FIELD, 2,500 A BUBBLE (owner 2026-10-29, the reference app's way: "you paste
    /// and send more, but each bubble is 2,500; up to 6,400 is about 3 bubbles"). His newer word
    /// replaces the 08-27 one (65,536) and the same day's flat 2,500. `ThreadView.send` splits.
    /// owner 2026-11-10: 4,096 (was 6,400), the size big messengers use.
    static var messageMaxChars: Int { ConfigClient.int(ConfigClient.K.messageMaxChars) }   // 4,096
    /// A photo's or video's caption (owner 2026-11-10): 1,024, shorter than a message.
    static var captionMaxChars: Int { ConfigClient.int(ConfigClient.K.captionMaxChars) }   // 1,024
    static var messageBubbleChars: Int { ConfigClient.int(ConfigClient.K.messageBubbleChars) }   // 2,500
    static var pinnedMessagesPerChat: Int { ConfigClient.int(ConfigClient.K.pinnedMessagesPerChat) }   // 3
    /// Photos or videos in one album message. Picking more starts another album rather than hiding the
    /// remainder behind a "+N" badge — 12 pictures ship as 10 + 2. Matches the ceiling the mosaic layout
    /// draws, so a sent album is always fully visible.
    static var albumMaxItems: Int { ConfigClient.int(ConfigClient.K.albumMaxItems) }   // 10
    static let pinnedChats = 3
    static var forwardChatsAtOnce: Int { ConfigClient.int(ConfigClient.K.forwardChatsAtOnce) }   // 0 = no limit (owner 2026-11-13)
    /// Messages that can be ticked and forwarded in one go, the reference's `maxForwardCount`. Past
    /// this the Forward button in the selection bar switches off rather than handing the picker a
    /// list the send path will not carry.
    static var maxForwardSelection: Int { ConfigClient.int(ConfigClient.K.forwardSelectionMax) }   // 32
    static var mediaPerMessage: Int { ConfigClient.int(ConfigClient.K.mediaPerMessage) }   // 32, raised for parity with standard messengers (user request; was 30)
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
    static var fileUploadBytes: Int { ConfigClient.int(ConfigClient.K.fileUploadMB) * 1024 * 1024 }                 // 25 MB, deliberately BELOW the rule
    /// ⛔ 100 MB (owner, 2026-08-25). The old 25 was doing two jobs and failing the second: it capped
    /// storage AND, through `VideoTranscoder`'s flat `fileLengthLimit`, it decided quality — every
    /// clip was squeezed to fit it, so a long one came out at roughly 300 kbps. The exporter targets
    /// a bitrate now and this is only the ceiling it may not pass.
    ///
    /// ⚠️ `storage.rules` was raised to match and MUST be deployed with any build carrying this.
    /// `fileUploadBytes` above stays at 25 on purpose: documents gain nothing from the room, and the
    /// chat Storage rule still has no membership check, so a smaller client-side cap is worth having.
    ///
    /// ⛔ AND 64 IS WHY IT IS NOT 100 OR 2000. A video is held in memory THREE TIMES on its way out:
    /// the transcoded `Data`, the byte array libsodium seals from, and the ciphertext that comes
    /// back. At 64 MB that peak is around 200 MB, which an older phone survives; at 2 GB, which is
    /// the number the reference app quotes, nothing here survives at all. Raising this further means
    /// sealing the clip in chunks first (libsodium secretstream), not editing this line.
    ///
    /// For scale: most chat clips are under two minutes, which at the exporter's 2 Mbps target is
    /// about 30 MB. 64 covers roughly three and a half minutes at full quality, and anything longer
    /// degrades smoothly instead of failing.
    ///
    /// ⛔ OWNER 2026-11-13: SENDING allows up to 100 MB, the COMPRESSION is unchanged. His 10 minute
    /// clip came out of the standard export at 68.2 MB (the encoder overshoots its 62 MB target on
    /// long clips) and was refused at 64. The export still aims at `videoExportTargetBytes` (the old
    /// 62 MB), so no clip is encoded differently; only the cap that refused it moved. Live storage
    /// rule chat/ is < 102 MB (100 + room for the encryption bytes). Memory peak for a 100 MB clip
    /// is about 300 MB (the three copies above), his decision.
    static var videoMessageBytes: Int { ConfigClient.int(ConfigClient.K.videoMessageMB) * 1024 * 1024 }              // 100 MB, storage.rules chat/ < 102 MB
    /// What the exporter aims for at most (unchanged since 64 MB was the cap: 64 - 2).
    static var videoExportTargetBytes: Int { ConfigClient.int(ConfigClient.K.videoExportTargetMB) * 1024 * 1024 }   // 62 MB
    /// The recording ceiling, and `AudioRecorder.maxDuration` IS this value rather than a copy of it.
    /// It used to be neither: this constant was referenced nowhere in the app and the recorder
    /// enforced its own 600, so the documented cap was three times the real one and anybody building
    /// against this file would have built against a number nothing honoured.
    static var voiceNoteSeconds: TimeInterval { TimeInterval(ConfigClient.int(ConfigClient.K.voiceNoteMinutes) * 60) }          // 30 min
    static let editWindowSeconds: TimeInterval = 15 * 60          // 15 min
    static var deleteForEveryoneSeconds: TimeInterval { TimeInterval(ConfigClient.int(ConfigClient.K.deleteForEveryoneHours) * 3600) } // 0 = no limit (owner 2026-11-13)
    static var blockedUsers: Int { ConfigClient.int(ConfigClient.K.blockedUsersMax) }   // 1000

    // Stories
    static let storiesPer24h = 50
    static var storyExpiryHours: Int { ConfigClient.int(ConfigClient.K.storyExpiryHours) }   // 24
    static var storyUploadBytes: Int { ConfigClient.int(ConfigClient.K.storyUploadMB) * 1024 * 1024 }              // 50 MB, storage.rules stories/ (StoryVideoEncoder sizes under it)
    /// How long ONE story can be. 90s is the reference app's status-feature number and the owner's spec (2026-08-04).
    /// A longer pick is no longer truncated to this — it is SPLIT into consecutive segments, each its
    /// own story, so nothing the user chose is thrown away.
    static var storyVideoSeconds: Int { ConfigClient.int(ConfigClient.K.storyVideoSeconds) }   // 90
    /// How long a pick may be before we refuse it outright: ten minutes, which at 90s a segment is
    /// seven stories. Past that the split stops being a story and starts being a film.
    static var storyVideoPickSeconds: Int { ConfigClient.int(ConfigClient.K.storyVideoPickSeconds) }   // 600
    static var storyCaptionChars: Int { ConfigClient.int(ConfigClient.K.storyCaptionChars) }   // 200, owner 2026-11-10 (was 700)

    // Groups
    static let groupMembers = 1024
    static var groupAdmins: Int { ConfigClient.int(ConfigClient.K.groupAdminsMax) }   // 0 = no limit (owner 2026-11-13)
    static var groupNameChars: Int { ConfigClient.int(ConfigClient.K.groupNameChars) }   // 100
    static let groupDescChars = 512
    /// A channel's description (owner 2026-11-10): 255. A group's comes from the panel (group_desc_max).
    static var channelDescChars: Int { ConfigClient.int(ConfigClient.K.channelDescChars) }   // 255

    // Profile
    /// ⚠️ MUST MATCH `USERNAME_MIN` in functions-username. The server is the one that counts; this
    /// copy only decides when the Done button lights up, so a disagreement shows as a button you can
    /// press that then fails.
    ///
    /// FOUR, not three (raised 2026-08-10) and deliberately not another mainstream messenger's five: Somali given names
    /// are very often exactly four letters — Ubah, Amal, Deeq, Muna, Asha, Iqra, Nimo, Hani, Suad —
    /// and a five-character floor would refuse a large share of this app's users their own first
    /// name. The reasoning in full sits beside the server constant.
    /// ⛔ FIVE since 2026-10-15 (owner): regular users claim 5+; 4-character names are given out by
    /// admins only. Mirrors `USERNAME_MIN` on the server, which is the one that counts.
    static let usernameMinChars = 5
    static let usernameMaxChars = 30
    static var bioChars: Int { ConfigClient.int(ConfigClient.K.bioChars) }   // 140
    static var profilePhotoBytes: Int { ConfigClient.int(ConfigClient.K.profilePhotoMB) * 1024 * 1024 }             // 8 MB, storage.rules profiles/
    // Username changes: 3 per 24 hours, counted by the server (functions-username MAX_CLAIMS_PER_DAY,
    // owner 2026-11-10). No copy here: the server's refusal says when to try again.

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
