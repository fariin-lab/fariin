import Foundation
import FirebaseFirestore
import FirebaseFunctions

// ⛔ PUBLIC GROUPS — 2026-10-19 groups v2 (owner: "go do like" the reference app). A group an admin
// makes Public takes an @name in the SAME namespace as people (usernames/{name}, kind 'group'), so
// it can be found in global search and opened from fariin.com/<name>. Every write goes through the
// server: the group document's `isPublic` / `username` / `usernameLower` are refused to every client
// by firestore.rules, and the name and the group move together in one transaction there.
//
//   checkGroupUsername / setGroupUsername   functions-username (the one username service)
//   searchUsernames { groupsOnly: true }    the group half of global search, its own rate budget
//   resolveUsername { groups: true }        a bare fariin.com/<name> link: a person or a group
//   publicGroupPreview / joinPublicGroup    functions-groups, the join page
//
// MESSAGES BEFORE JOINING (owner 2026-10-21): an outsider reads a public group's messages in the
// real chat screen when firestore.rules allow it (public, `e2ee == false`, history not hidden, not
// ended, not banned). `canPeek` asks; the group document itself stays members-only, so the header
// comes from `publicGroupPreview`. See PublicGroupSheet.

/// One public group from global search. Only what the join page shows anybody.
struct PublicGroupHit: Identifiable, Equatable {
    let cid: String
    let handle: String
    let title: String
    let photoUrl: String?
    let memberCount: Int
    let isMember: Bool
    var id: String { cid }

    /// "@name · 12 members", the search row's second line.
    var subtitle: String { "@\(handle) · \(GroupDirectory.membersLine(memberCount))" }

    init?(_ row: [String: Any]) {
        guard (row["kind"] as? String) == "group",
              let cid = row["cid"] as? String, GroupDirectory.safeId(cid),
              let handle = row["handle"] as? String, !handle.isEmpty else { return nil }
        self.cid = cid
        self.handle = handle
        let t = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.title = t.isEmpty ? "Group" : t
        let p = row["photoUrl"] as? String ?? ""
        self.photoUrl = p.isEmpty ? nil : p
        self.memberCount = (row["memberCount"] as? NSNumber)?.intValue ?? 0
        self.isMember = row["isMember"] as? Bool ?? false
    }
}

/// What `publicGroupPreview` says about a public group.
struct PublicGroupPreview: Equatable {
    let cid: String
    var username: String
    var title: String
    var photoUrl: String?
    var description: String
    var memberCount: Int
    var isMember: Bool
    var needsApproval: Bool
    var requested: Bool
    /// Who is in it, for a visitor's view of the group page (owner, admins, then the rest; at most
    /// 100, from `publicGroupPreview`). Empty from an older server.
    var members: [PublicGroupMember]

    init?(_ data: [String: Any]) {
        guard let cid = data["cid"] as? String, GroupDirectory.safeId(cid) else { return nil }
        self.cid = cid
        self.username = data["username"] as? String ?? ""
        let t = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.title = t.isEmpty ? "Group" : t
        let p = data["photoUrl"] as? String ?? ""
        self.photoUrl = p.isEmpty ? nil : p
        self.description = (data["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.memberCount = (data["memberCount"] as? NSNumber)?.intValue ?? 0
        self.isMember = data["isMember"] as? Bool ?? false
        self.needsApproval = data["needsApproval"] as? Bool ?? false
        self.requested = data["requested"] as? Bool ?? false
        self.members = (data["members"] as? [[String: Any]] ?? []).compactMap(PublicGroupMember.init)
    }
}

/// One member as a visitor sees them on a public group's page.
struct PublicGroupMember: Equatable, Identifiable {
    let uid: String
    let name: String
    let photoUrl: String?
    let role: String   // "owner" | "admin" | "member"
    var id: String { uid }

    init?(_ d: [String: Any]) {
        guard let uid = d["uid"] as? String, !uid.isEmpty else { return nil }
        self.uid = uid
        let n = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.name = n.isEmpty ? "Member" : n
        let p = d["photoUrl"] as? String ?? ""
        self.photoUrl = p.isEmpty ? nil : p
        self.role = d["role"] as? String ?? "member"
    }
}

/// The line under the Public Link field while a name is typed.
enum GroupNameCheck: Equatable {
    case idle, checking, available, taken, tooShort
    case invalid(String)
    case failed

    var text: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking…"
        case .available: return "This link is free to use."
        case .taken: return "Another group or person already has this link."
        case .tooShort: return "A link needs at least \(GroupDirectory.nameMin) characters."
        case .invalid(let why): return why
        case .failed: return "Couldn't check right now. Try again."
        }
    }
}

@MainActor enum GroupDirectory {
    nonisolated static let nameMin = 5
    nonisolated static let nameMax = 30
    private static var fns: Functions { Functions.functions(region: "me-central1") }

    /// One path segment, safe as a Firestore document id (the same test as KulanApp.safeSegment,
    /// callable off the main actor for the parsers above).
    nonisolated static func safeId(_ v: String) -> Bool {
        !v.isEmpty && !v.contains("/") && v != "." && v != ".."
            && !(v.hasPrefix("__") && v.hasSuffix("__")) && v.count <= 128
    }

    nonisolated static func membersLine(_ n: Int) -> String { "\(n) \(n == 1 ? "member" : "members")" }

    /// The public link of a group with this @name.
    static func link(_ name: String) -> String {
        "\(KulanApp.linkHost)/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
    }

    /// The shape rules the phone can judge without asking (the server judges all of them again).
    nonisolated static func localProblem(_ name: String) -> GroupNameCheck? {
        if name.isEmpty { return .idle }
        if name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) == nil {
            return .invalid("Use only letters, numbers and _.")
        }
        if name.count < nameMin { return .tooShort }
        if name.count > nameMax { return .invalid("A link can have at most \(nameMax) characters.") }
        if name.first == "_" || name.last == "_" { return .invalid("A link can't start or end with _.") }
        if name.first?.isLetter != true { return .invalid("A link must start with a letter.") }
        return nil
    }

    // MARK: - The group's own name (admins with change-info)

    static func check(cid: String, name: String) async -> GroupNameCheck {
        if let p = localProblem(name) { return p }
        do {
            let res = try await fns.httpsCallable("checkGroupUsername").call(["cid": cid, "username": name])
            let d = res.data as? [String: Any] ?? [:]
            if d["available"] as? Bool == true { return .available }
            switch d["code"] as? String {
            case "USERNAME_TAKEN": return .taken
            case "USERNAME_RESERVED": return .invalid("This link can't be used.")
            default: return .invalid(groupWords(d["reason"] as? String) ?? "This link can't be used.")
            }
        } catch {
            return .failed
        }
    }

    /// Make the group public under `name`, or private with "". Throws the server's own words.
    static func setName(cid: String, name: String) async throws {
        do {
            _ = try await fns.httpsCallable("setGroupUsername").call(["cid": cid, "username": name])
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain {
                // The literal "details" (the SDK constant's value), as ChatPin.lockDeadline does.
                let code = (ns.userInfo["details"] as? [String: Any])?["code"] as? String
                if code == "USERNAME_TAKEN" { throw Failure("Another group or person already has this link.") }
                if code == "USERNAME_RESERVED" { throw Failure("This link can't be used.") }
                throw Failure(groupWords(ns.localizedDescription) ?? "Couldn't save the link. Try again.")
            }
            throw Failure(NetworkState.shared.isOnline ? "Couldn't save the link. Try again."
                                                       : "No internet connection. Try again.")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// The name rules' sentences speak of "Usernames"; on a group's page it is the link.
    private static func groupWords(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "taken" else { return nil }
        return s.replacingOccurrences(of: "Usernames", with: "Links")
            .replacingOccurrences(of: "username", with: "link")
    }

    // MARK: - Search

    /// The public groups whose @name starts with `query` (3 characters and up, like people).
    static func search(_ raw: String) async -> [PublicGroupHit] {
        var q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
        guard q.count >= 3, q.count <= nameMax,
              q.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil else { return [] }
        let callable = fns.httpsCallable("searchUsernames")
        callable.timeoutInterval = 8
        guard let res = try? await callable.call(["query": q, "groupsOnly": true]),
              let rows = (res.data as? [String: Any])?["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap(PublicGroupHit.init)
    }

    // MARK: - A bare fariin.com/<name> link

    enum Resolved { case group(String), person, none }

    static func resolve(_ name: String) async -> Resolved {
        guard KulanApp.safeSegment(name) else { return .none }
        guard let res = try? await fns.httpsCallable("resolveUsername").call(["username": name, "groups": true]),
              let d = res.data as? [String: Any], d["found"] as? Bool == true else { return .none }
        if (d["kind"] as? String) == "group", let cid = d["cid"] as? String, KulanApp.safeSegment(cid) {
            return .group(cid)
        }
        return .person
    }

    // MARK: - The join page

    enum PreviewOutcome {
        case found(PublicGroupPreview)
        case refused(String)
        case failed(String)
    }

    // ⛔ OPEN AT ONCE, AS THE REFERENCE APP DOES — owner 2026-10-21: tapping a group in search showed
    // a spinner page while two server calls ran one after the other. Their search row already holds
    // the peer, so the chat opens on what is known and fills in behind. Ours: every answer is kept
    // (by cid and by @name), search warms the first few public hits, and the page asks both
    // questions at once.
    @MainActor private static var previews: [String: PublicGroupPreview] = [:]
    @MainActor private static var peeks: [String: Bool] = [:]

    @MainActor static func cachedPreview(name: String?, cid: String?) -> PublicGroupPreview? {
        if let cid, let p = previews["c:" + cid] { return p }
        if let name, let p = previews["n:" + name.lowercased()] { return p }
        return nil
    }
    @MainActor static func cachedPeek(_ cid: String) -> Bool? { peeks[cid] }

    @MainActor fileprivate static func remember(_ p: PublicGroupPreview) {
        previews["c:" + p.cid] = p
        if !p.username.isEmpty { previews["n:" + p.username.lowercased()] = p }
    }

    /// Fetched ahead (search results, Recent), so a tap opens with nothing left to wait for.
    @MainActor private static var warming = Set<String>()
    @MainActor static func warm(cid: String) {
        guard previews["c:" + cid] == nil, warming.insert(cid).inserted else { return }
        Task {
            async let a = preview(name: nil, cid: cid)
            async let b = canPeek(cid: cid)
            _ = await (a, b)
            await MainActor.run { _ = warming.remove(cid) }
        }
    }

    /// By @name (a link) or by cid (a search row).
    static func preview(name: String?, cid: String?) async -> PreviewOutcome {
        var args: [String: Any] = [:]
        if let name, !name.isEmpty { args["username"] = name }
        if let cid, KulanApp.safeSegment(cid) { args["cid"] = cid }
        guard !args.isEmpty else { return .refused("This group is not public.") }
        do {
            let res = try await fns.httpsCallable("publicGroupPreview").call(args)
            guard let p = PublicGroupPreview(res.data as? [String: Any] ?? [:]) else {
                return .refused("This group is not public.")
            }
            await MainActor.run { remember(p) }
            return .found(p)
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain, ns.code == FunctionsErrorCode.notFound.rawValue
                || ns.code == FunctionsErrorCode.permissionDenied.rawValue {
                return .refused(ns.localizedDescription)
            }
            return .failed(NetworkState.shared.isOnline ? "Couldn't connect" : "No internet connection. Try again.")
        }
    }

    /// May this phone read the group's messages from outside? One message asked of the server; any
    /// refusal or failure means no (an old encrypted group, history hidden from newcomers, ended,
    /// banned, rules not deployed yet, offline), and the join page shows as before. Never routed to
    /// SessionRecovery: a refusal here is an answer, not a broken session. owner 2026-10-21.
    static func canPeek(cid: String) async -> Bool {
        guard KulanApp.safeSegment(cid) else { return false }
        do {
            _ = try await FirestoreHub.db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true).limit(to: 1)
                .getDocuments(source: .server)
            await MainActor.run { peeks[cid] = true }
            return true
        } catch {
            // Offline is not an answer to keep; a refusal is.
            let ns = error as NSError
            if ns.code == FirestoreErrorCode.permissionDenied.rawValue { await MainActor.run { peeks[cid] = false } }
            return false
        }
    }

    enum JoinResult { case joined, requested, already }

    static func join(cid: String) async throws -> JoinResult {
        do {
            // 20s, not the default 70: a join that hangs must give the bar back with a message
            // (owner 2026-10-23, "Joining…" stuck).
            let callable = fns.httpsCallable("joinPublicGroup")
            callable.timeoutInterval = 20
            let res = try await callable.call(["cid": cid])
            switch (res.data as? [String: Any])?["status"] as? String {
            case "requested": return .requested
            case "already": return .already
            default: return .joined
            }
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain { throw Failure(ns.localizedDescription) }
            throw Failure(NetworkState.shared.isOnline ? "Couldn't join. Try again." : "No internet connection. Try again.")
        }
    }

    /// Opens the join page (`PublicGroupSheet`, presented by the Chats tab). A group I am already in
    /// opens its chat instead.
    /// `push`: slide the chat in from the right (a link tapped inside a chat). Off everywhere else:
    /// from search the Chats tab must REPLACE its path while the search page closes (owner
    /// 2026-10-23: pushing there left the chat list with no top buttons and no tab bar).
    static func open(cid: String?, name: String?, push: Bool = false) {
        guard Flags.groupsEnabled else { return }
        if let cid, let mine = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }),
           mine.users.contains(AuthService.shared.uid ?? "") {
            openChat(cid, title: mine.title, photo: mine.avatarUrl, push: push)
            return
        }
        AppRouter.shared.pendingPublicGroup = PublicGroupTarget(cid: cid, name: name)
    }

    static func openChat(_ cid: String, title: String, photo: String?, push: Bool = false) {
        let router = AppRouter.shared
        if router.activeChatId == cid { router.pendingChatReplaceTop = false; return }
        // owner 2026-10-23: a group link opened the chat with no slide. Without `pendingChatPush` the
        // Chats tab REPLACES its path; a user link sets it and pushes from the right (ProfileCardDoor).
        router.pendingChatPush = push
        router.pendingChatName = title
        router.pendingChatPhoto = photo
        router.pendingChatId = cid
    }
}

/// What the join page is for: a cid (from search) and/or an @name (from a link).
struct PublicGroupTarget: Identifiable, Equatable, Hashable {
    var cid: String?
    var name: String?
    var id: String { (cid ?? "") + "|" + (name ?? "") }
}
