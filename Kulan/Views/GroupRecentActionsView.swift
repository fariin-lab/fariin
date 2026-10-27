import SwiftUI
import FirebaseFunctions

// RECENT ACTIONS (audit 2026-10-26 item 14). Pushed from Group Settings › Recent Actions for the owner
// and the admins. What the group's managers did: members added or removed, admins and their rights,
// restrictions, info and settings changes, pins, join requests, links, and Fariin's own moderation.
// Everything comes from the server's `groupAdminLog` callable (functions-groups), 50 at a time;
// nothing from before it was deployed.
//
// REDESIGN (owner 2026-10-27, "half the reference app, half ours"). From the reference app's admin
// log: each action reads like a chat event under a centred date pill, with who did it, the action
// in words with the person or value it touched in bold, the detail it carries (the rights given,
// what a member is held back from and until when, the new name), and a filter by kind of action and
// by admin with "All" switches. Ours: the cards, glass, BusyArc, line icons and Fariin blue.
// Only what the log stores is shown: it keeps no old name, no old photo and no setting values, so
// those are not drawn. The current photo and description are shown on the NEWEST change of each,
// labelled as what the group has now.

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

    var fields: [String] { (detail["fields"] as? [String]) ?? [] }
}

/// The filter's kinds of action, as the reference app groups them.
enum RecentActionKind: String, CaseIterable, Identifiable {
    case newMembers, joinRequests, restrictions, admins, info, links, pins, fariin
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMembers:   return "New Members"
        case .joinRequests: return "Join Requests"
        case .restrictions: return "Restrictions and Removals"
        case .admins:       return "Admins and Owner"
        case .info:         return "Group Info and Settings"
        case .links:        return "Invite Links"
        case .pins:         return "Pinned Messages"
        case .fariin:       return "Fariin"
        }
    }

    /// "ic_" = the owner's outline drawings Group Settings uses, else an SF Symbol.
    var icon: String {
        switch self {
        case .newMembers:   return "ic_gs_members"
        case .joinRequests: return "ic_gs_join_requests"
        case .restrictions: return "ic_gs_banned"
        case .admins:       return "ic_gs_admins"
        case .info:         return "ic_gs_permissions"
        case .links:        return "link"
        case .pins:         return "pin"
        case .fariin:       return "checkmark.shield"
        }
    }

    static func of(_ type: String) -> RecentActionKind {
        switch type {
        case "member_added": return .newMembers
        case "join_approved", "join_denied": return .joinRequests
        case "member_removed", "member_unbanned", "restricted", "unrestricted": return .restrictions
        case "admin_added", "admin_removed", "admin_rights", "owner_changed", "roles": return .admins
        case "link_created", "link_edited", "link_revoked", "link_deleted", "links_reset": return .links
        case "pinned", "unpinned": return .pins
        case "fariin_action": return .fariin
        default: return .info   // info, settings, username_set, made_private, group_ended
        }
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
    /// nil = everything (the reference app's "All Actions" / "All Admins").
    @State private var kinds: Set<RecentActionKind>?
    @State private var actors: Set<String>?
    @State private var showFilter = false

    private var me: String { AuthService.shared.uid ?? "" }
    private var conv: Conversation? { ConversationsRepository.shared.conversations.first { $0.id == cid } }
    private var filtering: Bool { kinds != nil || actors != nil }

    private var shown: [GroupAdminLogEvent] {
        events.filter { e in
            (kinds?.contains(RecentActionKind.of(e.type)) ?? true) && (actors?.contains(e.by) ?? true)
        }
    }

    private struct DaySection: Identifiable {
        let day: Date
        var items: [GroupAdminLogEvent]
        var id: Date { day }
    }

    /// Days, newest first; each day's actions newest first (the order the server pages them in).
    private var days: [DaySection] {
        let cal = Calendar.current
        var out: [DaySection] = []
        for e in shown {
            let d = cal.startOfDay(for: e.at)
            if let last = out.last, last.day == d { out[out.count - 1].items.append(e) }
            else { out.append(DaySection(day: d, items: [e])) }
        }
        return out
    }

    /// Two days of placeholder entries in the page's own shape: a centred date pill, then a card of
    /// rows (photo, name line, action line).
    private var recentActionsSkeleton: some View {
        VStack(spacing: 18) {
            ForEach(0..<2, id: \.self) { day in
                VStack(spacing: 10) {
                    SkeletonBlock(width: 96, height: 24, radius: 12)
                    VStack(spacing: 0) {
                        ForEach(0..<(day == 0 ? 4 : 3), id: \.self) { i in
                            HStack(spacing: 12) {
                                SkeletonCircle(size: 40)
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonBlock(width: 110, height: 12)
                                    SkeletonBlock(width: [210, 170, 230, 150][i % 4], height: 11)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if loading && events.isEmpty {
                    // owner 2026-10-27: a skeleton of the page (date pill, a card of entries)
                    // instead of a spinner on an empty screen.
                    recentActionsSkeleton
                } else if let failure, events.isEmpty {
                    emptyState(icon: "exclamationmark.arrow.circlepath", title: "Couldn't Load", text: failure,
                               button: "Try Again") { Task { await load(more: false) } }
                } else if events.isEmpty {
                    emptyState(icon: "clock.arrow.circlepath", title: "No Recent Actions",
                               text: "What the owner and admins change in this group shows here.")
                } else if shown.isEmpty {
                    emptyState(icon: "line.3.horizontal.decrease", title: "No Matching Actions",
                               text: next == nil ? "Nothing here matches the filter."
                                                 : "Nothing loaded so far matches the filter.",
                               button: "Show All Actions") { kinds = nil; actors = nil }
                    if next != nil { moreLoader }
                } else {
                    ForEach(days) { section in
                        datePill(section.day)
                        dayCard(section.items)
                    }
                    if next != nil { moreLoader }
                }
                if !(loading && events.isEmpty) {
                    Text("Only the owner and admins see Recent Actions.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 28)
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Recent Actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilter = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(filtering ? Color.fariinBlue : Color.primary)
                }
                .accessibilityLabel(filtering ? "Filter, on" : "Filter")
                .disabled(events.isEmpty)
            }
        }
        .sheet(isPresented: $showFilter) {
            RecentActionsFilterSheet(people: filterPeople, kinds: kinds, actors: actors,
                                     name: name, photo: photo) { k, a in kinds = k; actors = a }
        }
        .task { if events.isEmpty { await load(more: false) } }
        .refreshable { await load(more: false) }
    }

    // MARK: Pieces

    private func datePill(_ day: Date) -> some View {
        Text(Self.dayTitle(day))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 18).padding(.bottom, 10)
    }

    private func dayCard(_ items: [GroupAdminLogEvent]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider().padding(.leading, 68) }
                row(e)
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func row(_ e: GroupAdminLogEvent) -> some View {
        let more = detail(e)
        return HStack(alignment: .top, spacing: 12) {
            actorAvatar(e)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name(e.by)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(e.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(action(e)).font(.subheadline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !more.isEmpty { detailView(more).padding(.top, 4) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// The actor's face with the kind of action in a small badge, like a chat event's author.
    private func actorAvatar(_ e: GroupAdminLogEvent) -> some View {
        Group {
            if e.by == "fariin", let img = OfficialConfig.shared.avatar {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 42, height: 42).clipShape(Circle())
            } else {
                AvatarView(name: name(e.by), photoUrl: photo(e.by), size: 42)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: Self.typeIcon(e))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))
                .offset(x: 4, y: 4)
        }
        .padding(.top, 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func detailView(_ d: EventDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote = d.quote {
                VStack(alignment: .leading, spacing: 1) {
                    if let label = d.quoteLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
                    Text(quote).font(.subheadline).foregroundStyle(.primary).lineLimit(4)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.fariinBlue).frame(width: 3)
                }
            }
            if let url = d.photoUrl {
                HStack(spacing: 10) {
                    AvatarView(name: conv?.title ?? "", photoUrl: url, size: 44)
                    Text("Current group photo").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note = d.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            if !d.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(d.bullets, id: \.self) { b in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{2022}")
                            Text(b)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var moreLoader: some View {
        BusyArc.small(Color.fariinBlue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            // A new identity per page, so it asks again if it is still on screen after a page whose
            // actions the filter hides.
            .id(events.count)
            .onAppear { Task { await load(more: true) } }
    }

    private func emptyState(icon: String, title: String, text: String,
                            button: String? = nil, _ act: (() -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 26, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 64, height: 64)
                .glassEffect(.regular, in: Circle())
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let button, let act {
                Button(button, action: act)
                    .buttonStyle(.glassProminent).tint(Color.fariinBlue)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 90)
    }

    // MARK: People

    private func name(_ uid: String) -> String {
        if uid.isEmpty { return "Someone" }
        if uid == "fariin" { return "Fariin" }
        if uid == me { return "You" }
        let n = names[uid] ?? conv?.names[uid] ?? ""
        return n.isEmpty ? "Someone" : n
    }

    private func photo(_ uid: String) -> String? {
        let p = conv?.photos[uid] ?? ""
        return p.isEmpty ? nil : p
    }

    /// Who the admin filter lists: the owner and today's admins, then anyone else who acted in what
    /// has loaded (a former admin, Fariin).
    private var filterPeople: [String] {
        var out: [String] = []
        if let c = conv {
            if !c.createdBy.isEmpty { out.append(c.createdBy) }
            out += c.admins.filter { $0 != c.createdBy }
        }
        for e in events where !e.by.isEmpty && !out.contains(e.by) { out.append(e.by) }
        return out
    }

    // MARK: Words

    private enum Part { case t(String), b(String) }

    private func say(_ parts: Part...) -> AttributedString {
        var a = AttributedString()
        for p in parts {
            switch p {
            case .t(let s): a += AttributedString(s)
            case .b(let s):
                var x = AttributedString(s)
                x.font = Font.subheadline.weight(.semibold)
                a += x
            }
        }
        return a
    }

    /// The action, without the actor (their name is the row's first line).
    private func action(_ e: GroupAdminLogEvent) -> AttributedString {
        let them = name(e.target)
        let d = e.detail
        switch e.type {
        case "member_added": return say(.t("added "), .b(them))
        case "member_removed":
            return (d["banned"] as? Bool ?? false)
                ? say(.t("removed and banned "), .b(them)) : say(.t("removed "), .b(them))
        case "member_unbanned": return say(.t("unbanned "), .b(them))
        case "admin_added": return say(.t("made "), .b(them), .t(" an admin"))
        case "admin_rights": return say(.t("changed the admin rights of "), .b(them))
        case "admin_removed": return say(.t("removed "), .b(them), .t(" as admin"))
        case "owner_changed": return say(.t("made "), .b(them), .t(" the owner"))
        case "restricted": return say(.t("restricted "), .b(them))
        case "unrestricted": return say(.t("lifted the restrictions on "), .b(them))
        case "roles":
            return e.target.isEmpty ? say(.t("changed member roles")) : say(.t("changed the role of "), .b(them))
        case "info":
            let words = e.fields.compactMap { f -> String? in
                switch f {
                case "name": return "name"
                case "description": return "description"
                case "photo": return "photo"
                default: return nil
                }
            }
            return words.isEmpty ? say(.t("changed the group info")) : say(.t("changed the group "), .b(Self.list(words)))
        case "settings":
            let keys = (d["keys"] as? [String]) ?? []
            return keys.count == 1 ? say(.t("changed "), .b(Self.settingName(keys[0])))
                                   : say(.t("changed the group settings"))
        case "pinned", "unpinned":
            let n = ((d["messages"] as? [String]) ?? []).count
            let verb = e.type == "pinned" ? "pinned " : "unpinned "
            return n > 1 ? say(.t(verb), .b("\(n) messages")) : say(.t(verb + "a message"))
        case "join_approved": return say(.t("let "), .b(them), .t(" in"))
        case "join_denied": return say(.t("turned down "), .b(them))
        case "link_created", "link_edited", "link_revoked":
            let verb = e.type == "link_created" ? "created " : e.type == "link_edited" ? "edited " : "turned off "
            return say(.t(verb), .b(Self.linkName(d)))
        case "link_deleted":
            let n = (d["count"] as? NSNumber)?.intValue ?? 0
            return n > 1 ? say(.t("deleted "), .b("\(n) invite links")) : say(.t("deleted an invite link"))
        case "links_reset": return say(.t("reset the invite links"))
        case "group_ended": return say(.t("ended the group"))
        case "username_set":
            let u = d["username"] as? String ?? ""
            return u.isEmpty ? say(.t("removed the group's public link"))
                             : say(.t("set the public link to "), .b("@" + u))
        case "made_private": return say(.t("made the group private"))
        case "fariin_action": return say(.t(Self.fariinWords(d["op"] as? String ?? "")))
        default: return say(.t("changed the group"))
        }
    }

    struct EventDetail {
        var quoteLabel: String?
        var quote: String?
        var photoUrl: String?
        var note: String?
        var bullets: [String] = []
        var isEmpty: Bool { quote == nil && photoUrl == nil && note == nil && bullets.isEmpty }
    }

    /// The richer part, from what the event stores (and, for the newest photo or description change,
    /// what the group has now, labelled so).
    private func detail(_ e: GroupAdminLogEvent) -> EventDetail {
        var out = EventDetail()
        let d = e.detail
        switch e.type {
        case "admin_added", "admin_rights":
            let rights = (d["rights"] as? [String]) ?? []
            // No list = a full admin (Conversation.adminCan: no adminRights entry means every right).
            out.note = rights.isEmpty ? "All admin rights" : "Can:"
            out.bullets = rights.map { Conversation.Right(rawValue: $0)?.label ?? $0 }
        case "restricted":
            let flags = (d["flags"] as? [String]) ?? []
            let until = (d["until"] as? NSNumber)?.doubleValue ?? 0
            let end = Date(timeIntervalSince1970: until / 1000)
            // The app's "no end date" is a date ~50 years on (ThreadView's restrict sheet).
            if until <= 0 || end.timeIntervalSince(e.at) > 10 * 365 * 86_400 {
                out.note = "No end date. Held back from:"
            } else {
                out.note = "Until \(end.formatted(date: .abbreviated, time: .shortened)). Held back from:"
            }
            out.bullets = flags.map(Self.restrictName)
        case "settings":
            let keys = (d["keys"] as? [String]) ?? []
            if keys.count > 1 { out.bullets = keys.map(Self.settingName) }
        case "info":
            if let n = d["name"] as? String, !n.isEmpty { out.quoteLabel = "New name"; out.quote = n }
            if e.fields.contains("photo"), newest("photo") == e.id,
               let url = conv?.avatarUrl, !url.isEmpty { out.photoUrl = url }
            if out.quote == nil, e.fields.contains("description"), newest("description") == e.id,
               let text = conv?.groupDescription, !text.isEmpty {
                out.quoteLabel = "Description now"; out.quote = text
            }
        case "owner_changed":
            if let from = d["from"] as? String, !from.isEmpty, from != e.by { out.note = "Before: \(name(from))" }
        default: break
        }
        return out
    }

    /// The newest loaded change of one info field (events come newest first).
    private func newest(_ field: String) -> String? {
        events.first { $0.type == "info" && $0.fields.contains(field) }?.id
    }

    private static func typeIcon(_ e: GroupAdminLogEvent) -> String {
        switch e.type {
        case "member_added": return "person.badge.plus"
        case "member_removed": return "person.badge.minus"
        case "member_unbanned", "join_approved": return "person.crop.circle.badge.checkmark"
        case "join_denied": return "person.crop.circle.badge.xmark"
        case "admin_added", "admin_rights": return "star"
        case "admin_removed": return "star.slash"
        case "owner_changed": return "crown"
        case "restricted": return "hand.raised"
        case "unrestricted": return "hand.raised.slash"
        case "roles": return "tag"
        case "info": return e.fields == ["photo"] ? "camera" : "pencil"
        case "settings": return "gearshape"
        case "pinned": return "pin"
        case "unpinned": return "pin.slash"
        case "link_created", "link_edited", "link_revoked", "link_deleted", "links_reset": return "link"
        case "username_set": return "at"
        case "made_private": return "lock"
        case "group_ended": return "xmark"
        case "fariin_action": return "checkmark.shield"
        default: return "clock"
        }
    }

    private static func settingName(_ key: String) -> String {
        switch key {
        case "disappearSeconds":    return "Auto-Delete Messages"
        case "onlyAdminsSend":      return "Who Can Send Messages"
        case "membersCanAdd":       return "Who Can Add Members"
        case "membersCanEditInfo":  return "Who Can Edit Group Info"
        case "onlyAdminsCall":      return "Who Can Start Calls"
        case "wallpaper":           return "Wallpaper"
        case "membersCanShareLink": return "Sharing the Invite Link"
        case "restrictedBy", "restrictRequest": return "Restricted Chat"
        case "noScreenshots":       return "Screenshots"
        case "noForwarding":        return "Forwarding"
        case "noSaving":            return "Saving Media"
        case "memberSend":          return "What Members Can Send"
        case "slowMode":            return "Slow Mode"
        case "hideHistoryAt":       return "Chat History for New Members"
        default:                    return "Group Settings"
        }
    }

    private static func restrictName(_ flag: String) -> String {
        switch flag {
        case "sendText":      return "Send Messages"
        case "sendMedia":     return "Photos, Videos, Files and Links"
        case "sendPhotos":    return "Photos and Videos"
        case "sendFiles":     return "Files"
        case "sendLinks":     return "Links"
        case "sendVoice":     return "Voice Messages"
        case "sendStickers":  return "Stickers and GIFs"
        case "sendPolls":     return "Polls"
        case "sendReactions": return "Reactions"
        case "pinMessages":   return "Pin Messages"
        case "addMembers":    return "Add Members"
        case "changeInfo":    return "Change Group Info"
        default:              return flag
        }
    }

    private static func linkName(_ d: [String: Any]) -> String {
        if (d["primary"] as? Bool) == true { return "the main invite link" }
        let n = d["name"] as? String ?? ""
        return n.isEmpty ? "an invite link" : "the invite link \u{201C}\(n)\u{201D}"
    }

    private static func fariinWords(_ op: String) -> String {
        switch op {
        case "groupModSet":    return "changed this group's status"
        case "groupModExpire": return "lifted a limit on this group"
        case "groupDisable":   return "disabled this group"
        case "groupRestore":   return "restored this group"
        case "groupVerify":    return "verified this group"
        case "groupUnverify":  return "removed this group's verified badge"
        case "groupReportSet": return "changed this group's Report button"
        default:               return "moderated this group"
        }
    }

    private static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }

    private static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        let style: Date.FormatStyle = sameYear ? .dateTime.day().month(.wide) : .dateTime.day().month(.wide).year()
        return day.formatted(style)
    }

    // MARK: Work

    private func load(more: Bool) async {
        if more {
            guard !loadingMore, !loading, next != nil else { return }
            loadingMore = true
        } else {
            loading = true
        }
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

// MARK: - Filter

/// The reference app's admin log filter: kinds of action and admins, each with an "All" switch.
/// Applies on Done; filters what has loaded (more loads as the list is scrolled).
private struct RecentActionsFilterSheet: View {
    let people: [String]
    let name: (String) -> String
    let photo: (String) -> String?
    let apply: (Set<RecentActionKind>?, Set<String>?) -> Void
    @State private var kinds: Set<RecentActionKind>
    @State private var actors: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(people: [String], kinds: Set<RecentActionKind>?, actors: Set<String>?,
         name: @escaping (String) -> String, photo: @escaping (String) -> String?,
         apply: @escaping (Set<RecentActionKind>?, Set<String>?) -> Void) {
        self.people = people
        self.name = name
        self.photo = photo
        self.apply = apply
        _kinds = State(initialValue: kinds ?? Set(RecentActionKind.allCases))
        _actors = State(initialValue: actors ?? Set(people))
    }

    private var allKinds: Binding<Bool> {
        Binding(get: { kinds.count == RecentActionKind.allCases.count },
                set: { kinds = $0 ? Set(RecentActionKind.allCases) : [] })
    }
    private var allPeople: Binding<Bool> {
        Binding(get: { people.allSatisfy(actors.contains) },
                set: { actors = $0 ? Set(people) : [] })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    Toggle("All Actions", isOn: allKinds)
                    ForEach(RecentActionKind.allCases) { k in
                        checkRow(on: kinds.contains(k)) {
                            if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
                        } label: {
                            icon(k.icon)
                            Text(k.title)
                        }
                    }
                }
                if !people.isEmpty {
                    Section("Admins") {
                        Toggle("All Admins", isOn: allPeople)
                        ForEach(people, id: \.self) { u in
                            checkRow(on: actors.contains(u)) {
                                if actors.contains(u) { actors.remove(u) } else { actors.insert(u) }
                            } label: {
                                if u == "fariin", let img = OfficialConfig.shared.avatar {
                                    Image(uiImage: img).resizable().scaledToFill()
                                        .frame(width: 32, height: 32).clipShape(Circle())
                                } else {
                                    AvatarView(name: name(u), photoUrl: photo(u), size: 32)
                                }
                                Text(name(u)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let everyKind = kinds.count == RecentActionKind.allCases.count
                        let everyone = people.allSatisfy(actors.contains)
                        apply(everyKind ? nil : kinds, everyone ? nil : actors)
                        dismiss()
                    }
                    .tint(Color.fariinBlue)
                    .disabled(kinds.isEmpty || (!people.isEmpty && actors.isEmpty))
                }
            }
        }
        .presentationDetents([.large])
    }

    private func checkRow<L: View>(on: Bool, _ tap: @escaping () -> Void,
                                   @ViewBuilder label: () -> L) -> some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                label()
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.fariinBlue)
                    .opacity(on ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func icon(_ name: String) -> some View {
        if name.hasPrefix("ic_") {
            Image(name).resizable().scaledToFit().frame(width: 24, height: 24).frame(width: 26)
        } else {
            Image(systemName: name).font(.system(size: 21)).frame(width: 26)
        }
    }
}
