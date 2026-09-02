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
    private var glow = GlowService.shared

    private var key: String { Array(glow.glowRelationship).sorted().joined(separator: ",") }

    var body: some View {
        content
            .navigationTitle("Glowing")
            .navigationBarTitleDisplayMode(.inline)
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
            ContentUnavailableView(
                glow.glowRelationship.isEmpty ? "No Glows yet" : "No live stories",
                systemImage: GlowStyle.symbol,
                description: Text(glow.glowRelationship.isEmpty
                    ? "Open somebody's profile and choose Glow to see their stories here."
                    : "Nobody you have a Glow with has posted in the last 24 hours."))
        case .loaded(let cards):
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(cards) { c in
                        // The CARD is the story; the face on it is the person. Same split as the
                        // notifications row — the picture opens the picture.
                        NavigationLink {
                            GlowProfileView(uid: c.person.id, initialName: c.person.name,
                                            initialPhoto: c.person.photoUrl)
                        } label: {
                            GlowStoryCardView(card: c)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }
}
