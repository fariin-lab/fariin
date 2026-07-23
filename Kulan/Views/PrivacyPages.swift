import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// The privacy audience system (user's reference, 2026-07-24). Each privacy item opens a
// page with Everyone / My Contacts / No One. "My Contacts" means people you share a chat
// with — Kulan never reads the phone book, so chats ARE the contact list. Choices are
// mirrored locally AND published to users/{me}.privacy so OTHER clients can honor them
// (their app hides your photo/bio/presence from non-qualified viewers; calls from
// non-qualified callers are declined by your device).

enum Audience: String, CaseIterable {
    case everyone, contacts, nobody
    var label: String {
        switch self {
        case .everyone: return "Everyone"
        case .contacts: return "My Contacts"
        case .nobody:   return "No One"
        }
    }
}

enum PrivacyPrefs {
    /// My audience for a key ("lastSeen", "photo", "bio", "calls", "groups").
    static func mine(_ key: String) -> Audience {
        Audience(rawValue: UserDefaults.standard.string(forKey: "priv.\(key)") ?? "") ?? .everyone
    }

    static func setMine(_ key: String, _ a: Audience) {
        UserDefaults.standard.set(a.rawValue, forKey: "priv.\(key)")
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Task {
            try? await Firestore.firestore().collection("users").document(uid)
                .setData(["privacy": [key: a.rawValue]], merge: true)
        }
    }

    /// Does someone whose privacy map says `audience` for a field allow ME to see it?
    /// qualified = I share a conversation with them.
    static func allows(_ privacy: [String: String], _ key: String, contactOfMine: Bool) -> Bool {
        switch Audience(rawValue: privacy[key] ?? "") ?? .everyone {
        case .everyone: return true
        case .contacts: return contactOfMine
        case .nobody:   return false
        }
    }

    /// Do I share a 1:1 conversation with this uid? (= they are "my contact")
    static func isContact(_ uid: String) -> Bool {
        let me = Auth.auth().currentUser?.uid ?? ""
        guard !me.isEmpty, !uid.isEmpty else { return false }
        return ConversationsRepository.shared.conversations.contains {
            !$0.isGroup && $0.users.contains(uid) && !$0.lastMessageCipher.isEmpty
        }
    }
}

// One audience page: Everyone / My Contacts / No One with a checkmark (reference layout).
struct AudiencePage: View {
    let title: String
    let key: String
    let footer: String
    @State private var selection: Audience

    init(title: String, key: String, footer: String) {
        self.title = title
        self.key = key
        self.footer = footer
        _selection = State(initialValue: PrivacyPrefs.mine(key))
    }

    var body: some View {
        List {
            Section {
                ForEach(Audience.allCases, id: \.self) { a in
                    Button {
                        selection = a
                        PrivacyPrefs.setMine(key, a)
                        if key == "lastSeen" { Task { await PresenceService.set(online: true) } }
                    } label: {
                        HStack {
                            Text(a.label).foregroundStyle(.primary)
                            Spacer()
                            if selection == a {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// App Lock as its own page (reference: "App lock >" row on the main privacy page).
struct AppLockPage: View {
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("appLockDelay") private var lockDelay = 0
    @AppStorage("screenSecurity") private var screenSecurity = false

    var body: some View {
        List {
            Section {
                Toggle("App Lock", isOn: $appLock).tint(.green)
                if appLock {
                    Picker("Auto-Lock", selection: $lockDelay) {
                        Text("Immediately").tag(0)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                        Text("After 1 hour").tag(3600)
                    }
                }
            } footer: {
                Text("Require Face ID or your passcode to unlock Kulan.")
            }
            Section {
                Toggle("Screen Security", isOn: $screenSecurity).tint(.green)
            } footer: {
                Text("Hides the app preview in the multitasking switcher.")
            }
        }
        .navigationTitle("App Lock")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Messages page: the two REAL reciprocal message signals. ("Who can message you" needs
// the message-requests system — it is deliberately absent rather than decorative.)
struct MessagesPrivacyPage: View {
    @AppStorage("readReceipts") private var readReceipts = true
    @AppStorage("typingIndicators") private var typingIndicators = true

    var body: some View {
        List {
            Section {
                Toggle("Read Receipts", isOn: $readReceipts).tint(.green)
                Toggle("Typing Indicators", isOn: $typingIndicators).tint(.green)
            } footer: {
                Text("These are reciprocal — if you turn one off, you won't see it from others either.")
            }
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
    }
}
