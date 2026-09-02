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
                ContactInfoView(cid: [AuthService.shared.uid ?? "", p.id].sorted().joined(separator: "_"),
                                name: p.name, photoUrl: p.photoUrl, source: .story)
            }
            .task(id: key) { await loader.load(Array(glow.glowRelationship).sorted(), key: key) }
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
                        let key = "glowpage-\(c.person.id)"
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
            }
        }
    }
}
