import SwiftUI
import UIKit
import LiveKit
import FirebaseFunctions
import FirebaseFirestore

/// The call screen's two-people button: who is in the call right now, who was invited and has not
/// come in, and (multi-person calls only) "Add people". The "In call" list reads the call stage, so
/// it shows the same speaking / muted / camera / network state as the tiles (owner spec §8, §16), and
/// a tap on someone shows them large: in a big call this is how you find and focus a person (§7, §13).
/// Owner, 2026-10-06: also who has a hand up, and (link creator) how many are waiting to be let in.
struct GroupCallParticipantsSheet: View {
    @ObservedObject private var service = GroupCallService.shared
    @StateObject private var stage: GroupCallStage
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    /// Link calls: the link's approval setting, read when the sheet opens (creator only).
    @State private var approval: Bool?
    @State private var approvalFailed = false
    /// Audit M-095, 2026-10-07: the value the server last confirmed, and whether a save is running.
    @State private var approvalSaved: Bool?
    @State private var approvalSaving = false
    /// Audit M-161, 2026-10-07: the setting could not be read (shown as such, with a retry).
    @State private var approvalLoadFailed = false
    // Group call permissions, 2026-10-06: the owner's and admins' controls.
    @State private var removeTarget: CallTile?
    /// Link calls, the link's owner: "Remove and Block" on this person, waiting for the confirmation.
    @State private var blockTarget: CallTile?
    /// The link creator's "N waiting to join" row opened the list of people asking.
    @State private var showRequests = false
    @State private var confirmEnd = false
    @State private var confirmRevoke = false
    @State private var makingLink = false
    @State private var copied = false
    @State private var actionError: String?
    /// A "Mute all" request is on its way (4-B1): the button waits for it.
    @State private var mutingAll = false
    /// Link calls (owner 2026-10-23): everyone Add people rang, live from the server's invite list.
    @StateObject private var linkInvites = LinkCallInvites()
    /// The bell's own wait, per person: one nudge a minute (the server holds the same line).
    @State private var nudgedAt: [String: Date] = [:]
    /// Group chat calls: when I last rang each person again from here (the button's one-minute wait).
    @State private var rangAgainAt: [String: Date] = [:]
    /// Group chat calls: the call doc's `joined` (everyone who has been in it), live while open.
    @State private var callJoined: Set<String> = []
    /// Bumped on `FirestoreHub.swapped`: restarts the `groupCalls/{cid}` listener on the fresh client.
    @State private var swapTick = 0
    /// People I removed from this call in this session (group chat calls keep no `removedUids`), so
    /// they are not listed as "Left" with a bell.
    @State private var removedHere: Set<String> = []
    /// The mic button's answer while the server catches up: uid -> asked to be muted (owner 2026-10-28).
    @State private var pendingBlocked: [String: Bool] = [:]
    /// A short line at the foot of the sheet ("Nudged X", a refusal).
    @State private var sheetToast: String?
    @State private var sheetToastTask: Task<Void, Never>?

    /// The call screen passes its own stage, so the list and the tiles agree on who is speaking.
    init(stage: GroupCallStage) {
        _stage = StateObject(wrappedValue: stage)
    }

    /// Fallback for call sites that have no stage yet: a stage of its own on the same room.
    init() {
        _stage = StateObject(wrappedValue: GroupCallStage(room: GroupCallService.shared.room))
    }

    /// The link this call runs on, when it is a link call (owner, 2026-10-06: the people button
    /// should offer Share link and Require approval, as the reference's call sheet does).
    /// After "Make a new link" this is the new one, so Share and Copy hand out the link that works.
    private var link: ActiveCallLink? { service.currentLink }

    /// The link to hand out from a running call, spelled for its type. The server's join answer
    /// said whether this link is voice-only (`cameraLocked`), which is the link's own setting;
    /// `service.isVideo` is only whether I came in with the camera on, so it cannot name the link.
    private var linkURL: URL? { link?.url(video: !service.cameraLocked) }

    /// The link's owner, as the server's join answer named me (or the link doc's `creatorUid`, which
    /// only the server writes, for a server that does not send a role yet). Hiding these is a
    /// convenience; the link functions check the creator themselves.
    private var ownsLink: Bool { link != nil && (service.myRole == .owner || service.isLinkCreator) }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let photoUrl: String?
        let subtitle: String?
        /// Group chat calls: the row's button. Ring (2026-10-23) for someone rung who has not come;
        /// Notify (owner 2026-10-28) for someone who was in the call and left: never rung again.
        var action: RowAction = .none
    }
    private enum RowAction { case none, ring, notify }

    /// Everyone connected right now: you first, then by name (the reference app's order; ties by id
    /// so two people with one name do not swap places on every update).
    private var inCall: [CallTile] {
        stage.tiles.sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    private var aloneInCall: Bool { !stage.tiles.contains { !$0.isLocal } }

    /// The call screen draws the 1:1 look (GroupCallView `front`): joined, at most one other
    /// person, nobody presenting.
    private var twoPersonLook: Bool {
        service.joinState == .joined
            && stage.tiles.filter { !$0.isLocal }.count <= 1
            && !stage.tiles.contains { $0.isScreenShare }
    }

    /// Invited and not here: still ringing for the first minute, then "Didn't join". Someone who
    /// came in and has since gone says so.
    /// Audit M-065 and M-158, 2026-10-07: "Ringing…" is the service's own answer per person
    /// (`ringingMembers`, each inside their own ring minute), not one room-wide clock that "Add
    /// people" restarted for everyone; and someone who declined or was busy says so instead of
    /// "Ringing…".
    private func invited(at now: Date) -> [Row] {
        let here = Set(stage.tiles.map(\.uid))
        if case .group(let cid)? = service.activeRoom { return groupInvited(cid: cid, here: here, at: now) }
        let ringing = Set(service.ringingMembers(at: now).map(\.uid))
        return service.members
            .filter { !here.contains($0.uid) && $0.uid != service.myUid }
            .map { m in
                Row(id: m.uid, name: m.name, photoUrl: m.photoUrl, subtitle: absentNote(m.uid, ringing: ringing))
            }
    }

    /// Controls audit 4-B2 (2026-10-23): a call started in a group chat has no member list of its
    /// own (`service.members` is for ad-hoc calls), so the sheet showed nobody under Invited while the
    /// header said "Ringing…". Now: the people the service is ringing (`ringingMembers`, the server's
    /// `rung` list once it lands), then whoever declined or was busy. Names and photos come from the
    /// group itself.
    /// Ring again (2026-10-23): every other member who is not here gets a row too, with a ring button
    /// (`groupCallRingAgain`): people whose ring went unanswered, and people the first ring skipped
    /// (muted the group, a group too big to ring). A decline stands: no button on "Declined". Busy
    /// is not a no, so it keeps the button. Someone rung from here reads "Ringing…" for the minute.
    ///
    /// ⛔ OWNER 2026-10-28: ONLY PEOPLE THIS CALL HAS TOUCHED. The rest of the group is no longer
    /// listed with a ring button each; they are rung from Add People (the sheet's first row). And
    /// someone who was in the call and LEFT is never rung again (the server refuses it too,
    /// `ringAgainSkipReason` 'joined'): their row says "Left" and its button sends one notification
    /// asking them back (`groupCallNudge`).
    private func groupInvited(cid: String, here: Set<String>, at now: Date) -> [Row] {
        let me = service.myUid
        let left = leftUids(here: here)
        // `stillRinging`, not `ringingMembers` (owner 2026-10-27): the people still being rung stay
        // listed after the first person came; `ringingMembers` empties at the first answer.
        let ringing = service.stillRinging(at: now).filter { !here.contains($0.uid) && $0.uid != me && !left.contains($0.uid) }
        var rows = ringing.map { Row(id: $0.uid, name: $0.name, photoUrl: $0.photoUrl, subtitle: "Ringing…") }
        var listed = Set(ringing.map(\.uid))
        for uid in left.sorted(by: { groupName(cid, $0) < groupName(cid, $1) }) {
            rows.append(Row(id: uid, name: groupName(cid, uid), photoUrl: groupPhoto(cid, uid),
                            subtitle: "Left", action: .notify))
            listed.insert(uid)
        }
        let answered = service.declinedUids.union(service.busyUids).subtracting(here).subtracting(listed)
        for uid in answered.sorted() where uid != me {
            let declined = service.declinedUids.contains(uid)
            let rangNow = !declined && ringingAgain(uid, at: now)
            rows.append(Row(id: uid, name: groupName(cid, uid), photoUrl: groupPhoto(cid, uid),
                            subtitle: declined ? "Declined" : rangNow ? "Ringing…" : "Busy",
                            action: declined ? .none : .ring))
            listed.insert(uid)
        }
        // Rung from Add People (or rung once and not answered): still on the list, with Ring.
        for uid in rangAgainAt.keys.sorted() where uid != me && !here.contains(uid) && !listed.contains(uid) {
            rows.append(Row(id: uid, name: groupName(cid, uid), photoUrl: groupPhoto(cid, uid),
                            subtitle: ringingAgain(uid, at: now) ? "Ringing…" : "Didn't join", action: .ring))
        }
        return rows
    }

    private func groupConv(_ cid: String) -> Conversation? {
        ConversationsRepository.shared.conversations.first { $0.id == cid }
    }
    private func groupName(_ cid: String, _ uid: String) -> String {
        ContactNames.shared.name(for: uid) ?? groupConv(cid)?.names[uid].flatMap { $0.isEmpty ? nil : $0 } ?? "Member"
    }
    private func groupPhoto(_ cid: String, _ uid: String) -> String? {
        groupConv(cid)?.photos[uid].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Was in this call and is not now: the call doc's `joined` (the server's word, read while the
    /// sheet is open) and everyone this phone saw in the room.
    private func leftUids(here: Set<String>) -> Set<String> {
        // Owner 2026-10-28: someone I removed is not "Left" (no bell asking them back). `removedUids`
        // is the ad-hoc call's server list; `removedHere` covers a group chat's call.
        callJoined.union(service.everHereUids).subtracting(here).subtracting([service.myUid, ""])
            .subtracting(service.removedUids).subtracting(removedHere)
    }

    /// Add People on a group chat's call: the group's members, with everyone already in, rung,
    /// left or who declined shown but not pickable.
    private func groupAddCandidates(_ cid: String) -> [CallMember] {
        (groupConv(cid)?.users ?? []).map { CallMember(uid: $0, name: groupName(cid, $0), photoUrl: groupPhoto(cid, $0)) }
    }
    private func groupAddNotes(here: Set<String>) -> [String: String] {
        let now = Date()
        var notes: [String: String] = [:]
        for uid in here { notes[uid] = "In this call" }
        for uid in leftUids(here: here) { notes[uid] = "Left · notify them from the list" }
        for uid in service.declinedUids where notes[uid] == nil { notes[uid] = "Declined" }
        for m in service.stillRinging(at: now) where notes[m.uid] == nil { notes[m.uid] = "Ringing…" }
        for uid in rangAgainAt.keys where notes[uid] == nil && ringingAgain(uid, at: now) { notes[uid] = "Ringing…" }
        return notes
    }
    /// The server's own wait (groupCallRingAgain): one ring again per person per minute.
    private static let ringAgainWait: TimeInterval = 60

    private func ringingAgain(_ uid: String, at now: Date) -> Bool {
        rangAgainAt[uid].map { now.timeIntervalSince($0) < Self.ringAgainWait } ?? false
    }

    /// Why an invited person is not in the call right now.
    private func absentNote(_ uid: String, ringing: Set<String>) -> String {
        if service.joinedUids.contains(uid) { return "Left" }
        if service.declinedUids.contains(uid) { return "Declined" }
        if service.busyUids.contains(uid) { return "Busy" }
        return ringing.contains(uid) ? "Ringing…" : "Didn't join"
    }

    /// Audit M-102 and M-103, 2026-10-07: Add people's line for each person it will not let me
    /// pick. "In this call" only for someone who has a tile now; the rest say why they are not
    /// here. They stay unpickable: ringing someone again needs the server's "ring again" (round 2).
    private func addNotes(removed: Set<String>) -> [String: String] {
        let here = Set(stage.tiles.map(\.uid))
        let ringing = Set(service.ringingMembers(at: Date()).map(\.uid))
        var notes: [String: String] = [:]
        for m in service.members where !here.contains(m.uid) {
            notes[m.uid] = absentNote(m.uid, ringing: ringing)
        }
        for uid in removed { notes[uid] = "Removed from this call" }
        return notes
    }

    // The list's sections, one property each: as one expression the body was too big for the
    // compiler to type-check in time (830 compile, 2026-10-06).

    /// Owner, 2026-10-06: who has a hand up, first in the list while anyone has (the reference's
    /// call sheet has this section too). Nothing at all with no hands up.
    private var raisedHandsSection: some View {
        GroupCallRaisedHandsSection(tiles: stage.tiles, myUid: service.myUid)
    }

    private var waitingTitle: String { "\(service.pendingRequests.count) waiting to join" }

    /// Link creator, approval on: how many are knocking. Opens the list with Approve All / Deny All
    /// (the cards over the call controls are behind this sheet while it is up).
    @ViewBuilder private var waitingSection: some View {
        if service.isLinkCreator && !service.pendingRequests.isEmpty {
            Section {
                Button { showRequests = true } label: {
                    HStack(spacing: 8) {
                        Label(waitingTitle, systemImage: "person.badge.clock")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Shows everyone waiting to be let in")
            }
        }
    }

    /// ⛔ THE LINK, SHOWN, AND THREE WAYS TO HAND IT ON (owner, 2026-10-07: "show me the link",
    /// "easy, simple, minimalist"). The link itself in blue on two lines, the Call Link sheet's own
    /// treatment, and Add / Copy / Share as one row of the Call Link sheet's round actions instead of
    /// three list rows. An ad-hoc call has no link: Add people alone.
    @ViewBuilder private var shareSection: some View {
        if service.isAdhoc || link != nil {
            Section {
                // ⛔ THE APP'S OWN LINK LOOK (owner 2026-10-20: "follow my app, minimalist"): the link
                // in one pill that copies on a tap, then the glass circles the Invite Links page uses.
                // Owner 2026-10-23: no link pill here any more, the three circles only.
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        // Owner, 2026-10-06: Add people on a link call too. It opens my chats and
                        // sends each person the link (a link call has no member list to add to).
                        if service.isAdhoc || (!service.linkRevoked && linkURL != nil) {
                            roundAction("person.badge.plus", "Add") { showAdd = true }
                        }
                        // Everyone may copy or share the link (the access table).
                        if !service.linkRevoked, let url = linkURL {
                            roundAction(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy") { copy(url) }
                            ShareLink(item: url) { roundLabel("ic_link_share", "Share") }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
    }

    /// ⛔ ADD PEOPLE, THE FIRST ROW (owner 2026-10-28, as the reference app has it): a group chat's call rings
    /// more of the group from here, picked from the group's members.
    @ViewBuilder private var groupAddSection: some View {
        if case .group? = service.activeRoom, service.isActive {
            Section {
                Button { showAdd = true } label: {
                    HStack(spacing: 12) {
                        // A plain icon as in Settings rows, no filled circle (owner 2026-10-28). The
                        // 36 pt frame keeps "Add People" lined up with the names below.
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                        Text("Add People").foregroundStyle(.primary)   // owner 2026-10-28: not blue, a plain row
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func roundAction(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(icon, title) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
    }

    private func roundLabel(_ icon: String, _ title: String) -> some View {
        PosterActionIcon(icon: icon, diameter: 54, onPhoto: false, label: title)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    /// ⛔ ONE BUTTON: REVOKE = A NEW LINK AT ONCE (owner, 2026-10-07: "when I click revoke, revoke
    /// the old one and create a new one; remove the make-a-new-link button"). The server's
    /// regenerate stops the old link and carries this call's room to the new one (`liveRoom`), so
    /// joiners of the new link land here; the link above shows the new one as soon as it exists.
    @ViewBuilder private var hostSection: some View {
        if ownsLink, let link {
            // Owner 2026-10-23: Revoke Link is no longer on this sheet (the link's own page keeps it).
            // People rung with Add people come straight in; the switch is for everyone else.
            Section {
                approvalRow(link)
            }
        }
    }

    /// Audit M-161, 2026-10-07: the switch only once the setting is known. While unknown it showed
    /// ON and greyed out, so an owner could believe approval protected a call it did not. Now:
    /// a spinner while it loads, "Couldn't load" with a retry when the read failed.
    @ViewBuilder private func approvalRow(_ link: ActiveCallLink) -> some View {
        if let value = approval {
            Toggle("Approve New People",
                   isOn: Binding(get: { approval ?? value }, set: { setApproval($0, link) }))
                .disabled(service.linkRevoked)
                .tint(.green)   // green always (owner, 2026-10-06: white-on-white in dark mode)
        } else {
            HStack {
                Text("Approve New People")
                Spacer(minLength: 8)
                if approvalLoadFailed {
                    Button("Couldn't load. Retry") { Task { await loadApproval(link) } }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                } else {
                    ProgressView()
                }
            }
        }
    }

    /// Reads the link's approval setting (each time the sheet opens, and on Retry).
    private func loadApproval(_ link: ActiveCallLink) async {
        approvalLoadFailed = false
        if let value = await CallLinkService.shared.approval(for: link) {
            guard !approvalSaving else { return }   // a save in flight knows better
            approval = value
            approvalSaved = value
        } else if approval == nil {
            approvalLoadFailed = true
        }
    }

    /// The people I may mute who are not muted yet.
    private var mutable: [CallTile] { inCall.filter { canModerate($0) && !$0.isMuted } }

    @ViewBuilder private var inCallSection: some View {
        Section {
            ForEach(inCall) { inCallRow($0) }
        } header: {
            // The reference app's header: bold title, count in regular weight (spec §16:
            // how many are in the call). Mute all beside it for whoever may mute (owner, 2026-10-07:
            // "an easy way to mute users").
            HStack(spacing: 0) {
                Text("In call").fontWeight(.semibold)
                Text(" · \(stage.inCallCount)")
                Spacer()
                if mutable.count > 1 {
                    Button("Mute all") { muteAll() }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                        .disabled(mutingAll)
                }
            }
            .textCase(nil)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private func invitedSection(at date: Date) -> some View {
        let waiting = invited(at: date)
        if !waiting.isEmpty {
            // Our own heading, the link call's too (owner 2026-10-27: not the reference's words).
            Section("Not here yet") {
                ForEach(waiting) { invitedRow($0, at: date) }
            }
        }
    }

    /// ⛔ NOT CONNECTED (owner 2026-10-23, the reference's call sheet): on a link call, everyone Add
    /// people rang who is not in the call now, with how it went and a bell. Someone who declined or
    /// missed the ring is not rung again; the bell sends them a nudge instead.
    @ViewBuilder private func notConnectedSection(at date: Date) -> some View {
        let rows = notConnected
        if service.isLink, !rows.isEmpty {
            Section {
                ForEach(rows) { notConnectedRow($0, at: date) }
            } header: {
                HStack(spacing: 0) {
                    Text("Not here yet").fontWeight(.semibold)
                    Text(" · \(rows.count)")
                }
                .textCase(nil)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var notConnected: [LinkCallInvites.Invite] {
        let here = Set(stage.tiles.map(\.uid))
        let me = service.myUid
        return linkInvites.invites.filter { !here.contains($0.uid) && $0.uid != me }
    }

    private func notConnectedRow(_ i: LinkCallInvites.Invite, at date: Date) -> some View {
        let who: CallMember? = linkInvites.people[i.uid]
        let name: String = who.map { ContactNames.shared.name(for: $0.uid) ?? $0.name } ?? "User"
        let status: String = LinkCallInvites.status(i, at: date)
        // No bell for someone who was in and left: they have the link and may come back.
        let canNudge = i.state != "joined"
        let waiting: Bool = nudgedAt[i.uid].map { date.timeIntervalSince($0) < 60 } ?? false
        return HStack(spacing: 12) {
            CallRingingAvatar(name: name, photoUrl: who?.photoUrl, ringing: status.hasPrefix("Ringing"))
            Text(name).lineLimit(1)
            Spacer(minLength: 8)
            Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if canNudge {
                Button { nudge(i.uid, name: name) } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.borderless)
                .disabled(waiting)
                .opacity(waiting ? 0.4 : 1)
                .accessibilityLabel("Nudge \(name)")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var endBar: some View {
        // The owner only: closes the call on the media server for everyone in it.
        if service.myRole == .owner && service.isActive {
            Button(role: .destructive) { confirmEnd = true } label: {
                Text("End Call for Everyone")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    // Owner 2026-10-23: "not like the Apple card, different corners". The list's own
                    // inset card: the same corner (iOS 26 grouped rows, continuous) and the same side
                    // inset as the cards above it (16pt on a narrow phone, 20pt from 400pt wide).
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, UIScreen.main.bounds.width >= 400 ? 20 : 16)
            .padding(.top, 10).padding(.bottom, 8)
            // The rows scroll under the bar: a short fade into the sheet colour instead of a hard
            // edge, so a card passing under it reads as scrolling, not cut off.
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Color(.systemGroupedBackground)
                }
                .padding(.top, -16)
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private var removeTitle: String { removeTarget.map { "Remove \($0.name) from the call?" } ?? "" }
    /// Decision 2026-10-06: on a link call Remove only puts them out, and they may knock again
    /// (Block is the one that keeps them out). Group and multi-person calls keep their text.
    private var removeMessage: String {
        service.isLink ? "They can ask to join again." : "They won't be able to rejoin it."
    }
    private var removeShown: Binding<Bool> {
        Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })
    }
    private var blockTitle: String { blockTarget.map { "Block \($0.name)?" } ?? "" }
    private var blockShown: Binding<Bool> {
        Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } })
    }
    private var errorShown: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private var sheetTitle: String { aloneInCall ? "Waiting for others" : "Participants" }
    private var errorTitle: String { actionError ?? "" }

    // The body in three steps (the list, the link's alerts, the people alerts), for the same
    // reason the sections are separate: one long chain is slow to type-check.
    private var list: some View {
        // Ticks so "Ringing…" turns into "Didn't join" without anyone touching the sheet.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            List {
                groupAddSection
                raisedHandsSection
                waitingSection
                shareSection
                hostSection
                inCallSection
                invitedSection(at: context.date)
                notConnectedSection(at: context.date)
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
        }
        // Owner 2026-10-23: End Call for Everyone always in reach, pinned under the list (in a
        // 100-person call it sat below everyone).
        .safeAreaInset(edge: .bottom, spacing: 0) { endBar }
        // Alone in the call, the sheet says what is happening, as the reference's does.
        .navigationTitle(sheetTitle)
        // Controls audit 4-B3 (2026-10-23): keyed on ownsLink. Opened while still connecting, the
        // creator's role was not known yet, the load never ran, and the switch spun for ever.
        .task(id: ownsLink) {
            guard ownsLink, let link, approval == nil else { return }
            await loadApproval(link)
            if await CallLinkService.shared.isRevoked(link) == true { service.noteLinkRevoked() }
        }
    }

    private var listWithLinkAlerts: some View {
        list
            .alert("Couldn't change setting", isPresented: $approvalFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("Check your connection and try again.") }
            .alert("Revoke this link?", isPresented: $confirmRevoke) {
                Button("Revoke", role: .destructive) { makeNewLink() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The current link stops working and a new one is made for this call. The call continues.") }
            .alert(errorTitle, isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            }
    }

    private var listWithAlerts: some View {
        listWithLinkAlerts
            .alert(removeTitle, isPresented: removeShown,
                   presenting: removeTarget) { t in
                Button("Remove", role: .destructive) { run(.remove, target: t.uid) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(removeMessage)
            }
            .alert(blockTitle, isPresented: blockShown,
                   presenting: blockTarget) { t in
                Button("Block", role: .destructive) { block(t) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("They won't be able to join this call again.")
            }
            .alert("End the call for everyone?", isPresented: $confirmEnd) {
                Button("End Call", role: .destructive) { run(.end) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Everyone in the call will be disconnected.") }
    }

    var body: some View {
        NavigationStack {
            listWithAlerts
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
        }
        // Owner 2026-10-23: the whole sheet dark, always, in the system's own greys.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .presentationBackground(Color(.systemGroupedBackground))
        // Owner 2026-10-28: opens full height, always (it opened at half, reversing 2026-10-06).
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Names and photos come from the service's member list; a stage built by the fallback init
        // has not had them yet, and an invite adds members while the sheet is open.
        .onAppear { stage.refreshProfiles(service.members) }
        .onChange(of: service.members) { _, members in stage.refreshProfiles(members) }
        // Closes itself when the last person waiting has been answered.
        .sheet(isPresented: $showRequests) { CallLinkBulkRequestsSheet() }
        // Link calls: the invite list follows the link the call is on now.
        .task(id: service.isLink ? link?.roomId : nil) {
            if service.isLink, let link { linkInvites.listen(roomId: link.roomId) } else { linkInvites.stop() }
            // Invites from an earlier call on the same link count for nothing (server contract):
            // the media room's session id tells this call's from those.
            if service.isLink, let sid = try? await service.room.sid() { linkInvites.currentSid = sid.stringValue }
        }
        .onDisappear { linkInvites.stop() }
        // Group chat calls: who has been in the call (the server's `joined`), for the "Left" rows.
        // Owner 2026-10-28: attached through `FirestoreHub.db`, and again on its swap signal (a new
        // `swapTick` restarts this task), so a swapped client never leaves the list stale.
        .task(id: "\(groupCid ?? "")#\(swapTick)") {
            guard let cid = groupCid else { return }
            let ref = FirestoreHub.db.collection("groupCalls").document(cid)
            let stream = AsyncStream<Set<String>> { cont in
                let reg = ref.addSnapshotListener { snap, _ in
                    cont.yield(Set(snap?.data()?["joined"] as? [String] ?? []))
                }
                cont.onTermination = { _ in FirestoreHub.drop([reg]) }
            }
            for await joined in stream { callJoined = joined }
        }
        .onReceive(NotificationCenter.default.publisher(for: FirestoreHub.swapped)) { _ in
            swapTick += 1
            linkInvites.reattachAfterSwap()
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeInOut(duration: 0.2), value: sheetToast)
        .sheet(isPresented: $showAdd) {
            if let cid = groupCid {
                let here = Set(stage.tiles.map(\.uid))
                let notes = groupAddNotes(here: here)
                AddPeopleSheet(alreadyIn: Set(notes.keys), notes: notes, actionTitle: "Ring",
                               candidates: groupAddCandidates(cid)) { people in
                    ringPeople(people.map { ($0.uid, ContactNames.shared.name(for: $0.uid) ?? $0.name) })
                }
            } else if service.isAdhoc {
                // `removedUids`: server-written, read by the service (audit M-102, fix/F4).
                let removed = service.removedUids
                AddPeopleSheet(alreadyIn: Set(service.members.map(\.uid)),
                               notes: addNotes(removed: removed),
                               unavailable: removed) { people in
                    Task { await service.invite(people) }
                }
            } else if let link, let url = linkURL {
                // Owner 2026-10-23: Add people RINGS each person (full-screen invitation), it does
                // not send the link. Everyone rung already, however it went, cannot be picked again.
                let here = Set(stage.tiles.map(\.uid))
                AddPeopleSheet(alreadyIn: here.union(linkInvites.invites.map(\.uid)),
                               notes: linkAddNotes(here: here),
                               actionTitle: "Add to call", linkCap: LinkCallInvites.cap) { people in
                    invite(people, link: link, url: url)
                }
            }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let sheetToast {
            Text(sheetToast)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                // Clear of the pinned End Call bar, which only the owner of a live call has.
                .padding(.bottom, service.myRole == .owner && service.isActive ? 84 : 24)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Add people's second line for someone already rung and not here.
    private func linkAddNotes(here: Set<String>) -> [String: String] {
        let now = Date()
        var notes: [String: String] = [:]
        for i in linkInvites.invites where !here.contains(i.uid) {
            notes[i.uid] = "Invited · " + LinkCallInvites.status(i, at: now)
        }
        return notes
    }

    /// Rings the people picked (`linkCallInvite`). A server without it yet (not found /
    /// unimplemented) gets the old way: the link in each person's 1:1 chat.
    private func invite(_ people: [CallMember], link: ActiveCallLink, url: URL) {
        let me = AuthService.shared.uid ?? ""
        let picked = people.filter { !$0.uid.isEmpty && $0.uid != me }
        guard !picked.isEmpty else { return }
        linkInvites.remember(picked)
        let payload: [String: Any] = ["roomId": link.roomId, "key": link.key, "uids": picked.map(\.uid)]
        Task {
            do {
                let result = try await Functions.functions(region: "me-central1")
                    .httpsCallable("linkCallInvite").call(payload)
                let data = result.data as? [String: Any] ?? [:]
                let rung = data["rung"] as? [String] ?? []
                let skipped = data["skipped"] as? [[String: Any]] ?? []
                let reasons = skipped.compactMap { $0["reason"] as? String }
                // The server's reasons (contract): full, unavailable, unreachable (rung, no phone
                // took it: the bell can nudge them), the rest = already here or already rung.
                if reasons.contains("full") {
                    showSheetToast("The call is full")
                } else if reasons.contains("unavailable") {
                    showSheetToast(picked.count == 1 ? "They can't be added" : "Some people can't be added")
                } else if reasons.contains("unreachable") {
                    showSheetToast("Couldn't reach their phone. Use the bell to nudge them.")
                } else if rung.isEmpty, !skipped.isEmpty {
                    showSheetToast(picked.count == 1 ? "Already invited" : "They were already invited")
                }
            } catch {
                let ns = error as NSError
                if ns.domain == FunctionsErrorDomain,
                   ns.code == FunctionsErrorCode.notFound.rawValue
                    || ns.code == FunctionsErrorCode.unimplemented.rawValue {
                    sendLink(url, to: picked)
                } else if ns.domain == FunctionsErrorDomain, ns.code == FunctionsErrorCode.permissionDenied.rawValue {
                    showSheetToast("Couldn't add people. Try again.")
                } else {
                    actionError = Self.errorText(error)
                }
            }
        }
    }

    /// The bell: "👋 <me> wants to talk" on their phone (`linkCallNudge`). Once a minute per person.
    private func nudge(_ uid: String, name: String) {
        guard let link else { return }
        nudgedAt[uid] = Date()
        let payload: [String: Any] = ["roomId": link.roomId, "key": link.key, "uid": uid]
        Task {
            do {
                _ = try await Functions.functions(region: "me-central1")
                    .httpsCallable("linkCallNudge").call(payload)
                showSheetToast("Nudged \(name)")
            } catch {
                let ns = error as NSError
                let code: FunctionsErrorCode? = ns.domain == FunctionsErrorDomain ? FunctionsErrorCode(rawValue: ns.code) : nil
                switch code {
                case .resourceExhausted?: showSheetToast("Wait a minute before nudging again")
                case .failedPrecondition?, .permissionDenied?: showSheetToast("Can't nudge them now")
                default:
                    nudgedAt[uid] = nil
                    showSheetToast("Couldn't nudge. Try again.")
                }
            }
        }
    }

    private func showSheetToast(_ text: String) {
        sheetToast = text
        UIAccessibility.post(notification: .announcement, argument: text)
        sheetToastTask?.cancel()
        sheetToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            sheetToast = nil
        }
    }

    /// Each person gets the link in our 1:1 chat (the id is derived; the chat need not exist yet).
    private func sendLink(_ url: URL, to people: [CallMember]) {
        let me = AuthService.shared.uid ?? ""
        Task {
            var failed = false
            for p in people where !p.uid.isEmpty && p.uid != me {
                let cid = [me, p.uid].sorted().joined(separator: "_")
                do { try await ChatService.sendText(cid: cid, text: url.absoluteString) }
                catch { failed = true }
            }
            if failed { actionError = "Couldn't send the link to everyone. Check your connection and try again." }
        }
    }

    /// Saved at once; a refusal puts the switch back and says so (same as the link's own page).
    /// Audit M-095, 2026-10-07: one save at a time. Each flip used to fire its own unordered call,
    /// so two quick flips could land in the wrong order and leave the server opposite to the
    /// switch. Now a flip during a save waits; when the save ends, the switch's value then is sent
    /// if it differs. A refusal goes back to what the server last confirmed, never a stale guess.
    private func setApproval(_ on: Bool, _ link: ActiveCallLink) {
        approval = on
        guard !approvalSaving else { return }
        approvalSaving = true
        Task { @MainActor in
            while let want = approval, want != approvalSaved {
                do {
                    try await CallLinkService.shared.setApproval(link, on: want)
                    approvalSaved = want
                } catch {
                    approval = approvalSaved
                    approvalFailed = true
                    break
                }
            }
            approvalSaving = false
        }
    }

    // MARK: - Owner and admin actions (group call permissions, 2026-10-06)

    /// Their role as the server signed it into their join pass, never a flag of ours.
    private func role(of t: CallTile) -> CallRole {
        _ = service.rolesVersion   // redraw when anyone's attributes change
        // Audit M-072, 2026-10-07 (with fix/F4): a group call reads roles from the group as it is
        // now; the attribute was frozen at join, so a new owner or a demoted admin was shown wrong.
        if let live = service.groupRole(of: t.uid) { return live }
        let attr = stage.participant(t.id)?.attributes["role"]
        // No attribute (a server without roles yet): the tile's host mark, itself server-sourced.
        if attr == nil, t.isHost { return .owner }
        return CallRole(attribute: attr)
    }

    /// The access table: never myself (any of my devices), and only the roles my role reaches.
    private func canModerate(_ t: CallTile) -> Bool {
        !t.isLocal && !t.uid.isEmpty && t.uid != service.myUid && service.myRole.canModerate(role(of: t))
    }

    /// Controls audit 4-B1 (2026-10-23): one `muteAll` request instead of one mute per person at
    /// the same moment (past 30 people the rate limit refused the rest, each refusal overwriting the
    /// last alert). A server from before `muteAll` says "Bad action"; then one at a time, stopping
    /// at the first "too many".
    private func muteAll() {
        guard !mutingAll else { return }
        let fallback = mutable.map(\.uid)
        mutingAll = true
        Task { @MainActor in
            defer { mutingAll = false }
            do {
                try await service.muteAllOthers()
            } catch let e as NSError where e.domain == FunctionsErrorDomain
                        && e.code == FunctionsErrorCode.invalidArgument.rawValue {
                var lastError: Error?
                for uid in fallback {
                    do { try await service.admin(.mute, target: uid) } catch {
                        lastError = error
                        let n = error as NSError
                        if n.domain == FunctionsErrorDomain && n.code == FunctionsErrorCode.resourceExhausted.rawValue { break }
                    }
                }
                if let lastError { actionError = Self.errorText(lastError) }
            } catch {
                actionError = Self.errorText(error)
            }
        }
    }

    private func run(_ action: CallAdminAction, target uid: String? = nil) {
        Task { @MainActor in
            do {
                try await service.admin(action, target: uid)
                if action == .remove, let uid { removedHere.insert(uid) }
            }
            catch { actionError = Self.errorText(error) }
        }
    }

    /// Link calls only, and only the link's owner (the server checks both again): Remove puts
    /// someone out and they may knock again; Block also keeps them from rejoining by this link.
    private var canBlock: Bool { service.isLink && ownsLink }

    private func block(_ t: CallTile) {
        Task { @MainActor in
            let done = await service.block(t.uid)
            if done { removedHere.insert(t.uid) }
            if !done { actionError = "Couldn't block \(t.name). Check your connection and try again." }
        }
    }

    private func revokeLink() {
        Task { @MainActor in
            do { try await service.revokeLink() }
            catch { actionError = Self.errorText(error) }
        }
    }

    private func makeNewLink() {
        guard !makingLink else { return }
        makingLink = true
        Task { @MainActor in
            do { try await service.makeNewLink() }
            catch { actionError = Self.errorText(error) }
            makingLink = false
        }
    }

    private func copy(_ url: URL) {
        UIPasteboard.general.url = url
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    /// One short line for the alert. The server's refusals come back as Functions error codes.
    private static func errorText(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code) else {
            return "Couldn't do that. Check your connection and try again."
        }
        switch code {
        case .permissionDenied: return "Only the host can do that"
        case .notFound: return "They're no longer in the call"
        case .resourceExhausted: return "Too many tries. Wait a moment and try again."
        case .unauthenticated: return "Sign in again, then try again."
        default: return "Couldn't do that. Try again."
        }
    }

    /// The trailing menu on a row the viewer may act on: Mute (while they are not muted), Remove,
    /// and for a link's owner "Remove and Block".
    private func actionsMenu(_ t: CallTile) -> some View {
        Menu {
            if !t.isMuted {
                Button { run(.mute, target: t.uid) } label: {
                    Label("Mute", systemImage: "mic.slash")
                }
            } else if adminMuted(t) {
                // 2026-10-28: an admin's mute holds until an admin allows them to speak (callAdmin
                // 'unmute'); the owner looked for it here first. Not for a self-muted person.
                Button { run(.unmute, target: t.uid) } label: {
                    Label("Allow to Speak", systemImage: "mic")
                }
            }
            Button(role: .destructive) { removeTarget = t } label: {
                Label("Remove from call", systemImage: "person.fill.xmark")
            }
            if canBlock {
                Button(role: .destructive) { blockTarget = t } label: {
                    Label("Remove and Block", systemImage: "nosign")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(t.name)")
    }

    // MARK: - In call rows

    private func isSpeaking(_ t: CallTile) -> Bool {
        // Audit M-135, 2026-10-07: the stage's settled speaker only. The raw flag was read here
        // too, but nothing redraws this list when only that flag changes (it is never published),
        // so the green ring stuck on or never showed.
        t.id == stage.activeSpeakerId
    }

    /// A remote row shows that person large and closes the sheet. Already focused stays focused:
    /// togglePin would unpin, and a tap here means "show me them", never "stop showing them".
    @ViewBuilder
    private func inCallRow(_ t: CallTile) -> some View {
        if t.isLocal {
            rowContent(t)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(t))
        } else if canModerate(t) {
            // Three controls in one row: borderless, so the row tap, the mic and the menu each keep
            // their own. The mic is the one-tap mute (owner, 2026-10-07); a muted person's mic is
            // shown struck through and does nothing, since only they can turn it back on.
            HStack(spacing: 6) {
                focusButton(t, micShown: false).buttonStyle(.borderless)
                muteButton(t).buttonStyle(.borderless)
                actionsMenu(t).buttonStyle(.borderless)
            }
        } else {
            focusButton(t)
        }
    }

    /// ⛔ ONE TAP EACH WAY (owner 2026-10-28: muting was easy, letting them speak again was hidden
    /// in the "..." menu). Their mic: tap to mute; red and struck through while muted, tap again to
    /// allow them to speak (callAdmin 'unmute').
    /// Owner 2026-10-28: red "allow to speak" only for someone an admin muted (the server sets their
    /// `micBlocked` attribute to "1"). Someone who muted THEMSELVES shows a plain muted mic that does
    /// nothing: only they can turn it back on.
    private func tapMic(_ t: CallTile, block: Bool) {
        let uid = t.uid
        pendingBlocked[uid] = block
        Haptics.impact(.light)
        Task { @MainActor in
            do {
                try await service.admin(block ? .mute : .unmute, target: uid)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if pendingBlocked[uid] == block { pendingBlocked[uid] = nil }
            } catch {
                pendingBlocked[uid] = nil
                actionError = Self.errorText(error)
            }
        }
    }

    private func adminMuted(_ t: CallTile) -> Bool {
        _ = service.rolesVersion   // redraw when anyone's attributes change
        return t.isMuted && stage.participant(t.id)?.attributes["micBlocked"] == "1"
    }

    /// ⛔ THE BUTTON ANSWERS THE TAP AT ONCE (owner 2026-10-28: "mute and unmute is not realtime").
    /// The real state (their track, the server's `micBlocked`) lands a moment later; until then the
    /// button shows what was asked. A refusal puts it back; after 4 s the real state rules again.
    private func muteButton(_ t: CallTile) -> some View {
        let asked = pendingBlocked[t.uid]
        let blocked = asked ?? adminMuted(t)
        let shownMuted = asked ?? t.isMuted
        let selfMuted = asked == nil && t.isMuted && !blocked
        return Button { tapMic(t, block: !blocked) } label: {
            Image(systemName: shownMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(blocked ? Color.white : (selfMuted ? Color.secondary : Color.primary))
                .frame(width: 36, height: 36)
                .background(blocked ? Color(.systemRed) : Color(.tertiarySystemFill), in: Circle())
                .contentShape(Circle())
        }
        .disabled(selfMuted)
        .accessibilityLabel(blocked ? "Allow \(t.name) to speak" : (selfMuted ? "\(t.name) is muted" : "Mute \(t.name)"))
    }

    private func focusButton(_ t: CallTile, micShown: Bool = true) -> some View {
        Button {
            // Audit M-162, 2026-10-07: no pin in the two-person look (the other person is already
            // the whole screen). It was set silently there and took over once a third joined.
            if !twoPersonLook, stage.pinnedId != t.id { stage.togglePin(t.id) }
            dismiss()
        } label: {
            rowContent(t, micShown: micShown).contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(t))
        .accessibilityHint("Shows them large on the call screen")
        .accessibilityAddTraits(.isButton)
    }

    /// `micShown` false: the row's own mute button says it, so no second mic (owner 2026-10-28:
    /// two struck-through mics on one row).
    private func rowContent(_ t: CallTile, micShown: Bool = true) -> some View {
        let speaking = isSpeaking(t)
        return HStack(spacing: 12) {
            // The reference app's 36pt avatar; the green ring is ours (spec §8: who is speaking must
            // be obvious in the list too), thin and faded, no glow.
            AvatarView(name: t.name, photoUrl: t.photoUrl, size: 36)
                .overlay {
                    Circle()
                        .strokeBorder(Color.green, lineWidth: 2)
                        .padding(-4)
                        .opacity(speaking ? 1 : 0)
                }
                .animation(GroupCallMotion.fade, value: speaking)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.isLocal ? "You" : t.name)
                    .fontWeight(speaking ? .semibold : .regular)
                    .lineLimit(1)
                // Host (owner) or Admin (moderator), as the server assigned it.
                if let badge = role(of: t).badge {
                    Text(badge).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // Minimal (owner 2026-10-28): only icons that say something. Camera only while it is
            // on, the mic only while muted, the network only while poor.
            HStack(spacing: 12) {
                if t.networkPoor { slot("wifi.exclamationmark", show: true, color: .orange) }
                if t.hasVideo { slot("video.fill", show: true, color: .secondary) }
                if micShown && t.isMuted { slot("mic.slash.fill", show: true, color: .secondary) }
            }
            .font(.system(size: 15))
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }

    private func slot(_ icon: String, show: Bool, color: Color) -> some View {
        Image(systemName: icon)
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .opacity(show ? 1 : 0)
    }

    /// One VoiceOver element per row: "<name>, host, speaking, muted, camera off".
    private func accessibilityText(_ t: CallTile) -> String {
        var parts = [t.isLocal ? "You" : t.name]
        if let badge = role(of: t).badge { parts.append(badge.lowercased()) }
        if isSpeaking(t) { parts.append("speaking") }
        if t.isMuted { parts.append("muted") }
        if !t.hasVideo { parts.append("camera off") }
        if t.networkPoor { parts.append("poor connection") }
        if stage.pinnedId == t.id { parts.append("shown large") }
        return parts.joined(separator: ", ")
    }

    private func invitedRow(_ r: Row, at date: Date) -> some View {
        let waiting: Bool = ringingAgain(r.id, at: date)
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                CallRingingAvatar(name: r.name, photoUrl: r.photoUrl, ringing: r.subtitle == "Ringing…")
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).lineLimit(1)
                    if let s = r.subtitle {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if r.action == .ring, r.subtitle != "Ringing…" {
                Button { ringAgain(r.id, name: r.name) } label: {
                    Image(systemName: "phone.arrow.up.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.borderless)
                .disabled(waiting)
                .opacity(waiting ? 0.4 : 1)
                .accessibilityLabel("Ring \(r.name)")
            } else if r.action == .notify {
                // Left the call: a bell, never the phone (owner 2026-10-28).
                let notified = nudgedAt[r.id].map { date.timeIntervalSince($0) < 60 } ?? false
                Button { notifyLeft(r.id, name: r.name) } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.borderless)
                .disabled(notified)
                .opacity(notified ? 0.4 : 1)
                .accessibilityLabel("Notify \(r.name)")
            }
        }
    }

    /// Ring again (2026-10-23): rings one member into this group chat's call (`groupCallRingAgain`,
    /// functions-groups). The server checks everything again; its answer is one line at the foot.
    private func ringAgain(_ uid: String, name: String) {
        guard case .group(let cid)? = service.activeRoom else { return }
        rangAgainAt[uid] = Date()
        let payload: [String: Any] = ["cid": cid, "uids": [uid]]
        Task { @MainActor in
            do {
                let result = try await Functions.functions(region: "me-central1")
                    .httpsCallable("groupCallRingAgain").call(payload)
                let data = result.data as? [String: Any] ?? [:]
                let rung = data["rung"] as? [String] ?? []
                if rung.contains(uid) {
                    service.noteRangAgain()
                    showSheetToast("Ringing \(name)")
                    return
                }
                let skipped = data["skipped"] as? [[String: Any]] ?? []
                let reason = skipped.first { ($0["uid"] as? String) == uid }?["reason"] as? String
                // Only a ring that went out (or one the server says is still up) holds the wait.
                if reason != "tooSoon" && reason != "unreachable" && reason != "ringing" { rangAgainAt[uid] = nil }
                showSheetToast(Self.ringAgainRefusal(reason, name: name))
            } catch {
                let ns = error as NSError
                let code: FunctionsErrorCode? = ns.domain == FunctionsErrorDomain ? FunctionsErrorCode(rawValue: ns.code) : nil
                if code != .resourceExhausted { rangAgainAt[uid] = nil }
                switch code {
                case .resourceExhausted?: showSheetToast("Too many rings. Wait a moment.")
                case .permissionDenied?: showSheetToast("Only people in the call can ring others")
                case .failedPrecondition?: showSheetToast("This call has ended")
                case .notFound?, .unimplemented?: showSheetToast("Ringing again isn't available yet")
                default: showSheetToast("Couldn't ring. Try again.")
                }
            }
        }
    }

    /// The group chat's id while this is a group chat's call.
    private var groupCid: String? {
        if case .group(let cid)? = service.activeRoom { return cid }
        return nil
    }

    /// Add People on a group chat's call: rings everyone picked (`groupCallRingAgain`, at most 16
    /// per request, so a bigger pick goes in turns). One foot line for the lot.
    private func ringPeople(_ people: [(uid: String, name: String)]) {
        guard let cid = groupCid, !people.isEmpty else { return }
        let now = Date()
        for p in people { rangAgainAt[p.uid] = now }
        Task { @MainActor in
            var rung = 0
            var lastRefusal: String?
            for start in stride(from: 0, to: people.count, by: 16) {
                let part = Array(people[start..<min(start + 16, people.count)])
                do {
                    let result = try await Functions.functions(region: "me-central1")
                        .httpsCallable("groupCallRingAgain").call(["cid": cid, "uids": part.map(\.uid)])
                    let data = result.data as? [String: Any] ?? [:]
                    rung += (data["rung"] as? [String] ?? []).count
                    for s in data["skipped"] as? [[String: Any]] ?? [] {
                        guard let uid = s["uid"] as? String, let p = part.first(where: { $0.uid == uid }) else { continue }
                        let reason = s["reason"] as? String
                        if reason != "tooSoon" && reason != "unreachable" && reason != "ringing" { rangAgainAt[uid] = nil }
                        lastRefusal = Self.ringAgainRefusal(reason, name: p.name)
                    }
                } catch {
                    for p in part { rangAgainAt[p.uid] = nil }
                    lastRefusal = "Couldn't ring. Try again."
                }
            }
            if rung > 0 {
                service.noteRangAgain()
                showSheetToast(people.count == 1 ? "Ringing \(people[0].name)" : "Ringing \(rung) people")
            } else if let lastRefusal {
                showSheetToast(lastRefusal)
            }
        }
    }

    /// Someone who left (owner 2026-10-28): one notification asking them back (`groupCallNudge`),
    /// never a ring. Once a minute per person, as the server holds it.
    private func notifyLeft(_ uid: String, name: String) {
        guard let cid = groupCid else { return }
        nudgedAt[uid] = Date()
        Task { @MainActor in
            do {
                _ = try await Functions.functions(region: "me-central1")
                    .httpsCallable("groupCallNudge").call(["cid": cid, "uid": uid])
                showSheetToast("Notified \(name)")
            } catch {
                let ns = error as NSError
                let code: FunctionsErrorCode? = ns.domain == FunctionsErrorDomain ? FunctionsErrorCode(rawValue: ns.code) : nil
                switch code {
                case .resourceExhausted?: showSheetToast("Wait a minute before notifying \(name) again")
                case .failedPrecondition?:
                    nudgedAt[uid] = nil
                    showSheetToast(ns.localizedDescription == "inCall" ? "\(name) is back in the call" : "Can't notify \(name) now")
                case .notFound?, .unimplemented?:
                    nudgedAt[uid] = nil
                    showSheetToast("Notify isn't available yet")
                default:
                    nudgedAt[uid] = nil
                    showSheetToast("Couldn't notify. Try again.")
                }
            }
        }
    }

    /// The foot line for a person the server did not ring (groupCallRingAgain's `skipped` reasons).
    private static func ringAgainRefusal(_ reason: String?, name: String) -> String {
        switch reason {
        case "declined": return "\(name) declined this call"
        case "inCall": return "\(name) is already in the call"
        case "joined": return "\(name) left this call. Notify them instead."
        case "ringing": return "\(name) is still ringing"
        case "tooSoon": return "Wait a minute before ringing \(name) again"
        case "unreachable": return "Couldn't reach \(name)'s phone"
        case "notMember": return "\(name) isn't in this group"
        // 2026-10-28 server limits: three rings per person per call; the ring list is full.
        case "limit": return "\(name) was rung 3 times. Try a notification later."
        case "full": return "Too many people rung in this call"
        default: return "Can't ring \(name) now"
        }
    }
}

/// The people sheet's "Raised hands" section: who has a hand up, the oldest first (the order they
/// should be heard in). A view of its own, so only this section is drawn again when the social
/// object changes; it publishes every emoji reaction too, and the whole list need not follow those.
private struct GroupCallRaisedHandsSection: View {
    @ObservedObject private var social = GroupCallSocial.shared
    /// The stage's tiles: a person's photo, and their name as the tiles show it.
    private let tiles: [CallTile]
    private let myUid: String

    init(tiles: [CallTile], myUid: String) {
        self.tiles = tiles
        self.myUid = myUid
    }

    private var hands: [GroupCallSocial.RaisedHand] { social.raisedHands }
    private var headerLabel: String { "Raised hands, \(hands.count)" }

    var body: some View {
        if !hands.isEmpty {
            Section {
                ForEach(hands) { row($0) }
            } header: {
                // The same shape as "In call": bold title, count in regular weight.
                HStack(spacing: 0) {
                    Text("Raised hands").fontWeight(.semibold)
                    Text(" · \(hands.count)")
                }
                .textCase(nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerLabel)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// Photo and name as the "In call" rows show them, the hand at the trailing edge. My own row
    /// can take the hand down again.
    private func row(_ hand: GroupCallSocial.RaisedHand) -> some View {
        let mine = !hand.uid.isEmpty && hand.uid == myUid
        let tile = tiles.first(where: { $0.uid == hand.uid })
        let shownName: String = tile?.name ?? hand.name
        let label: String = mine ? "You" : shownName
        let spoken: String = "\(label), hand raised"
        return HStack(spacing: 12) {
            AvatarView(name: shownName, photoUrl: tile?.photoUrl, size: 36)
            Text(label)
                .lineLimit(1)
                .accessibilityLabel(spoken)
            Spacer(minLength: 8)
            if mine {
                Button("Lower") { social.setHand(false) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Lower my hand")
            }
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }
}

/// The link a running call is on, as a `CallLinkRef` for the link service.
struct ActiveCallLink: CallLinkRef {
    let roomId: String
    let key: String
}

/// ⛔ CALL LINK INVITES (owner 2026-10-23): `callLinks/{roomId}/invites/{uid}`, written only by the
/// server (`linkCallInvite`, `groupRingAnswer`). The people sheet's "Not here yet" list and the
/// Add people picker's "already invited" both read it. Names and photos come from the profile
/// cache (the invite doc holds only the inviter's name), or from the picker for people I added.
@MainActor
final class LinkCallInvites: ObservableObject {
    /// People in a link call, the invited counted in (owner 2026-10-23: "N/30").
    static let cap = 30

    struct Invite: Identifiable, Equatable {
        let uid: String
        let at: Date?
        let sid: String?
        let state: String   // ringing | declined | missed | joined
        var id: String { uid }
    }

    /// Every invite doc under the link, this call's and older ones.
    @Published private var all: [Invite] = []
    /// The running call's media session. Known: invites of another session are left out.
    @Published var currentSid: String?
    var invites: [Invite] {
        guard let currentSid else { return all }
        return all.filter { $0.sid == nil || $0.sid == currentSid }
    }
    @Published private(set) var people: [String: CallMember] = [:]
    private var listener: ListenerRegistration?
    private var roomId: String?
    private var asked: Set<String> = []

    /// A ring still "ringing" a minute after it was sent reads as missed (the server may not have
    /// swept it yet).
    static func status(_ i: Invite, at now: Date) -> String {
        switch i.state {
        case "declined": return "Declined"
        case "missed": return "Missed"
        case "joined": return "Left"
        default:
            if let at = i.at, now.timeIntervalSince(at) > GroupCallService.ringWindow { return "Missed" }
            return "Ringing…"
        }
    }

    func listen(roomId: String) {
        guard roomId != self.roomId else { return }
        stop()
        self.roomId = roomId
        listener = FirestoreHub.db.collection("callLinks").document(roomId).collection("invites")
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }   // refused (rules not out yet): nothing to list
                let rows: [Invite] = snap.documents.compactMap { doc -> Invite? in
                    let d = doc.data()
                    let uid = d["uid"] as? String ?? doc.documentID
                    guard !uid.isEmpty else { return nil }
                    let sid = (d["sid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    return Invite(uid: uid, at: (d["at"] as? Timestamp)?.dateValue(), sid: sid,
                                  state: d["state"] as? String ?? "ringing")
                }
                .sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
                Task { @MainActor [weak self] in
                    guard let self, self.roomId == roomId else { return }
                    self.all = rows
                    self.loadProfiles(rows.map(\.uid))
                }
            }
    }

    /// Owner 2026-10-28: after `FirestoreHub.swapped`. The old registration belongs to the stuck
    /// client, so it is let go off the main thread and the same link is listened to again.
    func reattachAfterSwap() {
        guard let roomId, listener != nil else { return }
        FirestoreHub.drop([listener])
        listener = nil
        self.roomId = nil
        listen(roomId: roomId)
    }

    func stop() {
        listener?.remove(); listener = nil
        roomId = nil
        all = []
        currentSid = nil
    }

    /// The people just picked: their names are known at once.
    func remember(_ picked: [CallMember]) {
        for p in picked { people[p.uid] = p }
    }

    private func loadProfiles(_ uids: [String]) {
        let missing = uids.filter { people[$0] == nil && !asked.contains($0) }
        guard !missing.isEmpty else { return }
        asked.formUnion(missing)
        Task { @MainActor in
            for uid in missing {
                var found = await ProfileStore.shared.cachedPeer(uid)
                if found == nil { found = await ProfileStore.shared.fetch(uid) }
                guard let p = found else { continue }
                self.people[uid] = CallMember(uid: uid, name: p.name.isEmpty ? "User" : p.name, photoUrl: p.photoUrl)
            }
        }
    }
}

/// Controls audit 4-B1 (2026-10-23): the server's `callAdmin` "muteAll" (mutes everyone I may mute,
/// never me, in one request). `CallAdminAction` lives in GroupCallService.swift (another change's
/// file this round) and has no case for it yet, so the request is built here, naming the room the
/// same way `admin(_:target:)` does. Fold into `admin` once `CallAdminAction` gains `muteAll`.
private extension GroupCallService {
    func muteAllOthers() async throws {
        guard let r = activeRoom else {
            throw NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.notFound.rawValue)
        }
        let target: [String: String]
        switch r {
        case .group(let cid): target = ["kind": "group", "id": cid]
        case .adhoc(let id): target = ["kind": "adhoc", "id": id]
        case .link(let roomId, _): target = ["kind": "link", "id": currentLink?.roomId ?? roomId]
        }
        let payload: [String: Any] = ["room": target, "action": "muteAll"]
        _ = try await Functions.functions(region: "me-central1").httpsCallable("callAdmin").call(payload)
    }
}

/// A person's photo in the call's people list; while their phone rings, a soft ring pulses out
/// from it, the same pulse as the big ringing screen (GroupCallRingingView). Owner 2026-10-27: our
/// own sign, not the reference app's dots. On a timeline, not `.repeatForever` (audit H3: the iOS 26
/// deadlock pattern). Reduce Motion: a still ring.
struct CallRingingAvatar: View {
    let name: String
    let photoUrl: String?
    let ringing: Bool
    var size: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AvatarView(name: name, photoUrl: photoUrl, size: size)
            .background {
                if ringing {
                    if reduceMotion {
                        Circle().stroke(Color.green.opacity(0.6), lineWidth: 1.5)
                            .frame(width: size + 6, height: size + 6)
                    } else {
                        TimelineView(.animation) { ctx in
                            // One ring every 1.6 s, growing out of the photo and fading.
                            let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                            let e = 1 - (1 - p) * (1 - p)   // ease-out
                            Circle().stroke(Color.green.opacity(0.7 * (1 - e)), lineWidth: 1.5)
                                .frame(width: size, height: size)
                                .scaleEffect(1 + 0.45 * e)
                        }
                    }
                }
            }
            .frame(width: size, height: size)
    }
}
