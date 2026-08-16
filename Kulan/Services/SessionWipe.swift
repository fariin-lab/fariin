import Foundation

/// Every piece of account-scoped state that lives on this DEVICE, wiped in one place.
/// Called on sign-out and account deletion — the singletons otherwise outlive the
/// account, so a NEW sign-up on the same phone saw the previous account's chat list,
/// stories and call log (and silently reused its E2EE keypair). Firestore's own disk
/// cache is safe to keep: its queries are uid-scoped, so the new account matches none
/// of the old documents.
@MainActor
enum SessionWipe {
    static func wipeAccountData() {
        ConversationsRepository.shared.reset()
        StoriesRepository.shared.reset()
        CallsRepository.shared.reset()
        // The official channel and the admin rights that go with it are per-account: the next person
        // to sign in on this phone must not inherit the last one's read watermark, their mute, or —
        // the sharp one — their admin permissions, which would put a live Send Announcement screen in
        // a stranger's Settings until the listener caught up.
        OfficialChannelStore.shared.reset()
        AdminStore.shared.reset()
        OfficialConfig.shared.stop()
        // The story audiences are a list of the last person's friends by name, mirrored to disk so
        // the share sheet can open instantly. Left behind, the next account's Share Story sheet
        // would open holding a stranger's custom lists.
        StoryAudienceStore.shared.clear()
        ThreadMessageCache.shared.removeAll()   // decrypted messages
        ProfileStore.shared.me = nil
        Drafts.shared.clear()                   // unsent plaintext
        PlayedVoice.shared.clear()
        ContactNames.shared.clear()
        // Who has a profile photo, and who may see it — both are answers about OTHER people, read
        // through the last account's contact relationships. The next account must ask again.
        ProfilePhotoIndex.reset()
        SendQueue.removeAll()                   // queued unsent plaintext
        PendingOutbox.removeAll()               // forwarded bubbles waiting for a chat to be opened
        AudioCache.removeAll()                  // decrypted voice notes on disk
        VideoCache.removeAll()                  // decrypted videos on disk
        AppRouter.shared.pendingChatId = nil
        AppRouter.shared.pendingChatName = nil
        AppRouter.shared.pendingChatPhoto = nil
        AppRouter.shared.pendingInviteCode = nil
        wipeAccountPrefs()
        CallPrivacyIndex.clear()                // who-refuses-calls is per-account too
        VerificationIndex.clear()               // and who is verified — the next account starts blank
        SafetyKeyLog.wipe()                     // whose key we have seen: per account, never inherited
        // The launch cache. `wipeAll`, not the per-uid door: by the time a sign-out reaches here the
        // uid may already be gone, and a chat list left behind would be handed to whoever signs in
        // next — on their FIRST FRAME, before any listener could correct it.
        ConversationsDiskCache.shared.wipeAll()
        Crypto.shared.wipeIdentity()            // fresh keypair for the next account
    }

    /// ACCOUNT-SCOPED PREFERENCES (audit). These are plain global UserDefaults keys, so the next
    /// person to sign in on this phone inherited the previous account's choices. The sharpest case:
    /// `priv.calls` is read on-device by the callee-side gate, so account A setting Calls to "No One"
    /// silently auto-declined account B's incoming calls. Privacy is also published to the server, and
    /// nothing ever imports it back, so B's screen showed A's settings while B's server map said
    /// something else. Story prefs (hidden authors, seen items, likes, notify list) are the same
    /// class: B inherited A's hidden people and grey rings for stories B never watched.
    private static func wipeAccountPrefs() {
        let d = UserDefaults.standard
        let exact = [
            // privacy audiences + their reciprocity flags
            "priv.photo", "priv.bio", "priv.lastSeen", "priv.calls", "priv.groups", "priv.messages",
            "readReceipts", "typingIndicators", "shareLastSeen",
            // notifications
            "notif.push", "notif.preview", "notif.sound",
            "notif.inAppSound", "notif.inAppVibrate", "notif.inAppPreview",
            // stories
            "storyViewReceipts", "storiesOptedOut",
            "hiddenStories", "seenStoryItems", "notifyStories", "likedStories",
            // ⚠️ THESE TWO WERE MISSED, and both are account-scoped like everything above them.
            // `oneTimeUsed` is the burn list for view-once stories and it HARD-FILTERS them out of
            // every list, so a story account A used its single view on was invisible to account B on
            // the same phone — B's own view, silently spent by somebody else. `storyAudienceNames`
            // holds the private names of the author's custom audiences ("Close friends", and worse),
            // which is the one piece of story state that is explicitly nobody else's business.
            "oneTimeUsed", "storyAudienceNames",
            // misc account-scoped state
            "defaultDisappearSeconds", "callsSeenAt",
        ]
        for k in exact { d.removeObject(forKey: k) }
        HiddenMessages.clear()   // stored key + its in-memory mirror
        // Per-chat sounds are keyed by cid, so they have to be swept by prefix.
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("sound_") {
            d.removeObject(forKey: k)
        }
        StoryPrefs.dropCaches()   // the in-memory mirror of the story keys above
    }
}
