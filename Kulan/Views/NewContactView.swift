import SwiftUI

// Add a contact — Telegram-style layout (First/Last Name card + identifier below). Kulan is
// handle-based (no phone numbers), so the identifier is the @username. The name you type is saved
// locally (ContactNames) and shown for them in your chat list + headers; we find them by username.
struct NewContactView: View {
    var onOpen: (ChatTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var handle = ""
    @State private var working = false
    @State private var notFound = false
    @FocusState private var focus: Field?
    private enum Field { case first, last, handle }
    private var me: String { AuthService.shared.uid ?? "" }
    private var canSave: Bool { !ChatService.sanitizeHandle(handle).isEmpty && !working }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 22) {
                            // Name card (First + Last) — Telegram style.
                            VStack(spacing: 0) {
                                field("First Name", text: $firstName, focus: .first, submit: .last)
                                Divider().padding(.leading, 18)
                                field("Last Name", text: $lastName, focus: .last, submit: .handle)
                            }
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            // Identifier card (@username) — the real way Kulan finds people.
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 2) {
                                    Text("@").foregroundStyle(.secondary)
                                    TextField("username", text: $handle)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .focused($focus, equals: .handle)
                                        .submitLabel(.done)
                                        .onChange(of: handle) { _, v in
                                            let c = ChatService.sanitizeHandle(v); if c != v { handle = c }
                                        }
                                        .onSubmit { Task { await add() } }
                                }
                                .padding(.horizontal, 18).frame(height: 52)
                                .background(Color(.secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                                Text("Kulan finds people by @username — there are no phone numbers. The name you enter is how they'll show in your chats.")
                                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .alert("Sorry, this user doesn't seem to exist.", isPresented: $notFound) {
                Button("OK", role: .cancel) {}
            }
            .onAppear { focus = .first }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 40, height: 40).background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            Spacer()
            Text("New Contact").font(.headline)
            Spacer()
            Button { Task { await add() } } label: {
                Image(systemName: working ? "ellipsis" : "checkmark")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSave ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color.gray.opacity(0.4)), in: Circle())
            }
            .disabled(!canSave)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func field(_ placeholder: String, text: Binding<String>, focus f: Field, submit next: Field) -> some View {
        TextField(placeholder, text: text)
            .focused($focus, equals: f)
            .submitLabel(.next)
            .onSubmit { focus = next }
            .padding(.horizontal, 18).frame(height: 52)
    }

    private func add() async {
        let h = ChatService.sanitizeHandle(handle)
        guard !h.isEmpty else { return }
        working = true
        if let u = await ChatService.findByHandle(h), u.id != me {
            let full = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { ContactNames.shared.set(full, for: u.id) }   // save the local display name
            let cid = ChatService.convId(me, u.id)
            try? await ChatService.openConversation(other: u)
            working = false
            let display = full.isEmpty ? (u.name.isEmpty ? u.handle : u.name) : full
            onOpen(ChatTarget(id: cid, name: display, photo: u.photoUrl))
        } else {
            working = false
            notFound = true
        }
    }
}
