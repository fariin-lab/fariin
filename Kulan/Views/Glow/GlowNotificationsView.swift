import SwiftUI

/// GLOW NOTIFICATIONS — his first screenshot, 2026-09-02: a back chevron, the title, a row of
/// filter chips (All / Glowers / Comments / like), and rows of avatar + sentence + time, with a
/// pink "Glow back" on a glow row.
///
/// ⛔ THE ROWS ARE DERIVED, NOT A SECOND COLLECTION. A glow document already carries who and when,
/// which IS the row — so there is no `notifications` collection to write, to keep in step with the
/// truth, or to clean up when a glow is taken back. Un-glowing removes the edge and the row goes
/// with it, which is the correct behaviour and costs nothing to implement.
///
/// ⚠️ REACTIONS AND REPLIES ARE NOT WIRED YET, and the chips for them say so rather than showing an
/// empty list that looks like "nobody has ever reacted". His spec asks for "people who Loved your
/// Story" as well as glows; the story reaction path exists but does not yet write anything this page
/// can read, and inventing a fake feed for it would be worse than an honest empty state.
struct GlowNotificationsView: View {
    enum Chip: String, CaseIterable, Identifiable {
        case all, glowers, comments, likes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .glowers: return "Glowers"
            case .comments: return "Replies"
            case .likes: return "Loves"
            }
        }
    }

    @State private var chip: Chip = .all
    @State private var loader = GlowPeopleLoader()
    @State private var events: [(uid: String, at: Date)] = []
    @State private var loading = true
    private var glow = GlowService.shared

    var body: some View {
        VStack(spacing: 0) {
            chips
            Divider()
            content
        }
        .navigationTitle("Glow notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
        switch chip {
        case .comments, .likes:
            // Honest, not empty. See the note at the top: the reaction and reply feeds have no
            // source yet, and a blank list here would read as "this never happens to you".
            ContentUnavailableView {
                Label("Not available yet", systemImage: "clock")
            } description: {
                Text("\(chip.title) on your stories will appear here once story activity is recorded.")
            }
        case .all, .glowers:
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if events.isEmpty {
                ContentUnavailableView("No Glow activity yet", systemImage: GlowStyle.symbol,
                                       description: Text("When somebody glows you, it appears here."))
            } else {
                List {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.rows, id: \.uid) { row in
                                GlowNotificationRow(uid: row.uid, at: row.at,
                                                    person: person(row.uid),
                                                    unread: row.at > glow.seenUpTo)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text(section.title).font(.headline).foregroundStyle(Color(.label))
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await load(force: true) }
            }
        }
    }

    /// "This week" / "Last 30 days" / "Older" — his screenshot's own grouping, which is what makes a
    /// long list readable without a date on every row.
    private var sections: [(title: String, rows: [(uid: String, at: Date)])] {
        let now = Date()
        var week: [(uid: String, at: Date)] = []
        var month: [(uid: String, at: Date)] = []
        var older: [(uid: String, at: Date)] = []
        for e in events {
            let days = now.timeIntervalSince(e.at) / 86_400
            if days <= 7 { week.append(e) } else if days <= 30 { month.append(e) } else { older.append(e) }
        }
        return [("This week", week), ("Last 30 days", month), ("Older", older)]
            .filter { !$0.1.isEmpty }
    }

    private func person(_ uid: String) -> GlowPerson? {
        loader.state.value?.first { $0.id == uid }
    }

    private func load(force: Bool = false) async {
        loading = true
        events = await glow.recentGlowers()
        if force { loader.invalidate() }
        await loader.load(events.map(\.uid),
                          dates: Dictionary(events.map { ($0.uid, $0.at) }, uniquingKeysWith: { a, _ in a }),
                          key: events.map(\.uid).joined())
        loading = false
    }
}

/// One notification. His screenshot's shape: avatar, a sentence naming the person, the date, and an
/// action on the right.
private struct GlowNotificationRow: View {
    let uid: String
    let at: Date
    let person: GlowPerson?
    let unread: Bool
    private var glow = GlowService.shared

    init(uid: String, at: Date, person: GlowPerson?, unread: Bool) {
        self.uid = uid; self.at = at; self.person = person; self.unread = unread
    }

    var body: some View {
        HStack(spacing: 12) {
            // The unread mark: a dot, not a coloured row. A tinted row is hard to read and hard to
            // clear; a dot says the same thing and leaves the row alone.
            Circle().fill(unread ? GlowStyle.accent : .clear).frame(width: 7, height: 7)
            NavigationLink {
                GlowProfileView(uid: uid, initialName: person?.name ?? "", initialPhoto: person?.photoUrl)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(name: person?.name ?? "", photoUrl: person?.photoUrl, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person?.name ?? "Someone").font(.headline).lineLimit(1)
                        Text("Glowed at you · \(at.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if glow.isGlowing(uid) {
                Text("Glowing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Button { glow.give(to: uid) } label: {
                    Text("Glow back").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(GlowStyle.accent)
                .controlSize(.small)
            }
        }
    }
}
