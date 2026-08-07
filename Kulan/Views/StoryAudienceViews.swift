import SwiftUI
import UIKit

// The screens that create and manage story audiences. The share sheet and Settings › Stories both
// draw from these, because "who can see my story" is one question and the owner asked for one answer
// to it wherever it is asked.
//
// STRUCTURE COPIED FROM SIGNAL, LOOK FROM US (his standing rule). Signal's shape is: a list of named
// distribution lists with a + New, a two-step create (pick people → name it), and a page per list.
// That shape is right and it is what he drew. The chrome is ours: our capsule buttons, our grouped
// list, our avatars.

// MARK: - Contacts

/// One person who can be given a story. Deliberately NOT a Conversation: these screens care about a
/// uid, a name and a photo, and nothing else about a chat should be able to change how they behave.
struct StoryContact: Identifiable, Equatable {
    let id: String
    let name: String
    let photo: String?

    /// Everyone eligible to receive a story: the people you share an accepted 1:1 chat with, minus
    /// anybody you have blocked.
    ///
    /// BLOCKED PEOPLE ARE REMOVED HERE, NOT LATER. `postStory` already strips them from the real
    /// audience, so a picker that still listed them would let a story pass the "not empty" check and
    /// then reach nobody.
    static func all() -> [StoryContact] {
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations
            .filter { !$0.isGroup && !$0.isBlockedByMe(me) }
            .compactMap {
                let u = $0.otherUid(me)
                return u.isEmpty ? nil : StoryContact(id: u, name: $0.displayName(me), photo: $0.displayPhoto(me))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func ids(_ list: [StoryContact]) -> Set<String> { Set(list.map(\.id)) }

    /// Do I share an accepted, unblocked 1:1 chat with this person?
    ///
    /// THE SAME TEST THE AUDIENCE IS BUILT FROM, deliberately. It answers "may they reply to my
    /// story", and a story reply is an ordinary chat message — so if this drifted from `all()` the
    /// app would offer a reply bar to somebody the story was never sent to.
    static func isFriend(_ uid: String) -> Bool {
        guard !uid.isEmpty else { return false }
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations.contains { c in
            !c.isGroup && c.otherUid(me) == uid
                && !c.isBlockedByMe(me) && !c.isBlockedByMe(uid)
        }
    }
}

// MARK: - Shared row

/// The audience row every list uses: the badge, the title, the grey line, and whatever the caller
/// puts on the right. One row, so the share sheet and Settings cannot drift apart.
struct StoryAudienceRow<Trailing: View>: View {
    let audience: StoryAudience
    let contacts: Set<String>
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(audience.title).foregroundStyle(.primary).lineLimit(1)
                Text(audience.subtitle(contacts: contacts))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var badge: some View {
        // EVERYONE WEARS YOUR OWN FACE (owner 2026-08-06: "on the Everyone tab, please set my profile
        // picture not icon"). It is the audience that reaches your profile, so your profile is the
        // truest picture of it — and it is what Signal draws there. AvatarView falls back to the
        // coloured letter on its own when there is no photo, so there is no empty-circle case.
        if audience.kind == .everyone {
            AvatarView(name: ProfileStore.shared.me?.name ?? "You",
                       photoUrl: ProfileStore.shared.me?.photoUrl,
                       size: 40)
        } else {
            ZStack {
                Circle().fill(badgeTint.gradient)
                // A custom list wears the owner's own folder drawing (2026-08-07), FILLED: it is a
                // white glyph on a solid tinted circle, which is exactly where the filled weight
                // belongs. The outline of the same pair is used on the viewer's audience pill, where
                // the glyph sits over a photograph.
                if audience.kind == .custom {
                    Image("ic_story_folder_fill")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 19, height: 19)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: badgeIcon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)
        }
    }

    private var badgeIcon: String {
        switch audience.kind {
        case .everyone: return "globe"
        case .myFriends: return "person.2.fill"
        case .custom: return "rectangle.stack.fill"
        // Never drawn: `StoryAudienceStore.all` excludes the hide list, because it is not an
        // audience you can post to. Answered rather than trapped, so a future caller that does
        // reach it gets a sensible icon instead of a crash.
        case .hidden: return "eye.slash.fill"
        }
    }
    private var badgeTint: Color {
        switch audience.kind {
        case .everyone: return .blue
        case .myFriends: return .orange
        case .custom: return .gray
        case .hidden: return .gray
        }
    }
}

/// A circle that fills in when selected — the picker's radio, and the checkbox on the viewer list.
struct StoryTick: View {
    let on: Bool
    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.55))
            .symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Select Viewers

/// Step one of a custom story, and also "Add Viewers" on an existing one.
///
/// SECTIONED BY FIRST LETTER with a search field, which is his drawing and also the only layout that
/// survives a real contact list. `Next` stays dead until somebody is picked — a custom story with no
/// viewers is not a story, it is a hole.
struct SelectViewersView: View {
    var title: String = "Select Viewers"
    var actionTitle: String = "Next"
    /// Already in the list, so they cannot be picked twice. Empty when creating.
    var alreadyIn: Set<String> = []
    @Binding var selected: Set<String>
    let onAction: () -> Void
    var onCancel: (() -> Void)? = nil

    @State private var search = ""
    @State private var contacts: [StoryContact] = []

    private var visible: [StoryContact] {
        let pool = contacts.filter { !alreadyIn.contains($0.id) }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return pool }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// First letter, with everything that does not start with one under "#". Sorted so the sections
    /// come out A, B, C … # rather than in dictionary order with the hash in the middle.
    private var sections: [(String, [StoryContact])] {
        let groups = Dictionary(grouping: visible) { c -> String in
            let f = c.name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "#"
            return f.rangeOfCharacter(from: .letters) == nil ? "#" : f
        }
        return groups.sorted { a, b in
            if a.key == "#" { return false }
            if b.key == "#" { return true }
            return a.key < b.key
        }.map { ($0.key, $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }

    var body: some View {
        List {
            ForEach(sections, id: \.0) { letter, people in
                Section {
                    ForEach(people) { c in
                        Button {
                            if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: c.name, photoUrl: c.photo, size: 40)
                                Text(c.name).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 8)
                                StoryTick(on: selected.contains(c.id))
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text(letter)
                }
            }
            if visible.isEmpty {
                Section {
                    Text(contacts.isEmpty
                         ? "You have no chats yet. Start a chat with someone and they can be added here."
                         : "No one matches that.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Name or username")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onCancel() } label: { Image(systemName: "xmark") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(actionTitle) { onAction() }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
            }
        }
        .onAppear { if contacts.isEmpty { contacts = StoryContact.all() } }
    }
}

// MARK: - Name Story

/// Step two: the name, the reply setting, and a last look at who is in it.
struct NameStoryView: View {
    @Binding var name: String
    @Binding var allowReplies: Bool
    let viewers: [StoryContact]
    let onCreate: () -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        List {
            Section {
                TextField("Story Name (Required)", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
            } footer: {
                Text("Only you can see the name of this story.")
            }

            Section {
                Toggle("Allow Replies & Reactions", isOn: $allowReplies).tint(.green)
            } header: {
                Text("Replies & Reactions")
            } footer: {
                Text("Let people who can view your story react and reply.")
            }

            Section("Viewers") {
                ForEach(viewers) { c in
                    HStack(spacing: 12) {
                        AvatarView(name: c.name, photoUrl: c.photo, size: 36)
                        Text(c.name).lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("Name Story")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") { onCreate() }
                    .fontWeight(.semibold)
                    // Required means required. A nameless list is unfindable in the picker, which is
                    // the one place its name is ever read.
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // The name is the only thing this page is really for, so the keyboard is up on arrival.
        .onAppear { nameFocused = true }
    }
}

// MARK: - My Friends

/// The built-in list's own page: all your accepted chats, or that set narrowed either way.
///
/// This is Signal's "My Story" privacy page and it is the ONLY built-in that can be edited — the
/// owner's rule is that Everyone is fixed.
struct MyFriendsPrivacyView: View {
    @State private var store = StoryAudienceStore.shared
    @State private var contacts: [StoryContact] = []
    @State private var picking: PickTarget?
    /// WHO IS BEING CHOSEN RIGHT NOW, and not yet who is chosen.
    ///
    /// The mode used to be committed on the TAP, before anybody had been picked — so "All Except…"
    /// went ticked with 0 excluded, which reaches exactly the same people as "All chats you
    /// accepted" while claiming to be something else. Backing out left it ticked too. Editing a
    /// draft and committing on Done means the tick can only ever describe a real narrowing.
    @State private var draft: Set<String> = []

    private enum PickTarget: Identifiable {
        case except, only
        var id: Int { self == .except ? 0 : 1 }
        var mode: StoryAudience.Mode { self == .except ? .except : .only }
    }

    private var a: StoryAudience { store.myFriends }
    private var contactIds: Set<String> { StoryContact.ids(contacts) }

    var body: some View {
        List {
            Section {
                modeRow(.all, "All chats you accepted",
                        detail: "\(contactIds.count) \(contactIds.count == 1 ? "Viewer" : "Viewers")")
                modeRow(.except, "All Except…",
                        detail: a.mode == .except ? "\(a.members.count) excluded" : nil)
                modeRow(.only, "Only Share With…",
                        detail: a.mode == .only ? "\(a.members.count) selected" : nil)
            } header: {
                Text("Who Can View This Story")
            } footer: {
                Text("Choose which of your chats can view your story. Changes won't affect stories you've already sent.")
            }

            Section {
                Toggle("Allow Replies & Reactions", isOn: Binding(
                    get: { a.allowReplies },
                    set: { v in var n = a; n.allowReplies = v; store.update(n) }
                )).tint(.green)
            } header: {
                Text("Replies & Reactions")
            } footer: {
                Text("Let people who can view your story react and reply.")
            }
        }
        .navigationTitle("My Friends")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if contacts.isEmpty { contacts = StoryContact.all() } }
        .sheet(item: $picking) { target in
            NavigationStack {
                MembersEditor(
                    title: target == .except ? "All Except" : "Only Share With",
                    contacts: contacts,
                    members: $draft,
                    // NOTHING CHOSEN IS NOT A CHOICE. Done stays dead until at least one person is
                    // picked, the same rule Select Viewers already uses for a custom story — an
                    // empty except-list and an empty only-list both mean "the mode did nothing".
                    requireAtLeastOne: true,
                    onDone: {
                        // COMMITTED HERE, not on the tap that opened this. An empty draft leaves the
                        // mode exactly as it was, so backing out cannot leave a tick behind.
                        if !draft.isEmpty {
                            var n = a
                            n.mode = target.mode
                            n.members = Array(draft)
                            store.update(n)
                        }
                        picking = nil
                    },
                    onCancel: { picking = nil })
            }
        }
    }

    private func modeRow(_ m: StoryAudience.Mode, _ title: String, detail: String?) -> some View {
        Button {
            guard m != .all else {
                // "All chats" needs nobody picked, so it is the one mode that commits on the tap.
                var n = a
                n.mode = .all
                n.members = []
                store.update(n)
                return
            }
            // SWITCHING MODE STARTS FROM EMPTY. `except` and `only` mean opposite things by the same
            // field, so carrying one over to the other would turn "hide from these three" into
            // "show ONLY these three" without anybody asking for it. Returning to the mode you are
            // already on opens on the people you already chose.
            draft = a.mode == m ? Set(a.members) : []
            picking = (m == .except ? .except : .only)
        } label: {
            HStack(spacing: 12) {
                StoryTick(on: a.mode == m)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if a.mode == m && m != .all {
                    Text("Edit").font(.subheadline).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - A custom story's page

struct CustomStoryDetailView: View {
    let audienceId: String
    @State private var store = StoryAudienceStore.shared
    @State private var contacts: [StoryContact] = []
    @State private var adding = false
    @State private var addSelection: Set<String> = []
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var a: StoryAudience? { store.custom.first { $0.id == audienceId } }
    private var viewers: [StoryContact] {
        guard let a else { return [] }
        let want = Set(a.members)
        return contacts.filter { want.contains($0.id) }
    }

    var body: some View {
        Group {
            if let a {
                list(a)
            } else {
                // Deleted from another device while it was open. Nothing to manage, so leave rather
                // than sit on a page describing something that is gone.
                Color.clear.onAppear { dismiss() }
            }
        }
        .onAppear { if contacts.isEmpty { contacts = StoryContact.all() } }
    }

    @ViewBuilder private func list(_ a: StoryAudience) -> some View {
        List {
            Section {
                Button { addSelection = []; adding = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.secondary.opacity(0.18))
                            Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(width: 36, height: 36)
                        Text("Add Viewers").foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                ForEach(viewers) { c in
                    HStack(spacing: 12) {
                        AvatarView(name: c.name, photoUrl: c.photo, size: 36)
                        Text(c.name).lineLimit(1)
                    }
                }
                .onDelete { idx in
                    // Swipe a viewer away. There is no other way to remove one, and a list you can
                    // only ever add to stops being a custom audience after a week of use.
                    var n = a
                    let going = Set(idx.map { viewers[$0].id })
                    n.members.removeAll { going.contains($0) }
                    store.update(n)
                }
            } header: {
                Text("Who Can View This Story")
            } footer: {
                Text("Choose which of your chats can view your story. Changes won't affect stories you've already sent.")
            }

            Section {
                Toggle("Allow Replies & Reactions", isOn: Binding(
                    get: { a.allowReplies },
                    set: { v in var n = a; n.allowReplies = v; store.update(n) }
                )).tint(.green)
            } header: {
                Text("Replies & Reactions")
            } footer: {
                Text("Let people who can view your story react and reply.")
            }

            Section {
                Button("Delete Custom Story", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(a.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { draftName = a.name; renaming = true }
            }
        }
        .alert("Rename story", isPresented: $renaming) {
            TextField("Story Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let t = draftName.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                var n = a; n.name = t; store.update(n)
            }
        } message: {
            Text("Only you can see the name of this story.")
        }
        .alert("Delete \"\(a.name)\"?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { store.delete(a); dismiss() }
        } message: {
            Text("The list goes. Stories you already sent to it are not affected and still expire on their own.")
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                SelectViewersView(title: "Add Viewers", actionTitle: "Add",
                                  alreadyIn: Set(a.members), selected: $addSelection,
                                  onAction: {
                                      var n = a
                                      n.members.append(contentsOf: addSelection.subtracting(n.members))
                                      store.update(n)
                                      adding = false
                                  },
                                  onCancel: { adding = false })
            }
        }
    }
}

// MARK: - Members editor (the except / only lists)

/// A plain checkbox list over the same contacts, used by My Friends for both of its narrowing modes.
/// Separate from `SelectViewersView` because that one is a step in a flow with a Next; this one
/// edits a live list and is done when you say it is.
struct MembersEditor: View {
    let title: String
    let contacts: [StoryContact]
    @Binding var members: Set<String>
    /// Done is dead until somebody is picked. Used where an empty list would mean the mode does
    /// nothing at all — see `MyFriendsPrivacyView`.
    var requireAtLeastOne: Bool = false
    let onDone: () -> Void
    /// Leaves without applying anything. Without it the only way out of this sheet is a swipe,
    /// which lands on `onDone` in some presentations and on nothing in others.
    var onCancel: (() -> Void)? = nil

    @State private var search = ""

    private var visible: [StoryContact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? contacts : contacts.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            ForEach(visible) { c in
                Button {
                    if members.contains(c.id) { members.remove(c.id) } else { members.insert(c.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: c.name, photoUrl: c.photo, size: 40)
                        Text(c.name).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        StoryTick(on: members.contains(c.id))
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or username")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onCancel() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { onDone() }
                    .fontWeight(.semibold)
                    .disabled(requireAtLeastOne && members.isEmpty)
            }
        }
    }
}

// MARK: - The create flow, as one presentable piece

/// Select Viewers → Name Story → done, in its own navigation stack so it can be put in a sheet from
/// the share sheet AND from Settings without either of them owning the steps.
struct CreateCustomStoryFlow: View {
    /// The finished list, handed back so the share sheet can select it immediately.
    let onCreated: (StoryAudience) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var toName = false
    @State private var name = ""
    @State private var allowReplies = true
    @State private var contacts: [StoryContact] = []

    var body: some View {
        NavigationStack {
            SelectViewersView(selected: $selected, onAction: { toName = true }, onCancel: onCancel)
                .navigationDestination(isPresented: $toName) {
                    NameStoryView(name: $name, allowReplies: $allowReplies,
                                  viewers: contacts.filter { selected.contains($0.id) },
                                  onCreate: {
                                      let a = StoryAudienceStore.shared.createCustom(
                                          name: name, members: Array(selected), allowReplies: allowReplies)
                                      onCreated(a)
                                  })
                }
                .onAppear { if contacts.isEmpty { contacts = StoryContact.all() } }
        }
    }
}

// MARK: - The + New menu

/// The "+ New" capsule and the menu behind it, identical in the share sheet and in Settings.
///
/// STILL UIKIT, for the reason it always was: a `Button` inside a SwiftUI `Menu` renders on ONE
/// line whatever view you hand it, and his reference shows two-line items. `UIAction` has carried a
/// `subtitle` since iOS 15. The button itself wants UIKit too — a small capsule with an explicit
/// font, an explicit symbol size and an explicit disabled state, sized to sit in a section header,
/// which `UIButton.Configuration` says in one place.
///
/// GROUP STORIES ARE NOT DRAWN AT ALL. They need their own delivery path — the group's membership
/// resolved into viewers, replies landing in the group, the group's identity on the story row — and
/// the owner chose to land the person side first. It was greyed with "Coming soon" on his earlier
/// call and removed outright on his later one (2026-08-06).
struct NewAudienceButton: UIViewRepresentable {
    let onCustom: () -> Void
    /// Greyed once he is at the ceiling — his number ("the maximum number of Custom Stories is 5").
    /// A menu item that silently does nothing is worse than one that says why it cannot.
    var canAddCustom: Bool = true
    /// ONE-TIME STORY, and it is only offered where there is a story to post.
    ///
    /// Nothing is saved for a one-time story: you pick the people, it goes to them, and next time you
    /// pick again (the owner's call). So it has no place on the Settings page, which exists to manage
    /// the audiences you keep — an entry there would open a picker with nothing to send.
    /// Nil means no menu at all, and the button goes straight to New Custom Story.
    var onOneTime: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIButton {
        // SIZED FOR A SECTION HEADER, which is what it sits in.
        //
        // ⚠️ `buttonSize = .small` IS NOT ENOUGH and that was the bug he circled. It shrinks the
        // padding and leaves the title on UIButton's default 17pt BODY font, so the capsule came out
        // roughly as tall as a table row and towered over the "Stories" heading beside it.
        //
        // 15pt semibold for the word and 13pt for the plus, which is the proportion iOS uses for a
        // header accessory and the proportion Signal's own "+ New" reads at. Scaled through
        // UIFontMetrics so it still grows for anyone using larger text — a hardcoded 15 would be the
        // one control on the screen that ignored the setting.
        //
        // (Said plainly: these are matched by eye and by iOS convention. I could not read Signal's
        // source to copy their constants, and inventing numbers and calling them Signal's would be
        // worse than saying so.)
        var cfg = UIButton.Configuration.gray()
        let metrics = UIFontMetrics(forTextStyle: .subheadline)
        var title = AttributeContainer()
        title.font = metrics.scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        cfg.attributedTitle = AttributedString("New", attributes: title)
        cfg.image = UIImage(systemName: "plus",
                            withConfiguration: UIImage.SymbolConfiguration(
                                font: metrics.scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))))
        cfg.imagePadding = 4
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        cfg.cornerStyle = .capsule
        cfg.baseForegroundColor = .label
        let b = UIButton(configuration: cfg)
        // Set in updateUIView, which decides between a menu and a direct action.
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    func updateUIView(_ b: UIButton, context: Context) {
        context.coordinator.onCustom = onCustom
        context.coordinator.onOneTime = onOneTime
        // NEW GROUP STORY IS STILL GONE (owner 2026-08-06: "plz hide new group story that feature").
        // One-Time Story takes the slot it used to hold, and unlike Group Story it exists.
        //
        // ⚠️ THE MENU IS ALWAYS BOTH ITEMS NOW, EVEN WHERE ONE OF THEM CANNOT BE USED — his
        // 2026-08-07 instruction: "one-time story when user stay in setting disable, user can see
        // but cant click, make it like that".
        //
        // The Settings page used to get no menu at all, on the reasoning that a menu opening to a
        // single item is two taps for one decision. That reasoning was about a menu with ONE item in
        // it. A menu with two items where one is dimmed is a different thing: it tells you the
        // feature exists and that this is not where it lives, which a button that silently does
        // something else cannot. So the shape of this control no longer changes between the two
        // screens; only what is enabled does.
        //
        // UIKit, NOT SwiftUI's `Menu`, and that is the whole reason this view is a representable.
        // His reference shows two-line items, and SwiftUI renders a menu item on ONE line whatever
        // view you hand it. `UIAction.subtitle` has existed since iOS 15 and does it properly.
        //
        // The custom item wears HIS OWN folder drawing rather than `person.2` — the same outline
        // weight the audience rows and the viewer's pill use, so one custom story looks like the
        // same idea everywhere it appears.
        let custom = UIAction(title: "New Custom Story",
                              subtitle: "Visible only to specific people.",
                              image: UIImage(named: "ic_story_folder")) { _ in
            context.coordinator.onCustom()
        }
        // Dimmed rather than absent at the ceiling: an item that vanishes leaves you wondering
        // whether you imagined it, and this one says why it cannot be used.
        custom.attributes = canAddCustom ? [] : [.disabled]
        let oneTime = UIAction(title: "One-Time Story",
                               subtitle: "Can only be viewed once by each recipient.",
                               image: UIImage(systemName: "flame")) { _ in
            context.coordinator.onOneTime?()
        }
        // Nil handler == this screen cannot post, only manage audiences. Visible, and dimmed.
        oneTime.attributes = onOneTime == nil ? [.disabled] : []
        b.removeTarget(nil, action: nil, for: .touchUpInside)
        b.menu = UIMenu(children: [custom, oneTime])
        b.showsMenuAsPrimaryAction = true   // one tap opens it; there is no other action to lose
        b.isEnabled = true
    }

    /// Without this SwiftUI hands a representable the whole width it was offered, and a "+ New"
    /// capsule as wide as the section header is not a button, it is a bar.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCustom) }

    /// The closure lives on the coordinator, not captured in the action: `updateUIView` runs on
    /// every SwiftUI pass and a captured closure would pin the FIRST body's copy of the state it
    /// touches — the create sheet would open against a stale `creating` binding.
    final class Coordinator: NSObject {
        var onCustom: () -> Void
        var onOneTime: (() -> Void)?
        init(_ onCustom: @escaping () -> Void) { self.onCustom = onCustom }
        @objc func fire() { onCustom() }
    }
}
