import SwiftUI

// MARK: - Admin delete sheet (owner 2026-10-18)
//
// ⛔ OWNER 2026-10-18: in a GROUP, an admin who deletes SOMEONE ELSE'S message gets this sheet in
// place of the plain confirm, the reference app's admin delete: one Proceed that can also report the
// sender as spam, delete everything of theirs, and restrict or remove them. What was read in the
// reference app's source and copied here:
//   · the options are Report Spam (always), Delete all from (needs the delete right) and Restrict /
//     Ban (needs the ban right, and none of the senders may be the owner or an admin);
//   · NOTHING is ticked at first. Proceed on its own is just the delete;
//   · several senders: each option's row counts how many are ticked and opens a list of them;
//   · Restrict opens "what can this member do", starting from what they may do now; a switch the
//     whole group already has off cannot be turned on for one person; Send Messages off takes every
//     kind of media with it, and a media switch turned on brings Send Messages back;
//   · a restriction has no end date (theirs is "until forever" too); "Fully ban" turns the choice
//     into remove + ban;
//   · Proceed runs, in this order: the delete, delete-all, report, then ban or restrict.
// 1:1 chats, and a delete of only my own messages, keep the old alert. ThreadView decides.

/// What the sheet was opened on.
struct AdminDeleteRequest: Identifiable {
    let id = UUID()
    let messages: [Message]
}

/// What Proceed asks ThreadView to carry out. ThreadView owns the deletes (its tombstones and their
/// restore on a refusal); the rest goes straight to ChatService.
struct AdminDeleteOutcome {
    var deleteIds: [String] = []
    /// sender → their messages in this delete, for the spam report.
    var reportSpam: [String: [String]] = [:]
    /// removed from the group and kept out (`bannedUids`).
    var ban: [String] = []
    /// sender → restriction flags to write. Empty = lift what they had.
    var restrict: [String: [String]] = [:]
}

struct AdminDeleteSheet: View {
    let conv: Conversation
    let me: String
    let selected: [Message]
    /// Every LOADED message of each sender that I may delete for everyone (ThreadView's own test).
    /// "Delete all from" reaches these; nothing older than what this phone has loaded.
    let loadedByAuthor: [String: [String]]
    let onProceed: (AdminDeleteOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Option: Hashable { case report, deleteAll, restrict }

    @State private var report = Set<String>()
    @State private var deleteAll = Set<String>()
    @State private var restrict = Set<String>()
    @State private var banMode = false
    @State private var expanded: Option?
    /// The switches that are ON in "What can this member do?".
    @State private var allowed = Set<Conversation.Restrict>()
    @State private var mediaOpen = false
    @State private var seeded = false

    private typealias R = Conversation.Restrict
    private static let media: [R] = [.sendPhotos, .sendFiles, .sendVoice, .sendStickers, .sendLinks]
    private static let switches: [R] = [R.sendText] + media + [R.addMembers, R.pinMessages, R.changeInfo]

    // MARK: Who and what

    /// The senders, in the order their messages were picked. Never me.
    private var authors: [String] {
        var seen = Set<String>()
        return selected.map(\.authorId).filter { $0 != me && !$0.isEmpty && seen.insert($0).inserted }
    }
    private var single: Bool { authors.count == 1 }
    private func name(_ uid: String) -> String {
        let n = conv.names[uid] ?? ""
        return n.isEmpty ? "Member" : n
    }
    private var firstName: String { name(authors.first ?? "") }

    /// Restrict and ban are offered only when I hold the right and EVERY sender is a plain member:
    /// never the owner, never an admin (the rules exempt admins from restrictions, and only the
    /// owner may remove an admin).
    private var canRestrict: Bool {
        conv.adminCan(me, .banUsers)
            && authors.allSatisfy { !conv.isOwner($0) && !conv.admins.contains($0) && conv.users.contains($0) }
    }

    private var deleteIds: [String] {
        var ids = selected.map(\.id)
        var have = Set(ids)
        for a in authors where deleteAll.contains(a) {
            for id in loadedByAuthor[a] ?? [] where have.insert(id).inserted { ids.append(id) }
        }
        return ids
    }
    private var title: String {
        let n = deleteIds.count
        return "Delete \(n) Message\(n == 1 ? "" : "s")"
    }

    // MARK: Restrictions

    /// Does the GROUP let members do this at all? A switch it has off stays off and cannot be moved.
    private func groupLets(_ r: R) -> Bool {
        switch r {
        case .addMembers:  return conv.membersCanAdd
        case .changeInfo:  return conv.membersCanEditInfo
        case .pinMessages: return false   // pinning is for admins in every Fariin group
        default:           return !conv.onlyAdminsSend
        }
    }
    private func label(_ r: R) -> String {
        switch r {
        case .sendText:     return "Send Messages"
        case .sendPhotos:   return "Photos and Videos"
        case .sendFiles:    return "Files"
        case .sendVoice:    return "Voice Messages"
        case .sendStickers: return "Stickers and GIFs"
        case .sendLinks:    return "Links"
        case .addMembers:   return "Add Members"
        case .pinMessages:  return "Pin Messages"
        case .changeInfo:   return "Change Group Info"
        default:            return r.rawValue
        }
    }

    /// Start from what they may do now: a switch is on when no picked sender is held back from it.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        let now = Date().timeIntervalSince1970 * 1000
        allowed = Set(Self.switches.filter { r in
            groupLets(r) && !authors.contains { conv.isRestricted($0, r, now: now) }
        })
    }

    private func setAllowed(_ r: R, _ on: Bool) {
        var next = allowed
        if on { next.insert(r) } else { next.remove(r) }
        if r == .sendText && !on { next.subtract(Self.media) }               // no messages, no media
        if Self.media.contains(r) && on && groupLets(.sendText) { next.insert(.sendText) }
        allowed = next
    }

    /// The flags to write for one sender. Switches the group has locked keep that sender's own
    /// value, so a restriction is never lifted by a switch the admin could not touch.
    private func flags(for uid: String) -> [String] {
        let now = Date().timeIntervalSince1970 * 1000
        var f = Set<String>()
        for r in Self.switches {
            if groupLets(r) {
                if !allowed.contains(r) { f.insert(r.rawValue) }
            } else if conv.isRestricted(uid, r, now: now) {
                f.insert(r.rawValue)
            }
        }
        if f.contains(R.sendText.rawValue) {
            // The same set the simple Mute writes, plus the three finer media flags.
            f.formUnion(Conversation.muteAllFlags)
            f.formUnion([R.sendPhotos, .sendFiles, .sendLinks].map(\.rawValue))
        }
        // All three finer media flags off = the old all-media flag too, which older builds read.
        if [R.sendPhotos, .sendFiles, .sendLinks].allSatisfy({ f.contains($0.rawValue) }) {
            f.insert(R.sendMedia.rawValue)
        }
        return R.allCases.map(\.rawValue).filter { f.contains($0) }
    }

    private func proceed() {
        var out = AdminDeleteOutcome()
        out.deleteIds = deleteIds
        for a in authors where report.contains(a) {
            out.reportSpam[a] = selected.filter { $0.authorId == a }.map(\.id)
        }
        if canRestrict {
            let now = Date().timeIntervalSince1970 * 1000
            for a in authors where restrict.contains(a) {
                if banMode {
                    out.ban.append(a)
                } else {
                    let f = flags(for: a)
                    // Nothing held back and nothing held back before: no write, no notice.
                    if f.isEmpty && conv.activeRestrictions(a, now: now).isEmpty { continue }
                    out.restrict[a] = f
                }
            }
        }
        dismiss()
        onProceed(out)
    }

    // MARK: View

    var body: some View {
        NavigationStack {
            List {
                Section {
                    optionRows(.report, "Report Spam", $report)
                    optionRows(.deleteAll, single ? "Delete all from \(firstName)" : "Delete all from senders", $deleteAll)
                    if canRestrict {
                        optionRows(.restrict,
                                   banMode ? (single ? "Remove and ban \(firstName)" : "Remove and ban senders")
                                           : (single ? "Restrict \(firstName)" : "Restrict senders"),
                                   $restrict)
                    }
                } header: {
                    Text("Additional actions")
                } footer: {
                    if canRestrict && banMode && !restrict.isEmpty {
                        Button("Restrict instead") { withAnimation(.smooth(duration: 0.22)) { banMode = false } }
                            .font(.footnote.weight(.semibold))
                    }
                }
                if canRestrict && !banMode && !restrict.isEmpty {
                    restrictSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: proceed) {
                    Text("Proceed").font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.fariinAction, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .onAppear(perform: seed)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// One option: a single sender is one tick; several get a count and a list to pick from.
    @ViewBuilder
    private func optionRows(_ option: Option, _ text: String, _ picked: Binding<Set<String>>) -> some View {
        let all = Set(authors)
        let on = !picked.wrappedValue.isEmpty
        HStack(spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { picked.wrappedValue = on ? [] : all }
            } label: {
                HStack(spacing: 12) {
                    tick(on, partial: on && picked.wrappedValue.count < all.count)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text).foregroundStyle(.primary)
                        if option == .deleteAll && single {
                            let n = loadedByAuthor[authors.first ?? ""]?.count ?? 0
                            Text("\(n) loaded message\(n == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !single {
                Button {
                    withAnimation(.smooth(duration: 0.22)) { expanded = expanded == option ? nil : option }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(picked.wrappedValue.count)/\(all.count)").monospacedDigit()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded == option ? 180 : 0))
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded == option ? "Hide senders" : "Show senders")
            }
        }
        if !single && expanded == option {
            ForEach(authors, id: \.self) { uid in
                let mine = picked.wrappedValue.contains(uid)
                Button {
                    if mine { picked.wrappedValue.remove(uid) } else { picked.wrappedValue.insert(uid) }
                } label: {
                    HStack(spacing: 12) {
                        tick(mine, partial: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(uid)).foregroundStyle(.primary)
                            if option == .deleteAll {
                                let n = loadedByAuthor[uid]?.count ?? 0
                                Text("\(n) loaded message\(n == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tick(_ on: Bool, partial: Bool) -> some View {
        Image(systemName: on ? (partial ? "minus.circle.fill" : "checkmark.circle.fill") : "circle")
            .font(.title3)
            .foregroundStyle(on ? Color.fariinAction : Color.secondary)
    }

    private var restrictSection: some View {
        Section {
            switchRow(.sendText)
            switchRow(.sendPhotos, mediaHeader: true)
            if mediaOpen {
                ForEach(Self.media, id: \.self) { r in
                    switchRow(r).padding(.leading, 20)
                }
            }
            switchRow(.addMembers)
            // No Pin Messages switch (audit 2026-10-26 item 6): members never pin in a Fariin group
            // (firestore.rules, pinMessages is an admin right), so it was always grey and did nothing.
            // A flag already written stays as it is (`flags(for:)` keeps a locked switch's value).
            switchRow(.changeInfo)
        } header: {
            Text(single ? "What can \(firstName) do?" : "What can these members do?")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Switches that are grey are off for everyone in this group. The restriction stays until an admin lifts it.")
                Button(single ? "Fully ban this member" : "Fully ban these members") {
                    withAnimation(.smooth(duration: 0.22)) { banMode = true }
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    /// One switch. With `mediaHeader` it is the "Send Media" row instead: on while any kind of media
    /// is, flipping it flips all of them, and its count opens the five kinds.
    @ViewBuilder
    private func switchRow(_ r: R, mediaHeader: Bool = false) -> some View {
        if mediaHeader {
            let lets = groupLets(.sendPhotos)
            let onCount = Self.media.filter { allowed.contains($0) }.count
            Toggle(isOn: Binding(
                    get: { onCount > 0 },
                    set: { on in
                        var next = allowed
                        if on { next.formUnion(Self.media); if groupLets(.sendText) { next.insert(.sendText) } }
                        else { next.subtract(Self.media) }
                        allowed = next
                    })) {
                    Button {
                        withAnimation(.smooth(duration: 0.22)) { mediaOpen.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Send Media").foregroundStyle(lets ? .primary : .secondary)
                            Text("\(onCount)/\(Self.media.count)").monospacedDigit()
                                .font(.subheadline).foregroundStyle(.secondary)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(mediaOpen ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .disabled(!lets)
        } else {
            let lets = groupLets(r)
            Toggle(isOn: Binding(get: { lets && allowed.contains(r) }, set: { setAllowed(r, $0) })) {
                Text(label(r)).foregroundStyle(lets ? .primary : .secondary)
            }
            .disabled(!lets)
        }
    }
}

// MARK: - Spam report

extension ChatService {
    /// owner 2026-10-18 (admin delete sheet): Report Spam. The same `reports` write as the long-press
    /// Report (`report`), with reason "spam" and the ids of the sender's messages in this delete, so a
    /// moderator can tell which ones it was about even after they are gone.
    static func reportSpam(reportedUid: String, cid: String, messageIds: [String]) async {
        var data: [String: Any] = [
            "reporterUid": uid,
            "reportedUid": reportedUid,
            "cid": cid,
            "reason": "spam",
            "createdAt": Date().timeIntervalSince1970 * 1000,
            "handled": false,
        ]
        if !messageIds.isEmpty { data["messageIds"] = Array(messageIds.prefix(100)) }
        if let first = messageIds.first { data["messageId"] = first }
        if (try? await db.collection("reports").addDocument(data: data)) != nil {
            await MessageRequests.countDaily("reports")
        }
    }
}
