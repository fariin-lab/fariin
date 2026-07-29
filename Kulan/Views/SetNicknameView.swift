import SwiftUI

// "Set nickname" — the local, device-only contact card (Edit on a profile), rebuilt 2026-07-29 to the
// user's reference: avatar, First/Last in one grouped card, a private Note in its own card with the
// honest footer, and a red Delete that clears BOTH. X cancels, checkmark saves.
//
// Everything here is stored by ContactNames on this device and never sent, which is what lets the
// footer promise "Notes are only visible to you" without an asterisk.
struct SetNicknameView: View {
    let uid: String
    let profileName: String        // their real profile name, for the avatar fallback letter
    let photoUrl: String?

    @State private var first: String
    @State private var last: String
    @State private var note: String
    @State private var confirmDelete = false
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    private enum Field { case first, last, note }

    init(uid: String, profileName: String, photoUrl: String?, onSave: @escaping () -> Void) {
        self.uid = uid
        self.profileName = profileName
        self.photoUrl = photoUrl
        self.onSave = onSave
        let card = ContactNames.shared.card(for: uid)
        _first = State(initialValue: card.first)
        _last = State(initialValue: card.last)
        _note = State(initialValue: card.note)
    }

    private var hasSomethingToDelete: Bool { !ContactNames.shared.card(for: uid).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        AvatarView(name: profileName, photoUrl: photoUrl, size: 96)
                            .padding(.top, 12)

                        // First + Last share one card, divided — the reference grouping.
                        VStack(spacing: 0) {
                            field("First name", text: $first, field: .first, submit: .next)
                            Divider().padding(.leading, 16)
                            field("Last name", text: $last, field: .last, submit: .next)
                        }
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            field("Note", text: $note, field: .note, submit: .done)
                                .background(Color(.secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("Notes are only visible to you.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                        }

                        if hasSomethingToDelete {
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Text("Delete")
                                    .font(.body)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 15)
                            }
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Set nickname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark").font(.headline) }
                }
            }
            .alert("Delete Nickname?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    ContactNames.shared.remove(for: uid)
                    onSave()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this nickname and note.")
            }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .first } }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field,
                       submit: SubmitLabel) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            .font(.body)
            .focused($focus, equals: field)
            .submitLabel(submit)
            .onSubmit {
                switch field {
                case .first: focus = .last
                case .last:  focus = .note
                case .note:  save()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private func save() {
        ContactNames.shared.setCard(
            ContactCard(first: first.trimmingCharacters(in: .whitespaces),
                        last: last.trimmingCharacters(in: .whitespaces),
                        note: note.trimmingCharacters(in: .whitespaces)),
            for: uid)
        onSave()
        dismiss()
    }
}
