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
    @State private var mutedUntil: Double = 0   // ms
    private var isGroup: Bool { !cid.contains("_") && !OfficialChannel.isOfficial(cid) }
    private var isChannel: Bool { ConversationsRepository.shared.conversations.first { $0.id == cid }?.isChannel == true }
    /// "Off", "Always", "Until 3:40 PM", or "Until Tue 3:40 PM" past today.
    private var muteLabel: String {
        guard muted else { return "Off" }
        if mutedUntil >= 9_000_000_000_000 || mutedUntil == 0 { return "Always" }
        let d = Date(timeIntervalSince1970: mutedUntil / 1000)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jmm" : "EEEjmm")
        return "Until \(f.string(from: d))"
    }

    private func heading(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }
    private func footnote(_ t: String) -> some View {
        Text(t).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
    }

    var body: some View {
        // ⛔ TWO HEADED CARDS (owner 2026-10-19, from the reference app's page): what you mute is
        // named by the heading over it. Messages: Mute (with when it ends) and the sound. Calls: the
        // ring tone, only while the call-sound picker is on (hidden on his order 2026-08-21).
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                heading(isChannel ? "Posts by other admins" : "Messages")
                VStack(spacing: 0) {
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
                    Divider().padding(.leading, 56)
                    row("Message Sound", "ic_sound_message", value: messageSound.name) { picker = .message }
                }
                .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                // True of the server (onNewMessage): a mention of you still comes through a mute.
                if isChannel && ChannelFollows.shared.follows(cid) {
                    footnote("While this channel is muted, new posts come in without a sound or alert.")
                } else if isChannel {
                    // A channel's admins are told about each other's posts; nobody is told when someone follows.
                    footnote("This only mutes posts by the other admins. It changes nothing for your followers.")
                } else if isGroup {
                    footnote("While this group is muted, you're still told when someone mentions you.")
                }

                if SoundStore.callSoundPickerEnabled {
                    heading("Calls").padding(.top, 16)
                    VStack(spacing: 0) {
                        row("Call Sound", "ic_sound_call", value: callSound.name) { picker = .call }
                    }
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
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
        // Audit 2026-09-24: `setMute` keeps the official channel's mute on this device, not on the
        // conversation document, but this read only asked the document — so a muted Fariin channel
        // still said "Not muted" here.
        if OfficialChannel.isOfficial(cid) { muted = OfficialChannelStore.shared.state.isMutedNow; return }
        // A channel I follow (2026-10-29): the mute is on my own entry, not the channel's document.
        if let e = ChannelFollows.shared.entry(cid) {
            muted = e.isMuted
            // The page's "Always" test reads a far-future end; a follower's always is 0.
            mutedUntil = e.isMuted ? (e.mutedUntil > 0 ? e.mutedUntil : 9_999_999_999_999) : 0
            return
        }
        let me = AuthService.shared.uid ?? ""
        if let snap = try? await FirestoreHub.db.collection("conversations").document(cid).getDocument(),
           let until = ((snap.data()?["mutedBy"] as? [String: Any])?[me] as? NSNumber)?.doubleValue {
            muted = until > Date().timeIntervalSince1970 * 1000
            mutedUntil = until
        }
    }
    private func setMute(_ until: Double) {
        let was = (muted, mutedUntil)
        muted = until > Date().timeIntervalSince1970 * 1000
        mutedUntil = until
        // A refused write puts the label back (2026-10-19 fix round): it said "Muted" for a mute
        // the server never took.
        Task {
            let ok = await ChatService.setMute(cid, until: until)
            // A newer choice since: that one's own result rules.
            guard !ok, mutedUntil == until else { return }
            muted = was.0
            mutedUntil = was.1
        }
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
                        Text("iPhone Ringtone uses the ringtone set in iPhone Settings > Sounds & Haptics.")
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
                if selectedId == s.id { Image(systemName: "checkmark").foregroundStyle(Color.fariinAction) }
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
