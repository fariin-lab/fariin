import Foundation
import os

/// Handles already asked for. Outside the enum so it can be read from wherever a row is laid out:
/// a card that is rebuilt a hundred times starts one lookup and not a hundred.
private let requestedHandles = OSAllocatedUnfairLock(initialState: Set<String>())

/// Opens the chat behind a profile card's "Send Message".
///
/// ⛔ THE TAP USED TO WAIT ON FOUR ROUND TRIPS — owner, 2026-09-30: "when I click Send Message ...
/// is taking time". A card knows only a handle, so the tap looked the handle up (two reads), then
/// read and rewrote the conversation (two more), and only then moved. Two changes:
///
///   1. THE LOOKUP HAPPENS WHEN THE CARD IS DRAWN, not when it is tapped. By the time a finger
///      reaches the button the person is already known.
///   2. A CHAT THAT IS ALREADY IN THE LIST OPENS AT ONCE. The conversation id is a function of the
///      two uids, so nothing needs asking; the usual names-and-photos refresh still runs, behind it.
///
/// A person with no chat yet still waits for the conversation to be created, because there is
/// nothing to open until it exists.
@MainActor enum ProfileCardDoor {
    private struct Known {
        let profile: UserProfile
        let at: Date
    }

    /// How long a lookup is trusted. A handle can be released or an account removed; ten minutes
    /// bounds how long a card can keep opening a chat with somebody who is no longer there.
    private static let trust: TimeInterval = 600

    private static var known: [String: Known] = [:]
    private static var opening = Set<String>()

    private static func key(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Called when a profile card is laid out. Returns at once; the lookup runs behind it.
    nonisolated static func prewarm(_ handle: String) {
        let k = handle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return }
        let fresh = requestedHandles.withLock { $0.insert(k).inserted }
        guard fresh else { return }
        Task { @MainActor in
            _ = await resolve(handle)
        }
    }

    private static func resolve(_ handle: String) async -> UserProfile? {
        let k = key(handle)
        if let hit = known[k], Date().timeIntervalSince(hit.at) < trust { return hit.profile }
        guard let user = await ChatService.findByHandle(handle) else {
            known[k] = nil
            return nil
        }
        known[k] = Known(profile: user, at: Date())
        return user
    }

    /// The chat a card for `handle` opens. Reads the lookup made when the card was drawn, so it
    /// costs nothing on a tap. Nil when the person could not be found.
    static func chatId(_ handle: String) async -> String? {
        guard let user = await resolve(handle) else { return nil }
        return ChatService.convId(AuthService.shared.uid ?? "", user.id)
    }

    /// Opens the chat with the person behind `handle`. False when they could not be reached.
    /// `push` slides the chat in over the current one; without it the chat replaces the stack.
    @discardableResult
    static func open(_ handle: String, push: Bool) async -> Bool {
        let k = key(handle)
        // A second tap while the first is still opening must not open the chat twice.
        guard !opening.contains(k) else { return true }
        opening.insert(k)
        defer { opening.remove(k) }

        guard let user = await resolve(handle) else { return false }
        let me = AuthService.shared.uid ?? ""
        let cid = ChatService.convId(me, user.id)
        if ConversationsRepository.shared.conversations.contains(where: { $0.id == cid }) {
            route(cid, user, push: push)
            Task { _ = try? await ChatService.openConversation(other: user) }
            return true
        }
        guard let opened = try? await ChatService.openConversation(other: user) else { return false }
        route(opened, user, push: push)
        return true
    }

    private static func route(_ cid: String, _ user: UserProfile, push: Bool) {
        let router = AppRouter.shared
        router.pendingChatPush = push
        router.pendingChatName = user.name.isEmpty ? user.handle : user.name
        router.pendingChatPhoto = user.photoUrl
        router.pendingChatId = cid
    }
}
