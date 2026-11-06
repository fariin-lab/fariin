import Foundation

extension Notification.Name {
    /// A group or channel invite card's live answer moved: its name, photo or count changed, or the
    /// link stopped working. The open chat rebuilds the rows that show such a card.
    static let groupCardsChanged = Notification.Name("fariin.groupCardsChanged")
}

/// ⛔ A GROUP CARD SHOWS TODAY'S GROUP, NOT THE ONE THE SENDER SAW (2026-11-06). The card in a
/// message is a snapshot from the sender's phone at send time (`LinkPreviewService.groupDraft`).
/// When it is drawn, `GroupLinkDoor` (a /g/<code> link) or `GroupDirectory` (a public
/// fariin.com/<name> link) asks the server again, at most every 30 s per link and trusted for two
/// minutes, so scrolling does not call the server. This file is the bridge to the chat list: a
/// landed answer that differs from the last one posts `.groupCardsChanged` once (bursts are
/// folded together), and `token` is the part of a row's signature that makes that one row
/// reconfigure.
@MainActor enum LiveGroupCard {
    private static var pending = false

    /// Called by the two lookups when an answer lands that a card would draw differently.
    static func noteChanged() {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            pending = false
            NotificationCenter.default.post(name: .groupCardsChanged, object: nil)
        }
    }

    /// What a group card draws from the live answer, as a short string for a row's signature.
    /// "-" for every link that is not one of our group links.
    static func token(_ url: String) -> String {
        guard let u = URL(string: url) else { return "-" }
        if let code = LinkPreviewService.groupCode(in: u) {
            if GroupLinkDoor.refusal(code) != nil { return "X" }
            let m = GroupLinkDoor.isMember(code) ? "m" : "v"
            guard let p = GroupLinkDoor.lastFound(code) else { return "?" + m }
            return "\(m)\(p.title.hashValue):\(p.photoUrl?.hashValue ?? 0):\(p.memberCount):\(p.isChannel)"
        }
        if case .name(let name)? = KulanApp.route(from: u) {
            if GroupDirectory.nameIsDead(name) { return "X" }
            guard let cid = GroupDirectory.cachedCid(name: name),
                  let p = GroupDirectory.cachedPreview(name: name, cid: cid) else { return "?" }
            return "\(p.isMember)\(p.title.hashValue):\(p.photoUrl?.hashValue ?? 0):\(p.memberCount):\(p.followerCount):\(p.isChannel)"
        }
        return "-"
    }
}
