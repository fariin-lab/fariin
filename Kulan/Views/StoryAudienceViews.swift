import SwiftUI
import UIKit

// The screens that create and manage story audiences. The share sheet and Settings › Stories both
// draw from these, because "who can see my story" is one question and the owner asked for one answer
// to it wherever it is asked.
//
// STRUCTURE COPIED FROM THE REFERENCE APP, LOOK FROM US (his standing rule). The reference app's shape is: a list of named
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
            // ⚠️ BOTH DIRECTIONS, AND THIS HAD DRIFTED FROM THE TWO TESTS BESIDE IT. `isFriend` below
            // and `resolveAudience` in the service both ask "did I block them AND did they block me";
            // this asked only the first half, so somebody I had blocked could still be listed when
            // the conversation's flag had not caught up, and somebody who blocked ME was listed
            // every time. Either way the picker offered a person the post would then strip, which is
            // the owner's report: a blocked user must not be selectable at all.
            .filter { !$0.isGroup && !$0.isBlockedByMe(me) && !$0.isBlockedByMe($0.otherUid(me)) }
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
    /// ⚠️ ONE ROW HEIGHT FOR EVERY LIST THAT DRAWS THIS ROW — his 2026-08-18 "in stories settings
    /// Everyone / My Friends / customs has more space, make it less, like the share sheet".
    ///
    /// The share sheet trimmed these to 8pt above and below on his instruction months ago; the
    /// settings list kept the grouped list's own padding, which measures about 15 — a 44pt row
    /// sitting in a 74pt slot. Four audiences is most of a row's worth of screen spent on nothing.
    /// The number lives here, on the row itself, so the two lists cannot drift apart again.
    static var insets: EdgeInsets { EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16) }

    let audience: StoryAudience
    let contacts: Set<String>
    /// The glow relationship, for the Glowers row's own count. Defaulted so the settings list — which
    /// draws these rows too and has no reason to know about Glow — needs no change; that row simply
    /// shows its wordy subtitle there instead of a number. See `StoryAudience.recipients`.
    var glow: Set<String> = []
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(audience.title).foregroundStyle(.primary).lineLimit(1)
                Text(audience.subtitle(contacts: contacts, glow: glow))
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
        // truest picture of it — and it is what the reference app draws there. AvatarView falls back to the
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
                // ⛔ GLOW'S OWN MARK, NOT `sparkles` — 2026-09-11 consistency pass, and the last
                // call site the 2026-09-02 sweep missed. `GlowStyle.icon` replaced the symbol
                // everywhere else the feature draws itself, with a note saying `sparkles` was "the
                // system's nearest idea of a glow" and would go the day he sent a real drawing. He
                // sent one; this badge kept the placeholder, so the Glowers row in Settings wore a
                // different logo from the Glowers row one screen away.
                //
                // ⚠️ SAME 23 AS THE FOLDER BELOW, for the reason written there: a drawn glyph given
                // an N-point frame really is N points, while an SF Symbol's point size is its CAP
                // HEIGHT and draws visibly bigger. 23 is what makes a drawing match the 17pt symbols
                // sharing this badge. The tint comes from `badgeGlyph` on the ZStack, which for
                // Glowers is the background colour — see its note.
                if audience.kind == .glowers {
                    GlowStyle.mark(23).foregroundStyle(badgeGlyph)
                } else if audience.kind == .custom {
                    // ⚠️ 23, NOT 19, and the reason is that these two are not measured the same way.
                    // `person.2.fill` beside it is an SF Symbol at 17pt, and a symbol's point size is
                    // its CAP HEIGHT, not its box — it draws noticeably wider and taller than 17.
                    // A drawn glyph given a 19pt frame really is 19pt, so the folder came out visibly
                    // smaller than its neighbour inside the same 40pt circle. His report, and it is
                    // the standard way a custom icon ends up looking undersized next to a symbol.
                    Image("ic_story_folder_fill")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 23, height: 23)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: badgeIcon).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(badgeGlyph)
                }
            }
            .frame(width: 40, height: 40)
        }
    }

    private var badgeIcon: String {
        switch audience.kind {
        case .everyone: return "globe"
        case .myFriends: return "person.2.fill"
        // ⚠️ NO LONGER REACHED — Glowers is answered by its own drawing in the badge above, and
        // this case survives only to keep the switch exhaustive. Left as the old symbol rather than
        // deleted so it is obvious which branch went where if the badge is ever refactored.
        case .glowers: return "sparkles"
        case .custom: return "rectangle.stack.fill"
        // Never drawn: `StoryAudienceStore.all` excludes the hide list, because it is not an
        // audience you can post to. Answered rather than trapped, so a future caller that does
        // reach it gets a sensible icon instead of a crash.
        case .hidden: return "eye.slash.fill"
        }
    }
    /// The glyph ON the badge. Every built-in except Glowers sits on a saturated colour and takes
    /// white; Glowers sits on `.primary`, which IS white at night — so it takes the opposite.
    private var badgeGlyph: Color {
        audience.kind == .glowers ? Color(.systemBackground) : .white
    }

    private var badgeTint: Color {
        switch audience.kind {
        case .everyone: return .blue
        case .myFriends: return .orange
        // ⛔ THE APP'S OWN ACCENT — owner, 2026-09-02: "follow my app color is black and white".
        // The pink that was here was read off another app's screenshot and was never Fariin's.
        //
        // ⚠️ `Color.primary` IS WHITE AT NIGHT, so the glyph on this one badge cannot be the
        // hardcoded `.white` the others use — see `badgeGlyph`. That is the exact mistake the
        // accent-is-white-at-night note in this repo was written about.
        case .glowers: return Color.primary
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
            // `.blue` LITERALLY, not accentColor: the app's accent resolves near-grey here, and a
            // grey tick does not read as chosen (his 2026-08-09 screenshot with the ticks circled).
            // Same blue as the Post Story capsule, so the sheet's two affirmatives agree.
            .foregroundStyle(on ? Color.blue : Color.secondary.opacity(0.55))
            .symbolRenderingMode(on ? .monochrome : .hierarchical)
    }
}

// MARK: - The one privacy picker

/// ⛔ ONE SCREEN FOR EVERY STORY PRIVACY CHOICE — owner, 2026-09-11, with a screenshot: "make all
/// these pages visually consistent so users do not get confused… Everyone, Glowers, My Friends →
/// Only Share With, and All Except should all feel like the exact same screen/component."
///
/// So there is now exactly one of them, and the four callers differ ONLY in what they hand it and
/// what they do with the answer. Anything drawn here is drawn identically on all four; anything a
/// single page used to draw for itself (Everyone's explanatory paragraph, Glowers' Hide/Unhide
/// words) is gone, because a difference you can see is the confusion he is reporting.
///
/// The shape, from his screenshot: ✕ and Save in the bar, the search field pinned under it, the
/// people you have chosen in their own card at the top under their own heading, everybody else in
/// the card below. Tapping a row moves it between the two cards, and that movement IS the feedback —
/// there is no Hide/Unhide word to read and no tick whose meaning you have to guess.
///
/// ⚠️ A DRAFT, COMMITTED ON SAVE. Every caller now works this way, including Glowers, which used to
/// write on the tap. A screen with a Save button that has already saved is a lie, and one of the two
/// callers behind it (`setHidden`) also revokes stories that are already up — so a half-made
/// selection reaching the store would take a live story down and put it back. ✕ discards.
struct StoryPeoplePicker: View {
    let title: String
    /// The heading over the people who are ticked — "Hidden Users" on the two hide pages,
    /// "Selected" / "Excluded" on My Friends' two.
    let selectedHeader: String
    /// The heading over everybody else.
    let unselectedHeader: String
    let people: [StoryContact]
    @Binding var selected: Set<String>
    /// Drawn only while there is nothing to draw yet — the Glow pages fetch their names.
    var isLoading: Bool = false
    /// Save is dead until somebody is picked. True only where an empty list would mean the mode does
    /// nothing at all — see `MyFriendsPrivacyView`.
    var requireAtLeastOne: Bool = false
    let onSave: () -> Void
    let onClose: () -> Void

    @State private var search = ""

    /// ⚠️ HIS "the spacing between the avatar and the surrounding content is too large". A grouped
    /// list gives a 40pt avatar about 11pt above and below, which is a 62pt row; this is 52. The
    /// number lives here, once, so the four pages cannot drift apart the way the settings list and
    /// the share sheet did — the same reason `StoryAudienceRow.insets` exists.
    private static let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    /// Avatar + its gap, so the grey line starts under the name instead of under the picture.
    private static let separatorInset: CGFloat = 52

    private var visible: [StoryContact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let pool = q.isEmpty ? people : people.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return pool.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var chosen: [StoryContact] { visible.filter { selected.contains($0.id) } }
    private var rest: [StoryContact] { visible.filter { !selected.contains($0.id) } }

    var body: some View {
        List {
            // An empty group is not drawn at all rather than drawn with a line of apology text: the
            // heading is the whole label, and a heading with nothing under it says it twice. (No
            // empty-state art or copy — his standing rule.)
            if !chosen.isEmpty {
                Section { ForEach(chosen) { row($0) } } header: { header(selectedHeader) }
            }
            if !rest.isEmpty {
                Section { ForEach(rest) { row($0) } } header: { header(unselectedHeader) }
            }
            if visible.isEmpty && isLoading {
                Section { ProgressView() }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Name or username")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // ✕ rather than the word Cancel, his point 1. The label is still there for
                // VoiceOver, which cannot read a glyph.
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave() }
                    .fontWeight(.semibold)
                    .disabled(requireAtLeastOne && selected.isEmpty)
            }
        }
    }

    /// ⚠️ `.textCase(nil)` AND `.primary`: a grouped list's own heading is small grey capitals, and
    /// his screenshot is plain dark sentence case. It is the heading that tells you what a tick on
    /// that card means, so it is worth being readable.
    private func header(_ t: String) -> some View {
        Text(t).font(.headline).foregroundStyle(.primary).textCase(nil)
    }

    /// One person. Its own function, not inline in the `ForEach`: a `List` body carrying several
    /// closures over a binding is what the Swift type-checker gives up on ("unable to type-check in
    /// reasonable time"), and every one of those costs a CI round trip.
    @ViewBuilder private func row(_ c: StoryContact) -> some View {
        Button {
            // Animated because the row LEAVES — it is the card it sits in that answers "am I
            // hidden", so the move between cards has to be visible to be the answer.
            withAnimation(.snappy) {
                if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: c.name, photoUrl: c.photo, size: 40)
                Text(c.name).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                StoryTick(on: selected.contains(c.id))
            }
            .contentShape(Rectangle())
        }
        .listRowInsets(Self.rowInsets)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + Self.separatorInset }
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
    /// ⚠️ WHETHER AN EMPTY SELECTION IS A REFUSAL, AND IT IS ONLY TRUE WHERE THE SCREEN IS BUILDING
    /// SOMETHING. Creating a list or a one-time story with nobody in it makes no sense, so Done is
    /// dead there. EDITING an existing list is the opposite case: emptying it is the whole point of
    /// the visit. It was written for the old "Hide Story From" editor, where the hardcoded rule
    /// meant unticking the last hidden person killed the only button that saves — so the last person
    /// hidden could never be un-hidden from the screen that hides them, and the X discards.
    ///
    /// ⚠️ NO CALLER PASSES `false` ANY MORE (2026-09-05): the hide editor it was added for is gone,
    /// replaced by the per-person switches on `EveryonePrivacyView`. Kept because the reasoning above
    /// is about this screen, not about that one caller, and the next editing use will need it.
    var requiresSelection: Bool = true

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
                    .disabled(requiresSelection && selected.isEmpty)
            }
        }
        .onAppear { contacts = StoryContact.all() }
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
    /// The pending raise, held so leaving the page can cancel it. See the `.onAppear` below.
    @State private var focusWork: DispatchWorkItem?

    var body: some View {
        List {
            Section {
                TextField("Story Name (Required)", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    // ⚠️ CLAMPED AS IT IS TYPED, NOT REFUSED ON SAVE. His 2026-08-12 limit. A
                    // validator that only complains at the end lets somebody write a sentence and
                    // then takes it away; this simply stops accepting characters, which is what
                    // every native field with a ceiling does.
                    .onChange(of: name) { _, new in
                        if new.count > StoryAudience.nameLimit {
                            name = String(new.prefix(StoryAudience.nameLimit))
                        }
                    }
            } footer: {
                // The count appears only once it is nearly spent — the same rule the username
                // screen uses, and for the same reason: a counter on an empty field is noise.
                Text(name.count >= StoryAudience.nameLimit - 5
                     ? "Only you can see the name of this story. \(StoryAudience.nameLimit - name.count) left."
                     : "Only you can see the name of this story.")
            }

            // ⛔ REPLIES ONLY — owner, 2026-09-05: "Custom story + My Friends: allow blocking REPLY
            // only. Remove block-react." THE THREE SCREENS THAT CARRY THIS CONTROL ALL READ THIS
            // NOTE (My Friends and a custom story's page are the other two).
            //
            // ⚠️ THERE WAS NEVER A SECOND STORED SETTING TO DELETE. `allowReplies` is the only key,
            // and it has only ever closed the reply bar: the story viewer hands a story with replies
            // off `.plain(config: StoryInteractionConfig(showLikeButton: true))`, which is a heart
            // with no text field, so the reaction survives whatever this switch says. That is his own
            // earlier ruling — "don't close react love, open react, only close reply" — already in
            // the code. What the label and the footer promised was therefore a block the app does not
            // perform, and removing the react-block means removing that claim.
            Section {
                Toggle("Allow Replies", isOn: $allowReplies).tint(.green)
            } header: {
                Text("Replies")
            } footer: {
                Text("Let people who can view your story reply.")
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
        //
        // ⚠️ AFTER THE PUSH, NOT DURING IT — his 2026-08-18 report, with the keyboard photographed
        // sliding in from the RIGHT instead of up from the bottom, and the page arriving offset with it.
        //
        // This was `.onAppear`, which fires as the push BEGINS. So the field took first responder
        // while this view was still travelling in from the right edge, and the keyboard's own
        // presentation was handed to the navigation controller's in-flight transition: it rode the
        // push sideways rather than running its own upward curve. The stutter he calls lag is the
        // same instant — a keyboard appearing mid-push forces this List to re-lay-out its three
        // sections against a safe area that is changing on two axes at once.
        //
        // 0.35s is `UINavigationController`'s own push duration, so the field is asked the moment the
        // page has stopped moving and the keyboard gets the whole screen to itself and its normal
        // curve. `.task` rather than a dispatch, so backing out of the page cancels it instead of
        // raising a keyboard onto a view that has gone.
        // ⚠️ `.onAppear`, NOT `.task`, AND THAT IS THE WHOLE OF "it's working first time only".
        //
        // `.task` runs ONCE PER VIEW IDENTITY. Coming back to build a second custom list without the
        // sheet being dismissed reuses this same view, so the task never ran again — and `@FocusState`
        // is part of that reused view, so `nameFocused` was STILL TRUE from the first visit. The field
        // therefore took first responder the instant it existed, which is the beginning of the push,
        // which is the sideways keyboard all over again. The first visit worked because the flag
        // started false and only the delayed write raised it.
        //
        // `.onAppear` fires on every appearance, reused view or not. Lowering the flag here is what
        // makes the delayed write the only thing that can raise the keyboard, on the second visit as
        // much as the first.
        .onAppear {
            nameFocused = false
            focusWork?.cancel()
            // 0.35s is `UINavigationController`'s own push duration, so the field is asked the moment
            // the page has stopped moving and the keyboard gets the screen to itself.
            let work = DispatchWorkItem { nameFocused = true }
            focusWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        // Backing out before it lands must not raise a keyboard onto a page that has gone, and must
        // leave the flag DOWN for the next visit — the pair is the fix, not either half.
        .onDisappear {
            focusWork?.cancel()
            focusWork = nil
            nameFocused = false
        }
    }
}

// MARK: - The two hide lists, read and written the same way from both pages

// ⛔ THERE ARE TWO SEPARATE HIDE LISTS AND THEY ALWAYS WERE — this is what makes the owner's
// 2026-09-05 request ("let me hide someone from my chat, from my glow, or both, independently")
// buildable without touching the model at all:
//
//   • CHAT   — `StoryAudienceStore.hiddenFrom`, written with `setHidden`. `appliesGlobalHide` is
//              true for Everyone alone, and Everyone resolves to your accepted chats, so this is
//              exactly "hidden from my chat". It also revokes the stories already up.
//   • GLOW   — the Glowers audience's own `.except` members, written with `store.update`. Glowers
//              resolves to the glow relationship and never meets `hiddenFrom` at all.
//
// Nothing in either path is intersected with the other, so a person can be in one, the other, both
// or neither. That independence is the feature. Since 2026-09-11 there is ONE PAGE PER LIST — the
// Everyone page ticks the chat list, the Glowers page ticks the glow list — which is what let both
// of them become the same screen. See `StoryPeoplePicker`.
//
// `fileprivate`, not an extension on the store: the store lives in another file that other work is
// touching, and a helper declared here cannot collide with one added there.

/// Write the whole glow-hide list at once.
///
/// ⚠️ THE WHOLE LIST, not one person at a time: since 2026-09-11 the Glowers page keeps a draft and
/// commits it on Save, the same as every other privacy page, so what arrives here is the finished
/// answer rather than a single tap.
///
/// ⚠️ THE MODE IS INFERRED FROM WHAT IS LEFT, exactly as `GlowersPrivacyView` has always inferred
/// it: nobody excluded is `.all`, somebody excluded is `.except`. Written as a rule rather than
/// chosen, so the stored mode cannot disagree with the stored list.
///
/// ⛔ THIS ONLY EVER SUBTRACTS. It is why a demo uid is safe here in a way it would never be in
/// `recipientUids` — see the note on `realGlowRelationship`.
fileprivate func setHiddenFromGlow(_ hidden: Set<String>, _ store: StoryAudienceStore) {
    var n = store.glowers
    let members = hidden.filter { !$0.isEmpty }
    // Sorted, not `Array(set)`: a Set hands back its members in whatever order it feels like, so an
    // unsorted copy writes a different array to Firestore on every save even when the set of people
    // has not changed — and this array is also what the loader's key is built from.
    n.members = members.sorted()
    n.mode = members.isEmpty ? .all : .except
    store.update(n)
}

// MARK: - Everyone

/// ⛔ EVERYONE IS THE PAGE THAT LISTS PEOPLE FROM BOTH SOURCES — owner, 2026-09-05, his words:
/// "Everyone page = friends' chats + glowers, and let me hide someone from my chat, from my glow, or
/// both, independently."
///
/// ⛔ ONE TICK NOW, NOT TWO SWITCHES — owner, 2026-09-11, asked and confirmed: the tick on THIS page
/// means hidden from your chats, the tick on the Glowers page means hidden from your glow. The two
/// lists are still separate and a person can be on one, the other, both or neither — his 09-05
/// "independently" survives, it is just answered on two pages instead of two switches on one. What
/// it buys is the thing he actually asked for: this page and the Glowers page are now the same
/// screen, so a tick means the same thing wherever he sees it. See `StoryPeoplePicker`.
///
/// ⚠️ WHAT THAT REPLACED: a section per person carrying "Hide from Chats" and "Hide from Glow".
/// It was honest about the model and it was the only page in the app shaped that way.
///
/// ⚠️ THE UNION IS FOR THE LIST ONLY. It decides who gets a row on this page and nothing else; the
/// audiences themselves still resolve exactly as they did. In particular the glow side is NOT
/// intersected with the chat list anywhere here — a glower is very often somebody you have never
/// chatted with, which is the whole point of the feature.
///
/// ⚠️ IT REACHES BACKWARDS AS WELL AS FORWARDS on the chat side. `setHidden` also takes the person
/// off every story that is already up (see its own note), so that switch is not only a rule for the
/// next post. The glow switch is not retrospective — it narrows the next Glowers post.
///
/// The audience itself is still fixed and still cannot be edited, which was his earlier rule:
/// Everyone means everyone, and a version of it with people carved out would be a custom list under
/// another name. What this page edits are the two separate hide lists — see the helpers above.
///
/// ⚠️ WHAT THIS REPLACED: one "Hide Story From" row that opened a tick-list into `hiddenFrom`. It
/// could say nothing about glow at all, so there was no way to hide a glower without hiding them
/// from your chats as well.
struct EveryonePrivacyView: View {
    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init() {}

    @State private var store = StoryAudienceStore.shared
    @State private var contacts: [StoryContact] = []
    @State private var glowPeople = GlowPeopleLoader()
    /// Who is ticked right now, and not yet who is hidden. Seeded from the stored list the first
    /// time the page appears and written back only on Save — see `StoryPeoplePicker`.
    @State private var draft: Set<String> = []
    @State private var seeded = false
    @Environment(\.dismiss) private var dismiss
    /// ⚠️ `glowRelationship`, THE SCREEN-FACING ONE, so demo people are listed and can be hidden
    /// while he is testing — the same choice `GlowersPrivacyView` makes and for the same reason.
    /// Nothing on this page can put a uid into a recipient list; the tick only ever subtracts.
    private var glow = GlowService.shared

    /// The people this page has to fetch names for: the glow relationship, plus anybody already on
    /// either hide list.
    ///
    /// ⚠️ THE HIDE LISTS ARE IN HERE ON PURPOSE. Somebody you hid and then stopped chatting with (or
    /// stopped glowing) would otherwise have no row, and no way back off the list they are on.
    ///
    /// ⚠️ THE CHAT LIST IS DELIBERATELY NOT SUBTRACTED, even though it can name most of these people
    /// already. `contacts` arrives a beat after the first render, so subtracting it would change this
    /// key once on every open — and `GlowPeopleLoader.load` drops back to `.loading` whenever the key
    /// moves, which is a list that empties itself just after it has drawn. A handful of profile
    /// fetches the chat list could have answered is the cheaper of the two, and `everybody` below
    /// still prefers the chat list's own name and photo when it has them.
    private var lookupUids: [String] {
        Array(glow.glowRelationship
            .union(store.hiddenFrom)
            .union(store.glowers.members))
            .sorted()
    }
    private var lookupKey: String { lookupUids.joined(separator: ",") }

    /// Chats + glowers, one entry each, by name.
    private var everybody: [StoryContact] {
        var byId: [String: StoryContact] = [:]
        for c in contacts { byId[c.id] = c }
        for p in glowPeople.state.value ?? [] where byId[p.id] == nil {
            byId[p.id] = StoryContact(id: p.id, name: p.name, photo: p.photoUrl)
        }
        return byId.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        StoryPeoplePicker(
            title: "Everyone",
            selectedHeader: "Hidden Users",
            unselectedHeader: "Everyone",
            people: everybody,
            selected: $draft,
            isLoading: glowPeople.state.isLoading,
            onSave: { save() },
            onClose: { dismiss() })
        // `.onAppear` rather than `.task`: coming back to this page after blocking somebody has to
        // recount the chats, and a task keyed to the view's identity would not run again.
        .onAppear {
            contacts = StoryContact.all()
            // ONCE. `onAppear` fires again when the sheet comes back to the front, and re-seeding
            // there would throw away a selection he had already made.
            if !seeded { draft = store.hiddenFrom; seeded = true }
        }
        .task(id: lookupKey) { await glowPeople.load(lookupUids, key: lookupKey) }
    }

    /// ⛔ ONLY THE PEOPLE WHOSE SIDE ACTUALLY CHANGED. `setHidden` is the door that also revokes the
    /// stories already up (see its own note), so calling it for somebody who was already hidden
    /// would take a live story down and put it straight back. The two-way difference is the whole
    /// of the work, and it is why this page keeps a draft instead of writing on the tap.
    ///
    /// ⚠️ A DEMO UID CAN REACH THIS LIST, because the rows include glowers and the glow relationship
    /// carries demo people while he is testing. It is safe in the way the Glowers except-list is
    /// safe and NOT in the way `recipientUids` is dangerous: this list only ever subtracts, a fake
    /// id in it removes nobody, and the same tick takes it back out again. See the note on
    /// `realGlowRelationship`.
    private func save() {
        let was = store.hiddenFrom
        for uid in draft.subtracting(was) { store.setHidden(uid, true) }
        for uid in was.subtracting(draft) { store.setHidden(uid, false) }
        dismiss()
    }
}

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

            // ⛔ REPLIES ONLY — owner, 2026-09-05. The reasoning, and why there was no second stored
            // setting to remove, is written once on the same control in `NameStoryView`.
            Section {
                Toggle("Allow Replies", isOn: Binding(
                    get: { a.allowReplies },
                    set: { v in var n = a; n.allowReplies = v; store.update(n) }
                )).tint(.green)
            } header: {
                Text("Replies")
            } footer: {
                Text("Let people who can view your story reply.")
            }
        }
        .navigationTitle("My Chats")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { contacts = StoryContact.all() }
        .sheet(item: $picking) { target in
            NavigationStack {
                // THE SAME SCREEN THE TWO HIDE PAGES USE — his 2026-09-11 point 6 and 7. All that
                // changes between the four is the pair of headings and where the answer is written.
                StoryPeoplePicker(
                    title: target == .except ? "All Except" : "Only Share With",
                    selectedHeader: target == .except ? "Excluded" : "Selected",
                    unselectedHeader: target == .except ? "Not Excluded" : "Not Selected",
                    people: contacts,
                    selected: $draft,
                    // NOTHING CHOSEN IS NOT A CHOICE. Save stays dead until at least one person is
                    // picked, the same rule Select Viewers already uses for a custom story — an
                    // empty except-list and an empty only-list both mean "the mode did nothing".
                    requireAtLeastOne: true,
                    onSave: {
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
                    onClose: { picking = nil })
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

// MARK: - Glowers

/// ⛔ THE LIST ITSELF, NOT A PAGE ABOUT THE LIST — owner, 2026-09-02: "you are doing wrong, fix; the
/// Glowers page is wrong. Only show, when the user clicks Glowers, the glowers list and select to
/// hide, like image 2".
///
/// ⚠️ WHAT I BUILT FIRST AND WHY IT WAS WRONG. My first pass copied `MyFriendsPrivacyView`: two
/// radio rows (All / All Except…) with the picker one tap behind the second one. That is the right
/// shape for My Friends, which has three genuinely different modes; Glowers has one question — who
/// do I leave out — and wrapping a single question in a mode picker made a screen out of a list.
/// His image 2 is the picker, opened directly, and it is the whole feature.
///
/// The mode is INFERRED from what comes back rather than chosen: nobody excluded is `.all`,
/// somebody excluded is `.except`. That is the same information the radio rows were collecting, and
/// this way it cannot disagree with the list.
///
/// ⚠️ THE CANDIDATE LIST IS THE LIVE RELATIONSHIP, resolved the way every other Glow screen resolves
/// it. `StoryContact.all()` is the wrong source here and would be the same mistake `rawRecipients`
/// documents: it lists people you share an accepted chat with, and a glower is precisely somebody
/// you might not.
///
/// ⛔ TWO GROUPS NOW, HIDDEN AND NOT HIDDEN — owner, 2026-09-05: "The Glowers hide page is confusing.
/// Redesign… Glowers page = show hidden users and non-hidden glowers, clearly separated."
///
/// ⚠️ WHY THE TICK-LIST WAS CONFUSING, and it is worth writing down because the tick-list was itself
/// a fix for an earlier confusion. A checkbox beside a name answers "is this one ticked", and on this
/// page a tick meant HIDDEN — the opposite of every other tick in the app, where a tick means chosen
/// and included. Nothing on the screen said which way round it was, and the people it applied to were
/// mixed in with the people it did not. Two labelled groups say it without a caption: the group a
/// name is in IS its state, and tapping a row is the only thing that moves it.
///
/// ⛔ IT IS `StoryPeoplePicker` NOW — owner, 2026-09-11. The two groups, the search and the sorting
/// are all the shared screen's; this type is only the answer to "which list am I editing" and
/// "where do I write it". The Hide / Unhide words on the right are gone, replaced by the same blue
/// tick every other page uses, because the card a name sits in already says which it is.
///
/// ⚠️ A DRAFT COMMITTED ON SAVE, which is a change: this page used to write on the tap, on the
/// grounds that hiding a glower revokes nothing already up and so there was nothing to protect.
/// That is still true, but the screen now carries a Save button, and a Save button that has already
/// saved is a lie. ✕ discards.
struct GlowersPrivacyView: View {
    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init() {}

    @State private var store = StoryAudienceStore.shared
    @State private var people = GlowPeopleLoader()
    /// Who is ticked right now, and not yet who is hidden — see `StoryPeoplePicker`.
    @State private var draft: Set<String> = []
    @State private var seeded = false
    @Environment(\.dismiss) private var dismiss
    private var glow = GlowService.shared

    private var a: StoryAudience { store.glowers }
    /// ⚠️ `glowRelationship`, THE SCREEN-FACING ONE, so demo people are listed and can be hidden
    /// while he is testing. A demo uid landing in this except-list is safe in a way it would not be
    /// in `recipientUids`: this list only ever SUBTRACTS, so a fake id in it reaches nobody and
    /// removes nobody. See the note on `realGlowRelationship`.
    ///
    /// ⚠️ THE STORED EXCEPT-LIST IS UNIONED IN. Somebody hidden who has since stopped glowing is no
    /// longer in the relationship, and without this they would keep their place on the hidden list
    /// with no row anywhere to take them off it.
    ///
    /// ⚠️ HIDING AND UNHIDING A REAL GLOWER DOES NOT MOVE THIS KEY, because they are already in the
    /// relationship — so the ordinary tap does not send the loader back to `.loading`. The one case
    /// that does move it is unhiding somebody who has since stopped glowing, and their row leaving
    /// the page is the correct outcome of that tap anyway.
    private var uids: [String] { Array(glow.glowRelationship.union(a.members)).sorted() }
    private var key: String { uids.joined(separator: ",") }
    private var contacts: [StoryContact] {
        (people.state.value ?? []).map { StoryContact(id: $0.id, name: $0.name, photo: $0.photoUrl) }
    }

    var body: some View {
        StoryPeoplePicker(
            title: "Glowers",
            selectedHeader: "Hidden Users",
            unselectedHeader: "Glowers",
            people: contacts,
            selected: $draft,
            isLoading: people.state.isLoading,
            onSave: {
                setHiddenFromGlow(draft, store)
                dismiss()
            },
            onClose: { dismiss() })
        // ONCE. The sheet coming back to the front must not throw away a selection he has made.
        .onAppear { if !seeded { draft = Set(a.members); seeded = true } }
        .task(id: key) { await people.load(uids, key: key) }
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
        .onAppear { contacts = StoryContact.all() }
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

            // ⛔ REPLIES ONLY — owner, 2026-09-05. The reasoning, and why there was no second stored
            // setting to remove, is written once on the same control in `NameStoryView`.
            Section {
                Toggle("Allow Replies", isOn: Binding(
                    get: { a.allowReplies },
                    set: { v in var n = a; n.allowReplies = v; store.update(n) }
                )).tint(.green)
            } header: {
                Text("Replies")
            } footer: {
                Text("Let people who can view your story reply.")
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
                // The same ceiling as the create screen. An alert's TextField cannot be clamped as
                // it is typed (there is no `onChange` inside an alert builder), so it is trimmed
                // here — the one place a rename can be committed.
                let t = draftName.trimmingCharacters(in: .whitespaces).prefix(StoryAudience.nameLimit)
                guard !t.isEmpty else { return }
                var n = a; n.name = String(t); store.update(n)
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

// ⛔ `MembersEditor` IS GONE — 2026-09-11. It was the My Friends except/only list, a flat tick-list
// with Cancel and Done. `StoryPeoplePicker` replaced it for both of its callers, and keeping a
// second, nearly identical editor around is exactly the drift he is asking to have removed.

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
                .onAppear { contacts = StoryContact.all() }
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
        // 15pt semibold for the word and 11pt for the plus. Scaled through UIFontMetrics so it still
        // grows for anyone using larger text — a hardcoded 15 would be the one control on the screen
        // that ignored the setting.
        //
        // ⚠️ THE PLUS IS 11, NOT 13 (owner 2026-08-11, both screens circled: "the + icon make it
        // small not to much"). A symbol drawn at the SAME weight as the word beside it reads BIGGER
        // than the word even at a smaller point size — the glyph fills its box while a capital N
        // does not — so matching the two sizes by number is what made it tower. 11 lands the plus at
        // about the word's cap height, which is the proportion iOS uses for a header accessory.
        // Two points, not four: he asked for smaller, not for a hairline.
        //
        // (Said plainly: these are matched by eye and by iOS convention. I could not read the reference app's
        // source to copy their constants, and inventing numbers and calling them the reference app's would be
        // worse than saying so.)
        var cfg = UIButton.Configuration.gray()
        let metrics = UIFontMetrics(forTextStyle: .subheadline)
        var title = AttributeContainer()
        title.font = metrics.scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        cfg.attributedTitle = AttributedString("New", attributes: title)
        cfg.image = UIImage(systemName: "plus",
                            withConfiguration: UIImage.SymbolConfiguration(
                                font: metrics.scaledFont(for: .systemFont(ofSize: 11, weight: .semibold))))
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
                              image: Self.menuIcon("ic_story_folder")) { _ in
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

    /// A BUNDLED DRAWING, SIZED THE WAY THE MENU SIZES A SYMBOL.
    ///
    /// UIKit scales an SF Symbol in a menu to the row's text metrics. It does not do that for an
    /// image out of the asset catalogue — that one is drawn at its natural size, so our folder came
    /// out visibly larger than the flame sitting directly under it (his screenshot, with the folder
    /// circled).
    ///
    /// The target box is asked of the FLAME rather than written down, because the flame is the thing
    /// it has to match and its size moves with the user's text size. Aspect is preserved and the
    /// drawing is fitted inside that box, so a square icon fills it and a tall one is not stretched.
    /// Template mode so it tints with the menu label exactly as a symbol does — and so a disabled
    /// item greys the icon along with its text.
    private static func menuIcon(_ name: String) -> UIImage? {
        guard let raw = UIImage(named: name), raw.size.width > 0, raw.size.height > 0 else {
            return UIImage(named: name)
        }
        let box = UIImage(systemName: "flame")?.size ?? CGSize(width: 22, height: 22)
        let scale = min(box.width / raw.size.width, box.height / raw.size.height)
        let fitted = CGSize(width: raw.size.width * scale, height: raw.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: fitted, format: format).image { _ in
            raw.draw(in: CGRect(origin: .zero, size: fitted))
        }
        return drawn.withRenderingMode(.alwaysTemplate)
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
