import SwiftUI

/// GLOW NOTIFICATIONS — his reference, sent twice: a back chevron, the title, a row of filter
/// chips, and rows of face + sentence + time, with the story's own thumbnail on the right and a
/// pink Glow back on a glow row.
///
/// ⛔ THE LOVES ARE REAL — his second sending made that the point: "you can see who give you love
/// and Glow back or glow". My first pass showed an honest "not available yet" on the strength of
/// there being no reaction feed. There is one, and it was already in the app: a reaction is stored
/// ON the view receipt, which is what the Seen-by sheet has read all along. See `GlowEventsLoader`.
///
/// ⛔ THE ROWS ARE DERIVED, NOT A SECOND COLLECTION. A glow document carries who and when, which IS
/// the row; a love is a receipt carrying an emoji. So there is nothing to write, nothing to keep in
/// step with the truth, and nothing to clean up — un-glowing removes the edge and the row goes with
/// it, which is the correct behaviour for free.
struct GlowNotificationsView: View {
    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init() {}

    /// His chips, in his order and his words. "Comments" and "like" are what his reference says;
    /// Replies is the app's own word for a story reply and Loves matches the heart, so the two are
    /// named for what they are here rather than copied letter for letter.
    enum Chip: String, CaseIterable, Identifiable {
        case all, glowers, replies, loves
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .glowers: return "Glowers"
            case .replies: return "Replies"
            case .loves: return "Loves"
            }
        }
    }

    @State private var chip: Chip = .all
    @State private var events = GlowEventsLoader()
    private var glow = GlowService.shared

    var body: some View {
        VStack(spacing: 0) {
            chips
            Divider()
            content
        }
        .navigationTitle("Glow notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await events.load() }
        // Opening the page IS reading it — the badge on the Stories tab clears from here, which is
        // his "read/unread notification states" without a per-row flag to store or sync.
        .onDisappear { glow.markSeen() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Chip.allCases) { c in
                    Button { chip = c } label: {
                        Text(c.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(chip == c ? Color.white : Color.primary)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(chip == c ? GlowStyle.accent : Color.primary.opacity(0.08),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
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
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon,
                                       description: Text(emptyBody))
            } else {
                List {
                    ForEach(sections(rows), id: \.title) { section in
                        Section {
                            ForEach(section.rows) { e in
                                GlowEventRow(event: e, unread: e.at > glow.seenUpTo)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
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
        case .replies: return e.isReply
        case .loves: return e.isLove
        }
    }

    // Each empty state names the thing that is missing, rather than one sentence for four cases.
    private var emptyTitle: String {
        switch chip {
        case .all: return "Nothing yet"
        case .glowers: return "No Glows yet"
        case .replies: return "No replies yet"
        case .loves: return "No loves yet"
        }
    }
    private var emptyIcon: String {
        switch chip {
        case .loves: return "heart"
        case .replies: return "bubble.left"
        default: return GlowStyle.symbol
        }
    }
    private var emptyBody: String {
        switch chip {
        case .glowers: return "When somebody glows you, it appears here."
        case .loves: return "When somebody loves one of your stories, it appears here."
        case .replies: return "Replies to your stories appear here."
        case .all: return "Glows and reactions to your stories appear here."
        }
    }

    /// "This week" / "Last 30 days" / "Older" — his reference's own grouping, which is what makes a
    /// long list readable without a date on every row.
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

/// One row. His reference's shape: face, a sentence that names the person in bold, the date, then
/// either the story's thumbnail (a love or a reply, which are ABOUT a story) or a Glow back button
/// (a glow, which is about a person).
private struct GlowEventRow: View {
    let event: GlowEvent
    let unread: Bool
    private var glow = GlowService.shared

    init(event: GlowEvent, unread: Bool) {
        self.event = event
        self.unread = unread
    }

    var body: some View {
        HStack(spacing: 10) {
            // A dot, not a tinted row: a coloured row is hard to read and hard to clear.
            Circle().fill(unread ? GlowStyle.accent : .clear).frame(width: 6, height: 6)

            NavigationLink {
                GlowProfileView(uid: event.person.id, initialName: event.person.name,
                                initialPhoto: event.person.photoUrl)
            } label: {
                HStack(spacing: 10) {
                    AvatarView(name: event.person.name, photoUrl: event.person.photoUrl, size: 44)
                    sentence
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing
        }
    }

    /// The name in bold inside a running sentence, which is what makes his reference's rows read as
    /// language rather than as fields.
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
                    Text(event.person.name).fontWeight(.semibold)
                        + Text(" replied: \"\(what)\"")
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
            // The story it happened to — his reference puts it on the right of every story row.
            StoryImage(url: thumb)
                .frame(width: 38, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if event.isGlow {
            if glow.isGlowing(event.person.id) {
                Text("Glowing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Button { glow.give(to: event.person.id) } label: {
                    Text("Glow back").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(GlowStyle.accent)
                .controlSize(.small)
            }
        }
    }
}
