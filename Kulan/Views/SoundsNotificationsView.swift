import SwiftUI
import UniformTypeIdentifiers
import FirebaseFirestore

// Full-screen "Sounds & Notifications" for a chat (Telegram-style), pushed from the profile.
// Sections: Message Sound + Call Sound (each opens a real sound picker) and Mute.
struct SoundsNotificationsView: View {
    let cid: String
    @Environment(\.colorScheme) private var scheme

    @State private var messageSound = NotificationSound.default
    @State private var callSound = NotificationSound.default
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
                row("Message Sound", "speaker.wave.2", value: messageSound.name) { picker = .message }
                Divider().padding(.leading, 56)
                row("Call Sound", "phone", value: callSound.name) { picker = .call }
                Divider().padding(.leading, 56)
                // Native dropdown Menu (real Apple context menu), not a popover dialog.
                Menu {
                    if muted { Button("Unmute") { setMute(0) } }
                    Button("1 hour")  { setMute(ChatService.muteUntil(1)) }
                    Button("8 hours") { setMute(ChatService.muteUntil(8)) }
                    Button("1 day")   { setMute(ChatService.muteUntil(24)) }
                    Button("1 week")  { setMute(ChatService.muteUntil(168)) }
                    Button("Always")  { setMute(ChatService.muteUntil(nil)) }
                } label: {
                    rowLabel("Mute", "bell.slash", muteLabel)
                }
                .tint(.primary)
            }
            .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(16)
        }
        .background(pageBackground.ignoresSafeArea())   // grouped-list page so the white card pops, like Settings
        .navigationTitle("Sounds & Notifications")
        .navigationBarTitleDisplayMode(.inline)
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
            Image(systemName: icon).font(.system(size: 17)).frame(width: 26).foregroundStyle(.primary)
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

// The sound picker sheet: None + real built-in tones (tap to preview) + any custom sound + import.
// X cancels, checkmark commits the highlighted sound.
struct SoundPickerView: View {
    let cid: String
    let kind: SoundStore.Kind
    let title: String
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String
    @State private var custom: NotificationSound?     // an imported sound (kept selectable)
    @State private var showImporter = false

    init(cid: String, kind: SoundStore.Kind, title: String, onDone: @escaping () -> Void) {
        self.cid = cid; self.kind = kind; self.title = title; self.onDone = onDone
        let id = SoundStore.soundId(cid, kind)
        _selectedId = State(initialValue: id)
        if id.hasPrefix("custom:") { _custom = State(initialValue: NotificationSound.resolve(id)) }
    }

    var body: some View {
        NavigationStack {
            List {
                soundRow(.none)
                ForEach(NotificationSound.builtIn) { soundRow($0) }
                if let c = custom { soundRow(c) }
                Button { showImporter = true } label: {
                    HStack {
                        Text("Add custom sound…").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
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
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first, let path = SoundStore.importCustom(from: url) {
                    let s = NotificationSound.resolve("custom:\(path)")
                    custom = s; selectedId = s.id
                    SoundPlayer.shared.play(s)
                }
            }
        }
    }

    private func soundRow(_ s: NotificationSound) -> some View {
        Button {
            selectedId = s.id
            SoundPlayer.shared.play(s)   // preview on tap
        } label: {
            HStack {
                Text(s.name).foregroundStyle(.primary)
                Spacer()
                if selectedId == s.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let s: NotificationSound = selectedId == "none" ? .none
            : (custom?.id == selectedId ? custom! : NotificationSound.resolve(selectedId))
        SoundStore.set(cid, kind, s)
        onDone(); dismiss()
    }
}
