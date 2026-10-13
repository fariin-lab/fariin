import SwiftUI

/// ⛔ THE FULL SETTINGS, AS A SHEET FROM THE GEAR — owner 2026-10-13 (two reference screenshots): the
/// Settings tab became "you" (photo, Edit profile / Share profile, five shortcuts) and every setting
/// moved behind a gear at its top right. An X, the title, a search bar always showing, then the same
/// sections, rows and destinations the tab used to hold, unchanged.
///
/// The search reads `SettingsIndex`, the list the settings search page already used, so a page found
/// here and a page found there are the same page.
struct SettingsSheet: View {
    var onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    private var admin = AdminStore.shared
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("demoChats") private var demoChats = false
    @State private var showGroupCallDemo = false
    @State private var showScreenShareDemo = false
    @State private var query = ""

    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    results
                } else {
                    sections
                }
            }
            .listSectionSpacing(20)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .overlay {
                if searching, SettingsIndex.matching(query, onSignOut: onSignOut).isEmpty {
                    NoSearchResults(query: query.trimmingCharacters(in: .whitespaces))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    }
                    .tint(.primary)
                    .accessibilityLabel("Close")
                }
            }
            .fullScreenCover(isPresented: $showGroupCallDemo) { DemoGroupCallView() }
            .fullScreenCover(isPresented: $showScreenShareDemo) { ScreenShareDemoView() }
        }
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
    }

    @ViewBuilder private var results: some View {
        ForEach(SettingsIndex.matching(query, onSignOut: onSignOut)) { e in
            NavigationLink { e.dest } label: {
                e.system ? SettingsRowLabel(e.title, system: e.icon) : SettingsRowLabel(e.title, e.icon)
            }
        }
    }

    @ViewBuilder private var sections: some View {
        if AppFeatures.myProfileCard { Section {
            // MY PROFILE, its own card directly under the header (2026-09-11, above).
            // Destination is unchanged: `GlowProfileView` on his OWN uid, the page that
            // already exists for photo, name, handle, bio, the Glow stats card and Posted
            // stories. A second "my profile" screen would be a second place for those to
            // drift.
            NavigationLink {
                GlowProfileView(uid: AuthService.shared.uid ?? "",
                                initialName: profile.me?.name ?? "",
                                initialPhoto: profile.me?.photoUrl)
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                SettingsRowLabel("My Profile", "ic_account")
            }
        } }   // hidden 2026-10-11 — see `AppFeatures.myProfileCard`

        Section {
            // Account is data + session actions only — no profile fields here, they all
            // live above now (see AccountSettingsView's own note, user direction 2026-07-22).
            NavigationLink { AccountSettingsView(onSignOut: onSignOut).toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Account", "ic_account")
            }
            NavigationLink { DevicesView().toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Devices", "ic_linked_devices")
            }
        }

        Section {
            NavigationLink { NotificationsSettingsView().toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Notifications", "ic_notifications")
            }
            NavigationLink { AppearanceSettingsView().toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Appearance", system: "paintbrush")
            }
            // NO App Icon row here: it lives inside Appearance, and one door is enough (user
            // 2026-07-29, after seeing both). Two rows leading to the same page reads as a
            // duplicate, which is what it was.
            NavigationLink { ChatsSettingsView().toolbar(.hidden, for: .tabBar) } label: {
                // ITS OWN OUTLINED DRAWING, not the tab bar's. `ic_chat` is a SOLID bubble
                // because a tab bar icon has to read at 24pt against a selected pill; dropped
                // into this list it was a black blob beside Account, Devices, Notifications
                // and Privacy, which are all outlines. Same family, different weight — and a
                // settings row wants the outline.
                SettingsRowLabel("Chats", "ic_settings_chats")
            }
            NavigationLink { StorySettingsView().toolbar(.hidden, for: .tabBar) } label: {
                // ⛔ HIS NEW MARK, OUTLINE WEIGHT — owner, 2026-09-11, with the SVG. It is
                // the same drawing the tab bar now fills, and the pair is the app's usual
                // rule: a settings row is a place you go, so it takes the outline; the tab
                // you are standing on takes the fill.
                SettingsRowLabel("Stories", "ic_stories_stack")
            }
            NavigationLink { PrivacySettingsView().toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Privacy & Security", "ic_privacy")
            }
            NavigationLink { StorageDataView().toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Storage and Data", system: "externaldrive")
            }
        }

        // THE OFFICIAL CHANNEL'S SENDING SIDE. The whole section is absent unless this
        // account has a row in `admins`, and that is not cosmetic: the Firestore rules refuse
        // every write behind it independently, so a person who found the screen would still
        // be unable to send anything. Hidden here so a normal user never sees a door they
        // cannot open.
        if admin.isAdmin {
            // Off for now: the admin panel moves to a fariin.com subdomain (owner,
            // 2026-09-25). See `Flags.inAppAnnouncementAdmin`.
            if Flags.inAppAnnouncementAdmin {
                Section {
                    NavigationLink { AnnouncementAdminView().toolbar(.hidden, for: .tabBar) } label: {
                        SettingsRowLabel("Official Announcements", system: "megaphone")
                    }
                } footer: {
                    Text(admin.isOwner ? "You are the owner of the Fariin channel."
                                       : "You can send announcements from the Fariin channel.")
                }
            }

            // VERIFICATION, on its own capability. An admin who can send announcements is not
            // thereby somebody who can put the app's name behind a stranger's identity, so
            // this section appears only for `.verify` and the rules check the same thing
            // again before any write lands.
            if Flags.verificationConsole, admin.can(.verify) {
                Section {
                    NavigationLink { VerificationAdminView().toolbar(.hidden, for: .tabBar) } label: {
                        SettingsRowLabel("Verification", system: "checkmark.seal")
                    }
                } footer: {
                    Text("Give, change or withdraw a verified badge. Every decision is recorded permanently.")
                }
            }
        }

        Section {
            // My QR Code lives in the top-left toolbar button — no duplicate row here.
            ShareLink(item: inviteText, preview: InviteShare.preview) { SettingsRowLabel("Invite Friends", "ic_invite_friends") }
            NavigationLink { AboutView().toolbar(.hidden, for: .tabBar) } label: {
                SettingsRowLabel("Help & About", system: "questionmark.circle")
            }
        }

        // TESTFLIGHT AND DEBUG, NEVER THE APP STORE. This is the only demo switch left in
        // Settings: the "Demo story people" one in Story settings, which was gated the same
        // way and for the same reason, was removed on 2026-09-05.
        //
        // Six chats that live only in this phone's memory, added to the list above your
        // real ones so the website screenshots can be taken without signing out of your own
        // account. Nothing is written, nothing is uploaded, and nobody else can see them.
        // They are gone the moment the switch goes off or the app restarts.
        //
        // This is here rather than behind a demo LOGIN because that screen only appears
        // after a real sign-in succeeds, so reaching it meant making a second Apple or
        // Google account first. A switch in your own settings is one tap.
        if DemoMode.isAvailable {
            Section {
                Toggle("Demo chats", isOn: $demoChats).tint(.orange)
                    .onChange(of: demoChats) { _, on in
                        DemoMode.setChats(on)
                        ConversationsRepository.shared.refreshForDemo()
                        // The story row is built by its own repository and would not have
                        // noticed until the next launch, so the switch would have looked
                        // half-broken: chats appear at once, stories only tomorrow.
                        StoriesRepository.shared.refreshForDemo()
                    }
                Button { showGroupCallDemo = true } label: {
                    Label("Group Call Demo", systemImage: "person.3.fill")
                }
                .tint(.orange)
                Button { showScreenShareDemo = true } label: {
                    Label("Screen Share Demo", systemImage: "rectangle.on.rectangle")
                }
                .tint(.orange)
            } footer: {
                Text("Testers only. Adds seven local chats to your list and two people to the story row, for taking screenshots. They are made on this device, never uploaded, and nobody else can see them. Your own chats and your own story are not touched.")
            }
        }
    }
}
