import SwiftUI

// "Message Info" for a group message I sent: who has read it vs who it's only been delivered to,
// derived from the per-member lastRead timestamps (a member has read it if their last-read time is at
// or after this message's time). A standard read-by list, our own layout.
struct MessageInfoView: View {
    let message: Message
    let members: [String]                 // other group members (excluding me)
    let lastRead: [String: Double]        // uid -> last-read millis
    var nameFor: (String) -> String = { _ in "" }
    var photoFor: (String) -> String? = { _ in nil }
    @Environment(\.dismiss) private var dismiss

    private var msgMillis: Double { message.createdAt.timeIntervalSince1970 * 1000 }
    private var readBy: [String] {
        members.filter { (lastRead[$0] ?? 0) >= msgMillis }.sorted { nameFor($0) < nameFor($1) }
    }
    private var deliveredTo: [String] {
        members.filter { (lastRead[$0] ?? 0) < msgMillis }.sorted { nameFor($0) < nameFor($1) }
    }

    private var snippet: String {
        if message.isImage { return "📷 Photo" }
        if message.isVideo { return "🎥 Video" }
        if message.isAudio { return "🎤 Voice message" }
        return message.safeText   // never leak a raw fariin-…: marker (contact/location card)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet).font(.system(size: 15)).lineLimit(3)
                        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if !readBy.isEmpty {
                    Section {
                        ForEach(readBy, id: \.self) { memberRow($0) }
                    } header: {
                        Label("Read by \(readBy.count)", systemImage: "checkmark.circle.fill").textCase(nil)
                    }
                }
                if !deliveredTo.isEmpty {
                    Section {
                        ForEach(deliveredTo, id: \.self) { memberRow($0) }
                    } header: {
                        Label("Delivered to \(deliveredTo.count)", systemImage: "checkmark.circle").textCase(nil)
                    }
                }
            }
            .navigationTitle("Message Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func memberRow(_ uid: String) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: nameFor(uid), photoUrl: photoFor(uid), size: 40)
            Text(nameFor(uid)).font(.system(size: 16, weight: .medium))
            VerifiedMark(uid: uid, size: 13)
            Spacer()
        }
    }
}
