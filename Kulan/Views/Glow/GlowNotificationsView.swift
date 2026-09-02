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
        .navigationTitle("Glow notifications")
        .navigationBarTitleDisplayMode(.inline)
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
                List {
                    ForEach(sections(rows), id: \.title) { section in
                        Section {
                            ForEach(section.rows) { e in
                                GlowEventRow(event: e, unread: e.at > glow.seenUpTo, dark: dark)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text(section.title).font(.headline)
                                .foregroundStyle(Color(.label)).textCase(nil)
                        }
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

    /// "This week" / "Last 30 days" / "Older" — his reference's own grouping.
    private func sections(_ rows: [GlowEvent]) -> [(title: String, rows: [GlowEvent])] {
        let now = Date()
        var week: [GlowEvent] = [], month: [GlowEvent] = [], older: [GlowEvent] = []
        for e in rows {
            let days = now.timeIntervalSince(e.at) / 86_400
            if days <= 7 { week.append(e) } else if days <= 30 { month.append(e) } else { older.append(e) }
        }
        return [("This week", week), ("Last 30 days", month), ("Older", older)]
            .filter { !$0.1.isEmpty }
    }
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

    init(event: GlowEvent, unread: Bool, dark: Bool) {
        self.event = event
        self.unread = unread
        self.dark = dark
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(unread ? GlowStyle.accent : .clear).frame(width: 6, height: 6)

            // THE PERSON — face and words together, because they name one thing.
            // The ORDINARY profile — see the note on the same route in `StoriesTabView`. The Glow
            // profile is my own page and nobody else's.
            NavigationLink {
                ContactInfoView(cid: [AuthService.shared.uid ?? "", event.person.id]
                                    .sorted().joined(separator: "_"),
                                name: event.person.name,
                                photoUrl: event.person.photoUrl, source: .story)
            } label: {
                HStack(spacing: 12) {
                    // 52, up from 44 — his "avatars look small".
                    AvatarView(name: event.person.name, photoUrl: event.person.photoUrl, size: 52)
                    sentence
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing
        }
    }

    private var sentence: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                switch event.kind {
                case .glowed:
                    Text(event.person.name).fontWeight(.semibold) + Text(" glowed at you.")
                case .loved(let emoji):
                    Text(event.person.name).fontWeight(.semibold)
                        + Text(" reacted \(emoji) to your story.")
                case .replied(let what):
                    Text(event.person.name).fontWeight(.semibold) + Text(" replied: \"\(what)\"")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(2)

            Text(event.at.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                Text("Glowing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
