import SwiftUI

// The archive page's own two screens, both reached from the "..." menu it grew on 2026-08-13.
//
// Neither is new behaviour. The auto-archive switch already existed, three taps deep in
// Settings > Chats, where somebody standing in the archive was never going to find it; and nothing
// anywhere in the app said what archiving actually does. The owner asked for both, pointing at the
// reference app's Archive Settings / How Does It Work pair.

/// The switch, in the place it is about. Same `@AppStorage` key as Settings > Chats, so the two
/// screens are two windows onto one setting and cannot disagree.
struct ArchiveSettingsView: View {
    @AppStorage(UnknownChatArchiver.defaultsKey) private var autoArchiveUnknown = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Automatically Archive", isOn: $autoArchiveUnknown).tint(.green)
                } header: {
                    Text("New Chats from Unknown Users")
                } footer: {
                    // The same sentence as Settings > Chats, word for word and deliberately: one
                    // switch described twice is how two descriptions drift apart.
                    Text("When someone you have never replied to starts a chat, it goes straight to Archived and stays muted. You still get the message.")
                }
            }
            .navigationTitle("Archive Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// What archiving does, in THIS app's words.
///
/// Every line here was checked against the code rather than carried over from the app it is modelled
/// on: the list filter that hides an archived chat, the tab-badge filter that skips it, and the fact
/// that a new message does not pull it back. The one thing the reference app does that we do not is
/// mute on archive — manual archiving touches `archivedBy` and nothing else — so the page says so
/// instead of promising quiet it cannot deliver.
struct ArchiveHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    MenuIcon("ic_archive", size: 40)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 88, height: 88)
                        .background(Circle().fill(Color.accentColor.opacity(0.12)))
                        .padding(.top, 20)
                    Text("Archived Chats")
                        .font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 20) {
                        point("tray.and.arrow.down", "They leave your chat list",
                              "An archived chat moves out of Chats and waits in here. Nothing is deleted, and the messages stay exactly where they are.")
                        point("bell.slash", "Only the list goes quiet",
                              "Unread messages in here are left out of the number on the Chats tab. Notifications still arrive unless you mute the chat itself.")
                        point("hand.draw", "They stay until you take them out",
                              "A new message does not pull a chat back. Swipe it here, or hold it, and choose Unarchive.")
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
