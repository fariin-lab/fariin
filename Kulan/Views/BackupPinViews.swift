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
    /// The backup holds another key than this phone's (owner 2026-11-12): a Restore row, so a
    /// restore is never lost behind a Skip.
    @State private var otherKey: KeyBackup.Status?
    @State private var showRestore = false

    static let footer = "Your messages are end-to-end encrypted, so only your phone has the key that opens them. With a Backup PIN, that key is saved locked with your PIN. If you delete Fariin or move to a new phone, the PIN brings your older messages back. Fariin never sees your PIN and cannot reset it."

    var body: some View {
        List {
            Section {
                if on == nil && loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if on == true {
                    if otherKey != nil { Button("Restore Messages") { showRestore = true } }
                    Button("Change PIN") { changePin() }
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
            NewBackupPinPage { set(true); otherKey = nil }
        }
        .fullScreenCover(isPresented: $showRestore) {
            if let s = otherKey {
                RestoreMessagesView(status: s) { outcome in
                    showRestore = false
                    KeyBackupOffer.shared.finished(outcome, s)
                    if outcome != .skipped { otherKey = nil }
                    if outcome == .gone { set(false) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            let s = try await KeyBackup.status()
            set(s.exists)
            otherKey = await KeyBackup.holdsOtherKey(s) ? s : nil
            problem = nil
        }
        catch { if on == nil { problem = "Couldn't check your backup. Check your connection and try again." } }
        loading = false
    }

    private func set(_ value: Bool) {
        on = value
        onChange(value)
    }

    /// ⛔ WARN BEFORE THE OLDER KEY IS REPLACED (owner 2026-11-12, both apps): while the backup holds
    /// another key than this phone's, a new PIN saves this phone's key over it, for good.
    private func changePin() {
        guard otherKey != nil else { makePin = true; return }
        GlassConfirmDoor.show(
            title: "Replace your backup?",
            message: "Your backup still holds the key to your older messages. A new PIN saves this phone's key instead, and those messages can never be restored. Restore them first if you can.",
            confirm: "Replace") { makePin = true }
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

/// The second chance after Skip (owner 2026-11-12, both apps): a slim bar on the chat list just
/// above the tab bar. The bar or "Restore" opens the restore screen again; X hides it for this backup.
struct RestoreOlderBar: View {
    @State private var offer = KeyBackupOffer.shared

    var body: some View {
        if offer.bar != nil {
            HStack(spacing: 12) {
                Button { offer.reopen() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.onFariinAction)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.fariinAction))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Restore older messages").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("Enter your Backup PIN").font(.footnote).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("Restore").font(.subheadline.weight(.semibold)).foregroundStyle(Color.fariinAction)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { offer.hideBar() } } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide")
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(height: 52)
            .liquidGlass(Capsule())
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// After sign-in, when the account's backup holds a key other than this phone's.
struct RestoreMessagesView: View {
    enum Outcome { case restored, skipped, gone }
    let status: KeyBackup.Status
    var onDone: (Outcome) -> Void
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    /// The backup was deleted (10 wrong) or is not there: Skip just closes, no bar comes after.
    @State private var gone = false
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
            Button(gone ? "Continue" : "Skip") { onDone(gone ? .gone : .skipped) }
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .disabled(working)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        // ⛔ NO KEYBOARD BY ITSELF (owner 2026-11-12: it came up with no way to close it). It opens
        // on a tap in the PIN box; a tap anywhere else closes it.
        .background(Color(.systemBackground).ignoresSafeArea().onTapGesture { focused = false })
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
                onDone(.restored)
            } catch {
                pin = ""
                problem = (error as? KeyBackup.Failure)?.errorDescription ?? error.localizedDescription
                Haptics.notify(.error)
                if case .gone? = error as? KeyBackup.Failure { gone = true; KeyBackup.hideBar(status) }
            }
            working = false
        }
    }
}
