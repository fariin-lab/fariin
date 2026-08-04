import SwiftUI

// Settings > Chats. Sits between Appearance and Stories, on the owner's layout (2026-08-04).
//
// Same bones as every other settings sub-page: native List, one Section per idea, the explanation
// as the section FOOTER rather than a second line inside the row — that is what makes an iOS
// settings page read as one page instead of a stack of cards.
struct ChatsSettingsView: View {
    @AppStorage(AutoSaveToPhotos.defaultsKey) private var saveToPhotos = false
    @State private var confirmClear = false
    @State private var clearing = false

    private var chatCount: Int { ConversationsRepository.shared.conversations.count }

    var body: some View {
        List {
            Section {
                Toggle("Save to Photos", isOn: $saveToPhotos).tint(.green)
            } footer: {
                Text("Automatically save received photos and videos to your Photos library.")
            }

            Section {
                Button(role: .destructive) { confirmClear = true } label: {
                    HStack {
                        Text("Clear Chat History")
                        if clearing { Spacer(); ProgressView() }
                    }
                }
                .disabled(clearing || chatCount == 0)
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        // An action sheet, not an alert: the message is long and the choice is one destructive
        // button, which is the shape iOS uses for "this cannot be undone".
        .confirmationDialog("Clear Chat History?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { Task { await clearEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently delete all chat history, including messages, photos, videos, documents, voice messages, and call history, from all of your devices? This action cannot be undone.")
        }
    }

    /// Clears every chat the way the per-chat Delete does — `clearedAt` on the conversation, which
    /// is written SERVER-side and so reaches every device you are signed in on, which is what the
    /// sheet promises. It clears YOUR copy: the other person keeps theirs, exactly like deleting
    /// one chat does. Nothing here can touch someone else's device.
    private func clearEverything() async {
        clearing = true
        let ids = ConversationsRepository.shared.conversations.map(\.id)
        await withTaskGroup(of: Void.self) { g in
            for id in ids { g.addTask { await ChatService.deleteForMe(id) } }
        }
        clearing = false
    }
}
