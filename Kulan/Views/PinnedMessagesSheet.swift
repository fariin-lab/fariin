import SwiftUI

// "See All" from the pinned bar: a sheet listing ONLY the pinned messages (Telegram-style).
// Tap a row → close + jump to that message in the chat; swipe (or the pin button) unpins if allowed.
struct PinnedMessagesSheet: View {
    let pinned: [Message]
    var nameFor: (String) -> String
    var canUnpin: Bool
    var onUnpin: (String) -> Void
    var onTap: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private func snippet(_ m: Message) -> String {
        if m.isImage { return "📷 Photo" }
        if m.isVideo { return "🎥 Video" }
        if m.isAudio { return "🎤 Voice message" }
        if m.isFile  { return "📄 \(m.fileName ?? "File")" }
        return m.text
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(pinned, id: \.id) { m in
                    Button { onTap(m.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(nameFor(m.authorId)).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(m.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(snippet(m)).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if canUnpin {
                            Button(role: .destructive) { onUnpin(m.id) } label: { Label("Unpin", systemImage: "pin.slash") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if pinned.isEmpty {
                    ContentUnavailableView("No pinned messages", systemImage: "pin",
                                           description: Text("Pin a message from its menu."))
                }
            }
            .navigationTitle("Pinned Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
