import Foundation

// ⛔ STORY MENTIONS IN THE CHAT — owner 2026-10-16: "when someone mentions me in a story, show a
// card in our chat: the story in a circle, 'X mentioned you in a story', View Story; when the
// story is deleted or expires, a line saying it is no longer available".
//
// After a story has posted (its media is in place), every @name in its caption that belongs to a
// person who can SEE the story AND already has a chat with the poster gets one message in it. Who can see it is
// the audience the post itself resolved (`recipients`), so a mention never shows a story to
// somebody outside it. Not my own name, not somebody I have blocked.
//
// The message is an ordinary end-to-end encrypted text ("Mentioned in a story", what the chat list
// and a notification show) carrying a plain `storyMention` marker (story id and thumbnail url, the
// same plain pair a story reply carries). The chat draws it as the card (`MessageRowModelBuilder`).
// Its id is fixed per story and person, so a post resumed after a crash rewrites the same message
// instead of sending a second one.
enum StoryMentions {
    static let previewText = "Mentioned in a story"

    static func send(storyId: String, caption: String, thumbUrl: String, recipients: Set<String>, me: String) {
        guard caption.contains("@"), !storyId.isEmpty, !me.isEmpty,
              let re = try? NSRegularExpression(pattern: "@([A-Za-z][A-Za-z0-9_.]{0,29})") else { return }
        let ns = caption as NSString
        let handles = Set(re.matches(in: caption, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).lowercased() })
        guard !handles.isEmpty else { return }
        Task.detached(priority: .utility) {
            var sent = Set<String>()
            // One MENTION# line per name says where it stopped (owner 2026-10-16: no card arrived).
            // Remove once a device log has answered.
            func log(_ s: String) { Task { @MainActor in DiagLog.add("MENTION# story=\(storyId.prefix(6)) \(s)") } }
            log("names=\(handles.count) audience=\(recipients.count)")
            for h in handles {
                guard let u = await ChatService.findByHandle(h) else { log("@\(h) not found"); continue }   // never me
                guard u.id != me, !sent.contains(u.id) else { continue }
                guard recipients.contains(u.id) else { log("@\(h) not in audience"); continue }
                guard !BlockList.snapshot.contains(u.id) else { log("@\(h) blocked"); continue }
                // ⛔ ONLY INTO A CHAT WE ALREADY HAVE — owner 2026-10-16: never a first message to
                // somebody I have never chatted with, never a new chat. The app's one meaning of
                // "existing chat" (`isContact`: accepted 1:1, or an older chat with a message), the
                // same test the rules apply to a `storyMention` message on the server.
                let known = await MainActor.run { PrivacyPrefs.isContact(u.id) }
                guard known else { log("@\(h) no existing chat"); continue }
                sent.insert(u.id)
                let cid = ChatService.convId(me, u.id)
                do {
                    try await ChatService.sendText(cid: cid, text: previewText,
                                                   clientId: "storymention-\(storyId)-\(u.id)",
                                                   storyMention: StoryMentionRef(id: storyId, thumbUrl: thumbUrl))
                    log("@\(h) sent")
                } catch {
                    log("@\(h) send failed: \(error.localizedDescription)")
                }
            }
            Task { @MainActor in DiagLog.flagForUpload() }
        }
    }
}
