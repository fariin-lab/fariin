import SwiftUI
import LiveKit

/// The call screen's two-people button: who is in the call right now, who was invited and has not
/// come in, and (multi-person calls only) "Add people".
struct GroupCallParticipantsSheet: View {
    @ObservedObject private var service = GroupCallService.shared
    @ObservedObject private var room = GroupCallService.shared.room
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    private struct Row: Identifiable {
        let id: String
        let name: String
        let photoUrl: String?
        let subtitle: String?
    }

    /// Everyone connected right now, me first. Identity is the uid (the token's `sub`).
    private var inCall: [Row] {
        let me = service.myUid
        let local = Row(id: me.isEmpty ? "me" : me, name: "You",
                        photoUrl: service.members.first { $0.uid == me }?.photoUrl, subtitle: nil)
        let remote = room.remoteParticipants.values.map { p -> Row in
            let uid = p.identity?.stringValue ?? ""
            let m = service.members.first { $0.uid == uid }
            let name = (p.name?.isEmpty == false ? p.name : nil) ?? m?.name ?? "Member"
            return Row(id: uid.isEmpty ? UUID().uuidString : uid, name: name, photoUrl: m?.photoUrl, subtitle: nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [local] + remote
    }

    /// Invited and not here: still ringing for the first minute, then "Didn't join". Someone who
    /// came in and has since gone says so.
    private func invited(at now: Date) -> [Row] {
        let here = Set(inCall.map(\.id))
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
                    if service.isAdhoc {
                        Section {
                            Button { showAdd = true } label: {
                                Label("Add people", systemImage: "person.badge.plus")
                            }
                        }
                    }
                    Section("In call") {
                        ForEach(inCall) { row($0) }
                    }
                    let waiting = invited(at: context.date)
                    if !waiting.isEmpty {
                        Section("Invited") {
                            ForEach(waiting) { row($0) }
                        }
                    }
                }
            }
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddPeopleSheet(alreadyIn: Set(service.members.map(\.uid))) { people in
                Task { await service.invite(people) }
            }
        }
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: r.name, photoUrl: r.photoUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                if let s = r.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
