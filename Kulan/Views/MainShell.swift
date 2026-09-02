import SwiftUI
import UIKit

/// Ticking a row on or off, everywhere a list in this file has multi-select.
///
/// It exists because the three lists had drifted into three different answers: the chat list used
/// `.smooth(0.2)`, the archive list repeated that by hand, and the calls list had NO animation at
/// all, so its circle simply appeared. One function means a tick feels the same wherever you are.
///
/// The spring is deliberate. `.smooth` is a pure ease and reads as a fade; a light overshoot is what
/// makes a tick feel like it LANDED. It is small on purpose (0.24s, damping 0.7): this fires on every
/// row you touch while picking twenty of them, and anything bouncier becomes noise by the third tap.
///
/// ⚠️ The circle itself is Apple's, drawn by `List(selection:)` in edit mode, so the curve and the
/// haptic are the whole of what we control here. A tick that draws its check on and scales from
/// nothing needs our own view, which is a much larger change to this file — see the note on the
/// row's structural identity in `chatListRow`.
/// ⚠️ A `Binding`, NOT `inout`. `inout` on a `@State` property is copy-in/copy-out: the assignment
/// inside `withAnimation` would land on a local temporary and only be written back to the real
/// storage when this function RETURNS, which is after the transaction has closed. The tick would
/// snap, the code would look correct, and nothing would say so. A Binding's setter runs at the point
/// of assignment, so it is inside the transaction where it belongs.
@MainActor func toggleTick(_ id: String, in selection: Binding<Set<String>>) {
    // The system's own tick sound-and-feel. `.selectionChanged()` is the light one Apple uses for a
    // picker detent, NOT an impact — an impact on every row of a twenty-row selection is a hammer.
    UISelectionFeedbackGenerator().selectionChanged()
    var next = selection.wrappedValue
    if next.contains(id) { next.remove(id) } else { next.insert(id) }
    withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) { selection.wrappedValue = next }
}

// ⚠️ `StoryPresentation` IS GONE, AND SO IS THE FLAT WINDOW DIM IT DROVE (2026-08-07).
//
// It was one bool that switched a `Color.black.opacity(0.45)` over this whole shell — tab bar
// included — for as long as a story cover was up. It existed because a cover cannot darken what is
// behind it: anything inside the cover shrinks with the cover. Every door is on `StoryZoomPresenter`
// now, and that screen paints its own wall on the flight's own fraction (`heroDim`), so the backdrop
// answers to the finger continuously instead of snapping to grey on the first frame and back to
// white on the last. That snap is what the owner called "not fluid, not bound to the story frame".
//
// Do not reintroduce a boolean dim to "help" a door. Two dims on one flight is two curves fighting
// over the same pixels, and only one of them can be the one his finger is drawing.

// Native TabView keeps both tabs permanently mounted -> the header avatar never
// unmounts/blinks on tab switch (the RN bug, solved structurally).
struct MainShell: View {
    var onSignOut: () -> Void
    private var call: CallService { CallService.shared }
    private var profile = ProfileStore.shared
    private var callsRepo = CallsRepository.shared   // @Observable: drives the missed-call tab badge
    @State private var settingsIcon: UIImage?
    /// ⚠️ 2, WHICH IS CHATS. Stories took slot 0 when the bar was rebuilt (2026-08-30) and Calls
    /// took slot 1 when he swapped the two middle tabs the same day. The app opens on Chats, so
    /// this number follows Chats wherever it sits — it is not a default of "first tab".
    @State private var tab = 2
    /// Was a story upload in flight on the last body pass? Drives the tab switch below; see its note.
    @State private var sawStoryUpload = false
    // Missed-call badge on the Calls tab: incoming missed calls newer
    // than the last time the tab was viewed. Local-only "seen" watermark.
    @AppStorage("callsSeenAt") private var callsSeenAt: Double = 0
    private var missedBadge: Int {
        callsRepo.calls.filter { $0.missedIncoming && $0.date.timeIntervalSince1970 > callsSeenAt }.count
    }

    // CONVERSATIONS WAITING, NOT MESSAGES WAITING — how the standard messengers badge it. One person
    // sending five messages moves this by ONE, not five: the badge answers "how many chats do I need to
    // open", which is the question a chat list badge is actually for.
    //
    // The filter is deliberately the same one `markAllRead` uses, so the badge and the action that
    // clears it can never disagree about what counts: not cleared, not archived, and not a chat we have
    // silently blocked (a blocked contact's messages never badge a row either).
    //
    // It is computed, not stored, so it needs no invalidation: opening a chat, marking one read, or a
    // new message arriving all change `repo.conversations`, and @Observable re-reads this on the spot.
    private var chatsRepo = ConversationsRepository.shared
    private var unreadChatsBadge: Int {
        let me = AuthService.shared.uid ?? ""
        guard !me.isEmpty else { return 0 }
        // The official channel counts here exactly like any other chat. It is MUTED, not silent:
        // muting stops the noise, it does not hide that something arrived, and a row showing an
        // unread badge while the tab above it shows none is the kind of disagreement that reads as
        // a bug (the same rule the blocked-chat audit landed on).
        return (chatsRepo.conversations + [OfficialChannelStore.shared.listEntry].compactMap { $0 }).filter {
            !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                && (Flags.groupsEnabled || !$0.isGroup)   // audit: a hidden legacy group badged a list that refused to show it
                // `hasUnreadMark`, not a count: a chat you marked unread yourself still badges the
                // tab, it just does not claim a number. See Conversation.unread.
                && $0.hasUnreadMark(me)
        }.count
    }

    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    var body: some View {
        // iOS 26 gets the new `Tab` API: floating Liquid-Glass pill (Chats · Calls · Settings)
        // with a native selected-tab highlight, plus the `.search` role tab drawn as the
        // SEPARATE circular button detached to the right. Older OS (deployment target 17.0)
        // can't use the `Tab` API, so it falls back to the classic `.tabItem` bar with a
        // normal 4th Search tab — same screens, just not the floating/detached styling.
        tabsLandingOnPostedStory
        // THE VOICE NOTE THAT IS STILL PLAYING, wherever you have walked to.
        //
        // `safeAreaInset` rather than an overlay, deliberately: an overlay would sit ON TOP of each
        // tab's own header, and every screen underneath would keep laying out as though the bar were
        // not there. An inset makes the room, so nothing is covered and nothing has to know about it.
        //
        // Mounted here, on the tab shell, so it survives moving between tabs and pushing into another
        // chat. It draws nothing at all unless a note is playing outside the chat on screen — see
        // `VoiceNotePlayer.barVisible`.
        .safeAreaInset(edge: .top, spacing: 0) { VoiceNoteBar() }
        // (The window dim that used to live here is gone — see the note above `MainShell`. The
        // presenter's own wall covers the tab bar and every tab's content, because it IS a screen
        // over them, and it is driven by the flight's fraction rather than by a bool.)
        // A pending chat (from a notification tap or the Calls "Go to Chat" menu) must
        // foreground the Chats tab — otherwise it opens on a hidden tab and looks like a no-op.
        .onChange(of: AppRouter.shared.pendingChatId) { _, id in
            if id != nil { tab = 2 }   // 2 = Chats: Stories took 0 and Calls took 1
        }
        // REMOVED: the conversations delta-detector banner. It was the SECOND in-app banner system.
        // `InAppBannerCenter`, added in build 383 and mounted on RootView, is driven by the push actually
        // arriving while the app is foregrounded — so one incoming message tripped both: the push fired
        // that one, and the Firestore listener updating the conversation fired this one. Two banners for
        // one message (user report).
        //
        // The push-driven one is the keeper: it rides above every screen rather than only MainShell, it
        // shows nothing for the chat you are already looking at, and it plays the chosen tone itself.
        // `InAppNotify` stays as a type because the Settings sound picker uses its `playTone` preview —
        // it just no longer presents anything.
        //
        // Known trade-off, stated rather than hidden: with notification permission denied there is no
        // push, so there is no in-app banner either. The delta detector used to cover that case. Showing
        // everyone two banners to serve a user who has switched notifications off is the wrong trade.
        // Keep Media (Settings > Storage): age out old re-downloadable photo cache on launch.
        .task {
            let d = UserDefaults.standard.integer(forKey: "keepMediaDays")
            if d > 0 { DiskImageCache.shared.sweep(olderThanDays: d) }
        }
        // An invite deep link (kulan://g/<code>) presents its Join sheet from the Chats tab — foreground
        // it so the sheet isn't dropped on a hidden tab.
        .onChange(of: AppRouter.shared.pendingInviteCode) { _, code in
            if code != nil { tab = 2 }   // 2 = Chats: Stories took 0 and Calls took 1
        }
        // Call UI is mounted at the root (CallContainer in RootView) so it survives all
        // navigation. Here we only start listening for incoming calls.
        .onAppear {
            call.observeIncoming()
            // Fresh install: a 0 watermark counted EVERY historical missed call in the badge —
            // treat everything before first launch as seen. (Same unit as the compare above: seconds.)
            if callsSeenAt == 0 { callsSeenAt = Date().timeIntervalSince1970 }
        }
        .task(id: profile.me?.photoUrl) { await loadSettingsIcon() }
        // ⚠️ `previousTab` IS GONE WITH THE SEARCH TAB. It existed for one reason: the detached
        // search circle had to know whether it was searching Chats, Calls or Settings, so the
        // shell remembered where you came from. Search lives on its own page now and each page
        // knows what it searches, so there is nothing left to remember.
        .onChange(of: tab) { _, new in
            if new == 1 { callsSeenAt = Date().timeIntervalSince1970 }   // viewing Calls clears the badge
        }
        // New records landing while the user is already ON the Calls tab count as seen too.
        .onChange(of: callsRepo.calls) { _, _ in
            if tab == 1 { callsSeenAt = Date().timeIntervalSince1970 }
        }
        // Load call history at startup so the badge is right before the tab is ever opened
        // (CallsView's own .task keeps it fresh after; the 30s TTL stops double-fires).
        // STAGGERED ~1.5s (deferred app-readiness): this isn't needed for the first frame, and launching
        // it alongside the chat-list listener + key warm + stories load made a main-thread stampede in
        // the fragile launch window. Delaying non-critical launch work spreads the load out.
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await CallsRepository.shared.load()
        }
    }

    // Your profile photo as the Settings tab icon (full-color circle); falls back to a
    // person glyph — outline when inactive, filled when this tab is active. SwiftUI does NOT
    // auto-swap a base SF Symbol to its .fill on selection (it only tints), so we pick it.
    /// ⛔ A PRE-RENDERED GLYPH, BECAUSE A TAB ITEM DROPS VIEW MODIFIERS. His screenshot: the
    /// Stories icon came in at roughly twice the others and sat over its own label.
    ///
    /// `ic_stories.svg` declares an intrinsic 64pt and `ic_chat.svg` declares 27, which is the whole
    /// difference — Chats has been correct by accident. The 64 is deliberate and must stay: MenuIcon
    /// measures the ink on something big so the trim does not turn on a few edge pixels.
    ///
    /// `.resizable().frame(25)` does not fix it either. A tab item is converted to a native UIKit
    /// element and that conversion drops view modifiers — the same failure `MenuIcon`'s own comment
    /// records from the menus and the swipe actions, twice. Baking the size into the bitmap is the
    /// one thing the conversion cannot ignore, so this uses the same renderer they do.
    @ViewBuilder private var storiesTabLabel: some View {
        // ⛔ `ic_stories_fill` IS THE OUTLINE'S OWN GEOMETRY, NOT A NEW DRAWING. He asked for this
        // tab to fill like the others, so the front card of the existing mark is filled solid and
        // the plus is knocked OUT of it with `fill-rule="evenodd"` — the plus has to be a hole
        // rather than a white shape, because these assets render as TEMPLATES and a white fill
        // would be repainted with everything else.
        //
        // The back card stays a stroke on purpose. Filling both would need the front card
        // subtracted out of the back one to keep the gap between them, which is boolean geometry
        // and not something to hand-write into a path. One solid card behind one outlined card
        // reads as "selected" and keeps the mark he approved.
        Label { Text("Stories") } icon: { MenuIcon(tab == 0 ? "ic_stories_fill" : "ic_stories", size: 25) }
            .foregroundStyle(tab == 0 ? Color.primary : Color.secondary)
    }

    /// ⛔ THE ICON ACTUALLY SWAPS NOW, AND THE OLD CODE ONLY LOOKED LIKE IT DID.
    ///
    /// `Tab("Calls", systemImage: tab == 1 ? "phone.fill" : "phone", value: 1)` takes the icon's
    /// NAME and keeps whichever it was handed, so that ternary was read exactly ONCE, at launch,
    /// when the selected tab was not Calls. No build has ever drawn the filled phone. It reads like
    /// working code and has been dead since it was written.
    ///
    /// The `label:` closure form is re-evaluated when `tab` changes, which is the whole fix, and the
    /// Settings tab has quietly proved it for months.
    ///
    /// His call, 2026-08-30, after reading what the reference does on a tap: three things change
    /// there — a different drawing, a different colour, and a small animation. He asked for BLACK on
    /// the selected tab, so ours is a filled glyph in `.primary` against an outline in `.secondary`.
    ///
    /// ⚠️ THE COLOUR HALF MAY NOT TAKE. The tab bar is native UIKit under SwiftUI and it tints its
    /// own items; a `foregroundStyle` on the label is advice it is free to ignore, the same way it
    /// ignores `.resizable()`. The glyph swap does not depend on the colour landing.
    @ViewBuilder private var chatsTabLabel: some View {
        Label {
            Text("Chats")
        } icon: {
            MenuIcon(tab == 2 ? "ic_chat" : "ic_chat_outline", size: 25)
        }
        .foregroundStyle(tab == 2 ? Color.primary : Color.secondary)
    }

    @ViewBuilder private var callsTabLabel: some View {
        Label {
            Text("Calls")
        } icon: {
            // ⛔ PRE-RENDERED, BECAUSE A TAB BAR SUBSTITUTES THE `.fill` VARIANT BY ITSELF. His
            // report on 721: "the call one is always full, tap or not". The ternary was right and
            // the system was overriding it — UIKit's tab bar asks SF Symbols for the FILLED variant
            // of whatever symbol it is handed, so `phone` and `phone.fill` both arrive filled.
            //
            // Handing it a bitmap ends the argument: there is no symbol left for it to substitute.
            // Same renderer as the other three tabs, so all four are now one mechanism.
            //
            // ⚠️ THE COST, STATED: a bitmap cannot play `.symbolEffect(.replace)`, so the swap is
            // instant rather than animated. Theirs animates; ours is correct first.
            // ⛔ `.environment(\.symbolVariants, .none)`, NOT `.symbolVariant(.none)`, AND THE
            // DIFFERENCE IS THE WHOLE BUG.
            //
            // A tab bar deliberately forces the FILLED variant of any SF Symbol it is given — that
            // is documented behaviour since iOS 15, and it is why build 722 showed a filled phone
            // whether or not Calls was the selected tab. My first attempt to refuse it used
            // `.symbolVariant(.none)`, which COMBINES with the variant already in the environment
            // rather than replacing it, so the bar's `.fill` survived and nothing changed. Writing
            // the environment value directly is what overwrites it.
            //
            // Kept as a real symbol rather than the bitmap the other tabs use, deliberately: a
            // symbol is the only thing iOS can fill progressively as the glass pill glides over it,
            // which is the effect he is asking for. A bitmap forecloses it.
            //
            // ⚠️ IF THIS STILL COMES BACK FILLED, the environment is not the lever either and the
            // answer is that the bar simply cannot show an unselected symbol. Then this goes back to
            // `MenuIcon(system:)`, which does work, and the smooth fill needs a hand-built tab bar —
            // which is how the reference app does it: no system tab bar at all, and each icon is a
            // one-shot animation file (`AnimatedStickerNode`, `playbackMode: .once`, TabBarNode).
            Image(systemName: tab == 1 ? "phone.fill" : "phone")
                .environment(\.symbolVariants, .none)
                .contentTransition(.symbolEffect(.replace))
        }
        .foregroundStyle(tab == 1 ? Color.primary : Color.secondary)
    }

    @ViewBuilder private var settingsTabLabel: some View {
        Label {
            Text("Settings")
        } icon: {
            if let ui = settingsIcon {
                Image(uiImage: ui).renderingMode(.original)
            } else {
                Image(systemName: tab == 3 ? "person.crop.circle.fill" : "person.crop.circle")
                    .contentTransition(.symbolEffect(.replace))   // smooth fill<->outline swap
            }
        }
    }

    /// The tab view, plus the one observer that lands a posted story on the Chats tab.
    ///
    /// ⚠️ A PROPERTY RATHER THAN ANOTHER MODIFIER ON `body`, and that is not style. Adding this
    /// `onChange` directly to the body's chain tipped it past the type-checker's budget — "unable to
    /// type-check this expression in reasonable time" — which this file has hit before. A separate
    /// property gets its own budget and the chain in `body` is left as it was.
    ///
    /// ⛔ A POSTED STORY LANDS YOU ON THE CHATS TAB — owner, 2026-08-25, after posting: the camera
    /// was still on screen, and behind it he had no sight of the story he had just sent.
    ///
    /// The reference app switches to its chat list BEFORE the upload even starts, then scrolls that
    /// list's story row to your own avatar, and only then lets the editor collapse into it — so the
    /// uploading ring is what you are looking at when the editor leaves. Ours draws that ring in the
    /// row's first slot; this is the half that takes you to it, and `StoriesRowUIKit.applyMyCard`
    /// brings the row itself back to the front.
    ///
    /// ⚠️ KEYED TO THE UPLOAD STARTING, not to the post button, because that is the one signal that
    /// exists wherever a story can be posted from — the camera, the library picker, a text story, the
    /// audience sheet. A flag at each of those call sites would be four places to keep in step and a
    /// fifth to forget.
    private var tabsLandingOnPostedStory: some View {
        Group {
            if #available(iOS 26.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .onChange(of: StoriesService.shared.uploading) { _, uploading in
            let wasUploading = sawStoryUpload
            sawStoryUpload = uploading
            guard uploading, !wasUploading, tab != 0 else { return }
            tab = 0
        }
    }

    @available(iOS 26.0, *)
    private var modernTabView: some View {
        TabView(selection: $tab) {
            // ⚠️ BACK TO HOW IT WAS, ON THE OWNER'S WORD (2026-08-19). A whole afternoon went into
            // making these two icons swap between outline and filled on selection, it shipped to a
            // browser preview, he looked at it and said something was still off and he needs time to
            // decide. So this is the original, unchanged, and the decision is parked.
            //
            // ⚠️ AND THE LINE BELOW DOES NOT DO WHAT IT LOOKS LIKE IT DOES. `Tab(_:systemImage:value:)`
            // takes the icon's NAME and keeps the one it was handed, so this ternary is read exactly
            // once, at launch, with tab == 0 — Calls has therefore been permanently `phone` since it
            // was written, and no build has ever shown `phone.fill` here. It is left in place because
            // that IS the behaviour he is looking at and asked to keep for now. Making it real needs
            // the `label:` closure form. Do not "fix" it as a typo, and read the memory note first:
            // it holds the Apple guidance, why a black tint leaves the capsule as the only signal,
            // and the outline asset that is already drawn and waiting (`ic_chat_outline`).
            // ⛔ STORIES FIRST, AND SEARCH IS NOT A TAB ANY MORE — his call, 2026-08-30, off two
            // mockups. Search belongs at the top of the page it searches: Calls has had its own bar
            // for months and Chats has one now, which is what the detached circle was standing in
            // for. Settings gets none at all, on his word.
            // ⚠️ `ic_stories`, THE APP'S OWN GLYPH, NOT AN SF SYMBOL. His mockup of the bar draws
            // the stacked cards with a plus — the same mark the Stories tab's own add button wears,
            // so the tab and the action that fills it are one drawing. SF Symbols has nothing that
            // reads as "stories", and the circle-dashed stand-in that was here first read as a
            // loading state.
            Tab(value: 0) {
                StoriesTabView(onSignOut: onSignOut)
            } label: {
                storiesTabLabel
            }
            // ⛔ CALLS SITS BESIDE STORIES, CHATS SITS BESIDE SETTINGS — his call, 2026-08-30.
            // The two middle tabs are swapped from where they were this morning; the indices
            // follow the position, so Calls is 1 and Chats is 2 everywhere in this file.
            Tab(value: 1) {
                CallsView()
            } label: {
                callsTabLabel
            }
            .badge(missedBadge)   // 0 hides it
            Tab(value: 2) {
                ChatsView(onSignOut: onSignOut)
            } label: {
                chatsTabLabel
            }
            .badge(unreadChatsBadge)   // 0 hides it, same as the Calls tab
            Tab(value: 3) {
                SettingsView(onSignOut: onSignOut, asTab: true)
            } label: {
                settingsTabLabel
            }
        }
    }

    private var legacyTabView: some View {
        TabView(selection: $tab) {
            StoriesTabView(onSignOut: onSignOut)
                .tabItem { storiesTabLabel }
                .tag(0)
            CallsView()
                .tabItem { callsTabLabel }
                .badge(missedBadge)
                .tag(1)
            ChatsView(onSignOut: onSignOut)
                .tabItem { chatsTabLabel }
                .badge(unreadChatsBadge)
                .tag(2)
            SettingsView(onSignOut: onSignOut, asTab: true)
                .tabItem { settingsTabLabel }
                .tag(3)
        }
    }

    private func loadSettingsIcon() async {
        // ⚠️ NO PHOTO MEANS TAKE THE OLD ONE DOWN, and that is the half this was missing. Removing
        // your picture writes an EMPTY `photoUrl`, so this ran, failed to make a URL out of "", and
        // returned — leaving `settingsIcon` holding the photograph that had just been deleted. The
        // tab kept showing it for the rest of the session, and it is the one place in the app that
        // draws your picture without going through `AvatarView`.
        guard let s = profile.me?.photoUrl, !s.isEmpty, let url = URL(string: s) else {
            await MainActor.run { settingsIcon = nil }
            return
        }
        // Persistent cache first (same store as every other avatar) — was a raw URLSession fetch that
        // re-downloaded my own profile photo on every launch.
        var img = await DiskImageCache.shared.image(for: s)
        if img == nil, let (data, _) = try? await MediaSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            img = ui
        }
        guard let img else { return }
        let circ = img.circularIcon(28)   // tab-icon size — 56 overflowed onto the label
        await MainActor.run { settingsIcon = circ }
    }
}

// Render a circular, aspect-filled thumbnail for use as a (non-tinted) tab-bar icon.
private extension UIImage {
    func circularIcon(_ size: CGFloat) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: s)).addClip()
            let scale = Swift.max(s.width / self.size.width, s.height / self.size.height)
            let d = CGSize(width: self.size.width * scale, height: self.size.height * scale)
            self.draw(in: CGRect(x: (s.width - d.width) / 2, y: (s.height - d.height) / 2,
                                 width: d.width, height: d.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}

// Pending outbound call awaiting the user's confirm — thread-view parity (its call-history
// rows ask first); these surfaces dialed instantly on a stray tap.
struct PendingCall: Identifiable {
    let uid: String
    let name: String
    let photo: String?
    let video: Bool
    var id: String { uid + (video ? "-v" : "-a") }
}

// Native Phone-app-style call history (mockup IMG_4467): All / Missed segmented filter,
// search, rows with avatar, name (red if missed), direction, time, and an info button.
// Tap a row to call back; (i) opens the contact. Indigo brand kept.
struct CallsView: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    @State private var repo = CallsRepository.shared
    @State private var filter = 0            // 0 = All, 1 = Missed
    @State private var profileTarget: CallEntry?
    @State private var showNew = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showDeleteCalls = false
    @State private var searchText = ""
    @State private var pendingCall: PendingCall?   // confirm before dialing (thread-view parity)

    private var shown: [CallEntry] {
        var list = filter == 1 ? repo.calls.filter { $0.missedIncoming } : repo.calls
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) } }
        return list
    }
    // Consecutive same-kind calls collapse into one "name (3)" row (like the native Phone app):
    // same person, same direction/outcome/type, same day, adjacent in the list.
    struct CallRun: Identifiable {
        var entries: [CallEntry]          // newest first (list order)
        var latest: CallEntry { entries[0] }
        var id: String { latest.id }
        var ids: Set<String> { Set(entries.map(\.id)) }
    }
    private var shownRuns: [CallRun] {
        var runs: [CallRun] = []
        for e in shown {
            if let last = runs.last?.latest,
               last.otherUid == e.otherUid, last.mine == e.mine,
               last.missed == e.missed, last.video == e.video,
               Calendar.current.isDate(last.date, inSameDayAs: e.date) {
                runs[runs.count - 1].entries.append(e)
            } else {
                runs.append(CallRun(entries: [e]))
            }
        }
        return runs
    }
    private func deleteRun(_ r: CallRun) {
        Task { await repo.delete(ids: r.ids) }   // a grouped row deletes ALL calls in the run
    }
    /// Is everything currently on screen already ticked? Drives the Select All button's two states.
    /// ⚠️ Compared against `shownRuns`, the same list the button acts on, so filtering or searching
    /// mid-selection cannot leave the button claiming "all" about rows that are no longer visible.
    private var allShownSelected: Bool {
        !shownRuns.isEmpty && shownRuns.allSatisfy { selection.contains($0.id) }
    }

    private func deleteSelectedCalls() {
        // A run's id is its NEWEST entry's id, and runs are regrouped live — a call ending mid-
        // selection (recordCall force-reloads the repo), or a change of filter/search, gives that
        // run a new id. Matching only against the CURRENT runs then silently dropped those rows
        // while the toolbar still said "N Selected", so Delete removed fewer than it promised.
        // Falling back to the id itself covers a run whose grouping moved under us (audit).
        var ids = Set<String>()
        for id in selection {
            if let run = shownRuns.first(where: { $0.id == id }) { ids.formUnion(run.ids) }
            else { ids.insert(id) }   // the run regrouped; its newest entry id is still a real record
        }
        Task { await repo.delete(ids: ids) }
        selecting = false; selection = []
    }

    var body: some View {
        NavigationStack {
            Group {
                if !repo.hasLoaded && ConversationsRepository.shared.expectsChats {
                    // Shimmer only for an account with history on this device — a fresh sign-up goes
                    // straight to the empty state instead of fake rows (same rule as the chat list).
                    CallListSkeleton()
                } else if !repo.hasLoaded || repo.calls.isEmpty {
                    EmptyStateView(title: "No Calls Yet", icon: "phone",
                                   text: "Your call history will appear here.")
                } else {
                    List(selection: $selection) {   // stable binding (Set selects only in edit mode) -> smooth edit transition
                        ForEach(shownRuns) { run in
                            let call = run.latest
                            CallHistoryRow(
                                call: call,
                                count: run.entries.count,
                                onProfile: { profileTarget = call },
                                onCall: {   // the ROW: call back the same way (video stays video), no confirm
                                    CallService.shared.startCall(to: call.otherUid, name: call.name,
                                                                 photo: call.photoUrl, video: call.video)
                                }
                            )
                            // In edit mode the row's own buttons stayed live, so tapping the name or
                            // avatar pushed a profile and the round button dialled — instead of
                            // selecting the row. The chat list got this exact fix; this list didn't.
                            //
                            // allowsHitTesting, not disabled: disabled ALSO dims, and a greyed-out
                            // call list reads as switched off rather than ready to be picked from.
                            // Same fix, same reason, as the chat list one row type over.
                            .allowsHitTesting(!selecting)
                            .overlay {
                                if selecting {
                                    Color.clear.contentShape(Rectangle()).onTapGesture {
                                        toggleTick(run.id, in: $selection)
                                    }
                                }
                            }
                            .tag(run.id)
                            // ⛔ THE HAIRLINE, ON EVERY ROW. All three references he compared us
                            // against draw one here: Apple's Recents (measured off his
                            // screenshot, 77pt rows ruled from 76pt) and the reference app's
                            // own source (`ChatListItem.swift`). Ours drew none.
                            //
                            // 58, because the guide is measured from the ROW's leading edge and
                            // the row already sits 16pt in: 16 + 46pt avatar + 12pt gap = 74pt
                            // from the screen edge, which is where this row's text starts.
                            //
                            // No trailing guide needed, unlike the chat list: that list zeroes
                            // its row insets, so its rule had to be pulled back by hand. This
                            // one's 16pt trailing inset already ends the line where theirs ends.
                            .listRowSeparator(.hidden, edges: .top)   // never above the first row
                            .listRowSeparator(.visible, edges: .bottom)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
                            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleteRun(run) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)   // force red — the app's white tint was washing it out
                            }
                            // Long-press menu — every action is real.
                            // (Tick reposition lives in ChatRow; see chat list.)
                            // ⚠️ EVERY GLYPH CARRIES ITS OWN INK — `MenuIcon(ink:)`, never a bare
                            // `systemImage:`. A `.contextMenu` becomes a UIKit `UIMenu`, which tints
                            // its images with the presenting view's `tintColor`, and the app's
                            // `.tint(.primary)` is a SwiftUI value that never reaches it: white
                            // lettering, system-blue glyphs. See `MenuIcon.ink`.
                            .contextMenu {
                                Button {
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: false)
                                } label: { Label { Text("Voice Call") } icon: { MenuIcon(system: "phone", ink: .label) } }
                                Button {
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: true)
                                } label: { Label { Text("Video Call") } icon: { MenuIcon(system: "video", ink: .label) } }
                                Button {
                                    AppRouter.shared.pendingChatName = call.name
                                    AppRouter.shared.pendingChatPhoto = call.photoUrl
                                    AppRouter.shared.pendingChatId = call.cid
                                } label: {
                                    Label { Text("Chats") } icon: { MenuIcon("ic_menu_chat", ink: .label) }
                                }
                                Button {
                                    withAnimation(.smooth(duration: 0.35)) { selecting = true; selection = [run.id] }
                                } label: { Label { Text("Select") } icon: { MenuIcon(system: "checkmark.circle", ink: .label) } }
                                Divider()
                                // Red, to match its own title — the one item whose ink is not the label's.
                                Button(role: .destructive) { deleteRun(run) } label: {
                                    Label { Text("Delete") } icon: { MenuIcon(system: "trash", ink: .systemRed) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    // ANIMATE THE HISTORY CHANGING, NOT THE QUESTION CHANGING (owner 2026-08-13: tap
                    // Missed and "the whole page sorts in front of me"). Keyed on `shownRuns` this
                    // fired on the FILTER and the SEARCH too, so switching All → Missed sprang every
                    // surviving row into a new position while the rest faded — a re-sort performed
                    // for somebody who only asked a different question. Keyed on the call count it
                    // still animates the things that are genuinely movement in the list (a call
                    // arrives, a run is deleted), and a filter or a search term, which change no
                    // history at all, simply show their answer.
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: repo.calls.count)
                    .environment(\.defaultMinListRowHeight, 56)   // tight, compact rows
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
                    // THE SELECTION TICK. Edit mode draws its circle in the TINT, and this app tints
                    // itself `.primary` — so the filled tick was a white disc with a white check
                    // inside it, on a dark phone. Selected and unselected looked identical; the only
                    // way to know was the "4 Selected" title (owner 2026-08-16, calls page).
                    // Apple's own systemBlue, the same value and for the same reason as the unread
                    // count on the scroll-to-bottom button in ThreadView. Every swipe action in this
                    // list already names its own colour, so nothing else here moves.
                    .tint(Theme.defaultBubble(dark))
                }
            }
            .navigationTitle("Calls")
            .searchable(text: $searchText, prompt: "Search calls")
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } } label: { Image(systemName: "xmark") }.tint(.primary)
                    }
                    // SELECT ALL, which this list never had (owner 2026-08-16, comparing against two
                    // other messengers). It is NOT a faster Delete All — that button is already
                    // beside it. It is for the opposite job: take everything, then untick the two
                    // you want to keep, instead of tapping forty rows by hand.
                    //
                    // ⚠️ It selects `shownRuns`, not the whole history: the All/Missed filter and the
                    // search box are both live in selection mode, so "all" has to mean what is on
                    // screen. Selecting hidden rows would delete calls the user cannot see.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
                                selection = allShownSelected ? [] : Set(shownRuns.map(\.id))
                            }
                        } label: {
                            Image(systemName: allShownSelected ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .tint(.primary)
                        .disabled(shownRuns.isEmpty)
                    }
                    ToolbarItem(placement: .principal) {
                        Text(selection.isEmpty ? "Select Calls" : "\(selection.count) Selected").font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { showDeleteCalls = true } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selection.isEmpty).tint(.red)
                    }
                } else {
                    if !repo.calls.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Edit") { withAnimation(.smooth(duration: 0.35)) { selecting = true } }.tint(.primary)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $filter) {
                            Text("All").tag(0)
                            Text("Missed").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)   // compact All/Missed pill, not full-width
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNew = true } label: { Image(systemName: "phone.badge.plus") }
                    }
                }
            }
            .task { await repo.load() }
            .refreshable { await repo.load(force: true) }
            .confirmationDialog("Delete \(selection.count) call\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteCalls, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelectedCalls() }
                Button("Cancel", role: .cancel) {}
            }
            // Tapping a row pushes the contact's profile (back chevron, native). Calling
            // back happens only via the round phone button on the row.
            .navigationDestination(item: $profileTarget) { c in
                ContactInfoView(cid: c.cid, name: c.name, photoUrl: c.photoUrl, source: .calls)
            }
            .sheet(isPresented: $showNew) { NewCallView() }
            // Same native confirm the thread view uses — never dial on a stray tap.
            .alert(pendingCall?.video == true ? "Video call" : "Voice call",
                   isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } }),
                   presenting: pendingCall) { c in
                Button("Cancel", role: .cancel) { }
                Button("Call") {
                    CallService.shared.startCall(to: c.uid, name: c.name, photo: c.photo, video: c.video)
                }
            } message: { c in
                Text("\(c.video ? "Video call" : "Call") \(c.name)?")
            }
        }
    }
}

struct CallHistoryRow: View {
    let call: CallEntry
    var count: Int = 1        // consecutive same-kind calls collapsed into this row → "name (3)"
    var onProfile: () -> Void
    var onCall: () -> Void

    // Video calls get the camera-direction glyphs (Phone-app style); voice keeps the arrows.
    private var directionIcon: String {
        call.video ? (call.mine ? "arrow.up.right.video.fill" : "arrow.down.left.video.fill")
                   : (call.mine ? "arrow.up.right" : "arrow.down.left")
    }
    // Red "Missed" ONLY for calls THEY placed that I didn't answer; my own unanswered
    // outgoing call reads "Outgoing" like every big app (was wrongly red before).
    private var directionText: String { call.mine ? "Outgoing" : (call.missed ? "Missed" : "Incoming") }

    /// HOW LONG IT LASTED, which the entry has carried in `durationSec` since the call log was
    /// built and nothing has ever drawn. A call history that says only who and when is missing the
    /// third thing anybody looks one up for: whether the call actually happened. "Outgoing" alone
    /// cannot tell a four-minute conversation from one that rang out — both rows look identical.
    ///
    /// ONLY ON A SINGLE CALL. A collapsed "name (3)" row covers three calls with three different
    /// lengths; printing one of them beside the count would be a number that belongs to a call the
    /// reader cannot see, and adding them up would read as one long call rather than three.
    /// A missed call has no duration to report, and a zero-second answered one has nothing worth
    /// reporting.
    private var durationText: String? {
        guard count == 1, !call.missed, call.durationSec > 0 else { return nil }
        let secs = call.durationSec
        if secs < 60 { return "\(secs) sec" }
        let mins = secs / 60
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60, rest = mins % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    var body: some View {
        HStack(spacing: 12) {
            // ⛔ THE ROW DIALS. THE (i) OPENS THE PROFILE. Owner, 2026-08-29, with the reference
            // app's calls list beside ours: "that is how people assume it to work, not like now we
            // do". Ours had the two the other way round — the row opened a profile and a round
            // button dialled after a confirm — which reads backwards to anyone who has used any
            // other phone or messaging app: a call log is a list of calls, and tapping one places it.
            //
            // The confirm went with it. A call log entry is already a deliberate act of picking one
            // person out of a history, and every app people came from dials on that tap.
            Button(action: onCall) {
                HStack(spacing: 12) {
                    AvatarView(name: call.name, photoUrl: call.photoUrl, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(count > 1 ? "\(call.name) (\(count))" : call.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(call.missedIncoming ? Color.red : Color.primary)
                                .lineLimit(1)
                            VerifiedMark(uid: call.otherUid, size: 13)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: directionIcon).font(.system(size: 11, weight: .semibold))
                            // One Text, not two: "Outgoing" and "(4 min)" are one sentence about one
                            // call, and as separate views the line could break between them and put
                            // a bare bracketed number on a row of its own.
                            Text(durationText.map { "\(directionText) (\($0))" } ?? directionText)
                                .font(.system(size: 14))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(timeLabel(call.date)).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The (i) → the contact profile. Plain glyph, no disc behind it: the reference's is an
            // outline on the page's own background, and the disc we used to draw was there to make a
            // call button look like an action. This is not the action any more.
            Button(action: onProfile) {
                Image(systemName: "info.circle")
                    .font(.system(size: 21))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)        // 44pt hit target (HIG min) without enlarging the visual
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func timeLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// "New call" picker: A–Z grouped contacts, each with REAL voice + video call buttons + a side
// index. (No "Create Call Link" / phone-number search — those aren't real Fariin features.)
struct NewCallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var pendingCall: PendingCall?   // confirm before dialing (thread-view parity)
    private var me: String { AuthService.shared.uid ?? "" }

    private var sections: [(letter: String, convs: [Conversation])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = repo.conversations.filter { !$0.otherUid(me).isEmpty && !$0.isGroup }
        let filtered = q.isEmpty ? all : all.filter { $0.displayName(me).lowercased().contains(q) }
        let grouped = Dictionary(grouping: filtered) { c -> String in
            let n = c.displayName(me).trimmingCharacters(in: .whitespaces).uppercased()
            guard let f = n.first, f.isLetter else { return "#" }
            return String(f)
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.displayName(me).lowercased() < $1.displayName(me).lowercased() }) }
            .sorted { $0.letter == "#" ? false : ($1.letter == "#" ? true : $0.letter < $1.letter) }
    }
    private var indexLetters: [String] { sections.map(\.letter) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if sections.isEmpty {
                        ContentUnavailableView("No contacts", systemImage: "phone",
                                               description: Text("Start a chat first, then you can call them."))
                    } else {
                        ForEach(sections, id: \.letter) { section in
                            Section(section.letter) {
                                ForEach(section.convs) { c in callRow(c) }
                            }
                            .id(section.letter)
                        }
                    }
                }
                .listStyle(.insetGrouped)   // grouped cards (matches the reference)
                .overlay(alignment: .trailing) {
                    if query.isEmpty && indexLetters.count > 1 {
                        VStack(spacing: 1) {
                            ForEach(indexLetters, id: \.self) { l in
                                Text(l).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                                    .frame(width: 16).contentShape(Rectangle())
                                    .onTapGesture { withAnimation { proxy.scrollTo(l, anchor: .top) } }
                            }
                        }
                        .padding(.trailing, 1)
                    }
                }
            }
            .navigationTitle("New call")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search name or username")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
            }
            // Same native confirm the thread view uses — never dial on a stray tap.
            .alert(pendingCall?.video == true ? "Video call" : "Voice call",
                   isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } }),
                   presenting: pendingCall) { c in
                Button("Cancel", role: .cancel) { }
                Button("Call") {
                    CallService.shared.startCall(to: c.uid, name: c.name, photo: c.photo, video: c.video)
                    dismiss()
                }
            } message: { c in
                Text("\(c.video ? "Video call" : "Call") \(c.name)?")
            }
        }
    }

    private func callRow(_ c: Conversation) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 42)
            Text(c.displayName(me)).font(.system(size: 17, weight: .medium)).lineLimit(1)
            Spacer()
            Button { call(c, video: false) } label: {
                Image(systemName: "phone").font(.system(size: 19)).foregroundStyle(.primary)
            }
            .buttonStyle(.plain).frame(width: 44, height: 44).contentShape(Rectangle())
            Button { call(c, video: true) } label: {
                Image(systemName: "video").font(.system(size: 19)).foregroundStyle(.primary)
            }
            .buttonStyle(.plain).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .padding(.vertical, 2)
    }

    private func call(_ c: Conversation, video: Bool) {
        // Ask first; the alert's Call button dials + dismisses.
        pendingCall = PendingCall(uid: c.otherUid(me), name: c.displayName(me),
                                  photo: c.displayPhoto(me), video: video)
    }
}

struct ChatsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void = {}) { self.onSignOut = onSignOut }
    private var repo = ConversationsRepository.shared
    private var profile = ProfileStore.shared
    private var router = AppRouter.shared
    private var storiesRepo = StoriesRepository.shared   // @Observable: drives the chat-list story rings
    private var officialChannel = OfficialChannelStore.shared   // @Observable: the one synthetic row in the list
    private var call = CallService.shared                // @Observable: the live 1:1 call, for the row below
    @ObservedObject private var groupCall = GroupCallService.shared   // ObservableObject, so it needs the wrapper
    @Environment(\.colorScheme) private var scheme
    @State private var showNew = false
    /// FALSE UNTIL THE LIST HAS FINISHED ARRIVING, and it gates the reorder animation.
    ///
    /// The rows animate when a chat bumps to the top, which is right. On a cold launch it was also
    /// animating the list COMING INTO EXISTENCE: the cached chats land, the first server snapshot
    /// reorders them, and the official channel arrives separately from its own store, so `visible`
    /// changed three times in about a second and every row sprang toward a new position on each
    /// change. Mid-flight that draws rows on top of one another — the owner caught Fariin sitting
    /// across x test, half faded, on first open.
    ///
    /// An arrival is not a rearrangement. Nothing should animate until the list is a list.
    @State private var listSettled = false
    @State private var chatFilter = 0   // 0 = all, 1 = unread
    /// The page's own search box (2026-08-30). Matches the Calls page: it filters the list in
    /// place rather than pushing a separate results screen, so the row you tap is the row you
    /// were already looking at.
    @State private var chatSearch = ""
    /// ⛔ THE CHAT LIST'S SEARCH REACHES PAST THE CHAT LIST — owner, 2026-09-02: "the search inside
    /// the chat list must work like global; when the user wants to search: chats, users, new users".
    ///
    /// People who are NOT in your chats, found by username. `searchUsers` is an exact-handle lookup
    /// and deliberately not a prefix query — the note on it says so: a prefix search over profiles
    /// would need `list` permission on every profile document in the app, which is the same decision
    /// as making everyone's account enumerable. So this finds somebody when you type their username,
    /// and finds nobody when you type three letters of it.
    @State private var userHits: [UserProfile] = []
    @State private var searchingUsers = false
    @State private var path = NavigationPath()
    // NO "CURRENTLY OPEN CHAT" HIGHLIGHT. There was one here, and it is gone on the owner's word
    // (2026-08-03): "highlight only while the user's finger is touching it… never during the back
    // swipe". The whole highlight is Apple's pressed state now and nothing of ours — see the note at
    // the row's Button.
    @State private var pendingDelete: Conversation?
    @State private var pendingMute: Conversation?
    // Multi-select edit mode.
    @State private var selecting = false
    @State private var selection = Set<String>()
    // A page in the chat list's own stack. NavigationPath is type-erased, so one case is all the
    // archive needs to become a destination.
    enum ArchiveRoute: Hashable { case archive }
    @State private var showDeleteSelected = false
    @State private var storyLimitReached = false
    /// The server says this account may not post a story at all — see `AppLimits.storiesEnabled`.
    @State private var storiesOff = false
    /// Observed, so the button closes the moment the fiftieth story lands rather than at the next
    /// launch — `StoriesService` is `@Observable` and this reads its two counter properties.
    private var storyBudget: StoriesService { StoriesService.shared }
    @State private var showMyQR = false   // welcome empty-state → My QR Code sheet
    @State private var welcomeGreet = 0   // one-shot greeting bounce on the welcome glyph
    /// ⚠️ THE COVER IS GONE, AND SO ARE `viewerSourceID` AND `viewerHero` (2026-08-07, migration
    /// complete). Every story door in the app — this row, the chat-row rings, the archive, both
    /// profiles, a reply quote and the uploading card — now opens through `StoryDoor`, which is our
    /// own presentation, our own gesture and our own animation end to end. There is no
    /// `fullScreenCover` and no `.navigationTransition(.zoom(...))` left on any of them.
    ///
    /// Do not bring one back to "fix" a door. Two presentations for one interaction is what made the
    /// scroll-down feel like a different gesture depending on which circle you had tapped, and it is
    /// what build 481's crash cost. `StoryDoor` is the one way in.
    @State private var profileGroup: StoryGroup?
    // (`storyDoorState` went with the row: it existed to freeze the row's order while a viewer was
    // open, and this page has no row to freeze. It lives in `StoriesTabView` now.)
    /// ⛔ THE ARCHIVE ROW IS HIDDEN UNTIL THE LIST IS PULLED DOWN — the reference app's behaviour,
    /// which he asked for by name and asked me to change nothing else about the row.
    ///
    /// Theirs is not a disclosure control and there is nothing to tap: the row lives above the first
    /// chat, off the top of the list, and the only way to it is to overscroll. Pull down and it is
    /// there; scroll back down and it is gone again until the next pull. Their own documentation for
    /// it is one line — "pull down on the inbox list to unhide the archived chats folder, as well as
    /// pull up on the list to temporarily hide it" — and once it goes out of view it returns to
    /// hidden rather than staying put.
    ///
    /// ⚠️ IT IS INSERTED WHILE THE LIST IS ALREADY PULLED OPEN, and that is the whole trick. By the
    /// time this flips true the finger has already dragged the content down past the row's own
    /// height, so a 44pt row appearing at the top fills a gap that is already there instead of
    /// shoving every chat down. That is why there is no animation on it: the finger is the animation.
    // Stories opt-out (Settings > Stories > Turn Off Stories): the row disappears and chat-row
    // rings go dark — the whole surface, not a hidden-but-alive row.
    @AppStorage("storiesOptedOut") private var storiesOptedOut = false

    // MARK: - The chat list's story door
    //
    // ⛔ `openStoryFromRow` AND `openUploadingStory` MOVED TO `StoriesTabView` (2026-08-30),
    // with the row itself. They are not duplicated here: the row's door is unpinned (the
    // viewer pages person to person and the row has a card for whoever you paged to), the
    // ring's door below is pinned, and two copies of that distinction is exactly how one of
    // them ends up quietly wrong. The story-limit alerts and `composeStory` stay standing but
    // UNREFERENCED since the menu's Add Story was removed (2026-09-02) — see the note there.

    /// THE CHAT LIST'S RINGED AVATAR. Same door, same flight, and because the ring reports its
    /// radius as half its width the story grows out of it and lands back into it as a CIRCLE —
    /// The reference app's shape, the owner's reference. See StoryCardMorph's circular branch.
    ///
    /// `pinned` (the door's default), unlike the row: the ring is the only anchor this list has for
    /// the person who was tapped, and paging on to somebody else does not produce a second one.
    ///
    /// One person's story alone (`among:` left empty). The list is sorted by conversation, not by
    /// story, so paging out of a ring would walk an order nothing on screen is showing.
    private func openStoryFromRing(_ conv: Conversation, _ g: StoryGroup) {
        StoryDoor.open(g, from: "row-\(conv.id)", deliveredToMe: true,
                       onProfile: { grp in profileGroup = grp })
    }

    // Welcome empty state: icon + copy + the three ways to get a first chat going.
    // Reuses the existing flows (NewChatView search, MyQRView, Settings' invite text).
    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }
    // Big-app empty state (the big messengers rule: one visual, one line, ONE button).
    // The stacked three-pill version read as clutter — secondary actions are quiet
    // inline text links instead.
    private var emptyWelcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
                // One greeting bounce on appear (endless repeat read as fidgety).
                .symbolEffect(.bounce, value: welcomeGreet)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { welcomeGreet += 1 } }
            VStack(spacing: 4) {
                Text("No chats yet").font(.title3.weight(.semibold))
                Text("Find a friend by username to start talking.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // NOTHING ELSE. A fresh account used to get a "Find People" button plus "My QR" and
            // "Invite" links stacked under the message, which read as a landing page rather than an
            // empty inbox. The standard apps all show only a glyph, a title and one line here -
            // the actions already live in the compose button in the nav bar, so repeating them cluttered
            // the first thing a new user ever sees.
        }
        .padding(.horizontal, 32)
    }

    private func storyCid(_ other: String) -> String {
        [AuthService.shared.uid ?? "", other].sorted().joined(separator: "_")
    }
    private func openStoryChat(_ g: StoryGroup) {
        path.append(ChatTarget(id: storyCid(g.authorUid), name: g.name, photo: g.photoUrl))
    }
    // Header fade: hide the nav-bar icons while a chat is pushed so they
    // don't float statically over the screen during the interactive swipe-back. Driven by
    // navigation depth — a non-empty path (which holds through the ENTIRE drag) keeps them
    // hidden; they fade back only when the list is fully back (path empty again on commit).
    @State private var showHeaderIcons = true

    // Drops the toolbar icons to opacity 0 the instant we leave the list and fades them
    // back when it re-appears — without this SwiftUI keeps them pinned over the transition.
    private struct SwipeFade: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content.opacity(on ? 1 : 0).animation(.easeInOut(duration: 0.15), value: on)
        }
    }

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    // Per-segment seen flags for the 1:1 peer's stories (empty = no active story → no ring).
    private func storySeen(_ conv: Conversation) -> [Bool] {
        guard !conv.isGroup,
              !UserDefaults.standard.bool(forKey: "storiesOptedOut"),   // opted out: no rings anywhere
              !StoryPrefs.isHidden(conv.otherUid(me)),   // hidden author: no ring on the chat-list avatar
              let g = storiesRepo.others.first(where: { $0.authorUid == conv.otherUid(me) })
        else { return [] }
        // upTo watermark = same split-brain guard as the stories row (server lastViewedAt
        // covers views from other devices / reinstalls, not just local flags).
        return StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt)
    }

    // Mark every (non-archived) unread chat as read. Same filter as the tab badge — including
    // the blocked exclusion the badge always had: marking a silently-blocked chat read sent the
    // blocked person read receipts, revealing the block-hidden activity (audit).
    private func markAllRead() {
        let ids = repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                      && (Flags.groupsEnabled || !$0.isGroup)   // the clause the badge has; see above
                      && $0.hasUnreadMark(me) }   // clears a manual mark too — that is what "read all" means
            .map(\.id)
        Task { for id in ids { await ChatService.resetUnread(id); await ChatService.markRead(id) } }
    }

    // One chat-list row: full-row Button (a NavigationLink would draw the disclosure chevron;
    // in edit mode a Button is auto-disabled so native multi-select toggles via the row tag),
    // long-press menu + conversation PEEK preview, swipe actions both edges.
    /// In edit mode the List's own selection only reacts to taps on NON-interactive row content, and
    /// every chat row is a Button — so a tap on the avatar, the name, or the empty space was swallowed
    /// and pushed the chat instead of selecting it. Only the checkbox (outside the Button) worked.
    /// Route those taps here so the whole row toggles, like Mail and the reference app.
    private func toggleSelection(_ id: String) { toggleTick(id, in: $selection) }

    @ViewBuilder private func chatListRow(_ conv: Conversation) -> some View {
        // A real NavigationLink, not a Button with a hand-rolled press style.
        //
        // THE STUCK GREY ROW: ChatRowPressStyle painted the highlight from the ButtonStyle's `isPressed`.
        // That flag strands whenever the button's identity changes mid-press - and this list RE-SORTS on
        // updatedAt, so a message arriving while a finger rests on a row does exactly that. The row then
        // stayed grey with nothing to clear it, which is the "selected grey without selecting" report.
        // The system's own row highlight cannot get stuck this way, and it is also what makes the swipe
        // actions behave properly, since UIKit owns the whole cell interaction instead of splitting it
        // between a Button and the swipe platter.
        // ONE structure for both modes (owner's report: entering Select cross-faded TWO copies of
        // every row — the old if-selecting/else swap changed the row's structural identity, so
        // SwiftUI faded the plain-label copy in over the Button copy instead of sliding one row).
        // The Button stays permanently; Select mode just disables it and lays a tap-catcher on top,
        // so the native edit-mode indent slides the single row smoothly.
        //
        // A Button that pushes onto the same path, NOT a NavigationLink — because a
        // NavigationLink row draws the disclosure chevron and there is no API to turn it off
        // (user: "remove the arrow in chat list"). The link ALSO set the List's selection, and
        // SwiftUI never cleared it on the way back; fixed in the two onChange handlers on the List.
        // ⚠️ AND IT LEAVES THE ROW WITH NO PRESS HIGHLIGHT, WHICH IS NOW THE DECISION. A plain-styled
        // Button in a List row does NOT let the cell's own pressed state paint through it: the Button
        // takes the touch, so the cell never learns a press happened. That was called a bug on
        // 2026-08-13 and a custom grey was built for it; on 2026-08-19 he asked for the grey out and
        // this back the way it was. The note where `RowPressFill` used to live in Theme.swift says
        // what the grey cost — read it before anybody builds it a fourth time.
        //
        // A row used to stay lit while its chat was open (the reference app's `selectRow`, build 441). It is
        // deleted. On a phone that highlight is only ever VISIBLE during the back swipe, because
        // that is the one moment the list is on screen with a chat still on the stack — and it was
        // being cleared by `path.count` reaching zero, which happens when the pop FINISHES. So the
        // grey sat there at full strength for the whole gesture. the reference app solves that by deselecting
        // inside the navigation transition's own animation, which SwiftUI gives no way to reach; the
        // owner chose the simpler end of that trade deliberately: no state, no grey, nothing to fade.
        Button {
            path.append(ChatTarget(id: conv.id, name: conv.displayName(me),
                                   photo: conv.displayPhoto(me)))
        } label: {
            chatListRowLabel(conv)
        }
        // ⚠️ `.plain`, AND THE TOUCH GREY IS GONE ON HIS WORD (2026-08-19: "remove the highlight
        // grey we added when you tap a chat list row, back the way it was before"). It was asked for
        // on 2026-08-13, took three attempts to make visible, and each attempt cost something else:
        // driving the row from a gesture rather than a Button took the tap away entirely in 612, then
        // made a ringed avatar open the story AND the chat at once, and the app-wide touch-delay
        // change that went with it broke the story viewer's corners. None of that exists without the
        // grey. See the deleted `RowPressFill` in Theme.swift if it is ever asked for again — and
        // read what it cost before rebuilding it.
        .buttonStyle(.plain)   // no accent tint on the label, and no custom press flag to get stuck
        // Edit mode: the push is off, and the tap-catcher overlay below owns the tap.
        //
        // `.disabled(selecting)` was the wrong tool and `.opacity(1)` did not rescue it. Disabled
        // does two things — it stops the interaction AND it dims — and only the first was ever
        // wanted. The dimming is applied by the button style INSIDE, from the environment, so an
        // opacity of 1 on the outside means "change nothing further"; it cannot undo a fade that has
        // already been drawn. That is why Select Chats still greyed every avatar, name and preview
        // after the last attempt at this.
        //
        // allowsHitTesting stops the interaction and nothing else. The row keeps its own colours,
        // and the overlay above still receives the tap because the Button simply declines it.
        .allowsHitTesting(!selecting)
        .overlay {
            if selecting {
                // Whole row toggles, like Mail and the reference app (taps on a Button's content were
                // otherwise swallowed and only the checkbox worked).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { toggleSelection(conv.id) }
            }
        }
        .tag(conv.id)
        .listRowInsets(EdgeInsets())
        // ⛔ NO GREY UNDER A ROW — owner, 2026-09-02: "why is the chat list Chats card using grey,
        // remove that". It is the grouped list style's own doing and it arrived with the switch to
        // `.grouped` for the pin animation: a grouped list paints each row on
        // `secondarySystemGroupedBackground`, which is the raised card look those lists are for.
        //
        // ⚠️ `scrollContentBackground(.hidden)` DOES NOT REACH IT. That hides the LIST's background;
        // the row's is a separate surface the style gives every cell, and only `listRowBackground`
        // clears it. The headings already had this, which is why they looked right and the rows did
        // not — the grey stopped exactly where the headers began, in his screenshot.
        .listRowBackground(Color.clear)
        // ⛔ NO SEPARATOR AT ALL — owner, 2026-09-02: "also remove lines", settling a comparison
        // that had gone the other way.
        //
        // ⚠️ **THE HAIRLINE ADDED ON 2026-08-29 WAS BUILT ON A WRONG PREMISE, AND THE COMMIT
        // MESSAGE SAID SO OUT LOUD: "as theirs does".** It does not. Their chat list sets
        // `tableView.separatorStyle = .none` (`CLVTableDataSource.swift:119`) and draws no rule
        // between rows anywhere — verified in their source on 2026-09-02, not inferred from a
        // screenshot, because the screenshot that started this was ALSO misread as ours when it was
        // theirs. A colour is still assigned on the line after that one in their file, which is
        // dead code and is probably what an earlier reading latched onto.
        //
        // The 84pt leading guide and the 16pt trailing guide went with it. Both were correct
        // arithmetic for a rule that should not be drawn.
        .listRowSeparator(.hidden)
        // NO explicit row background: forcing systemBackground made the swiped row paint a
        // white slab OVER its own content (blank row on swipe, user report). The native
        // swipe platter (grey) is correct and keeps the row content visible.
        .moveDisabled(true)   // reordering removed — pinned chats stay fixed
        // Full-swipe enabled like the leading (Pin) edge. The FIRST action is what a full
        // swipe triggers, so Archive leads; Mute/Delete are still revealed for a tap.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await ChatService.setArchived(conv.id, true) }
            } label: {
                // The SOLID archive drawing, which is the one he sent for the swipe specifically.
                // MenuIcon, not a frame-modified Image: swipe actions drop view modifiers the same
                // way menus do, so the frame(22) never applied (see MenuIcon).
                Label { Text("Archive") } icon: { MenuIcon("ic_archive_fill") }
            }
            .tint(.gray)
            // Apple's symbols go through MenuIcon too now: it trims each icon to its ink, so a
            // symbol's built-in air no longer makes it read smaller than our drawings beside it.
            Button { pendingMute = conv } label: {
                Label { Text("Mute") } icon: { MenuIcon(system: "bell.slash.fill") }
            }
            .tint(.indigo)
            Button(role: .destructive) {
                pendingDelete = conv
            } label: { Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill") } }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) }
            } label: {
                Label { Text(conv.isPinned(me) ? "Unpin" : "Pin") } icon: {
                    // No size of its own. One number for menus and swipes alike, so a report about
                    // one place cannot leave the other behind — see MenuIcon.standard.
                    conv.isPinned(me) ? AnyView(MenuIcon(system: "pin.slash"))
                                      : AnyView(MenuIcon("ic_pin_menu"))
                }
            }
            .tint(.orange)
        }
    }

    // The row CONTENT with the context menu attached to it (not the Button — a Button in a
    // List swallows the long-press) + the conversation peek as the menu preview.
    private func chatListRowLabel(_ conv: Conversation) -> some View {
        ChatRow(conv: conv, me: me, dark: dark,
                onCall: conv.id == liveCallCid,
                storySeen: storySeen(conv),
                onStoryTap: {   // open this person's story in the same viewer the stories row uses
                    // The ring has its own tap gesture, which would beat the row's selection toggle.
                    if selecting { toggleSelection(conv.id); return }
                    // On the app's own presentation, and it lands back into the ring as a CIRCLE —
                    // see `openStoryFromRing`.
                    if let g = storiesRepo.others.first(where: { $0.authorUid == conv.otherUid(me) }) {
                        openStoryFromRing(conv, g)
                    }
                },
                draft: Drafts.shared.text(conv.id),
                voiceDraftSecs: AudioRecorder.draftIndex[conv.id] ?? 0,
                voiceUnplayed: PlayedVoice.shared.lastVoiceUnplayed(conv, me: me))
            .equatable()   // skip rebuild when this conversation is unchanged
            .frame(maxWidth: .infinity, alignment: .leading)
            // NO BACKGROUND OF OUR OWN. A fill painted here used to mark the open chat; it is gone
            // (see the Button above). Do not bring one back on this modifier, or on the List's
            // selection binding, or on `.listRowBackground`: the binding stranded a permanent grey
            // row twice, and listRowBackground painted a slab over the row's own content while it
            // was swiped. The cell's pressed state is the only highlight this row has, and it is
            // drawn by UIKit underneath everything here.
            .contentShape(Rectangle())   // whole row tappable (incl. empty space)
            .contextMenu {
                chatMenu(conv)
            } preview: {
                ChatPeekPreview(cid: conv.id, me: me)
            }
    }

    // ARCHIVE, VISIBLE FROM THE CHAT LIST (owner 2026-08-13: "make our archive visible ... now it
    // needs finding other ways"). It only lived in the filter menu, which is a place you have to
    // already know about. The reference app puts it where he pointed: one compact row at the top of
    // the chats, only there when the drawer holds something, scrolling away with the list.
    private var archivedChats: [Conversation] {
        // Same filter the archive page itself uses — including the official channel, which can be
        // archived like any other chat, so the count cannot disagree with what opens.
        (repo.conversations + [officialChannel.listEntry].compactMap { $0 })
            .filter { $0.isArchived(me) && !$0.isCleared(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
    }
    // Hidden people's stories live in the archive too, so the way in has to exist for them even
    // with no archived chat at all — otherwise unhiding somebody becomes unreachable.
    private var hasArchivedStories: Bool {
        storiesRepo.others.contains { StoryPrefs.isHidden($0.authorUid) }
    }
    // The number goes accent instead of grey when something in there is unread: same digit, and the
    // colour is the only thing saying there is news behind the door.
    private var archivedUnread: Bool {
        archivedChats.contains { !$0.isBlockedByMe(me) && $0.hasUnreadMark(me) }
    }
    // Not while selecting (the row carries no tag, so it can never be part of a selection), and not
    // under a filter — Unread and Groups are questions about the chats on THIS page.
    private var showsArchivedRow: Bool {
        // ⚠️ `selecting` IS NOT IN HERE ANY MORE (his reference, 2026-08-14): in select mode the row
        // STAYS, greyed and unselectable, instead of vanishing. A row that disappears the moment you
        // tap Edit reads as something you broke; theirs dims it, which says "not this one" without
        // moving anything. It carries no tag and takes `selectionDisabled`, so it never grows a
        // checkbox and can never end up in a selection.
        //
        // ⛔ ALWAYS ON, AND THE PULL-TO-REVEAL GATE THAT WAS HERE IS GONE (his order, 2026-08-21
        // evening, with the row circled: "make it how it was before, now hide and show remove").
        // That reverses his own order from the same morning to copy the reference app's hide/show,
        // and both were deliberate, so the later one stands. See the note in `onScrollGeometryChange`
        // for what the gate cost and why it went.
        //
        // One thing it quietly gives back: an unread archived chat is reachable again without
        // knowing to pull the list down for it. That trade was recorded when the gate went in and is
        // worth naming now that it is paid off.
        chatFilter == 0 && (!archivedChats.isEmpty || hasArchivedStories)
    }
    // ⛔ DELETED HERE: `archivedEntryRow`, and `archivedRowHeight` with it — owner,
    // 2026-09-02: "remove it completely from the chat list". `showsArchivedRow` stays because
    // the empty-state copy below still asks whether there is an archive to mention.
    //
    // Recorded rather than quietly dropped: this row carried a lot of settled argument — its
    // 56pt column and 12pt gap matched the chat rows, it stayed DIMMED rather than vanishing in
    // select mode (his 2026-08-14 reference), and it lost its separator on his word. None of that
    // is worth rediscovering, and none of it applies to a menu entry.

    /// THE SEARCH BOX'S TEST, A METHOD AND NOT AN INLINE CLOSURE. `visible` is one long chained
    /// expression and it is already at this file's type-checker budget — adding four lines
    /// inside the chain tipped it over ("unable to type-check this expression in reasonable
    /// time"), which is the same wall the story handlers hit. Named, it costs the checker
    /// nothing.
    ///
    /// Name only. The previews are ciphertext until a row decrypts them, so matching on those
    /// would search whatever subset happened to be decrypted and silently miss the rest.
    private func searchMatches(_ c: Conversation) -> Bool {
        let q = chatSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || c.displayName(me).lowercased().contains(q)
    }

    /// The query, once. Read from four places in a body that re-runs on every typing dot.
    private var searchTrimmed: String { chatSearch.trimmingCharacters(in: .whitespaces) }

    /// Found people who are NOT already a row above. Somebody you chat with matching the query is
    /// already in the list; offering to "start" a chat you are in the middle of would be two rows
    /// for one person saying different things.
    private var newPeople: [UserProfile] {
        let known = Set(visible.compactMap { $0.isGroup ? nil : $0.otherUid(me) })
        return userHits.filter { !known.contains($0.id) && $0.id != me }
    }

    /// One found stranger. Tapping opens the chat with them, which is what creates it.
    ///
    /// ⚠️ THEIR PHOTO IS THEIR CHOICE. A search result is by definition somebody you may not know,
    /// so the Profile Picture audience is honoured here exactly as `NewChatView` honours it — the
    /// two are the same situation and must not answer it differently.
    @ViewBuilder private func newPersonRow(_ u: UserProfile) -> some View {
        Button {
            let cid = ChatService.convId(me, u.id)
            chatSearch = ""
            path.append(ChatTarget(id: cid, name: u.name.isEmpty ? u.handle : u.name, photo: u.photoUrl))
            Task { try? await ChatService.openConversation(other: u) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: u.name.isEmpty ? u.handle : u.name,
                           photoUrl: PrivacyPrefs.allows(u.privacy, "photo",
                                                         contactOfMine: PrivacyPrefs.isContact(u.id))
                                     ? u.photoUrl : nil,
                           size: 56)
                    .padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.name.isEmpty ? u.handle : u.name).font(.headline).foregroundStyle(.primary)
                    Text("@\(u.handle)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled(true)
    }

    /// Ask the server who owns this username. Debounced by the trailing-edge check rather than by a
    /// timer: a stale answer is discarded when it lands, so a fast typist never sees the result of a
    /// query they have moved on from.
    private func lookUpPeople(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { userHits = []; searchingUsers = false; return }
        searchingUsers = true
        var found = await ChatService.searchUsers(prefix: q)
        if found.isEmpty, let exact = await ChatService.findByHandle(q) { found = [exact] }
        guard chatSearch.trimmingCharacters(in: .whitespaces) == q else { return }
        userHits = found
        searchingUsers = false
    }

    /// WHICH CHATS ARE PINNED, as one comparable value — the trigger for the list's pin animation.
    ///
    /// ⚠️ OFF THE REPOSITORY, NOT OFF `visible`. `visible` filters and sorts every conversation and
    /// this is read on each body pass, which the note below is about; this is a filter and a map
    /// over the raw list and nothing else. It also has to IGNORE the sort, because a message
    /// arriving reorders `visible` without changing what is pinned, and that must not animate.
    private var pinnedKey: String {
        repo.conversations.filter { $0.isPinned(me) }.map(\.id).sorted().joined(separator: ",")
    }

    /// The two halves of `visible`, for the "Pinned" / "Chats" sections.
    ///
    /// ⚠️ ONE PROPERTY RETURNING BOTH, AND THAT IS NOT TIDINESS. `visible` filters and SORTS the
    /// whole conversation list every time it is read, and this body re-runs on typing indicators,
    /// presence dots and read receipts. Two separate `pinned` / `unpinned` properties would sort it
    /// twice more on every one of those passes, for an answer that was already in hand.
    ///
    /// Split off the SAME sorted array, so a chat cannot land in both or in neither, and the order
    /// inside each section is the order it already had.
    private var chatSections: (pinned: [Conversation], rest: [Conversation]) {
        let v = visible
        return (v.filter { $0.isPinned(me) }, v.filter { !$0.isPinned(me) })
    }

    /// A section heading, theirs, read from source 2026-09-02 (`CLVTableDataSource.swift:309-322`):
    /// `.headline` — 17pt semibold, the same style and weight as a row's NAME — in the label colour,
    /// with insets of 14 above, 8 below and 16 each side.
    ///
    /// ⚠️ `.textCase(nil)` IS LOAD-BEARING. A SwiftUI plain-list section header upper-cases its text
    /// by default, so this would read "PINNED" — which is Apple's grouped-list convention and not
    /// what theirs draws. ⚠️ `.listRowInsets` is what lets the 16pt leading land where the row's own
    /// 16pt gutter does; the header is a row like any other and inherits the same zeroed insets.
    ///
    /// ⛔ A `Section` HEADER AGAIN, AND THE STYLE IS WHAT KEEPS IT SCROLLING. It was briefly a plain
    /// row, because a PLAIN list floats its headers and he reported them not following the scroll.
    /// That worked and cost more than it bought: a heading that is a row is a peer of a chat row in
    /// SwiftUI's diff, free to animate across one, which is the pin/unpin overlap he reported next.
    /// Their table is `style: .grouped`, where headers scroll AND sections stay sections — see
    /// `.listStyle(.grouped)` at the list.
    ///
    /// ⛔ ONE NUMBER FOR EVERY HEADING, 14, AND I INVENTED THE EXCEPTION — owner, 2026-09-02: "go
    /// read the real code, get the space the reference uses between search and Pinned, then make it
    /// exactly like that".
    ///
    /// Read from their source rather than guessed at this time. `CLVTableDataSource`'s
    /// `viewForHeaderInSection` builds a plain container with
    /// `layoutMargins = (top: 14, leading: 16, bottom: 8, trailing: 16)` and a `dynamicTypeHeadline`
    /// label in `.label`, and that is the whole of it — there is no first-section case in their file.
    /// My `first: 8` was an adjustment by eye toward a number I had not looked up, which is the
    /// exact move his instruction is aimed at.
    ///
    /// ⚠️ AND THE 14 IS THE ONLY SPACING THEY ALLOW. The same file returns `.leastNormalMagnitude`
    /// for every titleless header and for every footer, with the comment "we do not want that
    /// spacing" — so nothing sits between the search field and this heading except these 14 points.
    /// The list's own top margin below therefore has to be 0, or ours is 14 plus whatever we added.
    @ViewBuilder private func chatSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            // ⛔ `Color(.label)`, NOT `.primary` — owner, 2026-09-02, off build 725: "chats and
            // pinned text now looks dark, make it like the reference exactly". `.primary` is a
            // HIERARCHICAL style, and inside a list's header environment the primary level can
            // still render dimmed — which on his phone it did, a grey where theirs is full label.
            // The reference app's header colour is literally `UIColor.label` (read from its chat
            // list data source), so this is not an approximation of their colour, it is their
            // colour, and a concrete `Color` carries no hierarchy for a container to dim.
            .foregroundStyle(Color(.label))
            .textCase(nil)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled(true)
    }

    private var visible: [Conversation] {
        // The official channel joins the list as an ordinary Conversation value, so every filter,
        // sort, badge and swipe below treats it like any other chat and none of them had to learn
        // what an announcement is. It is nil until it has something to say — another mainstream messenger
        // keeps its release channel hidden the same way (an internal visibility flag) so a brand-new account never
        // opens onto an empty official chat.
        let live = liveCallCid   // read ONCE — the comparator below runs n·log n times
        // ⛔ STEPS, NOT ONE CHAIN. This was a single chained expression and it sat exactly at the
        // type-checker's budget: adding one `.filter` for the search box tipped it into "unable to
        // type-check this expression in reasonable time", twice. Each step is annotated, so the
        // checker resolves them one at a time instead of solving the whole pipeline at once.
        var out = repo.conversations + [officialChannel.listEntry].compactMap { $0 }
        out = out.filter { !$0.isCleared(me) && !$0.isArchived(me) }
        out = out.filter { Flags.groupsEnabled || !$0.isGroup }
        // A 1:1 chat you merely OPENED (from search / a profile) but never exchanged a message
        // in stays OUT of the list (standard behavior) until something real happens: a message
        // either way, an unread, a pin, or a draft you typed. Groups always list — creating
        // one is deliberate.
        out = out.filter { (c: Conversation) -> Bool in
            c.isGroup || !c.lastMessageCipher.isEmpty || c.hasUnreadMark(me) || c.isPinned(me)
                || !Drafts.shared.text(c.id).isEmpty
                || AudioRecorder.draftIndex[c.id] != nil   // a parked voice draft keeps its chat listed
                || c.id == live   // ...and so does a call: ringing someone you have never texted
        }                         //   otherwise the "Active call" row has no chat to sit on
        out = out.filter { searchMatches($0) }
        out = out.filter { (c: Conversation) -> Bool in   // Filter: 0 = All, 1 = Unread, 2 = Groups
            switch chatFilter {
            // Blocked-aware, like the row badge and the tab badge (audit: a silently blocked
            // chat appeared under Unread with no badge and a zero tab count).
            case 1: return !c.isBlockedByMe(me) && c.hasUnreadMark(me)
            case 2: return c.isGroup
            default: return true
            }
        }
        return out.sorted { (a: Conversation, b: Conversation) -> Bool in
            // A call you are ON outranks a pin. It is the one thing in the list that is
            // happening RIGHT NOW, and it goes back to where it was the moment it ends —
            // nothing is written to the conversation, so this costs the order nothing.
            if (a.id == live) != (b.id == live) { return a.id == live }
            if a.isPinned(me) != b.isPinned(me) { return a.isPinned(me) }
            // Both pinned: manual order (higher rank = higher in list).
            if a.isPinned(me) && b.isPinned(me) {
                if a.pinRank(me) != b.pinRank(me) { return a.pinRank(me) > b.pinRank(me) }
                return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)
            }
            return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)   // recency (frozen if blocked)
        }
    }

    /// The one chat that is on a call right now — 1:1 or group — or nil. Read by the sort above and
    /// by the row, so both agree without either of them knowing how a call is put together.
    private var liveCallCid: String? { call.liveConversationId ?? groupCall.activeCid }


    // Native nav bar with a crisp circle avatar — glass stripped via the iOS 26
    // opt-out, same as the chat header. Keeps the large "Chats" title + smooth
    // push transitions instead of a hand-rolled bar.
    // Avatar dropdown menu: Select Chats / Settings / Archive.
    // Left: Edit (multi-select). Settings moved to its own tab, so no avatar here anymore.
    private var editButton: some View {
        Button("Edit") { withAnimation(.smooth(duration: 0.35)) { selecting = true } }.tint(.primary)
    }
    // Right: Mark all read + filter (All / Unread / Groups) + Archive.
    private var filterMenu: some View {
        Menu {
            Button { markAllRead() } label: { Label("Mark All Read", systemImage: "checkmark.circle") }
            Divider()
            // Flat filter items (no "Filter by" header) — checkmark on the active one.
            Button { chatFilter = 0 } label: { if chatFilter == 0 { Label("All", systemImage: "checkmark") } else { Text("All") } }
            Button { chatFilter = 1 } label: { if chatFilter == 1 { Label("Unread", systemImage: "checkmark") } else { Text("Unread") } }
            if Flags.groupsEnabled {
                Button { chatFilter = 2 } label: { if chatFilter == 2 { Label("Groups", systemImage: "checkmark") } else { Text("Groups") } }
            }
            Divider()
            Button { path.append(ArchiveRoute.archive) } label: {
                Label { Text("Archive") } icon: { MenuIcon("ic_archive") }
            }
            // ⛔ NO "ADD STORY" HERE — owner, 2026-09-02, with the entry ringed. Posting a story is
            // the Stories tab's job and that tab now opens with its own add button in the header;
            // this menu belongs to the chat list, and every other thing in it acts on the chat list.
            // `composeStory` below is left standing, unreferenced, with the day's-limit alerts it
            // owns — it is the one door with the limit check in it, and the day a second entry point
            // is wanted it should be this, not a second copy of the check.
        } label: {
            // Plain three-lines filter glyph (no inner circle) — Apple moved off the
            // `.circle` variant; the glass button already supplies the round shape, so
            // the old symbol drew a circle-inside-a-circle. Active filter = accent tint.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 18))
                .foregroundStyle(chatFilter != 0 ? Color.accentColor : .primary)
        }
        .tint(.primary)
    }
    private var composeButton: some View {
        Button { showNew = true } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 18))
        }
        .tint(.primary)   // glass circle (default), black glyph
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        if selecting {
            // Minimal X close (replaces "Cancel"); no "Select All" — tap rows to select.
            ToolbarItem(placement: .topBarLeading) {
                Button { exitSelect() } label: { Image(systemName: "xmark") }.tint(.primary)
            }
            ToolbarItem(placement: .principal) {
                Text(selection.isEmpty ? "Select Chats" : "\(selection.count) Selected").font(.headline)
            }
            // Native bottom toolbar (like Mail/Photos edit mode) — no custom glass bar.
            ToolbarItemGroup(placement: .bottomBar) {
                Button { archiveSelected() } label: {
                    Image("ic_archive").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                }
                    .tint(.primary).disabled(selection.isEmpty)
                Spacer()
                Button(readTitle) { markReadTargets() }.tint(.primary).disabled(readTargets.isEmpty)
                Spacer()
                Button(role: .destructive) { showDeleteSelected = true } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
            }
        } else if #available(iOS 26.0, *) {
            // Edit keeps its native Liquid Glass capsule (no sharedBackgroundVisibility opt-out).
            ToolbarItem(placement: .topBarLeading) { editButton.modifier(SwipeFade(on: showHeaderIcons)) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu.modifier(SwipeFade(on: showHeaderIcons))
                composeButton.modifier(SwipeFade(on: showHeaderIcons))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) { editButton.modifier(SwipeFade(on: showHeaderIcons)) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu.modifier(SwipeFade(on: showHeaderIcons))
                composeButton.modifier(SwipeFade(on: showHeaderIcons))
            }
        }
    }

    // Persist a pinned-chat reorder via fractional indexing.
    private func reorderPinned(from source: IndexSet, to destination: Int) {
        let rows = visible
        guard let from = source.first, rows.indices.contains(from) else { return }
        let moved = rows[from]
        guard moved.isPinned(me) else { return }

        let pinnedCount = rows.prefix { $0.isPinned(me) }.count
        guard pinnedCount > 1 else { return }

        // Clamp into the pinned block so a pin can't be dropped among unpinned chats.
        let dest = min(max(destination, 0), pinnedCount)
        var pinned = Array(rows[0..<pinnedCount])
        pinned.move(fromOffsets: IndexSet(integer: from), toOffset: dest)
        guard let pos = pinned.firstIndex(where: { $0.id == moved.id }) else { return }

        let above = pos > 0 ? pinned[pos - 1].pinRank(me) : nil          // higher in list = bigger rank
        let below = pos < pinned.count - 1 ? pinned[pos + 1].pinRank(me) : nil
        let step = 1_000_000.0
        let newRank: Double
        switch (above, below) {
        case let (a?, b?): newRank = (a + b) / 2
        case let (a?, nil): newRank = a - step
        case let (nil, b?): newRank = b + step
        case (nil, nil): return
        }
        Task { await ChatService.setPinOrder(moved.id, newRank) }
    }

    private func exitSelect() { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } }
    private func selectAll() { selection = Set(visible.map { $0.id }) }

    // System action list for a chat row's context menu (HIG order + SF Symbols).
    @ViewBuilder private func chatMenu(_ conv: Conversation) -> some View {
        // Blocked-aware like the row badge (audit: the menu offered "Read" — which would leak read
        // receipts to the blocked person — for a chat whose row displays zero unread).
        // `hasUnreadMark`, NOT `unread(me) > 0`. A chat you marked unread yourself stores -1 as a
        // sentinel, and `unread()` clamps with max(0,…) so the list can never print "-1" — which
        // means the manual mark reads as ZERO here. The menu therefore offered "Unread" on a chat
        // that was already unread, and there was no way to undo it: mark it unread, and the only
        // thing on offer forever after is marking it unread again. That is what he circled.
        //
        // The archived menu below already asks the right question. This one was missed when the
        // sentinel went in.
        if !conv.isBlockedByMe(me) && conv.hasUnreadMark(me) {
            Button {
                // Full parity with opening the chat: reset MY counter, send read receipts,
                // and drop its delivered notifications + fix the app badge.
                Task { await ChatService.resetUnread(conv.id); await ChatService.markRead(conv.id) }
                NotificationCleaner.clear(cid: conv.id)
            } label: {
                Label { Text("Read") } icon: { MenuIcon(system: "envelope.open", ink: .label) }
            }
        } else {
            Button { Task { await ChatService.markUnread(conv.id) } } label: {
                Label { Text("Unread") } icon: { MenuIcon("ic_menu_unread", ink: .label) }
            }
        }
        // The official channel's mute is a plain on/off, not a timer. A "Mute for 1 hour" that
        // silently never un-mutes would be a label that lies — and un-muting on a timer is the exact
        // behaviour the channel promises never to have.
        if OfficialChannel.isOfficial(conv.id) {
            let quiet = conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000)
            Button { Task { await ChatService.setMuted(conv.id, !quiet) } } label: {
                Label { Text(quiet ? "Unmute" : "Mute") } icon: { MenuIcon(system: quiet ? "bell" : "bell.slash", ink: .label) }
            }
        } else {
        // Native submenu (clean popover) instead of a custom mute sheet.
        Menu {
            if conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) {
                Button("Unmute") { Task { await ChatService.setMute(conv.id, until: 0) } }
            }
            Button("Mute for 1 hour") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(1)) } }
            Button("Mute for 8 hours") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(8)) } }
            Button("Mute for 1 week") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(168)) } }
            Button("Mute Always") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(nil)) } }
        } label: { Label { Text("Mute") } icon: { MenuIcon(system: "bell.slash", ink: .label) } }
        }
        Button { Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) } } label: {
            Label { Text(conv.isPinned(me) ? "Unpin" : "Pin") } icon: {
                    conv.isPinned(me) ? AnyView(MenuIcon(system: "pin.slash", ink: .label))
                                      : AnyView(MenuIcon("ic_pin_menu", ink: .label))
                }
        }
        Button { Task { await ChatService.setArchived(conv.id, true) } } label: {
            Label { Text("Archive") } icon: { MenuIcon("ic_archive", ink: .label) }
        }
        Button(role: .destructive) { pendingDelete = conv } label: {
            Label { Text("Delete") } icon: { MenuIcon(system: "trash", ink: .systemRed) }
        }
    }
    // Batch ops run the per-chat writes CONCURRENTLY (was sequential = N round-trips in series).
    private func archiveSelected() {
        let ids = selection
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.setArchived(id, true) } } } }
        exitSelect()
    }
    // SELECT MODE'S READ BUTTON, that same messenger's rule (the reference implementation).
    //
    // With NOTHING selected it reads "Read All" and clears every unread chat in the list you are
    // looking at — you do not have to select anything first. The moment one chat is selected it
    // becomes "Read" and touches only the selection. Either way it is DISABLED when there is
    // nothing unread to act on, so the button never offers work it would not do. The old version
    // said "Read All" always, was dead until you selected something, and then quietly acted on the
    // selection only: the label and the behaviour disagreed.
    private var readTitle: String { selection.isEmpty ? "Read All" : "Read" }

    /// The chats the button would actually mark. Empty = nothing to do = disabled.
    /// Already-read chats drop out here, which is what makes "Read" ignore a read chat you picked.
    ///
    /// Skips silently-blocked chats, exactly like the tab badge, Mark All Read and the row menu
    /// (audit): markRead writes lastRead, which flips the blocked person's messages to read ticks
    /// and reveals the activity the block is hiding. Their rows show 0 unread, so nothing on
    /// screen even hints they were included.
    private var readTargets: [String] {
        // Nothing selected -> the whole list as it is currently filtered, which is that same messenger scoping
        // Read All to the rendered list. Selected -> resolve out of the repo, so a chat that the
        // filter stopped showing while you were selecting is still honoured.
        let pool = selection.isEmpty ? visible : repo.conversations.filter { selection.contains($0.id) }
        // hasUnreadMark, so Read All also clears the ones you marked unread BY HAND. `unread()`
        // clamps the -1 sentinel to zero, so those chats were invisible to this filter and survived
        // a "mark everything read" untouched.
        return pool.filter { !$0.isBlockedByMe(me) && $0.hasUnreadMark(me) }.map(\.id)
    }

    private func markReadTargets() {
        let ids = readTargets
        guard !ids.isEmpty else { return }
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.resetUnread(id); await ChatService.markRead(id) } } } }
        exitSelect()
    }
    private func deleteSelected() {
        let ids = selection
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.deleteForMe(id) } } } }
        exitSelect()
    }

    // THE BINDINGS AND THE DIALOG BODY LIVE OUT HERE, not inline in the modifier chain.
    //
    // `body` stopped compiling — "unable to type-check this expression in reasonable time" — and an
    // inline `Binding(get:set:)` is one of the most expensive things you can put in a chain that
    // long, because the compiler has to infer the closure types against every overload of the
    // modifier. Naming them costs nothing at runtime and hands the type-checker the answer.
    //
    // The cascade is worth remembering too: the SECOND error was "cannot find 'call' in scope",
    // pointing at a property declared at the top of this very file. It was not a real missing
    // symbol, it was the compiler giving up on the body and losing track of what was in it.

    /// EVERY dial site, including the profile. It used to read `!$0.fromProfile`, so a refusal raised
    /// from a profile fell through to a bottom sheet instead — see the alert for why that is gone.
    /// `fromProfile` is still carried on the value; nothing reads it any more, and it stays only so
    /// the call sites do not all need editing to drop an argument.
    private var restrictedCalleeAlert: Binding<Bool> {
        Binding(get: { CallService.shared.restrictedCallee != nil },
                set: { if !$0 { CallService.shared.restrictedCallee = nil } })
    }

    private var mutePrompted: Binding<Bool> {
        Binding(get: { pendingMute != nil }, set: { if !$0 { pendingMute = nil } })
    }

    private var muteTitle: String {
        guard let c = pendingMute else { return "Mute" }
        return "Mute \(c.displayName(me))"
    }

    @ViewBuilder private var muteActions: some View {
        if let c = pendingMute {
            if c.isMuted(me, now: Date().timeIntervalSince1970 * 1000) {
                Button("Unmute") { Task { await ChatService.setMute(c.id, until: 0) }; pendingMute = nil }
            }
            Button("Mute for 1 hour") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(1)) }; pendingMute = nil }
            Button("Mute for 8 hours") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(8)) }; pendingMute = nil }
            Button("Mute for 1 week") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(168)) }; pendingMute = nil }
            Button("Mute Always") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(nil)) }; pendingMute = nil }
        }
        Button("Cancel", role: .cancel) { pendingMute = nil }
    }

    private var pendingInvite: Binding<InviteCodeItem?> {
        Binding(get: { Flags.groupsEnabled ? router.pendingInviteCode.map { InviteCodeItem(code: $0) } : nil },
                set: { router.pendingInviteCode = $0?.code })
    }

    /// THE LOADED CHAT LIST: the List, the stories row floating over it, and every modifier
    /// the two need. Lifted out of `body` because the type-checker gave up on it — "unable to
    /// type-check this expression in reasonable time". `body` was already close to the budget
    /// and this is the heaviest part of it by a wide margin; splitting the value out is the
    /// documented fix and costs nothing at runtime.
    private var loadedChatList: some View {
                        ZStack(alignment: .top) {
                          // Selection is ALWAYS bound (a Set only selects in edit mode, so taps still OPEN
                          // the row when not editing). Swapping the binding nil<->$selection reconfigured
                          // the List and made the edit-mode transition POP; a stable binding lets the
                          // native circles-slide-in + rows-shift-right animate smoothly (withAnimation on
                          // `selecting` at the tap sites drives it).
                          List(selection: $selection) {
                          // The way into the archive, above the chats. Empty when there is nothing
                          // archived — the `if` lives inside the property so this body only grows by
                          // one element (this file's type-checker budget is a known cost).
                          // ⛔ THE ARCHIVE ROW MOVED TO THE BOTTOM OF THE LIST — owner, 2026-09-02,
                          // off build 725: "archive row hide in chatlist", with "like the reference
                          // app exactly" over the whole report. Theirs keeps Archived as the LAST
                          // row, after every conversation, so it is out of sight until you scroll
                          // for it and the list opens on actual chats. It used to sit above
                          // everything here ("above the chats", his earlier call — this reverses
                          // that on his newer word). Hidden, not deleted: it is still the only door
                          // to archived chats, and a door has to exist somewhere.
                          // ⛔ TWO SECTIONS, "Pinned" AND "Chats" — owner, 2026-09-02: "separate the
                          // chat list into Pinned and Chats sections exactly like the reference app".
                          //
                          // `visible` is ALREADY sorted with pinned chats first (its comparator
                          // does that), so this splits a sorted array rather than re-sorting it —
                          // the order inside each section is exactly the order the rows had before.
                          //
                          // ⚠️ BOTH HEADERS APPEAR ONLY WHEN BOTH SECTIONS EXIST. Theirs does the
                          // same: the header is `.leastNormalMagnitude` tall when it has no title,
                          // so a list with nothing pinned shows no "Chats" heading either — it just
                          // looks like the plain list it has always been. Showing a lone "Chats"
                          // above every chat in the app would be a label with nothing to contrast
                          // against.
                          //
                          // ⚠️ THE ROW BODY IS UNCHANGED AND THAT IS DELIBERATE. `chatListRow` owns
                          // this row's structural identity — this file's own note explains that
                          // changing it cross-faded two copies of every row when Select mode was
                          // entered. Two label rows join the flow; no chat row is rebuilt.
                          // ⚠️ Read ONCE into `split`. Naming it here is what keeps `visible` — a
                          // filter and a sort over every conversation — to a single evaluation per
                          // body pass; the un-sectioned branch rebuilds the same array from the two
                          // halves rather than asking for it again. They concatenate back to
                          // exactly `visible` because `visible` is already sorted pinned-first.
                          let split = chatSections
                          if split.pinned.isEmpty || split.rest.isEmpty {
                              ForEach(split.pinned + split.rest) { conv in chatListRow(conv) }
                          } else {
                              // ⛔ REAL SECTIONS AGAIN, AND THE STYLE IS WHAT MAKES THEM SCROLL —
                              // owner, 2026-09-02, after a pin and an unpin: "the Chats text jumps
                              // before the chat card comes down, causing overlap… don't do what you
                              // want, go read the reference app's real code and see how they do it".
                              //
                              // I read it. `ChatListViewController+Loading.applyRowChanges` inserts
                              // and deletes SECTIONS (`insertSections` / `deleteSections`) inside
                              // one `beginUpdates`/`endUpdates` transaction, so a heading moves as
                              // part of its section and can never travel on its own. A pin is a
                              // `moveRow` ACROSS sections, and their own comment beside it says why
                              // they do not use delete-plus-insert there: "it results in a weird
                              // animation". That comment is his bug, written down in their source.
                              //
                              // ⚠️ AND HEADINGS-AS-ROWS WAS MY WRONG ANSWER TO THE EARLIER REPORT.
                              // He said the headings did not scroll; they were pinned because a
                              // PLAIN list floats its headers. Their table is `style: .grouped`
                              // (`CLVTableView.init`), where headers scroll with the content — so
                              // the right fix was the list STYLE, not giving up sections. Turning
                              // them into rows did stop the pinning, and it also made a heading a
                              // peer of a chat row in SwiftUI's diff, free to animate across one.
                              // See `.listStyle(.grouped)` below: the two are one decision.
                              Section {
                                  ForEach(split.pinned) { conv in chatListRow(conv) }
                              } header: { chatSectionHeader("Pinned") }
                              Section {
                                  ForEach(split.rest) { conv in chatListRow(conv) }
                              } header: { chatSectionHeader("Chats") }
                          }
                          // ⛔ PEOPLE YOU HAVE NEVER CHATTED WITH, UNDER THE CHATS — owner,
                          // 2026-09-02. Only while searching, and only below every chat that
                          // matched: what you are almost always looking for is a conversation you
                          // already have, and a stranger pushed above those would be in the way of
                          // the common answer to serve the rare one.
                          if !searchTrimmed.isEmpty, !newPeople.isEmpty {
                              chatSectionHeader("Other people")
                              ForEach(newPeople) { u in newPersonRow(u) }
                          }
                          // ⛔ NO ARCHIVED ROW IN THE LIST AT ALL — owner, 2026-09-02, with it
                          // ringed: "remove it completely from the chat list; when the user wants
                          // archive he clicks the filter button then Archive, never a row in the
                          // chat list".
                          //
                          // ⚠️ THE DOOR IS THE MENU AND IT ALREADY EXISTS, which is what makes this
                          // a removal rather than a loss: `filterMenu` has carried an Archive entry
                          // since it was written, so archived chats stay one tap away from the same
                          // button that filters them.
                          //
                          // The history, because this row has been moved four times and each move
                          // had a reason that is now spent: above the chats, then below them on
                          // "exactly like the reference app", then gated behind a pull-to-reveal,
                          // then always-on when he reversed that. He is ending the argument by
                          // taking the row out of the list, and a menu entry cannot drift up and
                          // down a page.
                        }
                        // ⛔ GROUPED, THEIR STYLE, READ FROM SOURCE — `CLVTableView.init` is
                        // `super.init(frame: .zero, style: .grouped)`. This is the modifier that
                        // does the job headings-as-rows was doing: a PLAIN list floats its section
                        // headers under the nav bar, a GROUPED one scrolls them with the content.
                        // So we get non-sticky headings AND real sections, which is exactly the
                        // pair their table has.
                        //
                        // ⚠️ THE GROUPED CHROME IS TURNED OFF, not inherited. Grouped brings a
                        // system background and its own inter-section spacing; theirs shows neither
                        // (`separatorStyle = .none`, and every titleless header and footer returns
                        // `.leastNormalMagnitude` "because we do not want that spacing"). The
                        // background is hidden here and the spacing is already zeroed below.
                        .listStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        // ⛔ THE PIN IS ONE ANIMATED TRANSACTION, WHICH IS THE HALF I HAD MISSING —
                        // owner, 2026-09-02, third report on this: "still not like the reference,
                        // read the real code".
                        //
                        // I did, and the sections were only half of it. `applyRowChanges` wraps
                        // every change in `beginUpdates()` / `endUpdates()` with
                        // `defaultRowAnimation = .automatic`, so the whole rearrangement is ONE
                        // animation the table runs. Ours had none at all: `setPinned` writes to the
                        // server and the list moves whenever the listener echoes back, outside any
                        // transaction, so the rows and the headings simply appeared in their new
                        // places. That is the jump, and no amount of getting the sections right was
                        // ever going to fix it, because there was nothing animating.
                        //
                        // ⚠️ KEYED ON THE PINNED SET, NOT ON THE WHOLE LIST. A message arriving
                        // re-sorts this list all day; animating that would make every new message
                        // slide the page around. This value changes when — and only when — a chat
                        // is pinned or unpinned, so the animation runs for his action and nothing
                        // else.
                        //
                        // ⚠️ WHAT THIS STILL IS NOT: their `moveRow(at:to:)` across sections, where
                        // one row physically travels from Chats to Pinned. SwiftUI has no such call
                        // — a row leaving one `ForEach` for another is a delete and an insert to its
                        // diff — so ours crossfades in place instead of flying. Matching that last
                        // detail means this list becoming a `UITableView`, which is a much bigger
                        // change than he has asked for and I am not starting it unasked.
                        .animation(.snappy(duration: 0.3), value: pinnedKey)
                        // ⛔ THE SECTION GAP IS THE HEADER'S OWN 14, NOTHING MORE — owner,
                        // 2026-09-02, off build 725: "space between chats and pinned chats, make
                        // like the reference". The List adds its own inter-section spacing on top of
                        // whatever a header pads, so the gap rendered as system-spacing PLUS 14
                        // where theirs is a stated 14-above/8-below and nothing else
                        // (`CLVTableDataSource`'s header insets). Zeroed here so the header's
                        // numbers are the whole story.
                        .listSectionSpacing(0)
                        // THE STUCK GREY ROW, real cause. This List carries a `selection` binding for
                        // multi-select, and every row carries a `.tag`. A NavigationLink row does not only
                        // push - it ALSO sets the List's selection - and SwiftUI does not clear that on the
                        // way back, so the row stays SELECTED, and selected renders as a permanent grey fill.
                        // It is not a press highlight at all, which is why removing the custom press style
                        // did not fix it: the highlight was correct, the selection underneath it was not.
                        // Outside edit mode there is no such thing as a selected chat, so say so.
                        .onChange(of: selection) { _, sel in
                            if !selecting, !sel.isEmpty { selection.removeAll() }
                        }
                        .onChange(of: selecting) { _, on in
                            if !on, !selection.isEmpty { selection.removeAll() }   // leaving edit mode clears it
                        }
                        // When a new message bumps a chat to the top, the rows
                        // slide to their new order instead of popping. Scoped to the order/
                        // membership only, so it won't animate unrelated content changes.
                        // Nil until the list has settled, so a cold launch PAINTS its rows instead of
                        // flying them in from nowhere on top of each other. See `listSettled`.
                        .animation(listSettled ? .spring(response: 0.38, dampingFraction: 0.86) : nil,
                                   value: visible.map(\.id))
                        // A GRACE PERIOD FROM WHEN THE LIST FIRST EXISTS, not from `hasLoaded`.
                        //
                        // Keying it to `hasLoaded` looks right and is not: on a cold launch the skeleton
                        // holds this branch until `hasLoaded` is ALREADY true, so the List first appears
                        // on the far side of that flip and would unlock animation on its very first
                        // frame. The official channel then lands from its own store a moment later and
                        // flies in alone — the exact row he photographed sitting across another one.
                        //
                        // Timing from first appearance covers every path: skeleton-then-list,
                        // cached-chats-render-instantly, and empty-then-populated alike.
                        .onAppear {
                            guard !listSettled else { return }   // warm return: already a list, animate now
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { listSettled = true }
                        }
                        .environment(\.editMode, .constant(selecting ? .active : .inactive))
                        // The selection tick, same as the calls list — the app's `.primary` tint made
                        // it a white check on a white disc. See the note there.
                        .tint(Theme.defaultBubble(dark))
                        // Rows start below the stories row; as the list scrolls, the row above is
                        // offset by the same amount, so both move as ONE scroll surface.
                        // ⛔ 0, AND IT HAS TO BE — read from their source, 2026-09-02. Their chat
                        // list allows exactly one piece of spacing above a heading, the heading's
                        // own 14pt top margin: every titleless header and every footer in
                        // `CLVTableDataSource` returns `.leastNormalMagnitude`, with the comment
                        // "we do not want that spacing". Any margin here is added ON TOP of the 14
                        // and is the gap he measured against theirs.
                        //
                        // The 8 that was here was left over from the era when the stories row was
                        // drawn OVER this list and the list had to start below it. The row has been
                        // a page of its own for days; the number outlived its reason.
                        .contentMargins(.top, 0, for: .scrollContent)
                        // Extra bottom clearance so chat rows don't sit UNDER the native floating tab bar
                        // (its transparent margins otherwise show + tap-through to a row behind the pill).
                        .contentMargins(.bottom, 28, for: .scrollContent)
                        // Now that the list truly underlaps the nav bar (clip fix), the header draws
                        // its HARD edge line whenever content is beneath it — in BOTH scroll
                        // directions. Soft top edge = blur fade, no drawn line (bottom stays default,
                        // which the user confirmed fixed).
                        .scrollEdgeEffectStyle(.soft, for: .top)

                          // ⛔ THE STORIES ROW LEFT THIS PAGE — his call, 2026-08-30, off two
                          // mockups of the app: stories get a tab of their own
                          // (`StoriesTabView`) and the chat list is chats.
                          //
                          // What went with it is worth knowing, because it was most of the
                          // machinery here. The row was drawn OUTSIDE the List (inside one,
                          // the whole row lifts as ONE cell on a long press instead of each
                          // card lifting on its own — build 147), so it had to be slid by
                          // hand against `chatScrollY`, the List had to carry a top content
                          // margin the exact height of the row, and the row had to fade out
                          // over the last stretch of its slide so its blur and the List's
                          // edge blur were never both visible at once. Three mechanisms to
                          // make one view look like it was part of a list it could not be
                          // part of. On a page of its own it is simply the first thing on
                          // the page, and none of that is ported.
                          //
                          // ⚠️ THE RINGED AVATARS IN THE ROWS ARE NOT THIS AND DID NOT MOVE.
                          // A ring belongs to a conversation; see `openStoryFromRing`.
                        }   // ZStack (stories row scrolling in sync above the list)
                        // Empty state sits BELOW the stories row (which stays visible). "No chats yet"
                        // only when truly unfiltered; a filtered empty result says so instead.
                        .overlay(alignment: .top) {
                            // `hasLoaded` too, or the quiet window before the skeleton arms would show
                            // "No chats yet" to someone who has chats. An empty list is only news once
                            // we have actually heard back.
                            // ⚠️ `newPeople` TOO, or a username that matches nobody you chat with
                            // draws "No results" straight over the person it just found.
                            if visible.isEmpty, newPeople.isEmpty, repo.hasLoaded {
                                // A SEARCH THAT FOUND NOTHING IS NOT AN EMPTY INBOX. Without this
                                // branch, typing a name nobody has empties the list and the welcome
                                // state below tells someone with two hundred chats that they have
                                // none and offers to teach them how to start one.
                                if !chatSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                                    ContentUnavailableView.search(text: chatSearch)
                                        .allowsHitTesting(false)
                                } else if chatFilter == 0 {
                                    // First run: an empty list must TEACH the next step, not dead-end
                                    // (big-app pattern) — find people, share your QR, invite friends.
                                    // The stories row used to be cleared here as well, and getting
                                    // that clearance wrong floated this ~175pt too low whenever
                                    // stories were switched off. There is no row on this page now.
                                    // + the archive row when it is showing: archive every chat you
                                    // have and the list is "empty", so this overlay would otherwise
                                    // land on top of the one row still standing (and eat its taps).
                                    emptyWelcome
                                        // Was `24 + archivedRowHeight` when that row could sit
                                        // under an empty list. There is no row to clear now.
                                        .padding(.top, 24)
                                } else {
                                    // Per-filter copy — the Groups filter was showing the Unread text.
                                    ContentUnavailableView(
                                        chatFilter == 2 ? "No groups yet" : "No unread chats",
                                        systemImage: chatFilter == 2 ? "person.3" : "checkmark.circle",
                                        description: Text(chatFilter == 2 ? "Groups you join will appear here." : "You're all caught up."))
                                        .padding(.top, 24)
                                        // No archive row under a filter (see showsArchivedRow), so
                                        // this branch needs no clearance for it.
                                        .allowsHitTesting(false)
                                }
                            }
                        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // ⚠️ TYPE-ERASED, AND THAT IS NOT DECORATION. This body is one of the two in the app
            // that the compiler has given up on before ("unable to type-check this expression in
            // reasonable time" — three CI rounds in one day, recorded in the build notes), and adding
            // the archive's destination to the chain was enough to tip it again. AnyView resets the
            // complexity the stack has to solve, exactly the way the messages chain in ThreadView is
            // erased at its own boundary. No behaviour changes; the same views render.
            AnyView(homeStackC)
        }
        // Both stores seeded from disk on the SAME line, synchronously, before the first frame.
        // The stories row had a persisted copy all along; it just could not reach the screen in
        // time, because every path to it went through `await load(force:)`. See `seedRowFromDisk`.
        .onAppear { repo.start(); StoriesRepository.shared.seedRowFromDisk(); openPendingChat() }
        .onChange(of: router.pendingChatId) { _, _ in openPendingChat() }
        .onChange(of: repo.conversations.count) { _, _ in openPendingChat() }   // retry once chats load
    }

    /// SLICE ONE of the chat list's chain. ⚠️ THE CHAIN IS CUT INTO THREE AND EACH JOIN IS AN
    /// `AnyView`, because the whole of it in one expression is what the compiler gives up on
    /// ("unable to type-check this expression in reasonable time", twice tonight, and three CI
    /// rounds in one day before that — it is in the build notes). ThreadView's picker chain is cut
    /// the same way for the same reason. Nothing renders differently; the compiler just gets three
    /// small problems instead of one it cannot finish.
    private var homeStackA: some View {
            Group {
                if !repo.hasLoaded && repo.expectsChats && repo.skeletonArmed {
                    // Shimmer placeholders on a cold load — ONLY for an account that has ever had
                    // chats here. A fresh sign-up skips the fake rows and lands on the real empty
                    // state directly (its chats, if any ever come, still pop in via the listener).
                    ChatListSkeleton()
                } else {
                    // NOTE: the empty state is an OVERLAY inside this ZStack (below), not a separate
                    // branch — a separate branch replaced the whole view incl. the Stories row, so
                    // filtering to Unread with nothing unread made all stories vanish + showed a
                    // wrong "No chats yet". The row now always stays; only the list area goes empty.
                    loadedChatList
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)   // one row: avatar · Chats · compose
            // ⛔ SEARCH IS BACK ON THE PAGE — his call, 2026-08-30: "settings does not need search at
            // all, calls has one inside so the chat also will be like the one in the call page".
            // The detached search circle in the tab bar is gone with it. It was one control standing
            // in for three different searches depending on which tab you had come from, which is why
            // the shell had to remember where you had been; a page that knows what it searches needs
            // none of that.
            // ⛔ "chats, users, new users" — his word, so the prompt says so. It used to promise
            // only chats, which was accurate before and would be a lie now.
            .searchable(text: $chatSearch, prompt: "Search chats and people")
            // ⚠️ `.task(id:)` RATHER THAN `.onChange`. It cancels the previous lookup when the query
            // moves on, so a slow answer to an abandoned query cannot land after a fast answer to
            // the current one — which is the classic search-race and shows as the wrong person.
            .task(id: chatSearch) { await lookUpPeople(chatSearch) }
            .toolbar { homeToolbar }
            // Hide the header icons whenever a chat is on the stack (incl. the swipe-back
            // drag); reveal them only when we're fully back at the root list.
            .onChange(of: path.count) {
                showHeaderIcons = path.isEmpty
            }
            // Add Story opens the CAMERA, full screen (owner 2026-08-03). It was a bottom sheet
            // holding a picker; a camera in a card with the chat list showing behind it is not a
            // camera, and the sheet's own drag-to-dismiss would fight the preview.
            //
            // ⛔ THE COVER IS GONE — owner, 2026-08-24: it came up from the bottom, and a
            // `fullScreenCover` has no other move. The camera is mounted on the tab shell now and
            // arrives from the left on Apple's push metrics, mirrored — `StoryCameraDoor` presents
            // it with a real `UIViewControllerAnimatedTransitioning`, so UIKit owns the animation.
            // Opening is `StoryCameraDoor.open()`, from `composeStory`.
            // ⛔ THE ANSWER ARRIVES BEFORE THE CAMERA DOES (owner, 2026-08-20). Told at Upload
            // instead, a person has already opened the picker, chosen twenty photos, waited for
            // them to resolve and pressed the button — all of it spent on a post the database was
            // always going to refuse. See `composeStory`.
            // ⛔ AT THE TAP, BEFORE THE PICKER (owner, 2026-08-21: "the user must be informed before
            // selecting a photo or video … Show this message immediately when they tap Add Story").
            // His sentence, and no reason given with it: the reason is ours, it changes, and "the
            // server says no" is not something to put in front of somebody who only wants to know
            // whether to keep tapping.
            .alert(AppLimits.storiesOffMessage, isPresented: $storiesOff) {
                Button("OK", role: .cancel) {}
            }
            .alert("That's today's limit", isPresented: $storyLimitReached) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You've posted \(StoriesService.dailyStoryLimit) stories today. You can post again in about \(storyBudget.dailyLimitHoursLeft) hours.")
            }
            // Ask once when the row appears, so the button already knows the answer when it is
            // pressed. Posting keeps the count moving from there without another read.
            .task { await storyBudget.refreshDailyBudget() }
            // ONE ANSWER, EVERYWHERE, and it is this alert.
            //
            // A profile used to get a bottom sheet with the person's avatar on it while every other
            // dial site got this. The owner asked for the sheet gone: "no bottom sheet should ever be
            // shown". He is right that two presentations for one refusal was the wrong shape — the
            // sheet was a whole screen of furniture to say a sentence, and it made the same tap
            // behave differently depending on which screen you happened to be standing on.
            .alert("Can't Call", isPresented: restrictedCalleeAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This person restricts who can call them.")
            }
    }

    /// SLICE TWO: the presentations and the two navigation destinations. See homeStackA.
    private var homeStackB: some View {
        AnyView(homeStackA)
            .sheet(item: $profileGroup) { g in
                NavigationStack {
                    // .story source: no chat underneath → no Search/Wallpaper dead buttons (audit).
                    ContactInfoView(cid: storyCid(g.authorUid), name: g.name, photoUrl: g.photoUrl,
                                    source: .story)
                }
            }
            // ONE destination type for every chat (list taps AND search results),
            // keyed by cid via .id(...) so each conversation gets a fresh ThreadView
            // identity — a new chat can never inherit the previous chat's @State
            // (repo/cid), which was the cross-routing bug.
            // THE ARCHIVE IS A PAGE OF THIS STACK, not a sheet over it (owner 2026-08-13: "make it
            // like a sub page"). It rides the same path as a chat, so the back chevron is the system's
            // and a chat opened from inside the archive lands on top of it — back returns to the
            // archive, which is what both references do and what a sheet could never do.
            .navigationDestination(for: ArchiveRoute.self) { _ in
                ArchivedChatsView(pushed: true, onOpenChat: { t in path.append(t) })
            }
            .navigationDestination(for: ChatTarget.self) { t in
                // The official channel gets its own screen. ThreadView is built around a composer and
                // an encrypted message pipeline, neither of which exists here.
                if OfficialChannel.isOfficial(t.id) {
                    OfficialChatView().id(t.id)
                } else {
                    ThreadView(cid: t.id, title: t.name, photoUrl: t.photo)
                        .id(t.id)
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatView { t in
                    // Push behind the sheet, then dismiss — no flash back to the list.
                    path.append(t)
                    showNew = false
                }
            }
    }

    /// SLICE THREE: the alerts and the last of the sheets. See homeStackA.
    private var homeStackC: some View {
        AnyView(homeStackB)
            // Native alert (the confirmationDialog rendered as an anchored popover bubble on iOS 26,
            // which read as non-native). A destructive-action confirmation as an alert with a red
            // Delete button is the textbook Apple HIG pattern.
            .alert("Delete this chat?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete Chat", role: .destructive) {
                    if let c = pendingDelete { Task { await ChatService.deleteForMe(c.id) } }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes the chat from your list. It comes back if you get a new message.")
            }
            // displayName, not name(for:) — the latter shows a MEMBER's name for groups.
            .confirmationDialog(muteTitle, isPresented: mutePrompted,
                                titleVisibility: .visible) { muteActions }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            // (The archive is PUSHED now — see `archiveRoute` on the navigationDestination above.)
            .sheet(isPresented: $showMyQR) { MyQRView() }
            .sheet(item: pendingInvite) { item in
                JoinGroupSheet(code: item.code).presentationDetents([.large])
            }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
    }

    /// ⛔ ONE DOOR TO THE COMPOSER, AND THE DAY'S LIMIT IS CHECKED ON THE WAY THROUGH IT.
    ///
    /// Two places open it — the menu's Add Story and the "+" on the story row — and both went
    /// straight to opening the camera. The refusal then arrived from the database at Upload, after the
    /// picker had been opened, photos chosen and resolved and the button pressed, all of it spent
    /// on a post that was never going to land. He asked for the answer at the tap instead.
    ///
    /// The database is still the enforcement and this is not a second one: `dailyLimitReached` is
    /// false whenever the count is unknown, so nothing here can lock somebody out on its own.
    private func composeStory() {
        // THE FEATURE FIRST, THE ALLOWANCE SECOND. Being told "that is today's limit" when stories
        // are switched off for everybody would be a true sentence about the wrong thing.
        guard AppLimits.shared.storiesEnabled else { storiesOff = true; return }
        if storyBudget.dailyLimitReached {
            storyLimitReached = true
            // The cached count said full — confirm it against the server, so a window that rolled
            // while the app sat open opens the composer on the next tap instead of a day later.
            Task { await storyBudget.refreshDailyBudget() }
        } else {
            // The door, not a cover binding — it presents the camera itself, so nothing needs to be
            // mounted on this screen or on the tab shell for it.
            StoryCameraDoor.open()
        }
    }

    // Open a chat from a notification tap. Stays pending until the chat list loads
    // so we can resolve name/photo, then routes straight to it.
    private func openPendingChat() {
        guard let cid = router.pendingChatId else { return }
        // CLOSE WHATEVER IS COVERING THIS STACK FIRST (audit). The chat is pushed onto the path
        // underneath, so with the Archive sheet, a story cover, the compose sheet or a profile sheet
        // up, a notification tap looked like it did nothing — and the intent is consumed below, so
        // it never healed. This file's own comment already treats "opens somewhere hidden" as the
        // failure to prevent.
        // (No archive sheet to close any more: it is a page of this stack, and the chat is pushed
        // on top of it — see the ArchiveRoute destination.)
        showNew = false
        // The camera is not a cover any more, so a binding cannot take it away — the door does.
        StoryCameraDoor.close()
        // The story viewer is not a cover any more, so it cannot be dismissed by clearing a binding:
        // it is a presented screen and the door takes it away. Same job, one call.
        StoryDoor.dismiss()
        profileGroup = nil
        // Navigate even if the conv isn't cached yet (e.g. a brand-new 1:1 opened from a
        // group member sheet) — fall back to the name/photo the caller supplied.
        let conv = repo.conversations.first(where: { $0.id == cid })
        let name = conv?.displayName(me) ?? router.pendingChatName ?? "Chat"
        let photo = conv?.displayPhoto(me) ?? router.pendingChatPhoto
        var p = NavigationPath()
        p.append(ChatTarget(id: cid, name: name, photo: photo))
        path = p
        router.pendingChatId = nil
        router.pendingChatName = nil
        router.pendingChatPhoto = nil
    }
}

// Archived chats (reached from the avatar menu). Swipe to unarchive.
struct ArchivedChatsView: View {
    /// PUSHED, NOT PRESENTED (owner 2026-08-13, ours beside both references: "make it like a sub
    /// page"). Both of them push the archive onto the chat list's own stack — back chevron top left,
    /// the list sliding in from the right — and a drawer that slides up from the bottom reads as a
    /// detour instead of a place inside the app.
    ///
    /// ⚠️ WHEN PUSHED IT MUST NOT BUILD ITS OWN NavigationStack, and it must not declare a
    /// `navigationDestination` for ChatTarget either: it is INSIDE the chat list's stack, which
    /// already has one, and two registrations for the same type in one stack is a fight over who
    /// answers. So a pushed archive hands the tap up to its parent instead.
    var pushed = false
    var onOpenChat: ((ChatTarget) -> Void)? = nil
    /// ⚠️ SPELLED OUT, because the synthesised one cannot be called from here. Every other stored
    /// property below is `private`, so the memberwise initializer is synthesised private too — and
    /// `private` reaches this type and its own extensions, NOT the view next door that presents it,
    /// even in the same file. Without this, `ArchivedChatsView(pushed:)` resolves to the no-argument
    /// init and the compiler says the call takes no arguments.
    init(pushed: Bool = false, onOpenChat: ((ChatTarget) -> Void)? = nil) {
        self.pushed = pushed
        self.onOpenChat = onOpenChat
    }
    private var repo = ConversationsRepository.shared
    private var storiesRepo = StoriesRepository.shared   // archived (hidden) stories appear at the top
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var path = NavigationPath()
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showDeleteSelected = false
    @State private var pendingDelete: Conversation?     // one chat, from the swipe or the row menu
    @State private var prefsTick = 0              // re-render after Unhide
    /// Open Profile, from a story card's long press. The same sheet the chat list puts behind that
    /// action, so one menu entry does not mean two different things on two screens.
    @State private var profileGroup: StoryGroup?
    /// The strip floats over the list and travels with it — see the ZStack in `content`. Its own
    /// pair, not the chat list's: a different strip, a different height, a different List.
    /// The long press's ramp, read by the archive cards so a held one squeezes and dims. Shared, and
    /// harmless where it is not read — see `StoryPressVisual`.
    @ObservedObject private var pressVisual = StoryPressVisual.shared
    @State private var archiveScrollY: CGFloat = 0
    @State private var archiveStripHeight: CGFloat = 0
    /// What is typed in the bar at the bottom of the page. Empty = every archived chat.
    @State private var archiveQuery = ""
    @FocusState private var archiveSearchFocused: Bool

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    private var archivedStories: [StoryGroup] {
        _ = prefsTick
        return storiesRepo.others.filter { StoryPrefs.isHidden($0.authorUid) }
    }
    private var storyCardW: CGFloat { (UIScreen.main.bounds.width - 24 - 30) / 4 }

    /// The archived row's long-press menu. Deliberately short: this is a drawer you visit to take
    /// something OUT of, so the actions are the ones that belong to that, and every one of them is
    /// real. It does not reuse the chat page's `chatMenu` because half of that menu (Archive, Pin)
    /// makes no sense on a chat that is already archived.
    @ViewBuilder private func archivedMenu(_ conv: Conversation) -> some View {
        Button { Task { await ChatService.setArchived(conv.id, false) } } label: {
            Label { Text("Unarchive") } icon: { MenuIcon("ic_archive", ink: .label) }
        }
        if conv.hasUnreadMark(me) {
            Button {
                Task { await ChatService.resetUnread(conv.id); await ChatService.markRead(conv.id) }
            } label: {
                Label { Text("Read") } icon: { MenuIcon("ic_menu_unread", ink: .label) }
            }
        } else {
            Button { Task { await ChatService.markUnread(conv.id) } } label: {
                Label { Text("Unread") } icon: { MenuIcon("ic_menu_unread", ink: .label) }
            }
        }
        // Through the same confirmation the swipe uses, and the same one the chat list has always
        // had. This one deleted on the spot, which made the archive the only place in the app where
        // a chat could go with one tap and no question.
        Button(role: .destructive) { pendingDelete = conv } label: {
            Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill", ink: .systemRed) }
        }
    }

    /// The bar's own height plus its air, so the list can be told how much to leave clear of it.
    private static let archiveSearchSlot: CGFloat = 44 + 16

    /// ⛔ THE SEARCH BAR, AT THE BOTTOM OF THE PAGE (his order, circled at the foot of the screen).
    ///
    /// ⚠️ OURS AND NOT `.searchable`. That modifier picks its own placement, and on a page that is
    /// PUSHED with no tab bar under it, iOS puts the field in the NAVIGATION BAR — the top of the
    /// screen, not where he pointed.
    ///
    /// ⛔ 32 EACH SIDE, HIS NUMBER (2026-08-21). It was 16, the page margin the chat rows use.
    ///
    /// ⛔ AND IT IS AN OVERLAY NOW, NOT A `safeAreaInset`, WHICH IS THE WHOLE OF HIS "no effect".
    /// A safe-area inset RESERVES a strip: the list stops above the bar and nothing ever passes
    /// behind it. Liquid Glass refracts what is behind it, so a glass capsule with a strip of empty
    /// page behind it has nothing to work with and renders as a flat grey pill — which is exactly
    /// what he photographed. As an overlay with a matching bottom content margin, the chats scroll
    /// UNDER the bar and the glass finally has something to bend.
    private var archiveSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $archiveQuery)
                    .focused($archiveSearchFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // ⛔ THIS ONE CLEARS THE TEXT AND THAT IS ALL IT DOES NOW. It used to double as the
                // way out of the keyboard, appearing on focus as well as on text, and that is exactly
                // what he could not find: a small glyph INSIDE the pill, in the position every text
                // field in iOS puts a clear button, reads as "erase what I typed" no matter what it
                // is wired to. He looked straight at it and reported the button missing.
                if !archiveQuery.isEmpty {
                    Button { archiveQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .liquidGlass(Capsule())

            // ⛔ AND THIS ONE ENDS THE SEARCH — OUTSIDE THE PILL, WHICH IS THE WHOLE POINT.
            //
            // His reference shot: the field shortens and a round X stands beside it. Being its own
            // button, at the field's own 44pt, in its own glass circle, it cannot be mistaken for
            // part of the field — and there is now exactly one thing on screen that means "close
            // this" instead of two glyphs a few points apart meaning different things.
            //
            // Only while focused. At rest the bar is a search field alone and there is nothing to
            // end, which is also what keeps the resting layout he already approved unchanged.
            if archiveSearchFocused {
                Button {
                    archiveQuery = ""
                    archiveSearchFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        // NON-interactive glass, the same trap the call screen's buttons hit:
                        // `.interactive()` glass takes the touch itself and the wrapping Button never
                        // fires. `contentShape` is what makes the whole circle the target rather than
                        // just the drawn glyph.
                        .liquidGlass(Circle(), interactive: false)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        // ⛔ 32 AT REST, 16 WITH THE KEYBOARD UP (his order, 2026-08-21). A search bar sitting alone
        // above the home indicator can afford to be inset and look deliberate; the moment it is
        // being TYPED into it is the only thing on that half of the screen and wants the room, so it
        // widens to the page margin the chat rows use.
        //
        // Focus rather than a keyboard-height observer: this field is the only thing on the page
        // that can raise a keyboard, so being focused and the keyboard being up are the same fact,
        // and one of them is already state we hold.
        //
        // Animated on the same easing SwiftUI gives the keyboard, so the bar widens WITH it instead
        // of snapping before it — and the X now rides in on that same curve.
        .padding(.horizontal, archiveSearchFocused ? 16 : 32)
        .animation(.easeOut(duration: 0.25), value: archiveSearchFocused)
        .padding(.bottom, 8)
    }

    /// A search that found nothing has to say so. Without this the page just empties, which reads as
    /// the archive having been cleared rather than as a query matching no one.
    @ViewBuilder private var archiveNoResults: some View {
        if archived.isEmpty, !archiveQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("No chats found.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, archiveStripHeight + 40)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Is the story strip on screen at all — asked in two places (the strip itself and the top
    /// content margin that makes room for it), so it is one answer rather than two that can drift.
    private var archiveStripShowing: Bool {
        !archivedStories.isEmpty && archiveQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The story strip, floating over the list and travelling with it.
    ///
    /// ⛔ LIFTED OUT OF `content` FOR THE TYPE-CHECKER, which gave up on that expression the moment
    /// this was inlined into it ("unable to type-check this expression in reasonable time"). This
    /// file's budget is a known cost and the documented answer is to split values out; it costs
    /// nothing at runtime. The same reason `loadedChatList` exists.
    @ViewBuilder private var archivedStripOverlay: some View {
        // ⛔ THE STRIP GOES WHILE SEARCHING (his order): a search on this page is a question about
        // CHATS, and leaving a row of story cards above the answer is the same clutter the chat
        // list's own filters already refuse. `archiveQuery` empty = not searching.
        if archiveStripShowing {
            VStack(spacing: 0) {
                archivedStoriesRow
                // ⚠️ TEMPORARY — comes out with `StoryPressDebug.on`. See the note above it.
                StoryPressDebugReadout()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { archiveStripHeight = $0 }
            // Travels with the content. Negative, because a list scrolled DOWN has a positive
            // offset and the strip has to move UP by the same amount.
            .offset(y: -archiveScrollY)
        }
    }

    // Horizontal cards of hidden people; tap to view, long-press to Unhide.
    private var archivedStoriesRow: some View {
        // ⛔ A SCROLL VIEW WE OWN, NOT ONE THE PRESS HAS TO GO LOOKING FOR (his order, 2026-08-21:
        // "make the archive stories row use the same UIKit"). This was a SwiftUI `ScrollView` with
        // `StoryRowLongPress` hung off it as a `.background`, which had to CLIMB to find the scroller
        // and install a recogniser on whatever it found. Four reports, three fixes, all of them
        // patches on that climb. See `ArchiveStripScroller` for the whole account.
        //
        // ⚠️ THE CARDS BELOW ARE UNTOUCHED. Only the scroller changed hands.
        ArchiveStripScroller(target: archivedMenuTarget,
                             onTap: openArchivedStory,
                             // The card, its label, and the strip's own vertical padding — the same
                             // numbers the card's frame two dozen lines down is built from.
                             height: storyCardW * 1.46 + 6 + 16 + 20) {
            HStack(alignment: .top, spacing: 10) {
                // KEYED ON `authorUid`, THE SAME THING THE `.id()` BELOW SETS, and that mismatch is
                // his "long press the first story and it opens the second".
                //
                // `ForEach` was keying on `StoryGroup.id` while the row then re-declared its identity
                // as `authorUid`. Two different answers to "which view is this", so when SwiftUI
                // rebuilt the row it could hand a card's context menu to the neighbour it thought was
                // the same view. One key, declared once, and there is nothing left to disagree.
                ForEach(archivedStories, id: \.authorUid) { g in
                    // ⛔ NO BUTTON. THE TAP IS A RECOGNISER ON THE STRIP NOW (owner 2026-08-22, third
                    // time asking: "use the real one, the one the main chat list uses").
                    //
                    // A SwiftUI Button is backed by a gesture recogniser that BEGINS ON TOUCH-DOWN to
                    // drive its pressed state, and a recogniser that begins cancels the exclusive ones
                    // analysing the same touches — so the strip's long press was killed at touch-down
                    // and never reached its threshold. Four fixes shipped against that and every one
                    // left the Button in place.
                    //
                    // The chat list's cards are UIKit controls, which take input by touch DELIVERY
                    // rather than through a recogniser, so nothing competes with its press and it has
                    // never failed. Removing the Button is that same property. The tap now lives
                    // beside the press on the scroll view and is resolved by the same point lookup,
                    // so the two cannot disagree about which card was meant.
                    Group {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomLeading) {
                                StoryImage(url: g.stories.last?.previewUrl ?? "")
                                    .frame(width: storyCardW, height: storyCardW * 1.46)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))   // match home cards
                                AvatarView(name: g.name, photoUrl: g.photoUrl, size: 32)
                                    .overlay(StoryRingView(seen: StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt), lineWidth: 2)   // watermark: match the stories row
                                        .frame(width: 37, height: 37))
                                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                                    .padding(8)
                            }
                            Text(g.name.isEmpty ? "User" : g.name)
                                .font(.system(size: 12)).lineLimit(1).frame(width: storyCardW)
                        }
                    }
                    // ⛔ THE LONG-PRESS RAMP. WITHOUT THESE TWO LINES THE PRESS HAS NO ANIMATION AT ALL.
                    //
                    // His report the moment the press itself started working: "now long press is
                    // working but there's no animation". There never was one here. The chat list's
                    // cards are UIKit `UIControl`s, so they get `isHighlighted` on touch-down for
                    // free and the row springs them to 0.92 from it; these are plain SwiftUI views,
                    // which have no pressed state of their own at all — the press drives this one.
                    //
                    // 0.92 on a 0.28/0.7 spring, which is the CHAT ROW'S dip and not the reference
                    // app's ramp — his order after seeing the two side by side. The same row on two
                    // screens has to press the same way; see `StoryPressVisual.fingerDown`.
                    //
                    // No `.animation` modifier on purpose: the spring lives in that setter, so the
                    // press and the release cannot drift apart from each other here.
                    .scaleEffect(pressVisual.squeezedKey == MediaOpenRects.key(.storyRow, "arch-\(g.id)")
                                 ? StoryPressVisual.dipScale : 1)
                    // The flight's source. Same 24 the card is actually drawn with, so the story
                    // lands as a CARD here rather than the circle a ringed avatar gets — the shape
                    // is read from this number and nowhere else.
                    .modifier(MediaRectReporter(id: "arch-\(g.id)", scope: .storyRow, cornerRadius: 24))
                    // NO `.contextMenu` HERE ANY MORE (his 2026-08-08: "in archive page story when i
                    // long press is using native plz use my custom longpress"). Apple's menu did not
                    // lift this card, it rebuilt a second one from a `preview:` closure — the same
                    // thing the stories row was moved off in `4d1e02f`. The press below lifts the
                    // card's own pixels into the app's menu, so the two screens now feel the same.
                    // No `.id()` here any more: the ForEach above keys on `authorUid`, so the identity
                    // is already stable. Declaring it twice was the whole problem.
                }
            }
            // ONE recogniser for the whole strip, never one per card: a recogniser that lives on a
            // card has to be hit-testable, and then the card's own Button never sees the tap. It is
            // installed by `ArchiveStripScroller` on the scroll view it owns — the `.background`
            // that used to sit here is gone with the climb it depended on.
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    /// Which archived card is under the finger, and what its menu says. The rectangles come from the
    /// same registry the story flight flies to, so the lift and the flight cannot disagree about
    /// where a card is — the rule the stories row's own `menuTarget` is built on.
    ///
    /// THE PICTURE ALONE IS LIFTED. The reported rect here covers the whole button, name included,
    /// because that is what the flight was given; but the card is rounded and the name is not, so
    /// cutting the pair under one 24pt radius would round the label's bottom. The card's height is
    /// known exactly (`storyCardW * 1.46`, the frame two lines up from the reporter), so the strip
    /// that is lifted is the top of that rect and nothing else.
    /// Opening one by tap, resolved from the SAME rectangles the long press asks about.
    ///
    /// ⚠️ ONE LOOKUP FOR BOTH GESTURES, which is the point of doing it here rather than leaving a
    /// Button on the card. The press already answers "which card is under this finger" through
    /// `MediaOpenRects`; asking the same registry for the tap means a press and a tap can never
    /// disagree about which story was meant — the mismatch that produced "long press the first story
    /// and it opens the second" when two different things each had their own opinion.
    private func openArchivedStory(at p: CGPoint) {
        for g in archivedStories {
            let key = MediaOpenRects.key(.storyRow, "arch-\(g.id)")
            guard let r = MediaOpenRects.liveRect(key), r.contains(p) else { continue }
            // Archived stories are a drawer of ONE person each — no paging out of the card you
            // tapped into somebody else's, which the row does and this must not.
            StoryDoor.open(g, from: "arch-\(g.id)", deliveredToMe: true,
                           onClosed: { prefsTick += 1 })
            return
        }
    }

    /// The 1:1 conversation id for a person, built the way the chat list builds it: both uids
    /// sorted, joined. A story card knows an author, not a chat.
    private func storyCid(_ other: String) -> String {
        [me, other].sorted().joined(separator: "_")
    }

    /// Send Message, from a story card's long press. Routed exactly like an archived chat ROW is:
    /// handed up to the parent stack when this page is pushed, onto our own path when it is not.
    /// Anything else would push a chat onto a stack that is not the one on screen.
    private func openStoryChat(_ g: StoryGroup) {
        let t = ChatTarget(id: storyCid(g.authorUid), name: g.name, photo: g.photoUrl)
        if let onOpenChat { onOpenChat(t) } else { path.append(t) }
    }

    private func archivedMenuTarget(at p: CGPoint) -> StoryMenuTarget? {
        for g in archivedStories {
            let key = MediaOpenRects.key(.storyRow, "arch-\(g.id)")
            guard let r = MediaOpenRects.liveRect(key), r.contains(p) else { continue }
            // THE HIT USES THE MODEL RECT, THE LIFT USES THE DRAWN ONE — the same split the chat
            // list's `menuTarget` makes, and for the same reason: a card mid-press-dip has already
            // committed 0.92 to the model while its pixels are still nearer 0.96, so a window crop
            // taken at the model rectangle lifts a magnified card (his 2026-08-09 zoom report). The
            // finger test stays on `liveRect`, which is what the flight flies to.
            let drawn = MediaOpenRects.drawnRect(key) ?? r
            // ⚠️ THE CARD'S HEIGHT IS READ OFF THE DRAWN WIDTH, NEVER OFF `storyCardW` (owner
            // 2026-08-22: the white border round a long-pressed archive card). `storyCardW * 1.46`
            // is the card at REST, but `drawn` is the card mid-press-dip — so the clamp was ~8%
            // taller than the thing on screen, and the strip it photographed below the card was
            // archive-page background, which is near-white in light mode. Under the image view's own
            // 24pt corner mask that came out as an outline.
            //
            // The button is exactly one card wide, so `drawn.width` carries whatever the dip is
            // currently worth and `× 1.46` turns it into that same card's height. Self-correcting
            // mid-spring, where any fixed factor would only be right at one instant.
            let cardRect = CGRect(x: drawn.minX, y: drawn.minY, width: drawn.width,
                                  height: min(drawn.height, drawn.width * 1.46))
            // ⛔ THE STORIES ROW'S OWN MENU, ONE SWAPPED LINE (owner 2026-08-25: "why is it
            // different, use the long press like it does the regular time"). It held Unhide alone,
            // so pressing a card here answered a different question than pressing the same person's
            // card on the home row — and Send Message and Open Profile, the two that have nothing to
            // do with hiding, were missing for no reason. Only the last entry differs, because a
            // card that is already hidden has nothing to hide. Keep the order: the destructive-ish
            // one stays at the bottom on both screens.
            return StoryMenuTarget(key: key, rect: cardRect, actions: [
                CMAction(title: "Send Message", icon: "message") { openStoryChat(g) },
                CMAction(title: "Open Profile", icon: "person.crop.circle") { profileGroup = g },
                CMAction(title: "Unhide Story", icon: "tray.and.arrow.up") {
                    StoryPrefs.toggleHidden(g.authorUid)
                    prefsTick += 1
                },
            ])
        }
        return nil
    }

    private var hasAnyArchived: Bool {
        repo.conversations.contains { $0.isArchived(me) && !$0.isCleared(me) && (Flags.groupsEnabled || !$0.isGroup) }
    }
    private var archived: [Conversation] {
        // The official channel can be archived like any other chat, so it has to be findable here or
        // archiving it would look like deleting it.
        let all = (repo.conversations + [OfficialChannelStore.shared.listEntry].compactMap { $0 })
            .filter { $0.isArchived(me) && !$0.isCleared(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
        let q = archiveQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayName(me).lowercased().contains(q) }
    }

    var body: some View {
        // Pushed: no stack of its own, and no ChatTarget destination — the parent owns both. See the
        // note on `pushed`.
        if pushed { content } else { NavigationStack(path: $path) { content } }
    }

    private var content: some View {
            Group {
                if !hasAnyArchived && archivedStories.isEmpty {
                    EmptyStateView(title: "Nothing archived", icon: "archivebox",
                                   text: "Chats you archive and stories you hide will show here.")
                } else {
                    // ⛔ THE STRIP FLOATS OVER THE LIST AND MOVES WITH IT (his 2026-08-21: "when i
                    // scroll up archive chats is entering under story, story never moving").
                    //
                    // It was a VStack, so the strip was a SIBLING of the List: pinned, while the
                    // chats scrolled underneath it and disappeared behind it. This is the same
                    // arrangement the main chat list has used since its own stories row landed — a
                    // ZStack, a top content margin the height of the strip so the first chat starts
                    // below it, and the strip offset by the negative scroll so it travels with the
                    // content and leaves the top of the screen with it.
                    //
                    // ⚠️ IT STAYS OUTSIDE THE LIST. Inside one, a long press lifts the WHOLE CELL as
                    // a single preview and every card in the strip rises together — the note above
                    // the main row has said so since build 147. The offset is what makes an outside
                    // view behave like an inside one.
                    ZStack(alignment: .top) {
                        // THE STORIES ROW SITS OUTSIDE THE LIST, exactly as it does on the main
                        // chat page, and for the reason written there since build 147: inside a
                        // List a long press lifts the WHOLE CELL as one preview, so every card in
                        // the row rises together and the menu belongs to the row rather than to the
                        // story you pressed. That is what he is seeing. Out here each card carries
                        // its own menu, and `.id(authorUid)` keeps that menu bound to its person.
                        List(selection: $selection) {   // stable binding (Set selects only in edit mode) -> smooth edit transition
                            ForEach(archived) { conv in
                                // ⛔ THE CHAT LIST'S OWN SHAPE, NOT A SECOND ONE (owner 2026-08-22,
                                // third report: "a tap only highlights it, I have to tap again", and
                                // "only sometimes, not all the time").
                                //
                                // This row used to carry the select branch INSIDE the button, which
                                // is the arrangement `chatListRow` was deliberately moved away from
                                // and its note explains why: SwiftUI disables a Button in a List's
                                // edit mode, so a row that routes selection through its own button
                                // is routing it through the one thing that has been switched off.
                                // The chat list keeps the button permanently and lays a tap-catcher
                                // over it instead, so one structure serves both modes and the row's
                                // identity never changes underneath a finger — which is exactly the
                                // "sometimes" in his report: an intermittent fault is a race, and
                                // the race is a press whose button is rebuilt mid-touch.
                                //
                                // Same three lines, same order, same reasons. If this ever needs
                                // changing again, change `chatListRow` and copy it here — or better,
                                // make them one function.
                                Button {
                                    let t = ChatTarget(id: conv.id, name: conv.displayName(me),
                                                       photo: conv.displayPhoto(me))
                                    if let onOpenChat { onOpenChat(t) } else { path.append(t) }
                                } label: {
                                    ChatRow(conv: conv, me: me, dark: dark,
                                            draft: Drafts.shared.text(conv.id),
                                            voiceDraftSecs: AudioRecorder.draftIndex[conv.id] ?? 0,
                                            voiceUnplayed: PlayedVoice.shared.lastVoiceUnplayed(conv, me: me))
                                        // ⛔ THE OTHER TWO LINES FROM `chatListRowLabel`, AND THEY ARE WHAT
                                        // MADE THIS ROW OPEN ONLY WHERE THE TEXT IS (owner 2026-08-25,
                                        // screenshot: the empty band between the preview and the date was
                                        // dead to a finger). A Button's target is its label's shape, and a
                                        // bare ChatRow is only as wide as its content, so half the row was
                                        // never in it. The chat list has carried both lines all along.
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())   // whole row tappable (incl. empty space)
                                }
                                .buttonStyle(.plain)
                                .allowsHitTesting(!selecting)
                                .overlay {
                                    if selecting {
                                        Color.clear.contentShape(Rectangle())
                                            .onTapGesture { toggleTick(conv.id, in: $selection) }
                                    }
                                }
                                .moveDisabled(true)
                                .tag(conv.id)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                // Native swipe platter (grey) — no white listRowBackground override
                                // that painted over the row content on swipe.
                                //
                                // Unarchive stays FIRST, which is both the outermost button and the
                                // one a full swipe fires: taking something out is what this drawer is
                                // for, and it is what the reference app puts under the same finger.
                                // Delete was menu-only, so the one action people reach for by swiping
                                // on every other list was missing here (owner 2026-08-13).
                                .swipeActions(edge: .trailing) {
                                    Button { Task { await ChatService.setArchived(conv.id, false) } } label: {
                                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                                    }.tint(.indigo)
                                    // `.tint(.red)`, not left to `role: .destructive`. The role only
                                    // colours a swipe action while the app has not tinted itself,
                                    // and this one tints `.primary` app-wide — so the button took
                                    // WHITE at night and drew a white glyph on it (owner 2026-08-16,
                                    // screenshot: an empty white pill beside a purple Unarchive).
                                    // The chat list's own Delete already forces red for this reason.
                                    Button(role: .destructive) { pendingDelete = conv } label: {
                                        Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill") }
                                    }
                                    .tint(.red)
                                }
                                // THERE WAS NO LONG-PRESS MENU HERE AT ALL, and that is both of his
                                // reports about this list. The chat page has carried one since it was
                                // built; this list only ever had swipe actions, so a long press had
                                // nothing to open — AND nothing to hand the press to. A List row with
                                // no menu keeps the press highlight it lit on touch-down, which is the
                                // grey that never went away. Giving the row a menu takes the gesture
                                // and takes the highlight with it.
                                // AND THE SAME PEEK THE CHAT LIST HAS (his question, 2026-08-14: does
                                // the archive not have the preview?). It did not — menu only, while
                                // the chat list showed the conversation's real last messages above
                                // it. Same card, same builder; an archived chat is still a chat and
                                // the whole point of the peek is reading it without opening it.
                                .contextMenu {
                                    archivedMenu(conv)
                                } preview: {
                                    ChatPeekPreview(cid: conv.id, me: me)
                                }
                            }
                        }
                        .listStyle(.plain)
                        // ⛔ THE GREY THAT SURVIVES A ROUND TRIP (owner 2026-08-22: "I click a chat,
                        // open it, press back, and the highlight is still there").
                        //
                        // The row's Button pushes the chat — but the tap ALSO sets this List's
                        // selection, and SwiftUI does not clear that on the way back. The row is then
                        // genuinely SELECTED, and selected renders as a permanent grey fill. It is not
                        // a press highlight at all, which is why it outlives the press.
                        //
                        // Outside edit mode there is no such thing as a selected chat, so say so.
                        // These are the chat list's own two handlers, verbatim, added there for this
                        // exact report and never copied here — the same gap as the row structure was.
                        .onChange(of: selection) { _, sel in
                            if !selecting, !sel.isEmpty { selection.removeAll() }
                        }
                        .onChange(of: selecting) { _, on in
                            if !on, !selection.isEmpty { selection.removeAll() }   // leaving edit mode clears it
                        }
                        .environment(\.editMode, .constant(selecting ? .active : .inactive))
                        // The selection tick, same as the calls list. See the note there.
                        .tint(Theme.defaultBubble(dark))
                        // Room for the strip, so the first chat starts under it rather than behind
                        // it. The height is measured rather than guessed — the card is sized off the
                        // screen width and the label under it wraps.
                        // ⚠️ THE SAME CONDITION THE STRIP ITSELF USES. Searching hides the strip, so
                        // reserving its height would leave a band of nothing above the results.
                        .contentMargins(.top, archiveStripShowing ? archiveStripHeight : 0,
                                        for: .scrollContent)
                        // Room for the search bar the chats now scroll BEHIND — see `archiveSearchBar`.
                        .contentMargins(.bottom, hasAnyArchived ? Self.archiveSearchSlot : 0,
                                        for: .scrollContent)
                        .onScrollGeometryChange(for: CGFloat.self,
                                                of: { $0.contentOffset.y + $0.contentInsets.top },
                                                action: { _, y in archiveScrollY = y })

                        archiveNoResults
                        archivedStripOverlay
                    }
                }
            }
            // ⛔ THE BAR SITS UNDER THE LIST AND THE LIST SCROLLS CLEAR OF IT. Not while SELECTING:
            // that mode already owns the bottom of the screen with unarchive, read and delete, and
            // two bars stacked there is one too many. Not on an empty archive either — a field that
            // searches nothing.
            // ⛔ AN OVERLAY, SO THE CHATS PASS BEHIND THE GLASS. See `archiveSearchBar` — a
            // `safeAreaInset` reserved a strip and left the bar with nothing behind it to refract,
            // which is why it rendered as a flat pill. The matching bottom margin on the List is
            // what still lets the last row scroll clear of it.
            .overlay(alignment: .bottom) {
                if !selecting && hasAnyArchived { archiveSearchBar }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            // THE TAB BAR HAS NO BUSINESS HERE (owner 2026-08-19, screenshot). The archive is a
            // PUSHED page of the chats stack, so it inherited the shell's tab bar and the floating
            // Chats/Calls/Settings pill sat under a sub page. Every other pushed page in the app
            // already hides it (ThreadView, ContactInfoView). Only when pushed: presented as a
            // sheet this view lives outside the TabView and there is nothing to hide.
            .toolbar(pushed ? .hidden : .automatic, for: .tabBar)
            // NO SEARCH BAR (his call, 2026-08-13, first thing he caught on 571). It has been here
            // since June and neither reference has one: the archive is the short list you put things
            // in on purpose, and a permanent search field over a handful of rows is furniture. The
            // app's own search tab still finds these chats — archiving hides a chat from the list,
            // it does not hide it from search.
            // ⚠️ ONLY WHEN THIS VIEW OWNS THE STACK. Pushed, the chat list's stack already answers
            // for ChatTarget, and a second registration for the same type in one stack is two views
            // claiming the same destination.
            .navigationDestination(for: ChatTarget.self) { t in
                if pushed {
                    EmptyView()
                } else if OfficialChannel.isOfficial(t.id) {
                    OfficialChatView().id(t.id)
                } else {
                    ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
                }
            }
            // (No story cover here any more: the archived card opens through `StoryDoor`, which is
            // the same presentation, the same flight and the same drag-down close as every other
            // door in the app. See the Button above.)
            // ⛔ ONE WAY OUT OF SELECT MODE, NOT TWO (his screenshot: the chevron and the ✕ side by
            // side). The ✕ is added as a leading item while selecting, but the system back button is
            // still there underneath it, so both drew — and they do different things: one leaves the
            // mode, the other leaves the page with a selection still made. Same line the media
            // gallery already carries for the same reason.
            .navigationBarBackButtonHidden(selecting)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { exitSelect() } label: { Image(systemName: "xmark") }.tint(.primary)
                    }
                    ToolbarItem(placement: .principal) {
                        Text(selection.isEmpty ? "Select Chats" : "\(selection.count) Selected").font(.headline)
                    }
                    // Native bottom toolbar, same as the main chat list selection mode.
                    ToolbarItemGroup(placement: .bottomBar) {
                        // ⛔ OUR OWN ICON, THE ONE THE CHAT LIST ALREADY USES (his order, 2026-08-21).
                        // It was `tray.and.arrow.up`, an Apple symbol, sitting in the same position as
                        // the chat list's `ic_archive` and drawn in a different hand — two bottom bars
                        // that do the opposite halves of one action, looking like two different apps.
                        // Same asset, same 22pt, same template rendering as the chat list's.
                        Button { unarchiveSelected() } label: {
                            Image("ic_archive").renderingMode(.template).resizable().scaledToFit()
                                .frame(width: 22, height: 22)
                        }
                            .tint(.primary).disabled(selection.isEmpty)
                        Spacer()
                        Button(readTitle) { markReadTargets() }.tint(.primary).disabled(readTargets.isEmpty)
                        Spacer()
                        Button(role: .destructive) { showDeleteSelected = true } label: { Image(systemName: "trash") }
                            .disabled(selection.isEmpty)
                    }
                } else {
                    // Select is named outright here rather than hidden behind a "…" — see
                    // `archiveSelectButton`. Done stays exactly where it was.
                    if hasAnyArchived {
                        ToolbarItem(placement: .topBarTrailing) { archiveSelectButton }
                    }
                    // Pushed, the back chevron is the way out and a Done beside it is a second one.
                    if !pushed {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                    }
                }
            }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
            // Word for word the chat list's own delete alert — one question, asked the same way
            // wherever a chat can go.
            .alert("Delete this chat?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete Chat", role: .destructive) {
                    if let c = pendingDelete { Task { await ChatService.deleteForMe(c.id) } }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes the chat from your list. It comes back if you get a new message.")
            }
            // Open Profile, from the story card's menu. `.story` source, same as the chat list's:
            // there is no chat under this sheet, so Search and Wallpaper would be dead buttons.
            .sheet(item: $profileGroup) { g in
                NavigationStack {
                    ContactInfoView(cid: storyCid(g.authorUid), name: g.name, photoUrl: g.photoUrl,
                                    source: .story)
                }
            }
            .onAppear { repo.start() }
    }

    /// ⛔ A "SELECT" BUTTON, NOT A "…" MENU, AND THE MENU IS GONE ENTIRELY.
    ///
    /// His question, 2026-08-21, and it answers itself: "why is there a 3-dot button now when the
    /// only option inside it is Select?" A disclosure control exists to hold a CHOICE. Archive
    /// settings and How does it work were removed from here earlier the same day (both circled by
    /// him), which left one entry behind a control whose entire job is to say there are several —
    /// so every tap cost a menu, an animation and a second tap to reach the one thing it could do.
    ///
    /// Named outright now. The label is the action, one tap performs it, and the note that used to
    /// stand here about never shipping an EMPTY "…" is moot: there is no menu left to be empty.
    ///
    /// Still gated on `hasAnyArchived` at the call site, for the reason that gate has always had —
    /// nothing to select in an empty archive — but now the gate hides a button that would be dead
    /// rather than one that would open onto nothing.
    private var archiveSelectButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.35)) { selecting = true }
        } label: {
            Text("Select")
        }
        .tint(.primary)
    }

    private func exitSelect() { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } }
    private func unarchiveSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.setArchived(id, false) } }
        exitSelect()
    }
    // Identical rule to the main chat list's Read button — see the long note on `readTargets`
    // there. "Read All" here means every unread chat in the ARCHIVE, which is the list this
    // screen renders; that same messenger scopes Read All the same way, to the rendered list.
    private var readTitle: String { selection.isEmpty ? "Read All" : "Read" }

    private var readTargets: [String] {
        let pool = selection.isEmpty ? archived : repo.conversations.filter { selection.contains($0.id) }
        // Same blocked exclusion as the main list's version (audit) — the archived list can hold
        // silently blocked chats too, and markRead there leaks read receipts just the same.
        // hasUnreadMark, so Read All also clears the ones you marked unread BY HAND. `unread()`
        // clamps the -1 sentinel to zero, so those chats were invisible to this filter and survived
        // a "mark everything read" untouched.
        return pool.filter { !$0.isBlockedByMe(me) && $0.hasUnreadMark(me) }.map(\.id)
    }

    private func markReadTargets() {
        let ids = readTargets
        guard !ids.isEmpty else { return }
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.resetUnread(id); await ChatService.markRead(id) } } } }
        exitSelect()
    }
    private func deleteSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.deleteForMe(id) } }
        exitSelect()
    }
}

// Grey press highlight while a chat row is held (before the context menu lifts it).
// Drives the stories-row overlay: the sentinel reports its top (scroll offset), the row reports its height.
private struct StoryHeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct StoryRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


// (`RowStoryAnchor` is gone with the zoom it fed. The ringed avatar registers itself with
// `MediaOpenRects` instead — see the ChatRow avatar — which is what the flight actually reads.)

// Adds a high-priority tap ONLY when the avatar has a story, so it opens the story instead of the
// chat; otherwise the row's normal open-chat tap is untouched.
private struct StoryAvatarTap: ViewModifier {
    let active: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        // ONE STRUCTURE, ALWAYS. This used to be `if active { content.gesture } else { content }`,
        // which gives an avatar WITH a story a different view tree from one without. Structure is
        // identity to SwiftUI, so when Select mode slid the checkbox in and indented every row, a
        // ringed avatar was rebuilt rather than moved — it snapped to its new place while the plain
        // ones slid, which is exactly the row that stood out of line in his screenshot.
        //
        // `including:` carries the same meaning without the branch: `.subviews` leaves the
        // recogniser present but unreachable, so a story-less avatar still passes its taps through
        // to the row. Same fix, and same reason, as the view-once bubble's double tap.
        content.highPriorityGesture(TapGesture().onEnded(action),
                                    including: active ? .all : .subviews)
    }
}

struct ChatRow: View, Equatable {
    let conv: Conversation
    let me: String
    let dark: Bool
    var onCall: Bool = false        // a call with this chat is running right now → green "Active call" line
    var storySeen: [Bool] = []      // per-segment seen flags for this person's stories ([] = no active story)
    var onStoryTap: (() -> Void)? = nil   // tap the ringed avatar → open their story (not the chat)
    var draft: String = ""          // unsent composer text (local-only) → "Draft:" preview
    var voiceDraftSecs: Double = 0  // parked voice recording (local-only) → "Draft: 🎤 0:05" preview
    var voiceUnplayed: Bool = false // newest incoming voice note not played yet → accent mic

    // The 15s self-clear the THREAD's typing already had, applied to the row (audit HIGH: a sender
    // whose app died mid-typing/recording labeled this row "typing…"/"recording…" FOREVER, across
    // restarts, hiding the real preview). task(id: typingRawKey) restarts the window whenever the
    // raw map changes — recording's 10s refresh changes its value string, so a live recording
    // stays labeled; a stuck flag ages out like it does inside the chat.
    @State private var activityExpired = false

    // Time-driven repaint (audit): `muted` and `timeStr` read the clock at render, and this row is
    // Equatable on conv alone — so a lapsed 1-hour mute kept its bell-slash indefinitely and a row
    // from yesterday kept showing "14:03" instead of "Yesterday". The tick task below sleeps to the
    // nearest deadline (mute expiry or just past midnight), flips this, and re-arms.
    @State private var clockTick = false

    // Skip re-rendering a row whose conversation is unchanged, even when the parent body re-runs on
    // every snapshot (typing/unread/presence on OTHER chats). Conversation is Equatable → covers
    // lastMessage/unread/updatedAt/pinned/muted/etc.; decryption/avatars/time only recompute on change.
    static func == (l: ChatRow, r: ChatRow) -> Bool {
        l.conv == r.conv && l.me == r.me && l.dark == r.dark
            && l.onCall == r.onCall   // ⚠️ without this the row keeps its old preview for the whole call
            && l.storySeen == r.storySeen
            && l.draft == r.draft && l.voiceDraftSecs == r.voiceDraftSecs
            && l.voiceUnplayed == r.voiceUnplayed
    }

    private var voiceDraftLabel: String {
        let s = Int(voiceDraftSecs)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var decodedLast: String {
        // Demo previews are stored plaintext, so they must skip the decryptor or the row comes back
        // blank. THE TEST IS THIS CONVERSATION, not a global flag: demo chats now sit in the real
        // list beside real ones, and a global test would send every real preview down this branch
        // and render the whole list as ciphertext.
        if DemoMode.isDemoConversation(conv.id) { return conv.lastMessageCipher }
        // The official channel is a public broadcast, so its preview is already plaintext — there is
        // no key and nothing to decrypt. Running it through the decryptor would return an empty
        // string and the row would show a blank line.
        if OfficialChannel.isOfficial(conv.id) { return conv.lastMessageCipher }
        if conv.leaksBlocked(me) { return "" }   // don't leak a blocked person's message into the list
        // Group last-message is sealed by its sender → decrypt with the sender's key, not the cid pair.
        if conv.isGroup {
            return Crypto.shared.decryptGroupCached(conv.lastMessageCipher, cid: conv.id, authorId: conv.lastSender)   // memoized
        }
        return Crypto.shared.decryptCached(conv.lastMessageCipher, cid: conv.id)   // memoized: no re-decrypt per render
    }
    // Stored plaintext markers → an SF Symbol + clean label (native look, no emoji).
    /// `mine` = I placed the call this marker describes (`lastSender` is the caller's uid on a call
    /// record). It only ever changes the UNANSWERED cases: a call I placed that nobody picked up is
    /// an outgoing call, not a missed one, and the red belongs to the person who tried to reach me.
    private func previewBadge(_ s: String, mine: Bool = false) -> (String, String)? {
        // Newer voice markers carry the length ("🎤 Voice message · 0:53") — prefix match
        // keeps old plain markers working and surfaces the duration when present.
        if s.hasPrefix("🎤 Voice message") {
            return ("mic.fill", "Voice message" + String(s.dropFirst("🎤 Voice message".count)))
        }
        // ⛔ THE TWO ONE-TIME MARKERS, AND BOTH WERE FALLING THROUGH THIS WHOLE FUNCTION.
        //
        // "🎤 One-time voice message" does NOT start with "🎤 Voice message", and unlike 🎥/📷/🎬
        // there was no generic 🎤 catch below it. "View-once photo" carries no emoji at all, so
        // nothing here could recognise it either. Both then reached the plain-text branch — and
        // decryption returns a non-cipher string UNCHANGED — so the row printed the marker verbatim:
        // the voice one with its raw 🎤 showing, which is the exact thing every other case in here
        // exists to prevent, and the photo one as bare grey words with no icon while every other
        // photo preview had one.
        //
        // `1.circle` is the app's own one-time mark, the same glyph the composer and the story tray
        // wear, so the list agrees with the place the thing was sent from.
        if s == "🎤 One-time voice message" { return ("1.circle.fill", "One-time voice message") }
        if s == "View-once photo"          { return ("1.circle.fill", "View-once photo") }
        // A deleted newest message writes plain words too, for the same reason and with the same
        // result: no icon, while everything around it had one.
        if s == "This message was deleted" { return ("slash.circle", "This message was deleted") }
        if s.hasPrefix("🎥 Video") {   // video MESSAGE (🎥) — distinct from 📹 call markers
            return ("video.fill", "Video" + String(s.dropFirst("🎥 Video".count)))
        }
        // Generic media markers ("🎥 2 Videos", "📷 Photos", "📷 3 Photos"…): same native icon+label
        // treatment as single photos/videos — never raw emoji text in the preview.
        if s.hasPrefix("🎥 ") { return ("video.fill", String(s.dropFirst("🎥 ".count))) }
        if s.hasPrefix("📷 ") { return ("photo.fill", String(s.dropFirst("📷 ".count))) }
        // Mixed photo+video albums ("🎬 3 Media") — same icon+label treatment, never raw emoji.
        if s.hasPrefix("🎬 ") { return ("photo.on.rectangle.angled", String(s.dropFirst("🎬 ".count))) }
        // The 🎤 catch that was never here. Every other media emoji has one, and its absence is what
        // let the one-time voice marker reach the screen with its emoji intact. Anything new starting
        // 🎤 now lands as icon + words rather than leaking.
        if s.hasPrefix("🎤 ") { return ("mic.fill", String(s.dropFirst("🎤 ".count))) }
        switch s {
        case "📄 File":              return ("doc.fill", "File")
        // Our own GIF mark, the one the composer button wears. `sparkles` was standing in for a
        // symbol Apple does not ship, and it says "magic" rather than "GIF" (his 573 screenshot).
        case "GIF":                  return ("ic_gif", "GIF")
        // ⛔ AN UNANSWERED CALL IS "MISSED" ONLY FOR THE PERSON WHO WAS CALLED. The same marker
        // string reaches both phones — one conversation document, two readers — so the direction is
        // read from `lastSender` and applied here. The Calls tab has always drawn it this way; the
        // list is the surface that could not, and his own outgoing call sat in it in red.
        case "📞 Missed call":         return mine ? ("phone.arrow.up.right", "Outgoing call")
                                                  : ("phone.down.fill", "Missed call")
        case "📞 Call":                return ("phone.fill", "Call")
        // Legacy markers from before declines were removed from the log (2026-08-12): old
        // conversations may still hold the string, but it must not SAY declined to anyone.
        case "📞 Declined call":       return mine ? ("phone.arrow.up.right", "Outgoing call")
                                                  : ("phone.down.fill", "Missed call")
        case "📹 Missed video call":   return mine ? ("arrow.up.right.video.fill", "Outgoing video call")
                                                  : ("video.slash.fill", "Missed video call")
        case "📹 Video call":          return ("video.fill", "Video call")
        case "📹 Declined video call": return mine ? ("arrow.up.right.video.fill", "Outgoing video call")
                                                  : ("video.slash.fill", "Missed video call")
        default: return nil
        }
    }
    /// "ic_" names one of OUR drawings; anything else is an SF Symbol — the same convention the
    /// composer's attachment tiles use. It exists here because of the GIF row: SF Symbols has no GIF
    /// glyph at all, which is why that preview wore `sparkles` and read as anything but a GIF.
    private func previewRow(_ icon: String, _ text: String, iconTint: Color? = nil,
                            textTint: Color? = nil, weight: Font.Weight = .regular) -> some View {
        HStack(spacing: 5) {
            Group {
                if icon.hasPrefix("ic_") {
                    Image(icon).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: weight))
                }
            }
            .foregroundStyle(iconTint ?? Color.secondary)
            Text(text).font(.subheadline.weight(weight))
                .foregroundStyle(textTint ?? .secondary).lineLimit(1)
        }
    }
    /// The emoji shown as the row's trailing badge — the same fresh-reaction test the preview text
    /// uses, so the badge and the words always agree. Only when it was aimed at ME in a 1:1 (a badge
    /// for my own reaction, or for two other people's in a group, is noise).
    private var freshReactionEmoji: String? {
        // Aimed at ME everywhere, groups included — the old `isGroup ||` escape badged Alice
        // reacting to Bob on MY row, exactly the noise this comment forbids (audit).
        guard conv.freshReaction(me), conv.lastReactionBy != me,
              conv.lastReactionToAuthor == me,
              let enc = conv.lastReactionEnc else { return nil }
        let emoji = conv.isGroup
            ? Crypto.shared.decryptGroupCached(enc, cid: conv.id, authorId: conv.lastReactionBy)
            : Crypto.shared.decryptCached(enc, cid: conv.id)
        return emoji.isEmpty ? nil : emoji
    }

    // "Reacted 🙏" preview when the newest event in the chat is a reaction.
    private var reactionPreview: String? {
        guard conv.freshReaction(me), let enc = conv.lastReactionEnc else { return nil }
        let emoji = conv.isGroup
            ? Crypto.shared.decryptGroupCached(enc, cid: conv.id, authorId: conv.lastReactionBy)   // sealed by the reactor
            : Crypto.shared.decryptCached(enc, cid: conv.id)
        guard !emoji.isEmpty else { return nil }
        if conv.lastReactionBy == me { return "You reacted \(emoji)" }
        if conv.isGroup {
            let n = conv.names[conv.lastReactionBy] ?? "Someone"
            let first = n.split(separator: " ").first.map(String.init) ?? n
            return "\(first) reacted \(emoji)"
        }
        return conv.lastReactionToAuthor == me ? "Reacted \(emoji) to your message" : "Reacted \(emoji)"
    }
    // Live "recording…" for the list — the voice-note flavour of typingLabel, same synced field.
    private var recordingLabel: String? {
        guard !conv.isBlockedByMe(me) else { return nil }
        let recs = conv.others(me).filter { conv.recording[$0] == true }
        guard !recs.isEmpty else { return nil }
        if !conv.isGroup { return "recording…" }
        let n = conv.names[recs[0]] ?? "Someone"
        let first = n.split(separator: " ").first.map(String.init) ?? n
        return "\(first) is recording…"
    }
    // Live "typing…" for the list — the conv doc already syncs the typing map, so this is free.
    private var typingLabel: String? {
        guard !conv.isBlockedByMe(me) else { return nil }
        let typers = conv.others(me).filter { conv.typing[$0] == true }
        guard !typers.isEmpty else { return nil }
        if !conv.isGroup { return "typing…" }
        let names = typers.map { u in
            let n = conv.names[u] ?? "Someone"
            return n.split(separator: " ").first.map(String.init) ?? n
        }
        return names.count == 1 ? "\(names[0]) is typing…" : "\(names.joined(separator: ", ")) are typing…"
    }
    // "Alice: " prefix for group previews so you can tell who sent the last message.
    // Only for real messages (ciphertext or media markers) — NOT system events like "X added Y".
    /// Is the newest event in this chat a CALL RECORD? Two places need the answer and they need the
    /// same one: the preview, which reads `lastSender` as the caller, and the tick, which must not
    /// draw for a call at all.
    ///
    /// The two call emoji are the whole test. 📹 is a call marker and 🎥 is a video MESSAGE — a
    /// distinction the badge function above already turns on, and the reason this is not a
    /// `hasPrefix("🎥")` away from marking every sent video as a call.
    private var lastIsCall: Bool {
        let c = conv.lastMessageCipher
        return c.hasPrefix("📞 ") || c.hasPrefix("📹 ")
    }

    private var lastSenderPrefix: String {
        guard conv.isGroup, !conv.lastSender.isEmpty, conv.lastSender != me else { return "" }
        let c = conv.lastMessageCipher
        // ⚠️ THE TEST IS "DOES THE ROW RECOGNISE THIS", not a second hand-kept list of prefixes.
        //
        // It used to be its own literal list — enc / 📷 / 🎤 Voice message / 🎥 / 🎬 — which meant a
        // group whose newest message was a FILE, a GIF, a one-time note or a deleted message showed
        // the preview with nobody's name on it, while a photo one line above said "Ayaan: Photo".
        // Every marker the badge knows is a real message from a real person, so asking the badge is
        // both shorter and impossible to fall behind: add a marker there and the name follows.
        //
        // System events ("X added Y") stay bare, which is the whole point of the guard: they are
        // plain words nobody "sent", the badge does not recognise them, and a name in front of one
        // would read as somebody saying it. Call rows are already out — they write an empty
        // lastSender on purpose.
        guard c.hasPrefix("enc") || previewBadge(c) != nil else { return "" }
        let n = conv.names[conv.lastSender] ?? "Someone"
        return "\(n.split(separator: " ").first.map(String.init) ?? n): "
    }
    private var unread: Int { conv.isBlockedByMe(me) ? 0 : conv.unread(me) }   // silent block: no badge
    private var muted: Bool { conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) }

    // The last message is media we can thumbnail (ANY 📷/🎥 marker — single, album, or multi-video —
    // and not a frozen blocked-chat row). 📹 call markers are unaffected.
    private var isPhotoPreview: Bool {
        !conv.leaksBlocked(me)
            && (conv.lastMessageCipher.hasPrefix("📷") || conv.lastMessageCipher.hasPrefix("🎥") || conv.lastMessageCipher.hasPrefix("🎬"))
            && (conv.lastImageUrl?.isEmpty == false)
    }
    // "Photo" / "Photos" / "Video · 0:12" / "2 Videos" next to the little thumbnail (emoji stripped).
    private var photoPreviewLabel: String {
        let c = conv.lastMessageCipher
        if c.hasPrefix("🎥 ") { return String(c.dropFirst("🎥 ".count)) }
        if c.hasPrefix("📷 ") { return String(c.dropFirst("📷 ".count)) }
        if c.hasPrefix("🎬 ") { return String(c.dropFirst("🎬 ".count)) }   // mixed album → "3 Media"
        return "Photo"
    }
    // Preview area, in priority order: live call → blocked freeze → live typing → 2+ unread count →
    // unsent draft → photo thumbnail → media/call badge → say-hello → decrypted text.
    /// ⛔ THE "N NEW MESSAGES" BRANCH IS DELETED, AND IT WAS HIS OWN ORDER BOTH TIMES. He asked for
    /// it on 2026-08-23 ("when user send one message its shows what is saying, but when its one and
    /// more must count") and asked for it out on 2026-08-29, having put our list beside the
    /// reference: every large messenger shows the newest message whatever the unread count is, and
    /// lets the badge do the counting. A row that hides the words tells you less than the row above
    /// it that shows them.
    ///
    /// Do not restore it from the older instruction. The badge beside the preview is the count.
    @ViewBuilder private var previewContent: some View {
        if onCall {
            // FIRST, above everything — a call in progress outranks typing, a draft, the last
            // message, all of it. Green because that is what "live" reads as everywhere else in
            // the app (the minimized call bar, the answer button), not a colour picked here.
            previewRow("phone.fill", "Active call", iconTint: .green, textTint: .green)
        } else if conv.leaksBlocked(me) {
            previewRow("hand.raised.fill", "Blocked")
        } else if let r = recordingLabel, !activityExpired {
            (Text(Image(systemName: "mic.fill")).font(.system(size: 12)) + Text(" \(r)"))
                .font(.subheadline).foregroundStyle(Theme.accent(dark)).lineLimit(1)
        } else if let t = typingLabel, !activityExpired {
            Text(t).font(.subheadline).foregroundStyle(Theme.accent(dark)).lineLimit(1)
        } else if voiceDraftSecs > 0 {
            // A parked voice recording (his reference screenshots): the same red "Draft:" the text
            // draft below wears, then the mic and the note's length. Wins over a text draft — the
            // recording is the thing most in danger of being forgotten.
            (Text("Draft: ").foregroundStyle(.red)
             + Text(Image(systemName: "mic.fill")).font(.system(size: 12))
             + Text(" " + voiceDraftLabel).foregroundStyle(.secondary))
                .font(.subheadline).lineLimit(1)
        } else if !draft.isEmpty {
            (Text("Draft: ").foregroundStyle(.red) + Text(draft).foregroundStyle(.secondary))
                // 2 lines is the design, but the first layout pass can offer almost no width, and
                // without a cap the text stacks one letter per line. See the note on timeStr.
                .font(.subheadline).lineLimit(2).truncationMode(.tail)
        } else if let r = reactionPreview {
            Text(r).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        } else if isPhotoPreview {
            HStack(spacing: 5) {
                SecureImageView(imageUrl: conv.lastImageUrl ?? "", enc: conv.lastImageEnc, cid: conv.id)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(lastSenderPrefix + photoPreviewLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let badge = previewBadge(conv.lastMessageCipher, mine: lastIsCall && conv.lastIsMine(me)) {
            // A MISSED CALL IS THE ONE PREVIEW THAT IS BAD NEWS, and it was the same grey as
            // "Photo" (owner, 2026-08-23). Red now, icon and words together — the Calls tab has
            // always drawn its missed rows red and the list disagreed with it.
            //
            // ⚠️ RED FOR THE CALLS THAT CAME IN, exactly as the Calls tab does. This used to redden
            // BOTH directions, and the reasoning written here was that a call record wrote an empty
            // `lastSender` so the list had no direction to read. It carries the caller's uid now
            // (see `recordCall`), so the excuse is gone and so is the bug behind it: he placed a
            // call nobody answered and his own list called it missed.
            let missed = badge.1.hasPrefix("Missed")
            // Unheard voice note = accent mic (like an unread badge, but for your ears).
            previewRow(badge.0, lastSenderPrefix + badge.1,
                       iconTint: missed ? .red : (voiceUnplayed ? Theme.accent(dark) : nil),
                       textTint: missed ? .red : nil,
                       // Semibold on a missed call, regular on everything else. Two weights in the
                       // preview line is the convention every big messenger follows: the states you
                       // have to act on carry weight, the rest stay quiet. One weight for all of them
                       // is what made this line read thin under a 16pt bold name.
                       weight: missed ? .semibold : .regular)
        } else if decodedLast.isEmpty {
            previewRow("hand.wave.fill", "Say hello")
        } else if decodedLast.hasPrefix(Message.contactMarker) {
            // Shared-contact card → native icon + "Contact", never the raw marker text.
            previewRow("person.crop.circle.fill", lastSenderPrefix + "Contact")
        } else if decodedLast.hasPrefix(Message.locationMarker) {
            previewRow("mappin.circle.fill", lastSenderPrefix + "Location")
        } else if decodedLast.hasPrefix(Message.pinMarker) {
            // Pin notice — a marker THIS build fully supports. It must render as a friendly preview, NOT
            // the "newer version" fallback below (user report: both users on the latest build saw
            // "Message from a newer version" for a pin because pin had no case here and fell through to
            // the generic feature-marker catch-all). Every KNOWN marker (contact/location/pin) is handled
            // explicitly above; only genuinely-unknown markers reach the fallback.
            previewRow("pin.fill", lastSenderPrefix + "Pinned a message")
        } else if decodedLast.hasPrefix(Message.pollMarker) {
            previewRow("chart.bar.fill", lastSenderPrefix + "Poll")
        } else if decodedLast.range(of: Message.featureMarkerPattern, options: .regularExpression) != nil {
            // A newer-version feature this build doesn't recognize → never show the raw marker.
            previewRow("arrow.up.circle.fill", "Message from a newer version")
        } else {
            Text(lastSenderPrefix + decodedLast)
                // ⛔ `.subheadline`, like every other preview branch and like the hidden two-line
                // label that reserves this row's height. A fixed 15 and a semantic 15 are the same
                // size at the default text setting and diverge at every other one — which would
                // have left the reserve measuring one thing and the words another.
                .font(.subheadline.weight(unread > 0 ? .semibold : .regular))
                .foregroundStyle(unread > 0 ? Color.primary : .secondary).lineLimit(2)   // darker when unread
        }
    }

    // Delivery ticks for MY last message: single grey = sent, double accent = read.
    @ViewBuilder private var ticksView: some View {
        let read = conv.lastReadByOther(me)
        HStack(spacing: -3) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark") }
        }
        // ⛔ `.caption` (12pt), UP FROM A FIXED 10 — owner, 2026-09-02, off build 725: "the one
        // tick or 2 tick now looks small". The 10 was tuned against a 12pt timestamp; the match
        // pass took the row's text to 15 and left the ticks behind, so they shrank by comparison
        // without changing at all. 12 is the old proportion against the new text (10 × 15⁄12), and
        // a semantic style so the ticks now scale with the phone's text size like the rest of the
        // row does.
        .font(.caption.weight(.bold))
        .foregroundStyle(read ? Theme.accent(dark) : Color.secondary)
    }

    private var timeStr: String {
        let ms = conv.displayUpdatedAt(me)   // frozen at block time for blocked chats
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        // 56pt avatar; up to 2 preview lines; mute/pin/tick indicators inline.
        HStack(spacing: 12) {
            let _ = clockTick   // dependency: the tick task's flip must re-evaluate muted/timeStr
            // ⛔ ONE OUTER CIRCLE FOR EVERY ROW, AND THE PHOTO SHRINKS TO PAY FOR THE RING — owner,
            // 2026-09-02, with the ringed run of rows circled: "story users and non-story users look
            // different sizes; when a user uploads a story make the avatar small, the same as
            // non-story users; now story users are bigger".
            //
            // ⚠️ THIS IS THE THIRD SETTING AND IT REVERSES HIS OWN 2026-08-29 RULE, deliberately and
            // on his newer word. There are only two ways to draw a ring and they cannot both be had:
            //
            //   equal FACES  → the ring must live outside 56, so a ringed row's outer circle is 66
            //                  and reads as a bigger avatar. That was here, and it is what he just
            //                  circled.
            //   equal CIRCLES → the ring is the 56, so the photo inside it is 46 and ringed faces
            //                  are smaller. That is this, and it is what he asked for.
            //
            // The arithmetic: the arc is drawn inset by its own stroke, so a 56pt ring's inner edge
            // sits at 28 − 2 = 26, and a 46pt photo leaves the same 3pt of breathing room all round
            // that the 66/56 pair had. Nothing else about the row moves — the slot below is still a
            // flat 56, so the text column, the row height and the 16pt margin are untouched.
            // ⛔ 48, NOT 46 — owner, 2026-09-02: "the story circle and the avatar have more space,
            // fix". He has now bracketed this from both sides, which is what makes the number
            // findable rather than a guess: at a 0pt gap (ring 60 over a 56pt photo) he asked for
            // space; at 3 (ring 56 over 46) he says it is too much. 48 puts the photo's edge at 24
            // against the arc's inner edge at 26 — a 2pt gap, the midpoint of his own two reports.
            let photoSize: CGFloat = storySeen.isEmpty ? 56 : 48
            Group {
                // The official channel has no account and therefore no profile photo to fetch: its
                // face is the app's own mark, drawn from the bundle. Same 56pt footprint as every
                // other row, so nothing about the list's rhythm changes.
                if OfficialChannel.isOfficial(conv.id) {
                    OfficialAvatar(size: 56)
                } else {
                    AvatarView(name: conv.displayName(me), photoUrl: conv.displayPhoto(me),
                               size: photoSize)
                }
            }
                // THIS CIRCLE IS THE STORY'S DOOR: opening from here grows the viewer out of it, and
                // the drag-down flies home into it. (Apple's `matchedTransitionSource` that used to
                // sit beside this is gone with the zoom it belonged to.)
                //
                // The radius is HALF THE SIDE, which is the whole trick: `StoryCardMorph` reads what
                // its source reports, and a source reporting half its short side gets a CIRCULAR
                // flight — square crop, round mask, all the way rather than only at the landing.
                // The reference app's shape, no per-site branch.
                //
                // Reported on the PHOTO, not the ring: with the ring inside the anchor the transition
                // stretched the grey ring segments, which the owner screenshotted.
                // ⚠️ HALF THE PHOTO, WHICH IS NOW A VARIABLE. A source reporting half its short side
                // gets a CIRCULAR flight, so a hardcoded 28 against a 46pt photo would hand the
                // morph a rounded square and the story would fly out of the wrong shape.
                .modifier(MediaRectReporter(id: "row-\(conv.id)", scope: .storyRow,
                                            cornerRadius: photoSize / 2))
                .frame(width: 56, height: 56)
                .overlay {   // story ring around the avatar when this person has an active story
                    if !storySeen.isEmpty {
                        // 56, THE SAME OUTER CIRCLE A PLAIN AVATAR HAS — see the note above. It was
                        // 66 while the photo stayed 56; both numbers moved together because they are
                        // one measurement, and the 3pt gap between arc and face is unchanged.
                        StoryRingView(seen: storySeen, lineWidth: 2)
                            .frame(width: 56, height: 56)
                    }
                }
                // Tap the ringed avatar → open their story (high-priority so it beats the row's open-chat tap).
                .modifier(StoryAvatarTap(active: !storySeen.isEmpty && onStoryTap != nil) { onStoryTap?() })
                // Their `avatarStackConfig`, vMargin 12. With a 56pt avatar that is an 80pt floor —
                // the same number the row used to get from a hardcoded `minHeight: 76`, except it is
                // derived from the picture now, the way theirs is.
                .padding(.vertical, 12)
            // ⛔ 1, NOT 3 — their `vStackConfig` spacing. It reads impossibly tight as a number and
            // is right on screen: both rows are label boxes carrying their own font leading, so the
            // visible gap is that leading plus this, not this alone.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(conv.displayName(me))
                        // ⛔ `.headline`, WHICH IS 17pt SEMIBOLD — theirs, read from source
                        // 2026-09-02: `nameLabelConfig` uses `dynamicTypeHeadlineClamped`. Ours was
                        // a hardcoded 16.
                        //
                        // ⚠️ THE POINT SIZE IS THE SMALLER HALF OF THIS CHANGE. A semantic style
                        // GROWS with the phone's text size and a `.system(size:)` never does, so on
                        // a phone set larger than default their list re-flowed and ours stayed put.
                        // That is the ninth difference in the comparison and it is invisible until
                        // somebody changes their text size, which is why it survived this long.
                        .font(.headline.weight(unread > 0 ? .bold : .semibold))   // heavier when unread
                        .lineLimit(1)
                    // TWO TICKS, from two different authorities, and they are not interchangeable.
                    //
                    // The official channel's is drawn from a HARDCODED id rather than any field on
                    // any document, so there is nothing a copycat account could write to earn one.
                    // That is the right rule for the one channel that must never be impersonable.
                    //
                    // Everybody else's comes from the verification record on their own document,
                    // which only an admin holding `verify` can write. `VerifiedMark` draws nothing
                    // when there is no record, so it needs no `if` around it — and no `if` around it
                    // is the point, because an `if` here is a place for the rule to be restated
                    // slightly differently.
                    if OfficialChannel.isOfficial(conv.id) {
                        VerifiedTick(size: 15)
                    } else if !conv.isGroup {
                        VerifiedMark(uid: conv.otherUid(me), size: 15)
                    }
                    if muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(timeStr)
                        // ⛔ `.subheadline` — 15pt, the SAME style as the preview line beneath it,
                        // which is theirs (`dateTimeLabelConfig` and `snippetLabelConfig` both take
                        // `dynamicTypeSubheadlineClamped`). Ours was 12, the single biggest number
                        // in the whole comparison: a quarter smaller than theirs.
                        .font(.subheadline)
                        .foregroundStyle(unread > 0 ? Theme.accent(dark) : .secondary)
                        // NEVER WRAP. The list's first layout pass can offer a row almost no width,
                        // and an unconstrained Text answers that by stacking one letter per line —
                        // "Yesterday" became a vertical column of e/s/t/e/r/d/a/y (owner caught it
                        // frame by frame on a cold launch). It was invisible before only because
                        // there were no rows on screen that early to lay out badly.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .top, spacing: 4) {
                    // ⛔ TWO LINES OF PREVIEW ARE ALWAYS RESERVED, whatever this row's preview
                    // actually is — theirs, and the difference he can see most.
                    //
                    // `ChatListCell` reserves `snippetLineHeight * 2` as a fixed measurement rather
                    // than letting the label decide, so every row in their list is exactly the same
                    // height. Ours gave two lines to a text message and one to a voice note, a photo
                    // or a file, so the rows were ragged — that raggedness is why his list did not
                    // read as evenly spaced as theirs beside it.
                    //
                    // ⚠️ A HIDDEN TWO-LINE `Text`, NOT A HARDCODED HEIGHT. 44pt would be right today
                    // and wrong the moment the phone's text size moves, which is the ninth
                    // difference this same pass is fixing. An empty two-line label in the same style
                    // is two line heights by construction, at every text size, for free.
                    //
                    // ⚠️ It must not be reachable by VoiceOver or the row would read a blank line.
                    ZStack(alignment: .topLeading) {
                        // ⚠️ " \n " AND NOT "\n". A trailing EMPTY line is not guaranteed to be laid
                        // out, so a bare newline can measure as one line and reserve half of what is
                        // wanted. A space on each side makes both lines real.
                        Text(" \n ").font(.subheadline).hidden().accessibilityHidden(true)
                        previewContent
                    }
                    Spacer(minLength: 8)
                    // Status tick now lives in the right column — under the timestamp, beside the pin.
                    // ⚠️ NEVER ON A CALL ROW. `lastSender` carries the CALLER on a call record, which
                    // is what lets the preview above say "Outgoing call" instead of red "Missed
                    // call" — but a call is not a message and has no sent/read state, so a tick
                    // beside one would be reporting delivery of something that was never sent. The
                    // field used to be cleared to prevent exactly this; the guard lives here now.
                    if conv.lastIsMine(me), !lastIsCall { ticksView.padding(.top, 1) }
                    // ⛔ NO PIN GLYPH — owner, 2026-09-02, off build 725: "remove pin icon, now
                    // already everyone can see pinned, no need". He is right about the mechanism:
                    // the icon existed because pinned chats were only SORTED to the top with
                    // nothing marking them, and the "Pinned" section header now does that job by
                    // name. Two marks for one fact is one too many.
                    // ONE badge for every reaction, never the emoji itself (user spec 2026-07-29, with
                    // the reference screenshot: "if react always use that badge"). The preview text
                    // beside it already spells out WHICH emoji — "Reacted 🐱 to your message" — so
                    // repeating it here just made the right edge of the row a second, competing emoji.
                    // A constant heart reads as "there is a reaction" at a glance, and keeps the row's
                    // trailing column visually stable whatever anyone reacts with. Same freshness rule
                    // as the text, so the two can never disagree.
                    if freshReactionEmoji != nil {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            // ⛔ `.footnote` — 13pt, theirs (`unreadCounterLabelConfig` takes
                            // `dynamicTypeFootnoteClamped`). Ours was `.caption2`, which is 11.
                            // Their pill's height is `ceil(footnote.lineHeight * 1.25)`, about 20 at
                            // the default text size, which is where the 20 below comes from — and
                            // both the font and the box grow together with Dynamic Type, so the
                            // number can never outgrow the circle it sits in.
                            .font(.footnote.bold()).foregroundColor(Theme.onAccent(dark))
                            .contentTransition(.numericText())   // count rolls instead of snapping
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Theme.accent(dark)).clipShape(Capsule())
                    } else if conv.manuallyUnread(me) {
                        // A PLAIN DOT, no number. You marking a chat unread is a note to yourself;
                        // writing "1" on it claims somebody sent you something, which is what the
                        // owner reported — he read the chat to the end and the list then told him it
                        // held one unread message. Same circle, same colour, nothing written in it.
                        Circle()
                            .fill(Theme.accent(dark))
                            .frame(width: 12, height: 12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            // Their `vStackConfig` margins, and they are NOT symmetrical: 7 above, 9 below. The two
            // point difference is what sits the text block optically level against a 56pt circle
            // rather than mathematically level, and it is theirs, not a rounding artefact.
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
        // ⛔ NO `minHeight` ANY MORE. Theirs has no fixed row height at all — the table is
        // `.automaticDimension` and the cell measures itself, so the height is whichever of its two
        // columns is taller: the avatar with 12 above and below (56 + 24 = 80), or the text with 7
        // above and 9 below. A 76pt floor was ours, and with the two columns padded the way theirs
        // are it can only fight them.
        .animation(.easeInOut(duration: 0.22), value: unread)   // smooth bold/color/badge changes
        .animation(.easeInOut(duration: 0.22), value: muted)
        .animation(.easeInOut(duration: 0.22), value: conv.isPinned(me))   // pin icon fade
        // Restarts on every raw typing-map change (see activityExpired above); no-op for quiet rows.
        .task(id: conv.typingRawKey) {
            activityExpired = false
            guard conv.typing.values.contains(true) || conv.recording.values.contains(true) else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { activityExpired = true }
        }
        // The clock tick (see clockTick above): wake at mute expiry / just past midnight, repaint.
        .task(id: conv.mutedBy[me] ?? 0) {
            while !Task.isCancelled {
                let nowMs = Date().timeIntervalSince1970 * 1000
                var deadlines: [Double] = []
                let mute = conv.mutedBy[me] ?? 0
                if mute > nowMs { deadlines.append(mute) }
                if let midnight = Calendar.current.nextDate(after: Date(),
                                                            matching: DateComponents(hour: 0, minute: 0, second: 5),
                                                            matchingPolicy: .nextTime) {
                    deadlines.append(midnight.timeIntervalSince1970 * 1000)
                }
                guard let next = deadlines.min() else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(1, (next - nowMs) / 1000) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                clockTick.toggle()
            }
        }
        // ⛔ NO ROW-LEVEL VERTICAL PADDING — the two columns carry their own now, theirs do, and a
        // shared 2 on top of both would be 2 the reference does not have. See the two `padding`
        // calls inside: 12/12 on the avatar (`avatarStackConfig`, vMargin 12) and 7/9 on the text
        // (`vStackConfig`). Those two numbers ARE their row height.
        .padding(.horizontal, 16)   // 16pt gutter moved inside the cell (row insets are now
                                    // zero) so the reorder drag preview matches the cell width
                                    // and stays locked to the vertical axis (no horizontal drift)
    }
}

// Long-press PEEK of a conversation (reference behavior): the chat's real last messages as
// simple read-only bubbles. Cache-first — a chat opened this session renders instantly from
// ThreadMessageCache; otherwise one light fetch. Deliberately NOT ThreadView (a peek must stay
// cheap and side-effect free: no listeners, no read receipts, no keyboard).
// The long-press platter for a chat row.
//
// This used to be a hand-rolled fake: emoji text pills ("📷 Photo", "🎥 Video call") in a fixed 330pt
// box on a plain background, which read as a mock-up rather than the chat.
//
// the reference app's model (verified in their source: `CLVTableDataSource.tableView(_:contextMenuConfigurationForRowAt:point:)`
// → `ChatListViewController.createPreviewController` → a real `ConversationViewController` with
// `previewSetup()`) is to show the ACTUAL conversation view with only its chrome suppressed — real
// image thumbnails, real voice notes, real call cells — and to set NO explicit size, letting UIKit size
// the platter from the view controller (so it lands at the screen's own proportions).
//
// So: real `MessageBubble`s (the same view the chat renders), the chat's real wallpaper behind them,
// bottom-aligned like a real conversation, at the screen's aspect. The one place we must diverge from
// the reference app is the frame: a SwiftUI preview auto-sizes to intrinsic content and would collapse, so the
// size is stated explicitly and derived from the screen rather than being a magic number.
private struct ChatPeekPreview: View {
    let cid: String
    let me: String
    @State private var msgs: [Message]
    @State private var loaded: Bool
    @Environment(\.colorScheme) private var scheme

    init(cid: String, me: String) {
        self.cid = cid
        self.me = me
        let cached = (ThreadMessageCache.shared.messages(for: cid) ?? []).filter { !$0.isSystem }
        _msgs = State(initialValue: Array(cached.suffix(14)))
        _loaded = State(initialValue: !cached.isEmpty)
    }

    // Screen-proportional, like the platter the reference app gets for free from a full view controller.
    private var size: CGSize {
        let screen = UIScreen.main.bounds.size
        return CGSize(width: screen.width, height: screen.height * 0.62)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ChatWallpaperBackground(cid: cid)
            if OfficialChannel.isOfficial(cid) {
                // The channel's messages are announcements, not documents under this cid, so the
                // generic fetch below would find nothing and claim the chat was empty.
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(OfficialChannelStore.shared.visible.suffix(8)) { a in
                            AnnouncementRow(announcement: a, dark: scheme == .dark,
                                            onImageTap: { _ in }, onButtonTap: { _ in })
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDisabled(true)
            } else if !loaded {
                ProgressView()
            } else if msgs.isEmpty {
                Text("No messages yet").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Bottom-aligned and clipped at the top: a conversation reads from the bottom up, and
                // the newest messages are the ones worth previewing.
                // ANCHORED TO THE BOTTOM, so the NEWEST message is always fully visible and it is the
                // oldest that gets cut off at the top. The previous version was a plain VStack inside a
                // fixed frame: 14 bubbles are routinely taller than the platter, and SwiftUI centres an
                // oversized child, so it clipped BOTH ends - the last message was sliced in half at the
                // bottom, which is the opposite of what a conversation preview is for. A Spacer cannot fix
                // that, because it only has room to push when the content is SHORTER than the frame.
                // Scrolling is off: the platter is a preview, not an interactive view.
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(msgs) { m in
                            // The platter draws the real wallpaper above, so its bubbles have to
                            // resolve their surface against it exactly as the chat does — otherwise
                            // the peek shows flat grey bubbles on a picture the chat itself blurs.
                            MessageBubble(message: m, isMe: m.authorId == me, dark: scheme == .dark, cid: cid,
                                          onWallpaper: WallpaperStore.shared.hasWallpaper(for: cid))
                                .allowsHitTesting(false)   // the platter is not interactive
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDisabled(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task {
            // ⚠️ ALWAYS REFRESH — `guard !loaded` used to sit here, so a chat with anything cached
            // never asked the server and the peek showed the conversation as it stood the last time
            // it was OPENED. Messages that arrived since were simply absent (owner 2026-08-16).
            //
            // The cache is still what draws first, instantly, and that is the point of it. It just
            // is not the answer any more. Same shape as the chat list: paint what we know, then
            // correct it.
            //
            // ⚠️ AND THIS GOT WORSE THE DAY THE CACHE MOVED TO DISK. While it lived in memory a cold
            // launch had nothing to serve, so the peek fetched; now it can answer with something days
            // old and the fetch never ran. A cache that gains reach needs its readers re-checked.
            //
            // Still no listener, deliberately: a peek must stay cheap and side-effect free — no read
            // receipts, nothing marked seen. One fetch is the whole cost.
            guard !OfficialChannel.isOfficial(cid) else { return }
            // Newest-first fetch → ascending for display.
            let fetched = await ChatService.galleryContent(cid, limit: 14)
            msgs = Array(fetched.reversed()).filter { !$0.isSystem }
            loaded = true
        }
    }
}
