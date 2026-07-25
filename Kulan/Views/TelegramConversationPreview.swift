import SwiftUI

// Developer comparison screen for the experimental Telegram conversation mode.
// Turns the mode on, lists your chats so one can be opened immediately, and keeps a switch here so
// it can be flipped back and forth while looking at the same conversation.
struct TelegramConversationPreview: View {
    @AppStorage(TGMode.key) private var tgConversation = false
    @State private var repo = ConversationsRepository.shared
    @State private var open: Conversation?
    private var me: String { AuthService.shared.uid ?? "" }

    private var chats: [Conversation] {
        repo.conversations.filter { !$0.isCleared(me) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Telegram conversation mode", isOn: $tgConversation)
            } footer: {
                Text(tgConversation
                     ? "ON. Open a chat below, then flip this switch while looking at it to compare."
                     : "OFF. The conversation is exactly your original implementation.")
            }

            Section("What changes when it's on") {
                row("Merge window", TGMode.enabled ? "10 min" : "5 min",
                    "Telegram: abs(t1 - t2) < 10 * 60")
                row("Gap between groups", fmt(TGMode.clusterSpacing), "bubble.defaultSpacing")
                row("Gap inside a group", fmt(TGMode.mergedSpacing), "bubble.mergedSpacing")
                row("Corner radius", fmt(TGMode.cornerRadius), "image.defaultCornerRadius")
                row("Joined corner", fmt(TGMode.mergedCornerRadius), "image.mergedCornerRadius")
            }

            Section("Open a chat to compare") {
                if chats.isEmpty {
                    Text("No chats yet.").foregroundStyle(.secondary)
                }
                ForEach(chats) { c in
                    Button {
                        tgConversation = true   // preview always opens in the new mode
                        open = c
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 34)
                            Text(c.displayName(me)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Preview Telegram Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $open) { c in
            ThreadView(cid: c.id, title: c.displayName(me), photoUrl: c.displayPhoto(me))
        }
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.2fpt", v) }

    private func row(_ title: String, _ value: String, _ origin: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(origin).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
