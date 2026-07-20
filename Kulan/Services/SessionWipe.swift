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
        ThreadMessageCache.shared.removeAll()   // decrypted messages
        ProfileStore.shared.me = nil
        Drafts.shared.clear()                   // unsent plaintext
        PlayedVoice.shared.clear()
        ContactNames.shared.clear()
        SendQueue.removeAll()                   // queued unsent plaintext
        AudioCache.removeAll()                  // decrypted voice notes on disk
        VideoCache.removeAll()                  // decrypted videos on disk
        AppRouter.shared.pendingChatId = nil
        AppRouter.shared.pendingChatName = nil
        AppRouter.shared.pendingChatPhoto = nil
        AppRouter.shared.pendingInviteCode = nil
        Crypto.shared.wipeIdentity()            // fresh keypair for the next account
    }
}
