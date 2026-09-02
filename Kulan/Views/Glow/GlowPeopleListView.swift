import SwiftUI

/// THE GLOWERS / GLOWING LIST — his fourth reference, 2026-09-02: the person's name as the title,
/// TABS carrying their own counts, a search field, and rows of avatar + name + a wide action with a
/// dismiss ✕ beside it.
///
/// ⚠️ TABS WITH COUNTS, NOT A SEGMENTED SWITCH. My first pass used a segmented control, which shows
/// two words and no numbers — and the numbers are half the information on this screen. Underlined
/// tabs carry "12 Glowers" in the tab itself, so the count and the selection are one thing.
///
/// ⛔ ONLY EVER YOUR OWN LIST, and that is a privacy decision he made the same day, not a
/// limitation. Counts are public; the names are not. The rules enforce it — a `list` on /glows is
/// allowed only when the query pins one end to the caller's own uid — so this screen could not show
/// somebody else's people even if it tried. The user directory was closed on 2026-08-10 for exactly
/// this reason: a public number must not become a walkable graph.
struct GlowPeopleListView: View {
    enum Side: Hashable {
        case glowers, glowing
        var title: String { self == .glowers ? "Glowers" : "Glowing" }
        var emptyHint: String {
            self == .glowers ? "When somebody gives you a Glow, they appear here and in your Stories."
                             : "Open somebody's profile and choose Glow to follow their stories."
        }
    }

    var side: Side = .glowers
    /// The name in the title bar — whose lists these are. His reference puts the person's own
    /// username there rather than a generic heading.
    var title: String = ""

    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init(side: Side = .glowers, title: String = "") {
        self.side = side
        self.title = title
    }

    @State private var tab: Side = .glowers
    @State private var query = ""
    @State private var loader = GlowPeopleLoader()
    private var glow = GlowService.shared

    var body: some View {
        VStack(spacing: 0) {
            tabs
            searchField
            list
        }
        .navigationTitle(title.isEmpty ? "Glow" : title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tab = side }
        .task(id: uids) { await reload() }
    }

    // MARK: - Chrome

    /// His reference's own header: the count IS the label, and the active tab carries an underline
    /// rather than a filled pill — which is what keeps two long labels legible side by side.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach([Side.glowers, Side.glowing], id: \.self) { s in
                Button { tab = s; query = "" } label: {
                    VStack(spacing: 8) {
                        Text("\(count(s)) \(s.title)")
                            .font(.system(size: 16, weight: tab == s ? .bold : .regular))
                            .foregroundStyle(tab == s ? Color.primary : .secondary)
                            .lineLimit(1)
                        Rectangle()
                            .fill(tab == s ? Color.primary : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - The list

    @ViewBuilder private var list: some View {
        switch loader.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not load", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { loader.invalidate(); Task { await reload() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let people):
            let rows = filtered(people)
            if rows.isEmpty {
                // Three different empties, and they must not share a sentence: nobody at all,
                // nobody on this side, and nothing matching what was typed are three different
                // things to do something about.
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView(tab.title, systemImage: GlowStyle.symbol,
                                           description: Text(tab.emptyHint))
                }
            } else {
                List(rows) { p in
                    GlowPersonRow(person: p, side: tab)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { loader.invalidate(); await reload() }
            }
        }
    }

    // MARK: - Data

    private func count(_ s: Side) -> Int {
        s == .glowers ? glow.glowers.count : glow.glowing.count
    }

    private var uids: [String] {
        Array(tab == .glowers ? glow.glowers : glow.glowing).sorted()
    }

    private func filtered(_ people: [GlowPerson]) -> [GlowPerson] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter {
            $0.name.lowercased().contains(q) || $0.handle.lowercased().contains(q)
        }
    }

    private func reload() async {
        await loader.load(uids, key: "\(tab)-\(uids.joined())")
    }
}

/// One person. His reference's shape: the picture, the name over the handle, a wide action, and a
/// ✕ that takes the row away.
private struct GlowPersonRow: View {
    let person: GlowPerson
    let side: GlowPeopleListView.Side
    private var glow = GlowService.shared

    init(person: GlowPerson, side: GlowPeopleListView.Side) {
        self.person = person
        self.side = side
    }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                GlowProfileView(uid: person.id, initialName: person.name,
                                initialPhoto: person.photoUrl)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(name: person.name, photoUrl: person.photoUrl, size: 48)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if !person.handle.isEmpty {
                            Text("@\(person.handle)").font(.system(size: 14))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            action
            dismissX
        }
    }

    /// The wide button. What it offers depends on the side AND on whether the glow is already
    /// mutual, which is three states rather than two — "Glow back" would be a lie on somebody you
    /// have already glowed.
    @ViewBuilder private var action: some View {
        if side == .glowers {
            if glow.isGlowing(person.id) {
                Text("Glowing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 92)
            } else {
                Button { glow.give(to: person.id) } label: {
                    Text("Glow back")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 92)
                }
                .buttonStyle(.borderedProminent)
                .tint(GlowStyle.accent)
                .controlSize(.regular)
            }
        } else {
            Button { glow.remove(to: person.id) } label: {
                Text("Glowing")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 92)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    /// ⚠️ THE ✕ MEANS TWO DIFFERENT THINGS AND ONLY ONE OF THEM IS DESTRUCTIVE. On the GLOWERS side
    /// it severs somebody else's glow at you — his requirement that a relationship change works
    /// from both ends — so it asks first. On the GLOWING side it is the same thing as the button
    /// beside it, so it is not drawn at all rather than offered twice.
    @ViewBuilder private var dismissX: some View {
        if side == .glowers {
            Menu {
                Button("Remove this Glower", role: .destructive) {
                    glow.removeGlower(person.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
        }
    }
}

/// Glow's own look, stated once. The pink is read off the "Glow back" button in his 2026-09-02
/// notifications screenshot, and it is the one hue the whole feature uses — the audience badge, the
/// buttons, the section header's mark — so a Glow thing is recognisable anywhere in the app.
enum GlowStyle {
    static let accent = Color(hex: 0xFF3B6B)
    /// The word for the relationship in the one place a glyph is needed. `sparkles` is the system's
    /// nearest idea of a glow and it costs no drawing; if he supplies one, this is where it goes.
    static let symbol = "sparkles"
}
