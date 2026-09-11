import SwiftUI

// CHAT PIN, THE SCREENS — owner's spec, 2026-09-11, drawn from his four reference screenshots.
//
// Three views and two parts:
//   ChatPinEntrySheet   somebody ELSE's pin — the sheet with the face, "Enter Chat PIN", the six
//                       slots, the keypad and the Enter button (his third screenshot).
//   ChatPinPage         MY pin — behind "Chat PIN" in the Chats title menu (his first screenshot,
//                       where the reference app keeps "Number") and behind Privacy › Messages.
//   ChatPinSetSheet     choosing a pin, from that page.
//   ChatPinKeypad / ChatPinDigitsBox  the two parts both sheets are built from.
//
// ⛔ NO SYSTEM KEYBOARD. The reference draws its own keypad and so does this: a number pad the
// system offers comes with suggestions, a paste bar and a different height on every phone, and a
// pin is not a form field. The keypad below is twelve plain buttons.

/// The twelve keys. Appends up to `ChatPin.maxDigits`; the last key deletes.
struct ChatPinKeypad: View {
    @Binding var pin: String

    private static let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { key in
                        Button { tap(key) } label: {
                            Group {
                                if key == "⌫" {
                                    // ⛔ `delete.left`, NOT `chevron.left` — owner, 2026-09-11: "the
                                    // clear number icon looks like a back button". It was one: a
                                    // bare left chevron is the glyph every navigation bar in the app
                                    // uses to go back, so on a keypad it reads as "leave this sheet"
                                    // rather than "rub out a digit". `delete.left` is the key Apple's
                                    // own number pads draw for this and is the only symbol a person
                                    // will already know means backspace.
                                    Image(systemName: "delete.left").font(.system(size: 24, weight: .medium))
                                } else {
                                    Text(key).font(.system(size: 30, weight: .regular))
                                }
                            }
                            .foregroundStyle(Color(.label))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(key.isEmpty)
                        .opacity(key.isEmpty ? 0 : 1)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key)
                    }
                }
            }
        }
    }

    private func tap(_ key: String) {
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < ChatPin.maxDigits else { return }
        pin += key
    }
}

/// Six slots on a grey plate, "0" in the tertiary colour where nothing has been typed yet — the
/// reference's own placeholder, which says the shape of the thing without a caption.
struct ChatPinDigitsBox: View {
    let pin: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<ChatPin.maxDigits, id: \.self) { i in
                let filled = i < pin.count
                Text(filled ? String(pin[pin.index(pin.startIndex, offsetBy: i)]) : "0")
                    .font(.system(size: 26, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(filled ? Color(.label) : Color(.tertiaryLabel))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(pin.isEmpty ? "No digits entered" : "\(pin.count) digits entered")
    }
}

/// The wrong-code shake: three swings either side of centre, the idiom the lock screen answers a
/// wrong passcode with. Driven by a COUNTER rather than a flag, so a second refusal is a second
/// animation and not a no-op — and because whole numbers land on `sin(nπ)`, every run starts and
/// ends exactly where the box sits.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// The full-width capsule at the bottom of both sheets: black on white (white on black at night)
/// when there is something to submit, grey with white text until then — his third screenshot.
private struct ChatPinSubmitButton: View {
    let title: String
    let enabled: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).font(.body.weight(.semibold)).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(Color(.systemBackground)) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color(.systemBackground) : Color.white)
        .background(enabled ? Color(.label) : Color(.systemGray3), in: Capsule())
        .disabled(!enabled || busy)
    }
}

// MARK: - Somebody else's pin

/// "Enter @handle's Chat PIN to contact them." Verified on the server; on success the conversation
/// is already accepted by the time `onSuccess` runs, so the caller only has to open it.
struct ChatPinEntrySheet: View {
    let uid: String
    let name: String
    let photoUrl: String?
    /// "@handle" when the caller already has it. Fetched here when it does not.
    var handle: String? = nil
    let onSuccess: (String) -> Void

    /// ⚠️ SPELLED OUT. The `@State private` properties below make the synthesised memberwise init
    /// private too, and `private` does not reach the views that present this sheet — the same trap
    /// `MessageRequestsView` carries its own init for, which has cost a CI round trip before.
    init(uid: String, name: String, photoUrl: String?, handle: String? = nil,
         onSuccess: @escaping (String) -> Void) {
        self.uid = uid
        self.name = name
        self.photoUrl = photoUrl
        self.handle = handle
        self.onSuccess = onSuccess
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var failure = ""
    @State private var handleText = ""
    /// ⛔ THE REASON A WRONG PIN SAID NOTHING (owner, 2026-09-11: "when i inter wrong pin didn't
    /// tell me"). The refusal below sets `failure` and then empties `pin` so the next attempt can be
    /// typed — and emptying `pin` is a change to `pin`, so the `onChange` that clears the message
    /// when the user starts typing ran on the same pass and wiped the sentence before it was ever
    /// drawn. The message was always correct; it just lived for less than one frame.
    ///
    /// This says which of the two emptied it. Only a digit the USER pressed clears the sentence.
    @State private var clearedByRefusal = false
    @State private var shake: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    AvatarView(name: name, photoUrl: photoUrl, size: 56)
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(.secondarySystemFill), in: Capsule())
                }
                .padding(.top, 20)

                Text("Enter Chat PIN")
                    .font(.headline)
                    .padding(.top, 18)
                Divider()
                    .padding(.top, 12)
                    .padding(.horizontal, 20)

                (Text("Enter ") + Text(handleText.isEmpty ? name : handleText).fontWeight(.semibold)
                    + Text("’s Chat PIN to contact them."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 24)

                ChatPinDigitsBox(pin: pin)
                    .modifier(ShakeEffect(animatableData: shake))
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                // ONE SENTENCE, THE SERVER'S. A wrong pin, no pin and a block all read the same
                // here, on purpose (spec §7, §34); only the lockout names itself.
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(height: 20)
                    .padding(.top, 6)
                    .opacity(failure.isEmpty ? 0 : 1)

                ChatPinKeypad(pin: $pin)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

            }
        }
        // Anchored exactly as the Choose sheet's Save is, and for the same reason — the full
        // reasoning is written there. The two are one control on two sheets and must not drift.
        .safeAreaInset(edge: .bottom) {
            ChatPinSubmitButton(title: "Enter", enabled: ChatPin.isValid(pin), busy: busy) { submit() }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.fraction(0.84), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: pin) { _, _ in
            if clearedByRefusal { clearedByRefusal = false } else { failure = "" }
        }
        .task {
            if let handle, !handle.isEmpty { handleText = handle; return }
            if let p = await ProfileStore.shared.fetch(uid), !p.handle.isEmpty { handleText = "@" + p.handle }
        }
    }

    private func submit() {
        guard ChatPin.isValid(pin), !busy else { return }
        busy = true
        Task {
            do {
                let cid = try await ChatPin.verify(uid: uid, pin: pin)
                busy = false
                dismiss()
                onSuccess(cid)
            } catch {
                busy = false
                // Order matters only for readability; the flag is what protects the sentence.
                clearedByRefusal = true
                pin = ""
                failure = error.localizedDescription
                // A refused pin is worth feeling as well as reading — the same shake and the same
                // knock the lock screen answers a wrong passcode with.
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
            }
        }
    }
}

// MARK: - My pin

/// Behind "Chat PIN" in the Chats title menu and Privacy › Messages. Shows the pin this phone set,
/// with Copy and Share; says "set on another device" when it cannot; offers Set, Change and Remove.
struct ChatPinPage: View {
    @State private var isSet = ChatPin.isSet
    @State private var mine = ChatPin.mine
    @State private var checking = true
    @State private var setting = false
    @State private var confirmRemove = false
    @State private var removing = false
    @State private var copied = false
    @State private var failure = ""

    /// "4827" shown as "4 8 2 7": a number to read out, not a word to read.
    private var spaced: String { (mine ?? "").map(String.init).joined(separator: " ") }

    var body: some View {
        List {
            Section {
                if isSet {
                    if let mine, !mine.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(spaced)
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = mine
                                    copied = true
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity).frame(height: 40)
                                }
                                .buttonStyle(.plain)
                                .background(Color(.secondarySystemFill), in: Capsule())
                                ShareLink(item: "My Chat PIN on Fariin is \(mine). Enter it to message me directly.") {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity).frame(height: 40)
                                }
                                .buttonStyle(.plain)
                                .background(Color(.secondarySystemFill), in: Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // Set from another phone. The server holds only a hash, so there is nothing
                        // to show here but the fact; changing it from this phone puts it on screen.
                        Label("Your Chat PIN was set on another device.", systemImage: "iphone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if checking {
                    HStack { Text("Chat PIN"); Spacer(); ProgressView() }
                } else {
                    Button { setting = true } label: {
                        Text("Set a Chat PIN").frame(maxWidth: .infinity)
                    }
                }
            } header: {
                Text(isSet ? "Your Chat PIN" : "")
            } footer: {
                // "make it can call and message who know the pin" — owner, 2026-09-11. A pin makes
                // the chat accepted, and an accepted chat is what "friend" means for calls too.
                Text("Friends and anyone who knows your Chat PIN can message and call you directly, even when Messages or Calls is set to My Friends. Share it only with people you want to hear from.")
            }

            if isSet {
                Section {
                    Button("Change Chat PIN") { setting = true }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        HStack { Text("Remove Chat PIN"); if removing { Spacer(); ProgressView() } }
                    }
                    .disabled(removing)
                } footer: {
                    // Spec §22: rotating controls NEW access only.
                    Text("Changing or removing your Chat PIN doesn’t remove anyone who already used it. Remove a friend from their profile instead.")
                }
            }

            if !failure.isEmpty {
                Section { Text(failure).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Chat PIN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            // What this phone knows is shown at once; the server's answer refines it. A phone that
            // could not ask keeps what it had rather than flipping to "not set".
            if let set = await ChatPin.refreshStatus() { isSet = set }
            mine = ChatPin.mine
            checking = false
        }
        .sheet(isPresented: $setting) {
            ChatPinSetSheet {
                isSet = true
                mine = ChatPin.mine
                copied = false
                failure = ""
            }
        }
        .alert("Remove your Chat PIN?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nobody will be able to use it to message you. People who already did stay in your chats.")
        }
    }

    private func remove() {
        removing = true
        Task {
            do {
                try await ChatPin.remove()
                isSet = false
                mine = nil
                failure = ""
            } catch {
                failure = error.localizedDescription
            }
            removing = false
        }
    }
}

/// Choosing a pin: the same plate and keypad as entering one, with Save instead of Enter.
struct ChatPinSetSheet: View {
    let onSaved: () -> Void

    /// Spelled out for the reason `ChatPinEntrySheet`'s is.
    init(onSaved: @escaping () -> Void) { self.onSaved = onSaved }

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var failure = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Choose a Chat PIN")
                    .font(.headline)
                    .padding(.top, 26)
                Text("\(ChatPin.minDigits) to \(ChatPin.maxDigits) digits. Anyone who knows it can message and call you directly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                ChatPinDigitsBox(pin: pin)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(height: 20)
                    .padding(.top, 6)
                    .opacity(failure.isEmpty ? 0 : 1)

                ChatPinKeypad(pin: $pin)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
        }
        // ⛔ SAVE IS ANCHORED TO THE SHEET, NOT PARKED AFTER THE KEYPAD — owner, 2026-09-11: "the
        // Save button position is wrong", with the dead band under it circled.
        //
        // ⚠️ IT WAS THE LAST ITEM IN A `ScrollView`'s stack, and this sheet opens at a detent
        // (0.72) taller than its own content. A scroll view lays its content out from the top and
        // leaves whatever is left over BELOW it, so Save came to rest somewhere in the middle of
        // the sheet with an empty band beneath — which reads as a mistake rather than as space.
        //
        // A `safeAreaInset` is the system-positioned place for a sheet's one action: it is pinned to
        // the bottom edge, it keeps clear of the home indicator on its own, the keypad above it
        // scrolls under it when the sheet is dragged to `.large`, and it stays reachable at every
        // detent instead of moving with the content. That is his own distinction — the keypad is app
        // content inside the safe area, the action is edge-attached.
        .safeAreaInset(edge: .bottom) {
            ChatPinSubmitButton(title: "Save", enabled: ChatPin.isValid(pin), busy: busy) { save() }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                // ⚠️ 8, NOT THE OLD 16. A `safeAreaInset` already sits above the home indicator, so
                // the old bottom padding would now be stacked on top of that inset and push the
                // button up off the edge again — the same gap, smaller.
                .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: pin) { _, _ in failure = "" }
    }

    private func save() {
        guard ChatPin.isValid(pin), !busy else { return }
        busy = true
        Task {
            do {
                try await ChatPin.set(pin)
                busy = false
                dismiss()
                onSaved()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}
