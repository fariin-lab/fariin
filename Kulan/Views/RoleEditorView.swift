import SwiftUI

// ⛔ ROLE — owner 2026-10-18. The page an admin uses to give a member a role in the group: an
// optional emoji, a few words, and a live look at how it reads in the chat. Our own screen; the
// limits are the second reference app's (MemberLabelViewController.swift:89-90: 24 at most, the
// count appears from 9 left; :479, never an emoji alone). Who may open it is
// `Conversation.canSetRole`, and firestore.rules `roleWriteOK` holds the same line on the server.
struct RoleEditorView: View {
    let cid: String
    let uid: String
    let name: String
    let current: GroupRole?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var emoji: String?
    @State private var pickingEmoji = false
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var typing: Bool

    init(cid: String, uid: String, name: String, current: GroupRole?) {
        self.cid = cid
        self.uid = uid
        self.name = name
        self.current = current
        _text = State(initialValue: current?.text ?? "")
        _emoji = State(initialValue: current?.emoji)
    }

    private var cleaned: String { GroupRole.clean(text) }
    private var left: Int { GroupRole.maxText - text.utf16.count }
    /// Words are required (an emoji alone is not a role), and there must be something new to save.
    private var canSave: Bool {
        !busy && !cleaned.isEmpty && (cleaned != current?.text || emoji != current?.emoji)
    }
    private var preview: GroupRole? { cleaned.isEmpty ? nil : GroupRole(text: cleaned, emoji: emoji) }

    var body: some View {
        List {
            Section {
                previewBubble
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                HStack(spacing: 10) {
                    emojiButton
                    TextField("Role, like Designer", text: $text)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                    if left <= 9 {
                        Text("\(left)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(left <= 5 ? Color.red : Color.secondary)
                    }
                }
            } footer: {
                Text("Shown next to \(name)'s name in this group. Only admins can give roles.")
            }
            if current != nil {
                Section {
                    Button("Remove Role", role: .destructive) { remove() }
                        .disabled(busy)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current == nil ? "Set Role" : "Edit Role")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .tint(.blue)
                    .disabled(!canSave)
            }
        }
        .onChange(of: text) { _, new in
            // Typing or pasting past the limit keeps the first 24, whole characters only.
            if new.utf16.count > GroupRole.maxText { text = GroupRole.fit(new, max: GroupRole.maxText) }
        }
        .onAppear { typing = true }
        .sheet(isPresented: $pickingEmoji) {
            EmojiMorePicker(title: "Role Emoji") { emoji = $0 }
        }
        .alert("Could not save the role", isPresented: Binding(get: { errorText != nil },
                                                               set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    /// The emoji in front of the role: a smiley to add one, the emoji itself once picked, with a
    /// menu to change or drop it.
    @ViewBuilder private var emojiButton: some View {
        if let emoji {
            Menu {
                Button { pickingEmoji = true } label: { Label("Change Emoji", systemImage: "face.smiling") }
                Button(role: .destructive) { self.emoji = nil } label: { Label("Remove Emoji", systemImage: "xmark") }
            } label: {
                Text(emoji).font(.system(size: 24)).frame(width: 32, height: 32)
            }
        } else {
            Button { pickingEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add emoji")
        }
    }

    /// How the role will read in the chat: a received bubble with their name, the tick when they
    /// carry one, the role beside it, and a line of text under. The chip is drawn as the bubble
    /// draws it (MessageRowLayout's in-bubble name header), in the name's own colour.
    private var previewBubble: some View {
        let tint = Color(uiColor: BubblePalette.senderColor(uid))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                    .layoutPriority(1)
                VerifiedMark(uid: uid, size: 11)
                if let preview {
                    // The tag's own colour when it has one, as the chat draws it (owner 2026-10-28).
                    let chip = GroupRole.rgb(preview.color).map { Color(hex: $0) } ?? tint
                    Text(preview.display)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(chip)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(chip.opacity(0.14)))
                        .padding(.leading, 2)
                }
            }
            Text("See you all at six!").font(.body)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
        .animation(.snappy(duration: 0.2), value: preview)
    }

    private func save() {
        guard canSave else { return }
        write(text: cleaned, emoji: emoji)
    }

    private func remove() { write(text: "", emoji: nil) }

    private func write(text: String, emoji: String?) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await ChatService.setRole(cid: cid, uid: uid, text: text, emoji: emoji)
                await MainActor.run { busy = false; dismiss() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { busy = false; errorText = msg }
            }
        }
    }
}
