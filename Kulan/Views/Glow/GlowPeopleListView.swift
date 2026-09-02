import SwiftUI

/// THE GLOWERS / GLOWING LIST — what the stats card opens when it is tapped.
///
/// ⛔ ONLY EVER YOUR OWN, and that is a privacy decision he made on 2026-09-02, not a limitation.
/// Counts are public; the names are not. The rules enforce it — a `list` on /glows is allowed only
/// when the query pins one end to the caller's own uid — so this screen could not show somebody
/// else's people even if it tried. The user directory was closed on 2026-08-10 for the same reason:
/// a public number must not become a walkable graph.
struct GlowPeopleListView: View {
    enum Side { case glowers, glowing
        var title: String { self == .glowers ? "Glowers" : "Glowing" }
        /// The empty state's own words. Two different facts, so two different sentences — "no
        /// glowers" and "you have glowed nobody" are not the same thing to fix.
        var empty: String {
            self == .glowers ? "Nobody has glowed you yet."
                             : "You have not glowed anyone yet."
        }
        var emptyHint: String {
            self == .glowers ? "When somebody gives you a Glow, they appear here and in your Stories."
                             : "Open somebody's profile and choose Glow to follow their stories."
        }
    }

    let side: Side
    @State private var loader = GlowPeopleLoader()
    private var glow = GlowService.shared

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                // A spinner, not an empty list. An empty list that fills in a moment later reads as
                // "you have nobody" for exactly as long as the fetch takes.
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
            case .loaded(let people) where people.isEmpty:
                ContentUnavailableView(side.title, systemImage: "sparkles",
                                       description: Text(side.emptyHint))
            case .loaded(let people):
                List(people) { p in
                    GlowPersonRow(person: p, side: side)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { loader.invalidate(); await reload() }
            }
        }
        .navigationTitle(side.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: uids) { await reload() }
    }

    /// The ids this side is showing, in a stable order — newest relationships are not knowable from
    /// the live set alone, so this is alphabetical by uid and the ROW carries the date.
    private var uids: [String] {
        Array(side == .glowers ? glow.glowers : glow.glowing).sorted()
    }

    private func reload() async {
        await loader.load(uids, key: "\(side)-\(uids.joined())")
    }
}

/// One person in a Glow list. The trailing control says what YOU can do about this relationship,
/// which is different on each side — his requirement 16, a relationship change has to be reachable.
private struct GlowPersonRow: View {
    let person: GlowPerson
    let side: GlowPeopleListView.Side
    private var glow = GlowService.shared
    @State private var working = false

    init(person: GlowPerson, side: GlowPeopleListView.Side) {
        self.person = person
        self.side = side
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: person.name, photoUrl: person.photoUrl, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).font(.headline).lineLimit(1)
                if !person.handle.isEmpty {
                    Text("@\(person.handle)").font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailingControl
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailingControl: some View {
        if side == .glowers {
            // Their glow, aimed at me. What I can do is glow back — the pink button in his
            // notifications screenshot, and the same word.
            if glow.isGlowing(person.id) {
                Text("Glowing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Button {
                    glow.give(to: person.id)
                } label: {
                    Text("Glow back").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(GlowStyle.accent)
                .controlSize(.small)
            }
        } else {
            // My glow, aimed at them. What I can do is take it back.
            Button {
                glow.remove(to: person.id)
            } label: {
                Text("Glowing").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
