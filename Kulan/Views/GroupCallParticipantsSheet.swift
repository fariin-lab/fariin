import SwiftUI
import UIKit
import LiveKit
import FirebaseFunctions

/// The call screen's two-people button: who is in the call right now, who was invited and has not
/// come in, and (multi-person calls only) "Add people". The "In call" list reads the call stage, so
/// it shows the same speaking / muted / camera / network state as the tiles (owner spec §8, §16), and
/// a tap on someone shows them large: in a big call this is how you find and focus a person (§7, §13).
struct GroupCallParticipantsSheet: View {
    @ObservedObject private var service = GroupCallService.shared
    @StateObject private var stage: GroupCallStage
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    /// Link calls: the link's approval setting, read when the sheet opens (creator only).
    @State private var approval: Bool?
    @State private var approvalFailed = false
    // Group call permissions, 2026-10-06: the owner's and admins' controls.
    @State private var removeTarget: CallTile?
    @State private var confirmEnd = false
    @State private var confirmRevoke = false
    @State private var makingLink = false
    @State private var copied = false
    @State private var actionError: String?

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

    /// The link's owner, as the server's join answer named me (or the link doc's `creatorUid`, which
    /// only the server writes, for a server that does not send a role yet). Hiding these is a
    /// convenience; the link functions check the creator themselves.
    private var ownsLink: Bool { link != nil && (service.myRole == .owner || service.isLinkCreator) }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let photoUrl: String?
        let subtitle: String?
    }

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

    /// Invited and not here: still ringing for the first minute, then "Didn't join". Someone who
    /// came in and has since gone says so.
    private func invited(at now: Date) -> [Row] {
        let here = Set(stage.tiles.map(\.uid))
        let ringing = service.roomStartedAt.map { now.timeIntervalSince($0) < 60 } ?? false
        return service.members
            .filter { !here.contains($0.uid) && $0.uid != service.myUid }
            .map { m in
                let sub = service.joinedUids.contains(m.uid) ? "Left"
                    : ringing ? "Ringing…" : "Didn't join"
                return Row(id: m.uid, name: m.name, photoUrl: m.photoUrl, subtitle: sub)
            }
    }

    var body: some View {
        NavigationStack {
            // Ticks so "Ringing…" turns into "Didn't join" without anyone touching the sheet.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                List {
                    if service.isAdhoc || link != nil {
                        Section {
                            if service.isAdhoc {
                                Button { showAdd = true } label: {
                                    Label("Add people", systemImage: "person.badge.plus")
                                }
                            }
                            // Everyone may copy or share the link (the access table); a revoked one
                            // is not handed out.
                            if !service.linkRevoked, let url = link?.linkKey?.url {
                                Button { copy(url) } label: {
                                    Label(copied ? "Copied" : "Copy link", systemImage: "doc.on.doc")
                                }
                                .accessibilityLabel(copied ? "Link copied" : "Copy link")
                                ShareLink(item: url) {
                                    Label("Share link", systemImage: "link")
                                }
                            }
                        }
                    }
                    if ownsLink, let link {
                        Section {
                            if !service.linkRevoked {
                                Toggle("Require approval to join",
                                       isOn: Binding(get: { approval ?? true }, set: { setApproval($0, link) }))
                                    .disabled(approval == nil)
                                Button(role: .destructive) { confirmRevoke = true } label: {
                                    Label("Revoke link", systemImage: "xmark.circle")
                                }
                                .accessibilityHint("No one new can join with this link. The call continues.")
                            }
                            Button { makeNewLink() } label: {
                                HStack {
                                    Label("Make a new link", systemImage: "arrow.triangle.2.circlepath")
                                    Spacer()
                                    if makingLink { ProgressView() }
                                }
                            }
                            .disabled(makingLink)
                            .accessibilityHint("The old link stops working")
                        } footer: {
                            if service.linkRevoked {
                                Text("This link no longer works. No one new can join with it; the call continues.")
                            }
                        }
                    }
                    Section {
                        ForEach(inCall) { inCallRow($0) }
                    } header: {
                        // The reference app's header: bold title, count in regular weight (spec §16:
                        // how many are in the call).
                        HStack(spacing: 0) {
                            Text("In call").fontWeight(.semibold)
                            Text(" · \(stage.inCallCount)")
                        }
                        .textCase(nil)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("In call, \(stage.inCallCount)")
                        .accessibilityAddTraits(.isHeader)
                    }
                    let waiting = invited(at: context.date)
                    if !waiting.isEmpty {
                        Section("Invited") {
                            ForEach(waiting) { invitedRow($0) }
                        }
                    }
                    // The owner only: closes the call on the media server for everyone in it.
                    if service.myRole == .owner && service.isActive {
                        Section {
                            Button(role: .destructive) { confirmEnd = true } label: {
                                Text("End call for everyone")
                            }
                        }
                    }
                }
            }
            // Alone in the call, the sheet says what is happening, as the reference's does.
            .navigationTitle(aloneInCall ? "Waiting for others" : "Participants")
            .task {
                guard ownsLink, let link, approval == nil else { return }
                approval = await CallLinkService.shared.approval(for: link)
                if await CallLinkService.shared.isRevoked(link) == true { service.noteLinkRevoked() }
            }
            .alert("Couldn't change setting", isPresented: $approvalFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("Check your connection and try again.") }
            .alert(removeTarget.map { "Remove \($0.name) from the call?" } ?? "",
                   isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
                   presenting: removeTarget) { t in
                Button("Remove", role: .destructive) { run(.remove, target: t.uid) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("They won't be able to rejoin it.")
            }
            .alert("End the call for everyone?", isPresented: $confirmEnd) {
                Button("End Call", role: .destructive) { run(.end) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Everyone in the call will be disconnected.") }
            .alert("Revoke this link?", isPresented: $confirmRevoke) {
                Button("Revoke", role: .destructive) { revokeLink() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("No one new can join with this link. The call continues.") }
            .alert(actionError ?? "",
                   isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        // Names and photos come from the service's member list; a stage built by the fallback init
        // has not had them yet, and an invite adds members while the sheet is open.
        .onAppear { stage.refreshProfiles(service.members) }
        .onChange(of: service.members) { _, members in stage.refreshProfiles(members) }
        .sheet(isPresented: $showAdd) {
            AddPeopleSheet(alreadyIn: Set(service.members.map(\.uid))) { people in
                Task { await service.invite(people) }
            }
        }
    }

    /// Saved at once; a refusal puts the switch back and says so (same as the link's own page).
    private func setApproval(_ on: Bool, _ link: ActiveCallLink) {
        let before = approval
        approval = on
        Task { @MainActor in
            do { try await CallLinkService.shared.setApproval(link, on: on) }
            catch { approval = before; approvalFailed = true }
        }
    }

    // MARK: - Owner and admin actions (group call permissions, 2026-10-06)

    /// Their role as the server signed it into their join pass, never a flag of ours.
    private func role(of t: CallTile) -> CallRole {
        _ = service.rolesVersion   // redraw when anyone's attributes change
        let attr = stage.participant(t.id)?.attributes["role"]
        // No attribute (a server without roles yet): the tile's host mark, itself server-sourced.
        if attr == nil, t.isHost { return .owner }
        return CallRole(attribute: attr)
    }

    /// The access table: never myself (any of my devices), and only the roles my role reaches.
    private func canModerate(_ t: CallTile) -> Bool {
        !t.isLocal && !t.uid.isEmpty && t.uid != service.myUid && service.myRole.canModerate(role(of: t))
    }

    private func run(_ action: CallAdminAction, target uid: String? = nil) {
        Task { @MainActor in
            do { try await service.admin(action, target: uid) }
            catch { actionError = Self.errorText(error) }
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

    /// The trailing menu on a row the viewer may act on: Mute (while they are not muted) and Remove.
    private func actionsMenu(_ t: CallTile) -> some View {
        Menu {
            if !t.isMuted {
                Button { run(.mute, target: t.uid) } label: {
                    Label("Mute", systemImage: "mic.slash")
                }
            }
            Button(role: .destructive) { removeTarget = t } label: {
                Label("Remove from call", systemImage: "person.fill.xmark")
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
        // The tile's own flag is not republished on every flicker; the stage's store is live.
        stage.speech(for: t.id).isSpeaking || t.id == stage.activeSpeakerId
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
            // Two controls in one row: borderless, so the row tap and the menu each keep their own.
            HStack(spacing: 4) {
                focusButton(t).buttonStyle(.borderless)
                actionsMenu(t).buttonStyle(.borderless)
            }
        } else {
            focusButton(t)
        }
    }

    private func focusButton(_ t: CallTile) -> some View {
        Button {
            if stage.pinnedId != t.id { stage.togglePin(t.id) }
            dismiss()
        } label: {
            rowContent(t).contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(t))
        .accessibilityHint("Shows them large on the call screen")
        .accessibilityAddTraits(.isButton)
    }

    private func rowContent(_ t: CallTile) -> some View {
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
            // Fixed slots, space always kept, so every row's icons line up (as the reference's
            // mic slot does).
            HStack(spacing: 14) {
                slot(t.hasVideo ? "video.fill" : "video.slash", show: true, color: .secondary)
                slot("mic.slash.fill", show: t.isMuted, color: .secondary)
                slot("wifi.exclamationmark", show: t.networkPoor, color: .orange)
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

    private func invitedRow(_ r: Row) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: r.name, photoUrl: r.photoUrl, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                if let s = r.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The link a running call is on, as a `CallLinkRef` for the link service.
struct ActiveCallLink: CallLinkRef {
    let roomId: String
    let key: String
}
