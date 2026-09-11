import SwiftUI

// CHAT PIN, THE SCREENS — owner's spec, 2026-09-11, drawn from his four reference screenshots.
//
// Three views and two parts:
//   ChatPinEntrySheet   somebody ELSE's pin — the sheet with the face, "Enter Chat Key", the six
//                       slots, the keypad and the Enter button (his third screenshot).
//   ChatPinPage         MY pin — behind "Chat Key" in the Chats title menu (his first screenshot,
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
    /// ⛔ DEAD WHILE A REQUEST IS IN FLIGHT — audit L6. Only the submit button was disabled, so the
    /// keys stayed live: typing during a verify mutated the value being verified and wiped the
    /// refusal the moment it arrived. A keypad that accepts presses it will not act on is lying.
    var disabled: Bool = false

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
                        .disabled(key.isEmpty || disabled)
                        // The empty slot is invisible; a disabled keypad is visibly resting rather
                        // than gone, so the sheet does not appear to lose its keys mid-request.
                        .opacity(key.isEmpty ? 0 : (disabled ? 0.35 : 1))
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

/// The digits typed so far on a grey plate.
///
/// ⛔ IT NO LONGER DRAWS SIX ZEROES — audit U1. Six placeholder slots said the key is six digits
/// long, which is not true: four is valid and the button enables there, so the plate and the button
/// contradicted each other on every 4- and 5-digit key. A person filling slots believed they had two
/// more to type.
///
/// What it draws now is what has been typed, with the four the key genuinely REQUIRES marked out and
/// the two optional ones appearing only as they are used. The caption under it says the rule in
/// words, which is the honest place for a rule.
struct ChatPinDigitsBox: View {
    let pin: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                // The required four are always shown, so the plate states the minimum rather than
                // the maximum; anything beyond them appears as it is typed.
                ForEach(0..<max(ChatPin.minDigits, pin.count), id: \.self) { i in
                    let filled = i < pin.count
                    Text(filled ? String(pin[pin.index(pin.startIndex, offsetBy: i)]) : "•")
                        .font(.system(size: 26, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(filled ? Color(.label) : Color(.tertiaryLabel))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("\(ChatPin.minDigits) to \(ChatPin.maxDigits) digits")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pin.isEmpty
                            ? "No digits entered, \(ChatPin.minDigits) to \(ChatPin.maxDigits) required"
                            : "\(pin.count) digits entered")
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

/// "Enter @handle's Chat Key to contact them." Verified on the server; on success the conversation
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
    /// This phone's cooldown, latched from the server's refusal — audit U8. Enter is dead until it
    /// passes, and the sheet says so on open rather than after another spent attempt.
    @State private var lockedUntil: Date? = ChatPin.lockedUntil
    /// Ticks once a second ONLY while locked, so the countdown in the sentence stays true without a
    /// timer running on a sheet that is not waiting for anything.
    @State private var now = Date()
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

                Text("Enter Chat Key")
                    .font(.headline)
                    .padding(.top, 18)
                Divider()
                    .padding(.top, 12)
                    .padding(.horizontal, 20)

                (Text("Enter ") + Text(handleText.isEmpty ? name : handleText).fontWeight(.semibold)
                    + Text("’s Chat Key to contact them."))
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

                ChatPinKeypad(pin: $pin, disabled: busy || isLocked)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

            }
        }
        // Anchored exactly as the Choose sheet's Save is, and for the same reason — the full
        // reasoning is written there. The two are one control on two sheets and must not drift.
        .safeAreaInset(edge: .bottom) {
            ChatPinSubmitButton(title: "Enter",
                                enabled: ChatPin.isValid(pin) && !isLocked,
                                busy: busy) { submit() }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        // ⛔ A WAY OUT THAT IS NOT A GUESS — audit U5. The drag indicator was the only dismissal, and
        // a sheet whose whole subject is a secret should not make leaving it the undiscoverable
        // action. The app's own round X, in the app's own place for it.
        .overlay(alignment: .topLeading) {
            CloseXButton { dismiss() }
                .padding(.leading, 12)
                .padding(.top, 12)
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
        // The lock's own clock. Runs only while there IS a lock, and stops the moment it lapses.
        .task(id: lockedUntil) {
            guard let until = lockedUntil else { return }
            failure = ChatPin.lockSentence(until)
            while !Task.isCancelled, Date() < until {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
                if Date() < until { failure = ChatPin.lockSentence(until) }
            }
            guard !Task.isCancelled else { return }
            lockedUntil = nil
            failure = ""
        }
    }

    /// Read through `now` so the view re-evaluates as the countdown ticks.
    private var isLocked: Bool {
        guard let until = lockedUntil else { return false }
        return until > now
    }

    private func submit() {
        guard ChatPin.isValid(pin), !busy, !isLocked else { return }
        busy = true
        // The value being verified is frozen here rather than read inside the Task, so a keypad
        // press that lands in the same turn cannot change what was sent (audit L6's other half).
        let attempt = pin
        Task {
            do {
                let cid = try await ChatPin.verify(uid: uid, pin: attempt)
                busy = false
                // ⛔ THE CALLER RUNS AFTER THE SHEET IS GONE — audit U3. `dismiss()` starts an
                // animation; a push or a cover raised in the same turn fights it, and SwiftUI drops
                // one of the two. The handler is handed to the next runloop turn instead, which is
                // the same rule `MediaPresentGate` exists to enforce for the media viewer.
                dismiss()
                let handoff = onSuccess
                DispatchQueue.main.async { handoff(cid) }
            } catch {
                busy = false
                if let f = error as? ChatPin.Failure, let until = f.lockedUntil { lockedUntil = until }
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

/// Behind "Chat Key" in the Chats title menu and Privacy › Messages. Shows the pin this phone set,
/// with Copy and Share; says "set on another device" when it cannot; offers Set, Change and Remove.
struct ChatPinPage: View {
    @State private var isSet = ChatPin.isSet
    @State private var mine = ChatPin.mine
    @State private var checking = true
    @State private var setting = false
    @State private var confirmRemove = false
    @State private var removing = false
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var failure = ""
    /// When the server says the key was last set. Only ever shown on the branch that cannot show
    /// the key itself — see `L8` on `ChatPin.lastSetAt`.
    @State private var setAt: Date?

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
                                    // ⛔ IT SAYS "Copied" AND THEN STOPS — audit L3. Nothing ever
                                    // set this back, so the button wore a checkmark for the rest of
                                    // the page's life and the next copy gave no feedback at all.
                                    copiedResetTask?.cancel()
                                    copiedResetTask = Task {
                                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                                        guard !Task.isCancelled else { return }
                                        copied = false
                                    }
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity).frame(height: 40)
                                }
                                .buttonStyle(.plain)
                                .background(Color(.secondarySystemFill), in: Capsule())
                                ShareLink(item: "My Chat Key on Fariin is \(mine). Enter it to message me directly.") {
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
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Your Chat Key was set on another device.", systemImage: "iphone")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            // ⛔ THE ONE THING THIS PHONE CAN HONESTLY SAY ABOUT IT — audit L8. The
                            // server has always returned `updatedAt` and nothing read it, so the
                            // branch that cannot show the key said nothing about it at all. A date
                            // is enough to recognise a key you set yourself from one you did not.
                            if let setAt {
                                Text("Set \(setAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else if checking {
                    HStack { Text("Chat Key"); Spacer(); ProgressView() }
                } else {
                    Button { setting = true } label: {
                        Text("Set a Chat Key").frame(maxWidth: .infinity)
                    }
                }
            } header: {
                Text(isSet ? "Your Chat Key" : "")
            } footer: {
                // "make it can call and message who know the pin" — owner, 2026-09-11. A pin makes
                // the chat accepted, and an accepted chat is what "friend" means for calls too.
                Text("Anyone who knows your Chat Key can message and call you directly, whatever your Messages and Calls settings say. Share it only with people you want to hear from.")
            }

            if isSet {
                Section {
                    Button("Change Chat Key") { setting = true }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        HStack { Text("Remove Chat Key"); if removing { Spacer(); ProgressView() } }
                    }
                    .disabled(removing)
                } footer: {
                    // Spec §22: rotating controls NEW access only.
                    Text("Changing or removing your Chat Key doesn’t remove anyone who already used it. Remove a friend from their profile instead.")
                }
            }

            if !failure.isEmpty {
                Section { Text(failure).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Chat Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        // ⛔ EVERY VISIT, NOT THE FIRST — audit L2. `.task` runs once per view lifetime and
        // `@State isSet` is seeded once, so a page SwiftUI had kept alive went on showing what the
        // server said the first time: remove the key on another phone, come back here, and this one
        // still offered to "Change" a key that no longer existed. `onAppear` is the re-entry.
        .task { await refresh() }
        .onAppear { Task { await refresh() } }
        .sheet(isPresented: $setting) {
            ChatPinSetSheet {
                isSet = true
                mine = ChatPin.mine
                setAt = ChatPin.lastSetAt
                copied = false
                failure = ""
            }
        }
        .alert("Remove your Chat Key?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nobody will be able to use it to message you. People who already did stay in your chats.")
        }
    }

    /// What this phone knows is shown at once; the server's answer refines it. A phone that could
    /// not ask keeps what it had rather than flipping to "not set".
    private func refresh() async {
        if let set = await ChatPin.refreshStatus() { isSet = set }
        mine = ChatPin.mine
        setAt = ChatPin.lastSetAt
        checking = false
    }

    private func remove() {
        removing = true
        Task {
            do {
                try await ChatPin.remove()
                isSet = false
                mine = nil
                failure = ""
                // ⛔ AND THE MODE THAT DEPENDED ON IT COMES BACK TO EVERYONE — owner, 2026-09-11,
                // reporting the other half of this: a Messages setting of "People who know my key"
                // with no key is an account nobody new can contact at all. Removing the key here is
                // the one moment we KNOW that has happened, so it is healed at the source rather
                // than left for the privacy page to notice on its next visit (it does that too).
                if PrivacyPrefs.mine("messages") == .contacts {
                    PrivacyPrefs.setMine("messages", .everyone)
                }
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
    // ⛔ NO CONFIRM STEP — owner, 2026-09-11: "revert U6, I don't want the Chat Key to be entered
    // twice. Keep the original flow: the user enters the Chat Key once and saves it directly."
    //
    // The audit's reasoning was that the digits are never echoed while typing, so a slip becomes
    // your key silently. His answer stands on its own: the key IS echoed the moment it is saved —
    // `ChatPinPage` shows it back in full, spaced out, with Copy and Share — so a mistyped key is
    // visible on the very next screen and costs one tap on Change to correct. A second pass buys a
    // check the page already performs.
    //
    // ⚠️ THE REST OF THE AUDIT'S WORK ON THIS SHEET STAYS: the keypad rests while a request is in
    // flight, the saved value is frozen when it is sent, the handoff runs a runloop turn after the
    // dismissal, and there is a way out that is not a guess.

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Choose a Chat Key")
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

                ChatPinKeypad(pin: $pin, disabled: busy)
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
        // The same way out as the entry sheet — see the note there (audit U5).
        .overlay(alignment: .topLeading) {
            CloseXButton { dismiss() }
                .padding(.leading, 12)
                .padding(.top, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: pin) { _, _ in failure = "" }
    }

    private func save() {
        guard ChatPin.isValid(pin), !busy else { return }
        busy = true
        // Frozen here rather than read inside the Task, so a key press landing in the same turn
        // cannot change what is saved — audit L6's other half, which stays.
        let chosen = pin
        Task {
            do {
                try await ChatPin.set(chosen)
                busy = false
                // Handed to the next runloop turn for the reason the entry sheet's is — audit U3.
                dismiss()
                let handoff = onSaved
                DispatchQueue.main.async { handoff() }
            } catch {
                busy = false
                // The typed key stays on screen: it was refused by the server, not mistyped, and
                // clearing it would make the person re-enter something that was already right.
                failure = error.localizedDescription
            }
        }
    }
}
