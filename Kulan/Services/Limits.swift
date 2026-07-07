import Foundation

// Production limits — single source of truth on the client. Anything that protects data integrity
// or prevents abuse is ALSO enforced server-side (Firestore rules / Cloud Functions) so a modified
// client can't bypass it; these client values give instant UX (disable/trim/explain before a write).
// Mirror of functions/limits + firestore.rules — keep the three in sync.
enum Limits {
    // Chat
    static let pinnedMessagesPerChat = 3
    static let pinnedChats = 3
    static let forwardChatsAtOnce = 5
    static let mediaPerMessage = 30
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
    static let storyVideoSeconds = 30   // WhatsApp/Signal cap; longer picks are auto-trimmed, never rejected
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
