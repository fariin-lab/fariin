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
    static let fileUploadBytes = 2 * 1024 * 1024 * 1024            // 2 GB
    static let videoMessageBytes = 64 * 1024 * 1024                // 64 MB after 720p transcode
    static let voiceNoteSeconds: TimeInterval = 30 * 60           // 30 min
    static let editWindowSeconds: TimeInterval = 15 * 60          // 15 min
    static let deleteForEveryoneSeconds: TimeInterval = 48 * 3600 // 48 h
    static let blockedUsers = 1000

    // Stories
    static let storiesPer24h = 50
    static let storyExpiryHours = 24
    static let storyUploadBytes = 100 * 1024 * 1024              // 100 MB
    /// How long ONE story can be. 90s is WhatsApp Status's number and the owner's spec (2026-08-04).
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
    static let usernameMinChars = 3
    static let usernameMaxChars = 30
    static let bioChars = 140
    static let profilePhotoBytes = 20 * 1024 * 1024             // 20 MB
    static let usernameChangesPer30Days = 2

    // Anti-spam (rate limits enforced in Cloud Functions)
    static let reportsPerDay = 10
}
