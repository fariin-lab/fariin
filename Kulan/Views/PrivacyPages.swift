import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// The privacy audience system (user's reference, 2026-07-24). Each privacy item opens a
// page with Everyone / My Friends / No One.
//
// "MY FRIENDS", NOT "MY CONTACTS" (renamed 2026-07-29). The word contacts promises the phone book,
// and Fariin has never read it — there are no phone numbers in this app at all. What it actually
// means is "people I share a chat with", and calling those friends is both true and the only
// reading a user can arrive at without being told. Choices are
// mirrored locally AND published to users/{me}.privacy so OTHER clients can honor them
// (their app hides your photo/bio/presence from non-qualified viewers; calls from
// non-qualified callers are declined by your device).

enum Audience: String, CaseIterable {
    case everyone, contacts, nobody
    var label: String {
        switch self {
        case .everyone: return "Everyone"
        case .contacts: return "My Friends"
        case .nobody:   return "No One"
        }
    }
}

enum PrivacyPrefs {
    /// My audience for a key ("lastSeen", "photo", "bio", "calls", "groups").
    /// CALLS DEFAULT TO MY FRIENDS (owner 2026-08-04); everything else still defaults to Everyone.
    /// A stranger being able to make your phone ring is a different kind of exposure from a stranger
    /// reading your bio, and the default is what almost everyone will live with.
    static func defaultAudience(for key: String) -> Audience { key == "calls" ? .contacts : .everyone }

    static func mine(_ key: String) -> Audience {
        Audience(rawValue: UserDefaults.standard.string(forKey: "priv.\(key)") ?? "") ?? defaultAudience(for: key)
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

/// Which header every profile draws. Modern is the app's layout; the classic circle stays for
/// anyone who prefers it, which is why nothing about the old hero was deleted to build the new one.
///
/// Each row carries a small drawing of the layout it names, because "Modern Header" and "Classic
/// Circle Profile" are our words for it and a picture says it without them.
struct ProfileLayoutPage: View {
    @AppStorage(ProfileLayoutStyle.storageKey) private var layout = ProfileLayoutStyle.modern.rawValue

    var body: some View {
        List {
            Section {
                ForEach(ProfileLayoutStyle.allCases) { style in
                    Button {
                        layout = style.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            sketch(style)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.label).foregroundStyle(.primary)
                                Text(style.blurb).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if layout == style.rawValue {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("Someone with no profile photo always uses the classic circle, so there is never an empty header.")
            }
        }
        .navigationTitle("Profile Layout")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A 34×46 miniature of the page: a filled top block for the poster, a small circle for the
    /// classic hero, then two lines standing in for the name and the handle.
    private func sketch(_ style: ProfileLayoutStyle) -> some View {
        VStack(spacing: 3) {
            if style == .modern {
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.75))
                    .frame(width: 34, height: 24)
            } else {
                Circle().fill(Color.accentColor.opacity(0.75)).frame(width: 15, height: 15)
                    .frame(height: 24)
            }
            Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 22, height: 3)
            Capsule().fill(Color.secondary.opacity(0.28)).frame(width: 14, height: 3)
        }
        .frame(width: 34, height: 46)
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
                Text("Require Face ID or your passcode to unlock Fariin.")
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

// Messages page: WHO can message you (audience) + the reciprocal read/typing signals.
// "My Contacts" = people you already share a chat with. Enforced on the SENDER's client:
// their composer is disabled if you don't accept messages from them (see ThreadView).
struct MessagesPrivacyPage: View {
    @AppStorage("priv.messages") private var privMessages = "everyone"
    @AppStorage("readReceipts") private var readReceipts = true
    @AppStorage("typingIndicators") private var typingIndicators = true

    var body: some View {
        List {
            Section {
                ForEach(Audience.allCases, id: \.self) { a in
                    Button {
                        privMessages = a.rawValue
                        PrivacyPrefs.setMine("messages", a)
                    } label: {
                        HStack {
                            Text(a.label).foregroundStyle(.primary)
                            Spacer()
                            if privMessages == a.rawValue {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("Who can message you")
            } footer: {
                Text("People who can't message you won't be able to start a new chat. Chats you already have keep working.")
            }

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
