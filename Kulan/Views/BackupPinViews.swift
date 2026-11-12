import SwiftUI

// ⛔ BACKUP PIN SCREENS (owner 2026-11-12, both apps, Android's words). See `KeyBackup` for the format.
// Privacy & Security > Backup PIN (above App Lock), the New PIN page, and the full-screen
// "Restore your messages" shown after sign-in when the account has a backup of another key.

/// The row's word: last known On/Off at once, the server's answer when the page is opened.
struct BackupPinRow: View {
    @State private var on: Bool? = KeyBackup.knownOn

    var body: some View {
        NavigationLink { BackupPinPage(onChange: { on = $0 }) } label: {
            HStack {
                Text("Backup PIN")
                Spacer()
                if let on { Text(on ? "On" : "Off").foregroundStyle(.secondary) }
            }
        }
        .task { if on == nil, let s = try? await KeyBackup.status() { on = s.exists } }
    }
}

struct BackupPinPage: View {
    var onChange: (Bool) -> Void = { _ in }
    @State private var on: Bool? = KeyBackup.knownOn
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?
    @State private var makePin = false

    static let footer = "Your messages are end-to-end encrypted, so only your phone has the key that opens them. With a Backup PIN, that key is saved locked with your PIN. If you delete Fariin or move to a new phone, the PIN brings your older messages back. Fariin never sees your PIN and cannot reset it."

    var body: some View {
        List {
            Section {
                if on == nil && loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if on == true {
                    Button("Change PIN") { makePin = true }
                    Button("Turn Off", role: .destructive) { confirmOff() }
                        .disabled(working)
                } else {
                    Button("Create Backup PIN") { makePin = true }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let problem { Text(problem).foregroundStyle(.red) }
                    Text(Self.footer)
                }
            }
        }
        .navigationTitle("Backup PIN")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $makePin) {
            NewBackupPinPage { set(true) }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do { set(try await KeyBackup.status().exists); problem = nil }
        catch { if on == nil { problem = "Couldn't check your backup. Check your connection and try again." } }
        loading = false
    }

    private func set(_ value: Bool) {
        on = value
        onChange(value)
    }

    private func confirmOff() {
        GlassConfirmDoor.show(
            title: "Turn off Backup PIN?",
            message: "The saved key is deleted. If you delete Fariin or change phones, your older messages will not come back.",
            confirm: "Turn Off") {
                working = true
                Task {
                    do { try await KeyBackup.delete(); set(false); problem = nil }
                    catch { problem = error.localizedDescription }
                    working = false
                }
            }
    }
}

/// Two number fields, at least 6 digits, Save in the bar.
struct NewBackupPinPage: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var focus: Int?

    var body: some View {
        List {
            Section {
                SecureField("PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .focused($focus, equals: 0)
                SecureField("Confirm PIN", text: $confirm).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .focused($focus, equals: 1)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let problem { Text(problem).foregroundStyle(.red) }
                    Text("At least \(KeyBackup.minDigits) digits. Fariin can't reset it, so pick one you will remember.")
                }
            }
        }
        .navigationTitle("New PIN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { save() }.disabled(pin.isEmpty || confirm.isEmpty) }
            }
        }
        .onChange(of: pin) { _, v in pin = String(v.filter(\.isNumber).prefix(32)) }
        .onChange(of: confirm) { _, v in confirm = String(v.filter(\.isNumber).prefix(32)) }
        .onAppear { focus = 0 }
    }

    private func save() {
        guard pin.count >= KeyBackup.minDigits else { problem = "Use at least \(KeyBackup.minDigits) digits."; return }
        guard pin == confirm else { problem = "The PINs don't match."; return }
        problem = nil
        saving = true
        Task {
            do {
                try await KeyBackup.save(pin: pin)
                Haptics.notify(.success)
                onSaved()
                dismiss()
            } catch {
                problem = (error as? KeyBackup.Failure)?.errorDescription ?? error.localizedDescription
                Haptics.notify(.error)
            }
            saving = false
        }
    }
}

/// After sign-in, when the account's backup holds a key other than this phone's.
struct RestoreMessagesView: View {
    let status: KeyBackup.Status
    var onDone: () -> Void
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)
            Image(systemName: "lock.rotation").font(.system(size: 44, weight: .regular)).foregroundStyle(.secondary)
            Text("Restore your messages").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text("Enter your Backup PIN to bring back your older messages on this phone.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .multilineTextAlignment(.center).font(.title3)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemFill)))
                .focused($focused)
                .onChange(of: pin) { _, v in pin = String(v.filter(\.isNumber).prefix(32)) }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            Button { restore() } label: {
                ZStack {
                    Text("Restore").opacity(working ? 0 : 1)
                    if working { ProgressView().tint(Color.onFariinAction) }
                }
                .font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Capsule().fill(Color.fariinAction))
            }
            .disabled(pin.count < KeyBackup.minDigits || working)
            Button("Skip") { KeyBackup.skip(status); onDone() }
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .disabled(working)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { focused = true }
        .interactiveDismissDisabled()
    }

    private func restore() {
        problem = nil
        working = true
        Task {
            do {
                try await KeyBackup.restore(pin: pin, status: status)
                Haptics.notify(.success)
                ToastNotice.show("Your messages are back.")
                onDone()
            } catch {
                pin = ""
                problem = (error as? KeyBackup.Failure)?.errorDescription ?? error.localizedDescription
                Haptics.notify(.error)
                if case .gone? = error as? KeyBackup.Failure { KeyBackup.skip(status) }
            }
            working = false
        }
    }
}
