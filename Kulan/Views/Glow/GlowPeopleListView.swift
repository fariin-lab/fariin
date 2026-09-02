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
                    VStack(spacing: 7) {
                        Text("\(count(s)) \(s.title)")
                            .font(.system(size: 16, weight: tab == s ? .bold : .regular))
                            .foregroundStyle(tab == s ? Color.primary : .secondary)
                            .lineLimit(1)
                        // ⛔ THE UNDERLINE IS THE WORD'S WIDTH, NOT THE TAB'S — owner, 2026-09-02:
                        // "the white line now looks too much, make it small". It was a full-width
                        // rule under half the screen, which reads as a divider that happens to be
                        // white rather than as a mark on the selected tab. `fixedSize` collapses
                        // the stack to the label, and the `maxWidth` below centres that in its half.
                        Capsule()
                            .fill(tab == s ? Color.primary : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        // ⛔ NO HAND-DRAWN HAIRLINE — owner, same report: "the top header now has a border, use
        // Apple native design". A 1pt rule under the tabs is a second edge competing with the nav
        // bar's own, which draws its separator only when there is content under it. Ours was always
        // there, which is what made the header read as boxed in.
    }

    /// ⛔ A NATIVE-SHAPED SEARCH FIELD — owner, 2026-09-02: "search bar size and rounded corners,
    /// use Apple corners". The system's own field is a fully rounded capsule about 36pt tall; this
    /// was a 12pt rounded rectangle at roughly 38, which reads as a text box rather than a search
    /// field. Capsule and a stated 36 so it matches the one the chat list gets from `.searchable`.
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
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.07), in: Capsule())
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
                    ContentUnavailableView {
                        Label { Text(tab.title) } icon: { GlowStyle.mark(48) }
                    } description: {
                        Text(tab.emptyHint)
                    }
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
        s == .glowers ? glow.displayGlowers.count : glow.displayGlowing.count
    }

    private var uids: [String] {
        // `display*`, not the raw sets: the demo people have to be in the LIST as well as in the
        // count above it, or his own screen would say "4 Glowers" over three rows.
        Array(tab == .glowers ? glow.displayGlowers : glow.displayGlowing).sorted()
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
    @State private var showProfile = false
    /// ⚠️ READ FOR THE BUTTON LABELS, and it is not cosmetic. `GlowStyle.accent` is `Color.primary`,
    /// which is WHITE at night — so a filled button needs `onAccent`, and a hardcoded white label on
    /// it is invisible. See the note on `GlowStyle.accent`.
    @Environment(\.colorScheme) private var scheme

    init(person: GlowPerson, side: GlowPeopleListView.Side) {
        self.person = person
        self.side = side
    }

    var body: some View {
        HStack(spacing: 12) {
            // ⛔ A BUTTON AND A SHEET, NOT A `NavigationLink` — owner, 2026-09-02: "remove the small
            // arrow next to the name". A `NavigationLink` inside a `List` draws a disclosure chevron
            // and there is no modifier that turns it off; the row has its own trailing controls, so
            // a second arrow between the name and them was pointing at nothing the eye could follow.
            Button { showProfile = true } label: {
                HStack(spacing: 12) {
                    // 62, his number.
                    AvatarView(name: person.name, photoUrl: person.photoUrl, size: 62)
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
        // ⛔ THE ORDINARY PROFILE, NOT THE GLOW ONE — owner, 2026-09-02: "when I click a profile
        // you're showing me Glowers and Posted stories; that's wrong, that's the one I see when I
        // enter MY profile. Show a normal profile like the chat profile: call, mute, disappearing
        // messages."
        //
        // He is right and it was my mistake to route here. `GlowProfileView` was built from his
        // reference of HIS OWN page — the stats card is a door to my own lists and the posted-stories
        // rail is my own stories with their view counts. On somebody else it shows a stats card that
        // cannot open (their names are private, by his own rule) above a rail of their stories, and
        // none of the things you actually want on a person: call, mute, media, disappearing
        // messages. Those all already exist on `ContactInfoView`, which is also where his Glow
        // button lives.
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                ContactInfoView(cid: Self.cid(with: person.id), name: person.name,
                                photoUrl: person.photoUrl, source: .story)
            }
        }
    }

    /// The 1:1 conversation id for somebody, which is derived rather than looked up — the chat need
    /// not exist yet, and `ContactInfoView` opens on a person whether or not there is a thread.
    private static func cid(with other: String) -> String {
        [AuthService.shared.uid ?? "", other].sorted().joined(separator: "_")
    }

    /// The wide button. What it offers depends on the side AND on whether the glow is already
    /// mutual, which is three states rather than two — "Glow back" would be a lie on somebody you
    /// have already glowed.
    @ViewBuilder private var action: some View {
        if side == .glowers {
            if glow.isGlowing(person.id) {
                outlined("Glowing") { glow.remove(to: person.id) }
            } else {
                filled("Glow back") { glow.give(to: person.id) }
            }
        } else {
            outlined("Glowing") { glow.remove(to: person.id) }
        }
    }

    /// ⛔ THE LABEL TAKES ITS COLOUR FROM `onAccent` — owner, 2026-09-02: "fix Glow back, the text
    /// can't be seen in dark mode". `.borderedProminent` tinted with `GlowStyle.accent` filled the
    /// capsule with `Color.primary` — white at night — and then drew the system's own white label on
    /// it. White on white. This is the exact trap `GlowStyle.accent`'s note warns about, and I wrote
    /// the warning and then walked into it here.
    private func filled(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GlowStyle.onAccent(scheme == .dark))
                .frame(minWidth: 92).frame(height: 34)
                .background(GlowStyle.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// ⛔ A DRAWN BORDER — owner, same report: "the Glowing button has no border". `.bordered` fills
    /// with a tint at about 12% and draws no stroke at all, which on this page's black is a button
    /// you can only find by knowing it is there. A stated 1pt outline is the pair to `filled` above:
    /// same size, same shape, opposite emphasis.
    private func outlined(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(minWidth: 92).frame(height: 34)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
    /// ⛔ THE APP'S OWN ACCENT, NOT A COLOUR OF MINE — owner, 2026-09-02, seeing it built: "you are
    /// using different color, use my app design plz, don't use red, follow my app color is black
    /// and white".
    ///
    /// He is right and it was my mistake to invent one. I read a pink off the "Glow back" button in
    /// a screenshot of ANOTHER app and made it this feature's hue; nothing in Fariin is that colour.
    /// The app tints itself `.primary` — white at night, black by day — and every accent surface in
    /// it is that pair.
    ///
    /// ⚠️ `Color.primary` IS WHITE IN DARK MODE, which is the trap this codebase has a whole memory
    /// file about: a hardcoded white label on it is correct every day and invisible every night.
    /// So anything FILLED with `accent` must take its label from `onAccent`, never from `.white`.
    static let accent = Color.primary
    static func onAccent(_ dark: Bool) -> Color { Theme.onAccent(dark) }
    /// ⛔ HIS OWN DRAWING, SUPPLIED 2026-09-02 — outline and filled. The note that stood here said
    /// `sparkles` was the system's nearest idea of a glow and that this is where a real one goes if
    /// he ever sent one. He sent one.
    ///
    /// ⚠️ AN ASSET IS NOT AN SF SYMBOL AND EVERY CALL SITE HAD TO MOVE WITH IT. `systemImage:` takes
    /// a SYMBOL NAME: hand it an asset name and it draws nothing at all, quietly. So the six places
    /// that said `systemImage: GlowStyle.symbol` now build their label with `mark` below, and it is
    /// sized by a `frame` because an asset ignores `font` — the same trap written up against the
    /// attach sheet's album button.
    static let icon = "ic_glow"
    static let iconFill = "ic_glow_fill"

    /// The Glow mark at a stated size.
    ///
    /// Filled means THE RELATIONSHIP EXISTS — it is the same distinction the tab bar draws between
    /// the tab you are on and the ones you are not. Outline is the action and the empty state: the
    /// thing you could do, or the thing there is none of yet.
    static func mark(_ size: CGFloat, filled: Bool = false) -> some View {
        Image(filled ? iconFill : icon)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
