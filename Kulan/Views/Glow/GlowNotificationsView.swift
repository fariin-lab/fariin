import SwiftUI

/// GLOW NOTIFICATIONS — his reference, and then his corrections off the built screen (2026-09-02).
///
/// ⛔ THE CORRECTIONS, ALL SIX, BECAUSE THEY ARE THE FILE'S REAL SPEC NOW:
///   · **No Replies tab.** There is no reply feed to read, and a tab that only ever says "nothing
///     here" is a tab that teaches people the page is empty. Glows and Loves are what exist.
///   · **The tabs are glass** — the app's own `liquidGlass`, not flat capsules of my own making.
///   · **Bigger faces.** 44 read as small against the two-line sentence beside them; 52 is the size
///     the rest of this app gives a person in a list.
///   · **Two tap targets, not one.** The person opens the PERSON; the story preview opens the
///     STORY. One row that always went to the profile made the preview a decoration.
///   · **The app's colour, not mine.** See `GlowStyle.accent` — the pink was read off a screenshot
///     of another app and was never Fariin's.
///   · **No chevron.** With two real tap targets an arrow points at neither of them.
///
/// ⛔ THE ROWS ARE DERIVED, NOT A SECOND COLLECTION. A glow document carries who and when, which IS
/// the row; a love is a view receipt carrying an emoji. Nothing to write, nothing to keep in step,
/// and un-glowing removes the row for free.
struct GlowNotificationsView: View {
    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init() {}

    /// Three, not four. See the header: Replies has no source and an always-empty tab is worse
    /// than no tab.
    enum Chip: String, CaseIterable, Identifiable {
        case all, glowers, loves
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .glowers: return "Glowers"
            case .loves: return "Loves"
            }
        }
    }

    @State private var chip: Chip = .all
    @State private var events = GlowEventsLoader()
    @Environment(\.colorScheme) private var scheme
    private var glow = GlowService.shared
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            chips
            content
        }
        // ⛔ "Notifications", NOT "Glow notifications" — owner, 2026-09-02: "this page is not only
        // glow notifications, it's the person's notifications: when you upload a story and friends
        // react you see it here, when you get new glowers you see it here. Don't say glow
        // notifications, say only notifications."
        //
        // He is right about what it already holds. Loves come from reactions on MY stories by
        // anybody, friends included, and have nothing to do with Glow — naming the page after one
        // of its three chips told people the other two were something else.
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        // ⛔ NO TAB BAR ON A PUSHED PAGE — owner, 2026-09-02: "when I enter the notification page,
        // hide the bottom nav bar". Second time he has asked for this, after the profile: a page
        // you PUSHED is not a tab, and the floating bar sits over its last row. Applied to every
        // pushed Glow page rather than only this one, because the next one would be the same report.
        .toolbar(.hidden, for: .tabBar)
        .task { await events.load() }
        // Opening the page IS reading it — the badge on the Stories tab clears from here, which is
        // his "read/unread notification states" without a per-row flag to store or sync.
        .onDisappear { glow.markSeen() }
    }

    /// Glass, his word. The selected one is the app's accent filled, with its label taken from
    /// `onAccent` — never `.white`, which is invisible on a white accent at night.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Chip.allCases) { c in
                    let on = chip == c
                    Button { chip = c } label: {
                        Text(c.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? GlowStyle.onAccent(dark) : Color.primary)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background {
                                if on { Capsule().fill(GlowStyle.accent) }
                            }
                    }
                    .buttonStyle(.plain)
                    // The unselected chips are real glass; the selected one is a solid accent, so
                    // the glass goes UNDER both and the fill sits on top of it.
                    .liquidGlass(Capsule(), interactive: true, enabled: !on)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var content: some View {
        switch events.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not load", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await events.load() } }.buttonStyle(.borderedProminent)
            }
        case .loaded(let all):
            let rows = all.filter(matches)
            if rows.isEmpty {
                ContentUnavailableView {
                    Label { Text(emptyTitle) } icon: { emptyIcon }
                } description: {
                    Text(emptyBody)
                }
            } else {
                // ⛔ NO DATE HEADINGS — owner, 2026-09-02: "remove text cards like Last 30 days and
                // This week". The rows are already newest-first and each carries its own date, so
                // the headings restated the order they were already in and broke a short list into
                // three shorter ones.
                //
                // ⛔ 16, THE SAME MARGIN THE CHIPS USE — owner, 2026-09-02: "on the notification
                // page the left space, use the same one the All text chip uses". The chips are
                // `.padding(.horizontal, 16)` and the title bar's own margin is 16, so 16 is the
                // page's column and the faces are the only thing that was not on it.
                //
                // ⚠️ THE DOT IS OUT OF THE ROW'S FLOW NOW, which is what makes that possible. It sat
                // before the face with a gap, so any inset that put the DOT on 16 put the FACE at
                // 22 or 34. It hangs in the margin instead — see `GlowEventRow`.
                List {
                    ForEach(rows) { e in
                        GlowEventRow(event: e, unread: e.at > glow.seenUpTo, dark: dark)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .refreshable { await events.load() }
            }
        }
    }

    private func matches(_ e: GlowEvent) -> Bool {
        switch chip {
        case .all: return true
        case .glowers: return e.isGlow
        case .loves: return e.isLove
        }
    }

    private var emptyTitle: String {
        switch chip {
        case .all: return "Nothing yet"
        case .glowers: return "No Glows yet"
        case .loves: return "No loves yet"
        }
    }
    /// ⚠️ A VIEW, NOT A NAME. Loves is still an SF Symbol and Glow is now one of his own drawings,
    /// so the two cannot be a single `String` handed to `systemImage:` any more — one of them would
    /// have drawn nothing. They agree on SIZE instead, which is the only thing they had to share.
    @ViewBuilder private var emptyIcon: some View {
        if chip == .loves {
            Image(systemName: "heart").font(.system(size: 44))
        } else {
            GlowStyle.mark(48)
        }
    }
    private var emptyBody: String {
        switch chip {
        case .glowers: return "When somebody glows you, it appears here."
        case .loves: return "When somebody loves one of your stories, it appears here."
        case .all: return "Glows and reactions to your stories appear here."
        }
    }

    // ⛔ DELETED HERE: `sections`, which split the rows into This week / Last 30 days / Older.
    // Owner removed those headings by name, 2026-09-02 — see the note at the list. Recorded rather
    // than silently dropped so nobody restores it thinking it was an oversight.
}

/// One row: face, sentence, and then EITHER the story it happened to OR a Glow back.
///
/// ⚠️ TWO TAP TARGETS AND NO CHEVRON. His correction: the person opens the person, the preview
/// opens the story. A chevron would point at neither, which is why it is gone rather than moved.
private struct GlowEventRow: View {
    let event: GlowEvent
    let unread: Bool
    let dark: Bool
    private var glow = GlowService.shared
    @State private var showProfile = false

    init(event: GlowEvent, unread: Bool, dark: Bool) {
        self.event = event
        self.unread = unread
        self.dark = dark
    }

    var body: some View {
        HStack(spacing: 12) {

            // THE PERSON — face and words together, because they name one thing.
            //
            // ⛔ A BUTTON AND A SHEET, NOT A `NavigationLink` — owner, 2026-09-02: "remove the small
            // arrow". A link inside a `List` draws a disclosure chevron and nothing turns it off;
            // this row already ends in a story thumbnail or a button, so the arrow sat in the middle
            // pointing at neither.
            Button { showProfile = true } label: {
                HStack(spacing: 12) {
                    // 62, his number.
                    AvatarView(name: event.person.name, photoUrl: event.person.photoUrl, size: 62)
                    sentence
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing
        }
        // ⛔ THE UNREAD DOT HANGS IN THE MARGIN — owner, 2026-09-02: the faces must start on the
        // same 16 the chips do. It used to be the first thing in this row, so every inset that put
        // the DOT on the page's column pushed the FACE off it. As an overlay it takes no width at
        // all: the row lays out as face-then-words, and the dot sits in the gutter beside it the way
        // an unread mark is meant to.
        .overlay(alignment: .leading) {
            Circle().fill(unread ? GlowStyle.accent : .clear)
                .frame(width: 6, height: 6)
                .offset(x: -11)
        }
        // The ORDINARY profile — see the note on the same route in `StoriesTabView`. The Glow
        // profile is my own page and nobody else's.
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                ContactInfoView(cid: [AuthService.shared.uid ?? "", event.person.id]
                                    .sorted().joined(separator: "_"),
                                name: event.person.name,
                                photoUrl: event.person.photoUrl, source: .story)
            }
        }
    }

    /// ⛔ THE DATE RIDES THE SENTENCE — owner, 2026-09-02: "the time or date position is wrong, put
    /// it next to the text like 'reacted to your story • 1 Sep'". It was a second line under the
    /// words, which gave every row three lines and a date that read as a heading for the row below
    /// it. Inline, dimmed, after a middle dot: the same shape a chat row's timestamp has.
    private var sentence: some View {
        Group {
            switch event.kind {
            case .glowed:
                Text(event.person.name).fontWeight(.semibold) + Text(" glowed at you.") + stamp
            case .loved(let emoji):
                Text(event.person.name).fontWeight(.semibold)
                    + Text(" reacted \(emoji) to your story.") + stamp
            case .replied(let what):
                Text(event.person.name).fontWeight(.semibold) + Text(" replied: \"\(what)\"") + stamp
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(3)
    }

    private var stamp: Text {
        Text("  •  " + Self.stampText(event.at)).foregroundColor(.secondary)
    }

    /// ⛔ HIS RULES, IN ORDER — 2026-09-02: "if only days or weeks show like 10d or 1W; every time
    /// don't show the year when it's the year you're talking about; if it's another year tell me."
    ///
    ///   under 7 days   → "3d"      (today is "now")
    ///   under 5 weeks  → "2w"
    ///   this year      → "1 Sep"
    ///   another year   → "16 Jul 2025"
    ///
    /// ⚠️ THE YEAR IS DECIDED BY THE CALENDAR, NOT BY 365 DAYS. Two dates eleven months apart can
    /// sit in different years and two dates a week apart can straddle New Year, so "is it this year"
    /// is a question about the calendar and nothing else.
    static func stampText(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> String {
        let secs = now.timeIntervalSince(d)
        if secs < 60 { return "now" }
        let days = Int(secs / 86_400)
        if days < 7 { return days < 1 ? "today" : "\(days)d" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        return d.formatted(sameYear ? .dateTime.day().month(.abbreviated)
                                    : .dateTime.day().month(.abbreviated).year())
    }

    @ViewBuilder private var trailing: some View {
        if let thumb = event.storyThumb, !thumb.isEmpty {
            // THE STORY — its own tap target, opening the story this happened to. A love is on one
            // of MY stories, so the door is my own row in the viewer.
            Button { openMyStory() } label: {
                StoryImage(url: thumb)
                    .frame(width: 42, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        } else if event.isGlow {
            if glow.isGlowing(event.person.id) {
                // ⛔ A DRAWN BORDER — owner, 2026-09-02: "the Glowing button has no borders". It was
                // bare secondary text beside a filled capsule, so the mutual state read as a label
                // rather than as the same control in its other state. Same size and shape as
                // "Glow back" above, opposite emphasis — the pair the Glowers list now uses too.
                Button { glow.remove(to: event.person.id) } label: {
                    Text("Glowing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button { glow.give(to: event.person.id) } label: {
                    Text("Glow back")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlowStyle.onAccent(dark))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(GlowStyle.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Open my own story row at the story this reaction landed on.
    ///
    /// ⚠️ A DEMO ROW OPENS NOTHING. Its story id belongs to no document, so `StoryDoor` would be
    /// handed a group it cannot page — see `GlowDemo`.
    private func openMyStory() {
        guard !GlowDemo.isDemoPerson(event.person.id),
              let mine = StoriesRepository.shared.mine else { return }
        StoryDoor.open(mine, among: [mine], from: mine.id, pinned: true, deliveredToMe: false)
    }
}
