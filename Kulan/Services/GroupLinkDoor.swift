import Foundation
import FirebaseFunctions
import os

/// What the server says about a fariin.com/g/<code> link (`groupLinkPreview`, Kulan
/// functions-groups). The member list never comes to the phone: only the count, and up to three of
/// the members the caller already has a chat with.
struct GroupLinkPreview: Equatable {
    struct Mutual: Equatable, Identifiable {
        let uid: String
        let name: String
        let photoUrl: String?
        var id: String { uid }
    }
    let code: String
    var cid: String?            // only when I am a member
    var title: String
    var photoUrl: String?
    var memberCount: Int
    var isMember: Bool
    var needsApproval: Bool
    var requested: Bool
    var mutuals: [Mutual]
    var mutualCount: Int
    /// 2026-10-19 groups v2 step 4: the join page's description and up to three faces (the people
    /// I talk to first, then other members with a photo). Empty on a `lite` card lookup.
    var description: String
    var faces: [Mutual]

    var membersLine: String { "\(memberCount) \(memberCount == 1 ? "member" : "members")" }

    init(code: String, data: [String: Any]) {
        self.code = code
        let cid = data["cid"] as? String ?? ""
        self.cid = cid.isEmpty ? nil : cid
        let t = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.title = t.isEmpty ? "Group" : t
        let p = data["photoUrl"] as? String ?? ""
        self.photoUrl = p.isEmpty ? nil : p
        self.memberCount = (data["memberCount"] as? NSNumber)?.intValue ?? 0
        self.isMember = data["isMember"] as? Bool ?? false
        self.needsApproval = data["needsApproval"] as? Bool ?? false
        self.requested = data["requested"] as? Bool ?? false
        self.mutuals = (data["mutuals"] as? [[String: Any]] ?? []).compactMap { m in
            guard let uid = m["uid"] as? String, let name = m["name"] as? String, !name.isEmpty else { return nil }
            let ph = m["photoUrl"] as? String ?? ""
            return Mutual(uid: uid, name: name, photoUrl: ph.isEmpty ? nil : ph)
        }
        self.mutualCount = (data["mutualCount"] as? NSNumber)?.intValue ?? mutuals.count
        self.description = (data["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A server from before step 4 sends no faces: the mutuals stand in.
        let f = (data["faces"] as? [[String: Any]] ?? []).compactMap { m -> Mutual? in
            guard let uid = m["uid"] as? String else { return nil }
            let ph = m["photoUrl"] as? String ?? ""
            return Mutual(uid: uid, name: m["name"] as? String ?? "", photoUrl: ph.isEmpty ? nil : ph)
        }
        self.faces = f.isEmpty ? mutuals : f
    }
}

/// The groups I am in, by their CURRENT invite code (`Conversation.inviteCode`), so a card for one
/// of my own groups says Open Group on its first frame and a tap goes straight to the chat. Fed by
/// `ConversationsRepository.conversations`; outside the enum so the repository can write it from
/// wherever its snapshot lands.
private let memberCodes = OSAllocatedUnfairLock(initialState: [String: String]())

/// THE DOOR BEHIND A GROUP LINK — owner 2026-10-18: a fariin.com/g/<code> link in a chat showed the
/// website's banner. It now has a card like a profile link's, and the first tap opens a join sheet
/// (the reference app's), not the group. A group I am already in opens straight away.
///
/// Like `ProfileCardDoor`, the server lookup is made when the card is DRAWN, so the sheet that a tap
/// opens already has the group, its count and the people I know in it.
@MainActor enum GroupLinkDoor {
    enum Outcome {
        case found(GroupLinkPreview)
        /// The link is dead, or I may not use it. The server's own words.
        case refused(String)
        /// Offline or the call failed: worth trying again.
        case failed(String)
    }

    private struct Known {
        let outcome: Outcome
        let full: Bool          // carries the mutuals (not a `lite` card lookup)
        let at: Date
    }

    /// How long an answer is reused: a member count or a revoked link should not be stale for long.
    private static let trust: TimeInterval = 120
    private static var known: [String: Known] = [:]
    private static var inFlight: [String: Task<Outcome, Never>] = [:]
    private static var requestedCodes = Set<String>()
    private static var fns: Functions { Functions.functions(region: "me-central1") }

    // MARK: - My groups by code

    nonisolated static func noteConversations(_ convs: [Conversation]) {
        var map: [String: String] = [:]
        for c in convs where c.isGroup && !c.inviteCode.isEmpty { map[c.inviteCode] = c.id }
        memberCodes.withLock { $0 = map }
    }

    /// The chat behind `code` when it is one of my groups' current link. Costs a dictionary read.
    nonisolated static func memberCid(_ code: String) -> String? {
        memberCodes.withLock { $0[code] }
    }

    /// Am I in the group behind `code`, as far as this phone knows right now.
    static func isMember(_ code: String) -> Bool {
        if memberCid(code) != nil { return true }
        if case .found(let p)? = fresh(code)?.outcome { return p.isMember }
        return false
    }

    /// The last answer for `code` if it is still trusted.
    static func cached(_ code: String) -> GroupLinkPreview? {
        if case .found(let p)? = fresh(code)?.outcome { return p }
        return nil
    }

    /// The server's refusal for `code` ("This link is no longer valid."), if that was the last answer.
    static func refusal(_ code: String) -> String? {
        if case .refused(let why)? = fresh(code)?.outcome { return why }
        return nil
    }

    private static func fresh(_ code: String) -> Known? {
        guard let k = known[code], Date().timeIntervalSince(k.at) < trust else { return nil }
        return k
    }

    // MARK: - Lookups

    /// Called when a group card is laid out (`MessageRowModelBuilder`, main actor). Returns at once;
    /// the lookup runs behind it, once per code until it fails.
    static func prewarm(_ code: String) {
        guard KulanApp.safeSegment(code), requestedCodes.insert(code).inserted else { return }
        Task { @MainActor in _ = await load(code) }
    }

    /// `lite`: the sender's card only (title, photo, count), without the mutuals.
    static func load(_ code: String, lite: Bool = false) async -> Outcome {
        guard KulanApp.safeSegment(code) else { return .refused("This link is no longer valid.") }
        if let k = fresh(code), k.full || lite { return k.outcome }
        let key = code + (lite ? "#lite" : "")
        if let t = inFlight[key] { return await t.value }
        let task = Task<Outcome, Never> { @MainActor in
            do {
                var args: [String: Any] = ["code": code]
                if lite { args["lite"] = true }
                let res = try await fns.httpsCallable("groupLinkPreview").call(args)
                return .found(GroupLinkPreview(code: code, data: res.data as? [String: Any] ?? [:]))
            } catch {
                let ns = error as NSError
                // FunctionsErrorCode: 5 not found, 7 permission denied. Anything else (offline,
                // unavailable, internal, too many requests) is a failure worth retrying.
                if ns.domain == FunctionsErrorDomain, ns.code == FunctionsErrorCode.notFound.rawValue
                    || ns.code == FunctionsErrorCode.permissionDenied.rawValue {
                    return .refused(ns.localizedDescription)
                }
                return .failed(NetworkState.shared.isOnline ? "Couldn't connect" : "No internet connection. Try again.")
            }
        }
        inFlight[key] = task
        let out = await task.value
        inFlight[key] = nil
        switch out {
        case .failed:
            requestedCodes.remove(code)   // a later card may try again
        default:
            // A lite answer never replaces a full one that is still trusted.
            if !(lite && (fresh(code)?.full ?? false)) {
                known[code] = Known(outcome: out, full: !lite, at: Date())
            }
        }
        return out
    }

    /// After a join through the sheet: the card says Open Group from now on, and the next tap goes
    /// straight to the chat.
    static func noteJoined(_ code: String, cid: String) {
        memberCodes.withLock { $0[code] = cid }
        if var p = cached(code) {
            p.isMember = true
            p.cid = cid
            known[code] = Known(outcome: .found(p), full: true, at: Date())
        }
    }

    static func noteRequested(_ code: String) {
        if var p = cached(code) {
            p.requested = true
            // Trusted for 20 s, not the full two minutes: an admin may decline at once, and the
            // card should then let the person ask again (audit 2026-10-20).
            known[code] = Known(outcome: .found(p), full: true, at: Date().addingTimeInterval(20 - trust))
        }
    }

    // MARK: - The tap

    /// The card, its button and the link itself all come here. A group I am in opens; any other
    /// link opens the join sheet (`JoinGroupSheet`, presented by the Chats tab).
    static func open(_ code: String, push: Bool) {
        guard Flags.groupsEnabled, KulanApp.safeSegment(code) else { return }
        let cid = memberCid(code) ?? cached(code).flatMap { $0.isMember ? $0.cid : nil }
        if let cid {
            let router = AppRouter.shared
            if router.activeChatId == cid { return }   // already on screen
            router.pendingChatPush = push
            if let p = cached(code) {
                router.pendingChatName = p.title
                router.pendingChatPhoto = p.photoUrl
            }
            router.pendingChatId = cid
            return
        }
        AppRouter.shared.pendingInviteCode = code
    }
}
