import SwiftUI

// "Set nickname" — the local, device-only contact card (Edit on a profile): avatar, First/Last, a
// private Note with its footer, and a red Delete that clears BOTH. X cancels, checkmark saves.
// Built on the same grouped `Form` as Settings > Edit Profile, deliberately — see body.
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
            // A REAL GROUPED FORM, the same one Settings > Edit Profile uses (user 2026-07-29, with a
            // screenshot circling the cards: "that section is not looks native… make it like when i go
            // setting then i click edit name").
            //
            // What was here before drew the look by hand: a ScrollView of VStacks with their own
            // 16pt-radius backgrounds, own padding and a hand-placed Divider. It could only ever
            // approximate the real thing, and it was wrong in exactly the places the eye checks — the
            // card inset and radius, the separator's inset, the row height, and the footer, which was a
            // floating caption under a card rather than a section footer. None of that is worth owning:
            // `Form` renders all of it, matches whatever iOS does next, and keeps the two name screens
            // identical for free.
            Form {
                Section {
                    AvatarView(name: profileName, photoUrl: photoUrl, size: 96)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)   // sits on the grouped background, no card
                }

                Section {
                    TextField("First name", text: $first)
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .first)
                        .submitLabel(.next)
                        .onSubmit { focus = .last }
                        .onChange(of: first) { _, v in if v.count > 40 { first = String(v.prefix(40)) } }
                    TextField("Last name", text: $last)
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .last)
                        .submitLabel(.next)
                        .onSubmit { focus = .note }
                        .onChange(of: last) { _, v in if v.count > 40 { last = String(v.prefix(40)) } }
                }

                Section {
                    // GROWS INSTEAD OF SCROLLING SIDEWAYS. A one-line field pushed a long note off to
                    // the left as you typed, so you could not read back what you had written — the same
                    // shape the Bio field in Settings already solved with a vertical axis.
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focus, equals: .note)
                } footer: {
                    // A real section footer, so it takes the system's own inset and spacing rather than
                    // sitting under the card at a guessed padding.
                    Text("Notes are only visible to you.")
                }

                if hasSomethingToDelete {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("Delete").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
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
