import SwiftUI
import FirebaseFunctions

// RECENT ACTIONS (audit 2026-10-26 item 14). Pushed from the group's page (GroupInfoView › Recent
// Actions) for the owner and the admins. A plain list, newest first, of what the group's managers
// did: members added or removed, admins and their rights, restrictions, info and settings changes,
// pins, join requests, links, and Fariin's own moderation. Everything comes from the server's
// `groupAdminLog` callable (functions-groups), 50 at a time; nothing from before it was deployed.

struct GroupAdminLogEvent: Identifiable {
    let id: String
    let at: Date
    let type: String
    let by: String
    let target: String
    let detail: [String: Any]

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        at = Date(timeIntervalSince1970: ((d["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        type = d["type"] as? String ?? ""
        by = d["by"] as? String ?? ""
        target = d["target"] as? String ?? ""
        detail = d["detail"] as? [String: Any] ?? [:]
    }
}

struct GroupRecentActionsView: View {
    let cid: String
    @State private var events: [GroupAdminLogEvent] = []
    @State private var names: [String: String] = [:]
    @State private var next: [String: Any]?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var failure: String?

    private var me: String { AuthService.shared.uid ?? "" }
    private var conv: Conversation? { ConversationsRepository.shared.conversations.first { $0.id == cid } }

    var body: some View {
        List {
            if loading && events.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            } else if let failure, events.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load(more: false) } }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else if events.isEmpty {
                Section {
                    ContentUnavailableView("No Recent Actions", systemImage: "clock.arrow.circlepath",
                                           description: Text("What the owner and admins change in this group shows here."))
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(events) { e in row(e) }
                    if next != nil {
                        Button {
                            Task { await load(more: true) }
                        } label: {
                            HStack {
                                Spacer()
                                if loadingMore { ProgressView() } else { Text("Show More") }
                                Spacer()
                            }
                        }
                        .disabled(loadingMore)
                    }
                } footer: {
                    Text("Only the owner and admins see Recent Actions.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Recent Actions")
        .navigationBarTitleDisplayMode(.inline)
        .task { if events.isEmpty { await load(more: false) } }
        .refreshable { await load(more: false) }
    }

    private func row(_ e: GroupAdminLogEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sentence(e)).foregroundStyle(.primary)
            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Words

    private func name(_ uid: String) -> String {
        if uid.isEmpty { return "Someone" }
        if uid == "fariin" { return "Fariin" }
        if uid == me { return "You" }
        let n = names[uid] ?? conv?.names[uid] ?? ""
        return n.isEmpty ? "Someone" : n
    }

    private func sentence(_ e: GroupAdminLogEvent) -> String {
        let who = name(e.by)
        let them = name(e.target)
        let d = e.detail
        switch e.type {
        case "member_added": return "\(who) added \(them)"
        case "member_removed":
            return (d["banned"] as? Bool ?? false) ? "\(who) removed and banned \(them)" : "\(who) removed \(them)"
        case "member_unbanned": return "\(who) unbanned \(them)"
        case "admin_added": return "\(who) made \(them) an admin"
        case "admin_rights": return "\(who) changed what \(them) can do as admin"
        case "admin_removed": return "\(who) removed \(them) as admin"
        case "owner_changed": return "\(who) made \(them) the owner"
        case "restricted": return "\(who) restricted \(them)"
        case "unrestricted": return "\(who) lifted the restrictions on \(them)"
        case "roles": return e.target.isEmpty ? "\(who) changed member roles" : "\(who) changed the role of \(them)"
        case "info":
            let fields = (d["fields"] as? [String]) ?? []
            if fields == ["name"], let n = d["name"] as? String, !n.isEmpty { return "\(who) renamed the group to \"\(n)\"" }
            let words = fields.compactMap { f -> String? in
                switch f {
                case "name": return "name"
                case "description": return "description"
                case "photo": return "photo"
                default: return nil
                }
            }
            return words.isEmpty ? "\(who) changed the group info" : "\(who) changed the group \(Self.list(words))"
        case "settings": return "\(who) changed the group settings"
        case "pinned": return "\(who) pinned a message"
        case "unpinned": return "\(who) unpinned a message"
        case "join_approved": return "\(who) let \(them) in"
        case "join_denied": return "\(who) turned down \(them)"
        case "link_created": return "\(who) created an invite link"
        case "link_edited": return "\(who) edited an invite link"
        case "link_revoked": return "\(who) turned off an invite link"
        case "link_deleted": return "\(who) deleted invite links"
        case "links_reset": return "\(who) reset the invite links"
        case "group_ended": return "\(who) ended the group"
        case "username_set": return "\(who) changed the group's public link"
        case "made_private": return "\(who) made the group private"
        case "fariin_action": return Self.fariinWords(d["op"] as? String ?? "")
        default: return "\(who) changed the group"
        }
    }

    private static func fariinWords(_ op: String) -> String {
        switch op {
        case "groupModSet": return "Fariin changed this group's status"
        case "groupDisable": return "Fariin disabled this group"
        case "groupRestore": return "Fariin restored this group"
        case "groupVerify": return "Fariin verified this group"
        case "groupUnverify": return "Fariin removed this group's verified badge"
        case "groupReportSet": return "Fariin changed this group's Report button"
        default: return "Fariin moderated this group"
        }
    }

    private static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }

    // MARK: Work

    private func load(more: Bool) async {
        if more { loadingMore = true } else { loading = true }
        defer { loading = false; loadingMore = false }
        var args: [String: Any] = ["cid": cid, "limit": 50]
        if more, let next { args["before"] = next }
        do {
            let r = try await Functions.functions(region: "me-central1").httpsCallable("groupAdminLog").call(args)
            let d = r.data as? [String: Any] ?? [:]
            let page = ((d["events"] as? [[String: Any]]) ?? []).compactMap(GroupAdminLogEvent.init)
            if let n = d["names"] as? [String: String] { names.merge(n) { _, new in new } }
            if more {
                let have = Set(events.map(\.id))
                events += page.filter { !have.contains($0.id) }
            } else {
                events = page
            }
            next = d["next"] as? [String: Any]
            failure = nil
        } catch let e as NSError where e.domain == FunctionsErrorDomain {
            failure = e.code == FunctionsErrorCode.permissionDenied.rawValue
                ? "Only the group's owner and admins can see this."
                : "Couldn't load recent actions. Check your connection and try again."
        } catch {
            failure = "Couldn't load recent actions. Check your connection and try again."
        }
    }
}
