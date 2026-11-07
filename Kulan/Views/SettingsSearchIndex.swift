import SwiftUI

// MARK: - Settings search index

/// ⛔ EVERY SETTING, NOT JUST EVERY CARD — owner 2026-11-05: "Wallpaper", "App Icon", "In-App
/// Preview", "Read Receipts" found nothing, because the index only listed the Settings cards. This
/// is one list of every page AND every row, toggle and button inside them, each with the path of
/// pages that leads to it, the words people type for it, and where a tap goes (the page that holds
/// it). Used by the Settings page's own search and by the app-wide search's Settings tab, so the
/// two never disagree.
///
/// ⚠️ A ROW THAT A PAGE HIDES IS NOT INDEXED. Each gate below is the same test the page uses
/// (admin, remote flags, the Chat Key switch, stories opted out). When a page gains a condition,
/// copy it here, or search will offer a row that is not there.
@MainActor
enum SettingsIndex {
    enum Open {
        /// Pushed onto the search's navigation stack.
        case page(@MainActor () -> AnyView)
        /// Done in place (share sheet, web page), as the Settings row itself does.
        case action(@MainActor () -> Void)
    }

    struct Entry: Identifiable {
        let title: String
        /// The pages that lead to it, Settings first and Settings itself left out. Empty for a card
        /// on the Settings page.
        let path: [String]
        let keywords: String
        var icon: String = ""
        /// true = an SF Symbol, false = one of the app's own icon assets (same as SettingsRowLabel).
        var system = false
        /// A page of its own (listed while the field is empty), rather than a row inside one.
        var isPage = false
        let open: Open

        var id: String { (path + [title]).joined(separator: "\u{203A}") }
        /// "Appearance › Chat Wallpaper", shown under the title.
        var breadcrumb: String? { path.isEmpty ? nil : path.joined(separator: " \u{203A} ") }
    }

    // Page names exactly as their navigation titles read.
    private static let account = "Account"
    private static let devices = "Devices"
    private static let notifications = "Notifications"
    private static let appearance = "Appearance"
    private static let chats = "Chats"
    private static let stories = "Stories"
    private static let privacy = "Privacy & Security"
    private static let storage = "Storage and Data"
    private static let help = "Help & About"

    static func entries(onSignOut: @escaping () -> Void) -> [Entry] {
        var out: [Entry] = []

        func card<V: View>(_ title: String, _ icon: String, system: Bool = false, _ kw: String,
                           _ dest: @escaping @MainActor () -> V) {
            out.append(Entry(title: title, path: [], keywords: kw, icon: icon, system: system,
                             isPage: true, open: .page({ AnyView(dest()) })))
        }
        func page<V: View>(_ title: String, _ path: [String], _ kw: String,
                           _ dest: @escaping @MainActor () -> V) {
            out.append(Entry(title: title, path: path, keywords: kw, isPage: true,
                             open: .page({ AnyView(dest()) })))
        }
        /// A row, toggle or button: opens the page it sits on.
        func row<V: View>(_ title: String, _ path: [String], _ kw: String,
                          _ dest: @escaping @MainActor () -> V) {
            out.append(Entry(title: title, path: path, keywords: kw, open: .page({ AnyView(dest()) })))
        }
        func action(_ title: String, _ icon: String, system: Bool = false, _ kw: String,
                    _ run: @escaping @MainActor () -> Void) {
            out.append(Entry(title: title, path: [], keywords: kw, icon: icon, system: system,
                             open: .action(run)))
        }

        let admin = AdminStore.shared
        let chatKeyVisible = MsgPolicy.shared.chatKeyVisible

        // ── The Settings page's cards, in its order ─────────────────────────────────────────
        if ProfileStore.shared.me?.handle.lowercased() == "v" {
            card("Subscriptions", "star.circle", system: true, "subscription premium plan pay") { SubscriptionsView() }
        }
        if AppFeatures.myProfileCard {
            card("My Profile", "ic_account", "profile bio photo edit stories") { MyProfileView() }
        }
        card(account, "ic_account", "account email password username sign in sign out log out delete") {
            AccountSettingsView(onSignOut: onSignOut)
        }
        card(devices, "ic_linked_devices", "devices sessions linked signed in log out sign out") { DevicesView() }
        card(notifications, "ic_notifications", "notifications push alerts sound vibrate preview") { NotificationsSettingsView() }
        card(appearance, "paintbrush", system: true, "appearance theme dark mode light mode night colors look") {
            AppearanceSettingsView()
        }
        card(chats, "ic_settings_chats", "chats messages save to photos camera roll history") { ChatsSettingsView() }
        card(stories, "ic_stories_stack", "stories status story audience who can see") { StorySettingsView() }
        card(privacy, "ic_privacy", "privacy security who can see last seen blocked app lock") { PrivacySettingsView() }
        card(storage, "externaldrive", system: true, "storage data cache download network usage media") { StorageDataView() }
        if admin.isAdmin, Flags.inAppAnnouncementAdmin {
            card("Official Announcements", "megaphone", system: true, "announcements admin broadcast official channel") {
                AnnouncementAdminView()
            }
        }
        if admin.isAdmin, Flags.verificationConsole, admin.can(.verify) {
            card("Verification", "checkmark.seal", system: true, "verification verified badge admin") { VerificationAdminView() }
        }
        action("Invite Friends", "ic_invite_friends", "invite friends share app link tell") { InviteShare.present() }
        action("Safety", "checkmark.shield", system: true, "safety tips help abuse") {
            if let u = URL(string: "https://fariin.com/safety") { WebLink.open(u) }
        }
        card(help, "questionmark.circle", system: true, "help about version support faq") { AboutView() }

        // ── Account ─────────────────────────────────────────────────────────────────────────
        let acc = [account]
        page("Email address", acc, "email address change mail sign in") { ChangeEmailView() }
        // The Password row shows only when this account can have a typable password.
        if AuthService.shared.passwordAddress != nil || AuthService.shared.hasTypableAddress {
            row("Password", acc, "password change set sign in") { AccountSettingsView(onSignOut: onSignOut) }
        }
        page("Username", acc, "username handle @ who can find me contact me") {
            MessagesPrivacyPage(usernameMode: true)
        }
        page("Passkeys", acc, "passkeys passkey face id sign in key") { PasskeysView() }
        if Flags.twoStepEnabled {
            page("Two-step verification", acc, "two step twostep verification 2fa additional password code security") {
                TwoStepVerificationView()
            }
        }
        page("Security notifications", acc, "security notifications alerts new login sign in email") {
            SecurityNotificationsView()
        }
        row("Sign-in alerts", acc + ["Security notifications"], "sign in alerts new login email security") {
            SecurityNotificationsView()
        }
        row("Your Account Data", acc, "export download account data copy text file") { AccountSettingsView(onSignOut: onSignOut) }
        row("Log out", acc, "log out sign out logout signout exit") { AccountSettingsView(onSignOut: onSignOut) }
        row("Delete Account", acc, "delete account remove close erase") { AccountSettingsView(onSignOut: onSignOut) }

        // ── Devices ─────────────────────────────────────────────────────────────────────────
        let dev = [devices]
        row("Sign out all other devices", dev, "sign out log out other devices sessions terminate") { DevicesView() }
        row("Automatic sign-out", dev, "automatic sign out after inactive days devices") { DevicesView() }

        // ── Notifications ───────────────────────────────────────────────────────────────────
        let notif = [notifications]
        row("Show Notifications", notif, "show notifications push on off alerts") { NotificationsSettingsView() }
        row("Message Preview", notif, "message preview text lock screen banner content") { NotificationsSettingsView() }
        page("Sound", notif, "notification sound message tone ringtone tone alert") { NotificationSoundView() }
        row("In-App Sounds", notif, "in app sounds sound while open") { NotificationsSettingsView() }
        row("In-App Vibrate", notif, "in app vibrate vibration haptic") { NotificationsSettingsView() }
        row("In-App Preview", notif, "in app preview banner sender message while open") { NotificationsSettingsView() }
        row("Sound When Sent", notif, "sound when sent sent sound outgoing tone") { NotificationsSettingsView() }
        row("Reset All Notifications", notif, "reset all notifications muted chats sounds default") { NotificationsSettingsView() }

        // ── Appearance ──────────────────────────────────────────────────────────────────────
        let ap = [appearance]
        row("Chat Theme", ap, "chat theme themes colors preview dark light") { AppearanceSettingsView() }
        page("Chat Wallpaper", ap, "wallpaper background photo image presets chat background") { ChatWallpaperPage() }
        page("Wallpaper Color", ap + ["Chat Wallpaper"], "wallpaper color colour solid background") { WallpaperColorPage() }
        // Chat Color lives in Bubble Styles now (owner 2026-11-07), so its words lead there.
        if BubbleStyles.shown { page("Bubble Styles", ap, "chat color colour accent message color bubble styles cute aesthetic pink lavender peach mint cotton candy heart kawaii glass plus picture anime gen z cute careers sport everyday") { BubbleStylesPage() } }
        page("App Icon", ap, "app icon home screen icon alternate logo") { AppIconPage() }
        page("Quick Reaction", ap, "quick reaction double tap emoji react heart like") { QuickReactionPage() }
        page("Night Mode", ap, "night mode dark mode light mode theme system appearance") { NightModePage() }

        // ── Chats ───────────────────────────────────────────────────────────────────────────
        let ch = [chats]
        if chatKeyVisible {
            page("Chat Key", ch, "chat key pin number code private contact me") { ChatPinPage() }
        }
        row("Save to Photos", ch, "save to photos camera roll gallery auto save media") { ChatsSettingsView() }
        row("Link Previews", ch, "link previews url card website") { ChatsSettingsView() }
        row("Automatically Archive", ch, "automatically archive archived new chats chat key muted") { ChatsSettingsView() }
        row("Clear Chat History", ch, "clear chat history delete everything all messages erase") { ChatsSettingsView() }

        // ── Stories (the page hides its rows when stories are switched off) ─────────────────
        if !UserDefaults.standard.bool(forKey: "storiesOptedOut") {
            let st = [stories]
            for a in StoryAudienceStore.shared.all {
                let kw = "story audience who can see stories list"
                // The same four doors the Stories page uses, in the same order of tests.
                if a.kind == .everyone {
                    page(a.name, st, kw + " everyone public") { EveryonePrivacyView() }
                } else if a.kind == .myFriends {
                    page(a.name, st, kw + " my friends chats") { MyFriendsPrivacyView() }
                } else if a.kind == .glowers {
                    page(a.name, st, kw + " glowers glow") { GlowersPrivacyView() }
                } else {
                    let id = a.id
                    page(a.name, st, kw + " custom list") { CustomStoryDetailView(audienceId: id) }
                }
            }
            row("View Receipts", st, "view receipts story views seen viewers") { StorySettingsView() }
        }

        // ── Privacy & Security ──────────────────────────────────────────────────────────────
        let pr = [privacy]
        let audienceKw = "who can see everyone my chats nobody privacy"
        page("Last seen & online", pr, "last seen online status presence " + audienceKw) {
            AudiencePage(title: "Last seen & online", key: "lastSeen", footer: PrivacySettingsView.audienceFooter("lastSeen"))
        }
        page("Profile photo", pr, "profile photo picture avatar " + audienceKw) {
            AudiencePage(title: "Profile photo", key: "photo", footer: PrivacySettingsView.audienceFooter("photo"))
        }
        page("Hide From", pr + ["Profile photo"], "hide from exceptions profile photo people") { HideFromPage() }
        page("Bio", pr, "bio about description " + audienceKw) {
            AudiencePage(title: "Bio", key: "bio", footer: PrivacySettingsView.audienceFooter("bio"))
        }
        if Flags.groupsEnabled {
            page("Groups & Channels", pr, "groups channels add me invite " + audienceKw) {
                AudiencePage(title: "Groups & Channels", key: "groups", footer: PrivacySettingsView.audienceFooter("groups"))
            }
        }
        page("Messages", pr, "messages who can message me new people requests " + audienceKw) { MessagesPrivacyPage() }
        row("Read Receipts", pr + ["Messages"], "read receipts blue ticks seen checks") { MessagesPrivacyPage() }
        row("Typing Indicators", pr + ["Messages"], "typing indicators is typing") { MessagesPrivacyPage() }
        page("Calls", pr, "calls who can call me voice video " + audienceKw) {
            AudiencePage(title: "Calls", key: "calls", footer: PrivacySettingsView.audienceFooter("calls"))
        }
        page("Blocked Users", pr, "blocked block users blocklist unblock") { BlockedUsersView() }
        row("Block User", pr + ["Blocked Users"], "block user person add blocked") { BlockedUsersView() }
        row("Always Relay Calls", pr, "always relay calls ip address hide server") { PrivacySettingsView() }
        row("Show Calls in Recents", pr, "show calls in recents phone app call history") { PrivacySettingsView() }
        row("Disappearing Messages", pr, "disappearing messages timer auto delete default") { PrivacySettingsView() }
        page("App Lock", pr, "app lock face id touch id passcode lock") { AppLockPage() }
        row("Require Face ID", pr + ["App Lock"], "require face id touch id passcode biometrics unlock") { AppLockPage() }
        row("Auto-Lock", pr + ["App Lock"], "auto lock timer immediately minutes") { AppLockPage() }
        row("Screen Security", pr + ["App Lock"], "screen security screenshot app switcher hide") { AppLockPage() }
        row("Safety Tips", pr, "safety tips help private") { PrivacySettingsView() }
        if Flags.profileLayoutChoice {
            page("Profile Layout", pr, "profile layout header classic modern circle") { ProfileLayoutPage() }
        }

        // ── Storage and Data ────────────────────────────────────────────────────────────────
        let sd = [storage]
        page("Manage storage", sd, "manage storage space usage cache free up") { ManageStoragePage() }
        row("Keep Media", sd + ["Manage storage"], "keep media forever days auto delete old photos") { ManageStoragePage() }
        row("Clear Media", sd + ["Manage storage"], "clear media delete videos voice notes free space") { ManageStoragePage() }
        row("Clear Cache", sd + ["Manage storage"], "clear cache free space temporary") { ManageStoragePage() }
        for k in AutoDownloadPrefs.Kind.allCases {
            page(k.label, sd + ["Media auto-download"], "auto download automatic media wifi wi-fi cellular " + k.label) {
                AutoDownloadPage(kind: k)
            }
        }
        row("Reset Auto-Download Settings", sd, "reset auto download settings media") { StorageDataView() }
        page("Sent Media Quality", sd, "sent media quality hd high standard photo video resolution") { SentMediaQualityPage() }
        page("Use Less Data", sd, "use less data calls data saver low data cellular") { UseLessDataPage() }

        // ── Help & About ────────────────────────────────────────────────────────────────────
        let hp = [help]
        row("Help Center", hp, "help center support faq questions") { AboutView() }
        row("Version", hp, "version build number app version") { AboutView() }
        row("Privacy Policy", hp, "privacy policy legal") { AboutView() }
        row("Terms & Conditions", hp, "terms conditions service legal") { AboutView() }

        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    // MARK: Matching

    /// Case, accent and width insensitive, so "notificación" and "NOTIFICATION" both find it.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// True when `q` starts at the beginning of a word of `text` ("prev" in "Message Preview").
    private static func startsAWord(_ q: String, in text: String) -> Bool {
        let qn = words(q).joined(separator: " ")
        guard !qn.isEmpty else { return false }
        return (" " + words(text).joined(separator: " ")).contains(" " + qn)
    }

    /// Higher is better; 0 = no match. Exact title, then title prefix, then a word of the title,
    /// then anywhere in the title, then the keywords and path the same way, then every typed word
    /// found somewhere.
    private static func score(_ e: Entry, _ q: String) -> Int {
        let title = fold(e.title)
        if title == q { return 1000 }
        if title.hasPrefix(q) { return 900 }
        if startsAWord(q, in: title) { return 800 }
        if title.contains(q) { return 600 }
        let rest = fold(e.keywords + " " + e.path.joined(separator: " "))
        if startsAWord(q, in: rest) { return 400 }
        if rest.contains(q) { return 200 }
        let tokens = words(q)
        guard tokens.count > 1 else { return 0 }
        let all = title + " " + rest
        let allWords = words(all)
        var s = 100
        for t in tokens {
            if allWords.contains(where: { $0.hasPrefix(t) }) { s += 2 }
            else if all.contains(t) { s += 1 }
            else { return 0 }
        }
        return s
    }

    static func matching(_ query: String, onSignOut: @escaping () -> Void) -> [Entry] {
        let all = entries(onSignOut: onSignOut)
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        // Nothing typed: the pages, top level first, as before (not every single toggle).
        guard !q.isEmpty else { return all.filter { $0.isPage && $0.path.count <= 1 } }
        return all.enumerated()
            .compactMap { (pair) -> (Int, Int, Entry)? in
                let s = score(pair.element, q)
                return s > 0 ? (s, pair.offset, pair.element) : nil
            }
            .sorted { a, b in
                if a.0 != b.0 { return a.0 > b.0 }
                if a.2.path.count != b.2.path.count { return a.2.path.count < b.2.path.count }
                return a.1 < b.1
            }
            .map { $0.2 }
    }
}

// MARK: - Result row

/// One search result: a Settings card keeps its icon row; anything inside a page shows its title
/// with the path under it ("Read Receipts / Privacy & Security › Messages"). Tapping pushes the page
/// that holds it, or does the card's action in place.
struct SettingsIndexResultRow: View {
    let entry: SettingsIndex.Entry

    var body: some View {
        switch entry.open {
        case .page(let dest):
            NavigationLink { dest() } label: { label }
        case .action(let run):
            Button { run() } label: { label.contentShape(Rectangle()) }
                .foregroundStyle(Color(uiColor: .label))
        }
    }

    @ViewBuilder private var label: some View {
        if let crumb = entry.breadcrumb {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body).foregroundStyle(Color(uiColor: .label))
                Text(crumb).font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .padding(.vertical, 2)
        } else if entry.icon.isEmpty {
            Text(entry.title).font(.body)
        } else if entry.system {
            SettingsRowLabel(entry.title, system: entry.icon)
        } else {
            SettingsRowLabel(entry.title, entry.icon)
        }
    }
}
