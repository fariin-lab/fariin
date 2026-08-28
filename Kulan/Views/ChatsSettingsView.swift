import SwiftUI

// Settings > Chats. Sits between Appearance and Stories, on the owner's layout (2026-08-04).
//
// Same bones as every other settings sub-page: native List, one Section per idea, the explanation
// as the section FOOTER rather than a second line inside the row — that is what makes an iOS
// settings page read as one page instead of a stack of cards.
struct ChatsSettingsView: View {
    @AppStorage(AutoSaveToPhotos.defaultsKey) private var saveToPhotos = false
    @AppStorage(UnknownChatArchiver.defaultsKey) private var autoArchiveUnknown = false
    /// ⛔ THE SWITCH THAT MAKES THE LINK PREVIEW AVOIDABLE. Building one means THIS PHONE contacting
    /// the linked site before anything is sent, so it is a request the person makes whether they
    /// meant to or not — paste a link to ask somebody about it, delete it unsent, and the site has
    /// your address and the time. Theirs has exactly this setting for exactly this reason. Default
    /// on, as theirs is.
    @AppStorage("linkPreviewsEnabled") private var linkPreviews = true
    @State private var confirmClear = false
    @State private var clearing = false

    private var chatCount: Int { ConversationsRepository.shared.conversations.count }

    var body: some View {
        List {
            Section {
                Toggle("Save to Photos", isOn: $saveToPhotos).tint(.green)
            } footer: {
                Text("Automatically save received photos and videos to your Photos library.")
            }

            Section {
                Toggle("Link Previews", isOn: $linkPreviews).tint(.green)
            } footer: {
                Text("Show a preview card for links you type or paste. Your phone contacts the site to build it, before the message is sent.")
            }

            // The setting moves WHERE a stranger's first message waits, and nothing else. It is
            // still an ordinary conversation with Accept and Delete inside it either way — there is
            // no separate requests inbox in this app and this does not add one.
            Section {
                Toggle("Automatically Archive", isOn: $autoArchiveUnknown).tint(.green)
            } header: {
                Text("New Chats from Unknown Users")
            } footer: {
                // NAMED THREE THINGS THIS APP DOES NOT HAVE. `Flags.groupsEnabled` is false, there
                // are no channels at all, and there is no contact list to be in or out of — the
                // sweep's actual test is whether YOU have ever replied (see UnknownChatArchiver).
                // Copy carried over from a reference app describes that app, not this one.
                Text("When someone you have never replied to starts a chat, it goes straight to Archived and stays muted. You still get the message.")
            }

            Section {
                Button(role: .destructive) { confirmClear = true } label: {
                    HStack {
                        Text("Clear Chat History")
                        if clearing { Spacer(); ProgressView() }
                    }
                }
                .disabled(clearing || chatCount == 0)
            } footer: {
                // The only red row in Settings with nothing written under it. Every other one says
                // what it does before you touch it — Reset All Notifications, Turn Off Stories,
                // Delete Account — and this is the most destructive of the lot. Saying it only
                // inside the confirm means the first time you learn what the button does is after
                // you have already pressed it.
                Text("Deletes every message, photo, video and call from all your devices. It cannot be undone.")
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        // ALERT, NOT confirmationDialog, and this one matters more than most. On iOS 26 a
        // confirmationDialog attached to a plain view renders as an anchored popover and DROPS the
        // cancel button, because a popover expects to be dismissed by tapping outside. The owner
        // photographed exactly that on the official chat's Block sheet: a floating bubble with one
        // red button and no way out inside it.
        //
        // Here the one red button says "Delete Everything" and the copy says it cannot be undone. A
        // confirmation for the most destructive action in the app must not be the one that loses its
        // Cancel. The old comment argued for an action sheet on shape grounds, and the shape is fine
        // in principle — it is what BottomActionSheet exists for — but a system dialog that silently
        // drops Cancel is not the shape it claims to be.
        .alert("Clear Chat History?", isPresented: $confirmClear) {
            Button("Delete Everything", role: .destructive) { Task { await clearEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently delete all chat history, including messages, photos, videos, documents, voice messages, and call history, from all of your devices? This action cannot be undone.")
        }
    }

    /// Clears every chat the way the per-chat Delete does — `clearedAt` on the conversation, which
    /// is written SERVER-side and so reaches every device you are signed in on, which is what the
    /// sheet promises. It clears YOUR copy: the other person keeps theirs, exactly like deleting
    /// one chat does. Nothing here can touch someone else's device.
    private func clearEverything() async {
        clearing = true
        let ids = ConversationsRepository.shared.conversations.map(\.id)
        await withTaskGroup(of: Void.self) { g in
            for id in ids { g.addTask { await ChatService.deleteForMe(id) } }
        }
        clearing = false
    }
}
