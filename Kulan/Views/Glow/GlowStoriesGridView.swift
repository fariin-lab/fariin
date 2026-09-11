import SwiftUI

/// ALL GLOWING STORIES — the page behind the "Glowing ›" heading on the Stories tab.
///
/// ⛔ HIS CORRECTION, 2026-09-02: "when I click glowing text it's showing wrong page… when user
/// clicks glowing it MEANS show glowing stories, not profile". The heading used to push the
/// Glowers/Glowing PEOPLE list, which is a different question — that one belongs to the stats card
/// on the profile, where the question really is "who".
///
/// A section heading with a chevron promises MORE OF THIS. The section is stories, so more of it is
/// stories. The people list is still one tap away from any card's profile.
struct GlowStoriesGridView: View {
    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init() {}

    @State private var loader = GlowStoriesLoader()
    /// The face tapped on a card — pushes that person's profile. `GlowPerson` is Identifiable, so
    /// this doubles as the presentation trigger.
    @State private var profileTarget: GlowPerson?
    /// The long press's Send Message, pushed the same way the face is. The tab's own grids append to
    /// a `NavigationPath` they own; this page has no path of its own, so it follows the pattern it
    /// already uses for profiles rather than reaching for the tab's.
    @State private var chatTarget: ChatTarget?
    private var glow = GlowService.shared

    private var key: String { Array(glow.glowRelationship).sorted().joined(separator: ",") }

    var body: some View {
        content
            .navigationTitle("Glowing")
            .navigationBarTitleDisplayMode(.inline)
            // A pushed page is not a tab — see the note in `GlowNotificationsView`.
            .toolbar(.hidden, for: .tabBar)
            // The ORDINARY profile — see the note on the same route in `StoriesTabView`. The Glow
            // profile is my own page and nobody else's.
            .navigationDestination(item: $profileTarget) { p in
                ContactInfoView(cid: cid(p.id), name: p.name, photoUrl: p.photoUrl, source: .story)
            }
            .navigationDestination(item: $chatTarget) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
            }
            .task(id: key) { await loader.load(Array(glow.glowRelationship).sorted(), key: key) }
    }

    private func cid(_ uid: String) -> String {
        [AuthService.shared.uid ?? "", uid].sorted().joined(separator: "_")
    }

    /// ⛔ THIS PAGE HAD NO LONG PRESS AT ALL — his 2026-09-11 report, "long-pressing any story does
    /// not show the context menu" on the Glowing page.
    ///
    /// It was not broken, it was never mounted. The Stories tab carries `glowCardLongPress` on its
    /// Glowing SECTION and on the pushed Friends page, and this page — the third grid of the same
    /// cards — was missed when the other two were wired on 2026-09-05. Nothing here is new
    /// machinery: same mount, same helper, same two actions the tab's Glowing cards answer with, so
    /// one hold means one thing wherever the app draws a glower's story.
    ///
    /// ⚠️ THE KEY IS THIS PAGE'S OWN NAMESPACE, `glowpage-<uid>`, the same string the cards register
    /// as their `rectKey` below. The tab's Glowing section files the same person under `glow-<uid>`;
    /// a press that looked under the wrong one would photograph the card on the screen underneath.
    private func pressTarget(at p: CGPoint) -> StoryMenuTarget? {
        for c in (loader.state.value ?? []) {
            if let t = GlowCardPress.target(Self.pageKey(c.person.id), at: p,
                                            actions: actions(c.person)) { return t }
        }
        return nil
    }

    private static func pageKey(_ id: String) -> String { "glowpage-\(id)" }

    /// The tab's `glowActions`, word for word and in its order. No "Hide Stories" for the reason
    /// written there: nothing filters a Glowing grid, so the entry would appear to do nothing here
    /// while quietly hiding the same person from Friends.
    private func actions(_ p: GlowPerson) -> [CMAction] {
        [CMAction(title: "Send Message", icon: "message") {
            chatTarget = ChatTarget(id: cid(p.id), name: p.name, photo: p.photoUrl)
         },
         CMAction(title: "Open Profile", icon: "person.crop.circle") { profileTarget = p }]
    }

    @ViewBuilder private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not load", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") {
                    loader.invalidate()
                    Task { await loader.load(Array(glow.glowRelationship).sorted(), key: key) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded(let cards) where cards.isEmpty:
            // Two different empties: nobody to glow with at all, versus people who simply have no
            // live story right now. The second is the common one and is not a problem to fix.
            ContentUnavailableView {
                Label {
                    Text(glow.glowRelationship.isEmpty ? "No Glows yet" : "No live stories")
                } icon: { GlowStyle.mark(48) }
            } description: {
                Text(glow.glowRelationship.isEmpty
                    ? "Open somebody's profile and choose Glow to see their stories here."
                    : "Nobody you have a Glow with has posted in the last 24 hours.")
            }
        case .loaded(let cards):
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: GlowStoryCardView.gutter),
                                    GridItem(.flexible(), spacing: GlowStoryCardView.gutter)],
                          spacing: GlowStoryCardView.gutter) {
                    ForEach(cards) { c in
                        // The CARD is the story; the face on it is the person. Same split as the
                        // notifications row and the section this page grew out of — the picture
                        // opens the picture.
                        // Its own key prefix: this page and the Stories tab's Glowing section draw
                        // the same person, and the one that is on screen must be the one the
                        // story flies out of.
                        let key = Self.pageKey(c.person.id)
                        Button {
                            Task { await GlowStoryOpen.open(c.person, from: key) }
                        } label: {
                            GlowStoryCardView(card: c, rectKey: key) { profileTarget = c.person }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, GlowStoryCardView.margin)
                .padding(.top, 8)
                // The hold, on this page's own scroller — see `pressTarget`.
                .glowCardLongPress { pressTarget(at: $0) }
            }
        }
    }
}
