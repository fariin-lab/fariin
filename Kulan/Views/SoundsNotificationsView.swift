import SwiftUI
import UniformTypeIdentifiers
import FirebaseFirestore

// Full-screen "Sounds & Notifications" for a chat (full-page style), pushed from the profile.
// Sections: Message Sound + Call Sound (each opens a real sound picker) and Mute.
struct SoundsNotificationsView: View {
    let cid: String
    @Environment(\.colorScheme) private var scheme

    // Each kind has its OWN default: a message tone is a short blip, a ringtone is a looping
    // phrase. Both used to start as `.default`, which is an Apple alert tone and wrong for both.
    @State private var messageSound = NotificationSound.defaultMessageTone
    @State private var callSound = NotificationSound.defaultRingtone
    @State private var muted = false
    @State private var picker: SoundStore.Kind?

    private var dark: Bool { scheme == .dark }
    // Native grouped-list colors, matching the profile page: white card in light mode
    // (0x1C1C1E in dark) sitting on a grey/black grouped-background page, like Settings.
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var pageBackground: Color { Color(uiColor: .systemGroupedBackground) }
    private var muteLabel: String { muted ? "Muted" : "Not muted" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row("Message Sound", "ic_sound_message", value: messageSound.name) { picker = .message }
                Divider().padding(.leading, 56)
                // ⛔ HIDDEN ON HIS ORDER, 2026-08-21, and the divider goes with it or the list ends
                // on a line under nothing. The picker, the seven tones and the per-chat storage are
                // all still here — `SoundStore.callSoundPickerEnabled` is the one switch, and while
                // it is off every call rings the phone's own ringtone.
                if SoundStore.callSoundPickerEnabled {
                    row("Call Sound", "ic_sound_call", value: callSound.name) { picker = .call }
                    Divider().padding(.leading, 56)
                }
                // Native dropdown Menu (real Apple context menu), not a popover dialog.
                Menu {
                    if muted { Button("Unmute") { setMute(0) } }
                    Button("1 hour")  { setMute(ChatService.muteUntil(1)) }
                    Button("8 hours") { setMute(ChatService.muteUntil(8)) }
                    Button("1 day")   { setMute(ChatService.muteUntil(24)) }
                    Button("1 week")  { setMute(ChatService.muteUntil(168)) }
                    Button("Always")  { setMute(ChatService.muteUntil(nil)) }
                } label: {
                    rowLabel("Mute", "ic_sound_mute", muteLabel)
                }
                .tint(.primary)
            }
            .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(16)
        }
        .background(pageBackground.ignoresSafeArea())   // grouped-list page so the white card pops, like Settings
        .navigationTitle("Sounds & Notifications")
        .navigationBarTitleDisplayMode(.inline)
        // Follows the phone. A pushed screen inherits the bar's appearance from whoever pushed it,
        // and the profile page forces its bar dark — see the note in `MediaGalleryView`.
        .toolbarColorScheme(nil, for: .navigationBar)
        .task { reload(); await loadMute() }
        .sheet(item: $picker) { kind in
            SoundPickerView(cid: cid, kind: kind,
                            title: kind == .message ? "Message Sound" : "Call Sound") { reload() }
        }
    }

    private func row(_ title: String, _ icon: String, value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, icon, value) }.buttonStyle(.plain)
    }

    // The shared row visual — used by the Button rows AND the native Mute Menu.
    private func rowLabel(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            // "ic_" names one of our own drawings; anything else is an SF Symbol.
            Group {
                if icon.hasPrefix("ic_") {
                    Image(icon).renderingMode(.template).resizable().scaledToFit().frame(width: 21, height: 21)
                } else {
                    Image(systemName: icon).font(.system(size: 17))
                }
            }
            .frame(width: 26).foregroundStyle(.primary)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func reload() {
        messageSound = SoundStore.sound(cid, .message)
        callSound = SoundStore.sound(cid, .call)
    }
    private func loadMute() async {
        let me = AuthService.shared.uid ?? ""
        if let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument(),
           let until = ((snap.data()?["mutedBy"] as? [String: Any])?[me] as? NSNumber)?.doubleValue {
            muted = until > Date().timeIntervalSince1970 * 1000
        }
    }
    private func setMute(_ until: Double) {
        muted = until > Date().timeIntervalSince1970 * 1000
        Task { await ChatService.setMute(cid, until: until) }
    }
}

// The sound picker sheet: None + the app's own tones, tap to preview. No custom import: every sound
// ships with the app, so a call tone is always a bundle file CallKit can actually play.
// X cancels, checkmark commits the highlighted sound.
struct SoundPickerView: View {
    let cid: String
    let kind: SoundStore.Kind
    let title: String
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String

    init(cid: String, kind: SoundStore.Kind, title: String, onDone: @escaping () -> Void) {
        self.cid = cid; self.kind = kind; self.title = title; self.onDone = onDone
        // Resolve the STORED id to one this list actually contains, or an old value (a "default"
        // from when Apple's Note was offered) ticks nothing and the screen looks unset. A stored
        // "none" on a CALL resolves to "system": that row never muted anything, it handed the ring
        // to iOS, and this is where it picks up its honest name.
        let stored = SoundStore.soundId(cid, kind)
        _selectedId = State(initialValue: kind == .call
            ? NotificationSound.resolveRingtone(stored).id
            : (stored == "none" ? "none" : NotificationSound.resolveMessageTone(stored).id))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // FIRST ROW. For a call it is the phone's own ringtone (Reflection, Buoyant,
                    // Pond, whatever they picked in iOS Settings) — the only route to one of Apple's
                    // tones, because CallKit will only name a file inside our bundle. For a message
                    // it is real silence. See `NotificationSound.systemRingtone` for the whole
                    // reason there is one row here and not a list of seven.
                    soundRow(kind == .call ? .systemRingtone : .none)
                    // Calls get REAL ringtones (long, looping, melodic); messages get our own bundled tones -
                    // the SAME list Settings > Notifications > Sound shows, so the two screens finally agree.
                    // They used to disagree completely: Settings offered these files while this picker offered
                    // Apple's system alert tones, so a per-chat choice could never match what a push played.
                    ForEach(kind == .call ? NotificationSound.ringtones : NotificationSound.messageTones) { soundRow($0) }
                } footer: {
                    // Says it on the screen rather than leaving somebody to wonder why their
                    // ringtone is not in the list.
                    if kind == .call {
                        Text("iPhone Ringtone plays whatever you have chosen in Settings > Sounds & Haptics. Apple's ringtones can only be used that way, so they cannot be listed here one by one.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commit() } label: { Image(systemName: "checkmark").font(.headline) }
                }
            }
        }
    }

    private func soundRow(_ s: NotificationSound) -> some View {
        Button {
            selectedId = s.id
            // Preview: a ringtone previews as a single pass (looping it would trap the user in a ring).
            SoundPlayer.shared.play(s)
        } label: {
            HStack {
                Text(s.name).foregroundStyle(.primary)
                Spacer()
                if selectedId == s.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            // The WHOLE ROW is the target. Without this the hit area collapsed onto the label's own
            // content - the name text and the checkmark - so tapping the empty middle of a row did
            // nothing and the list felt broken (user report).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        // Custom imported sounds are gone on purpose: only tones that ship with the app, so every sound
        // is one we control and a call tone is always a file CallKit can actually play from the bundle.
        // A CALL id always goes through resolveRingtone, which is what turns an old stored "none"
        // into `systemRingtone`. Only a message can actually be silent.
        let s: NotificationSound = kind == .call
            ? NotificationSound.resolveRingtone(selectedId)
            : (selectedId == "none" ? .none : NotificationSound.resolveMessageTone(selectedId))
        SoundStore.set(cid, kind, s)
        onDone(); dismiss()
    }
}
