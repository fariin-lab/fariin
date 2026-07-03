import SwiftUI
import UIKit

// Flattened story image awaiting the audience sheet (used by both the photo editor + text composer).
struct StoryShareData: Identifiable { let id = UUID(); let data: Data; var caption: String = "" }

// "Share Story" audience sheet: choose who sees the story, then Post.
// Posting kicks off a BACKGROUND upload (StoriesService.postStoryBackground) and pops to chat.
struct ShareStorySheet: View {
    let image: Data
    var caption: String = ""
    var onPosted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    // Remember the last audience choice (WhatsApp/Signal/Telegram all do) instead of resetting each post.
    @State private var mode = UserDefaults.standard.integer(forKey: "storyAudMode")   // 0 contacts, 1 except, 2 only
    @State private var excluded = Set(UserDefaults.standard.stringArray(forKey: "storyAudExcluded") ?? [])
    @State private var included = Set(UserDefaults.standard.stringArray(forKey: "storyAudIncluded") ?? [])
    @State private var emptyAudienceAlert = false
    @State private var posting = false   // one-shot guard so a double-tap can't double-post
    private var me: String { AuthService.shared.uid ?? "" }

    struct AudienceContact: Identifiable { let id: String; let name: String; let photo: String? }
    private var contacts: [AudienceContact] {
        // Exclude blocked contacts — postStory drops them from the real audience, so if the picker
        // still showed/counted them a story could pass the "not empty" guard yet post to NO ONE.
        repo.conversations.filter { !$0.isGroup && !$0.isBlockedByMe(me) }.compactMap {
            let u = $0.otherUid(me)
            return u.isEmpty ? nil : AudienceContact(id: u, name: $0.displayName(me), photo: $0.displayPhoto(me))
        }
    }

    // Fully NATIVE structure (the old custom card's row taps were unreliable on device: the
    // selection visibly never moved). Plain List rows select; the people picker is a PUSHED
    // page (no nested sheet — those get recreated by iOS and can drop state).
    var body: some View {
        NavigationStack {
            audienceList
                .safeAreaInset(edge: .bottom) { postButton }
                .navigationTitle("Share Story")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
                // Persist every audience change IMMEDIATELY (not only on Post), so no recreation of
                // this sheet's content can ever bounce the selection back.
                .onChange(of: mode) { _, v in UserDefaults.standard.set(v, forKey: "storyAudMode") }
                .onChange(of: excluded) { _, v in UserDefaults.standard.set(Array(v), forKey: "storyAudExcluded") }
                .onChange(of: included) { _, v in UserDefaults.standard.set(Array(v), forKey: "storyAudIncluded") }
                .alert("No one will see this", isPresented: $emptyAudienceAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(mode == 2
                         ? "Pick at least one person under \"Only share with,\" or choose \"My contacts.\""
                         : "Everyone you'd share with is excluded. Adjust the audience and try again.")
                }
        }
        // 60% sheet: shows all 3 audience rows + the Post button comfortably. Drag up to .large.
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        // SOLID background — the default translucent material let the story photo show through the
        // sheet ("looks different"); this makes it a normal opaque grouped-list sheet.
        .presentationBackground(Color(.systemGroupedBackground))
    }

    @ViewBuilder private var audienceList: some View {
        List {
            Section("Who can see your story") {
                optionRow(0, "person.fill", "My contacts")
                optionRow(1, "person.fill.xmark", "My contacts except")
                optionRow(2, "person.crop.circle.badge.checkmark", "Only share with")
            }
            if mode == 1 {
                Section {
                    NavigationLink {
                        AudiencePicker(title: "Exclude", contacts: contacts, selected: $excluded)
                    } label: {
                        pickerRowLabel("Excluded people", count: excluded.count)
                    }
                }
            }
            if mode == 2 {
                Section {
                    NavigationLink {
                        AudiencePicker(title: "Only share with", contacts: contacts, selected: $included)
                    } label: {
                        pickerRowLabel("Selected people", count: included.count)
                    }
                }
            }
        }
    }

    private func pickerRowLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    private var postButton: some View {
        Button { post() } label: {
            Text("Post Story").font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(.blue, in: Capsule())
        }
        .buttonStyle(StoryPressStyle())
        .disabled(posting)
        .padding(.horizontal, 16).padding(.vertical, 10)
        // Match the sheet background (was `.bar`, which showed as a grey strip behind the button).
        .background(Color(.systemGroupedBackground))
    }

    private func optionRow(_ m: Int, _ icon: String, _ title: String) -> some View {
        Button { mode = m } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.primary)
                    .frame(width: 34, height: 34).background(Color.primary.opacity(0.08), in: Circle())
                Text(title).foregroundStyle(.primary)
                Spacer()
                if mode == m {
                    Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())   // whole row taps, not just the icon/text
        }
    }

    private func post() {
        guard !posting else { return }   // ignore a second tap while the first is in flight
        // Compute the EFFECTIVE audience (intersect with current contacts) and block an empty one
        // with a visible alert — not just a silent haptic. This catches both "only share with,
        // nobody picked" AND the stale-list case (only-share with X, then X was deleted/blocked →
        // recipientUids would be empty and the story would post to literally no one).
        let contactIds = Set(contacts.map { $0.id })
        let effective: Set<String>
        if mode == 2 { effective = included.intersection(contactIds) }
        else if mode == 1 { effective = contactIds.subtracting(excluded) }
        else { effective = contactIds }
        if effective.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyAudienceAlert = true
            return
        }
        // Remember this audience for next time.
        UserDefaults.standard.set(mode, forKey: "storyAudMode")
        UserDefaults.standard.set(Array(excluded), forKey: "storyAudExcluded")
        UserDefaults.standard.set(Array(included), forKey: "storyAudIncluded")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        posting = true
        StoriesService.shared.postStoryBackground(
            image: image,
            caption: caption,
            excluded: mode == 1 ? excluded : [],
            included: mode == 2 ? included : []
        )
        onPosted()   // dismisses the editor -> back to chat; upload runs in the background
    }
}

// Multi-select contact list for the except/only audience lists.
struct AudiencePicker: View {
    let title: String
    let contacts: [ShareStorySheet.AudienceContact]
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    // Pushed inside the Share Story NavigationStack (NOT presented as its own sheet), so it must
    // not wrap its own NavigationStack. Back or Done both pop.
    var body: some View {
        List {
            if contacts.isEmpty {
                ContentUnavailableView("No contacts", systemImage: "person.2",
                                       description: Text("Start a chat to build your contact list."))
            }
            ForEach(contacts) { c in
                Button {
                    if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: c.name, photoUrl: c.photo, size: 36)
                        Text(c.name).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(c.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())   // whole row taps, not just the avatar (Spacer was dead)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
    }
}
