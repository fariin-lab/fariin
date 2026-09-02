import SwiftUI

/// THE BIG STORY CARD — his sixth and seventh references, 2026-09-02. The story's own picture, the
/// author's name bottom-left, the author's face bottom-right wearing a story ring.
///
/// ⚠️ ONE CARD VIEW, TWO SECTIONS. The Glowing grid and the Friends grid draw the identical card,
/// because they are the identical thing: somebody's newest story, big enough to judge by its
/// picture. Two card views would be two places for a corner radius to drift.
struct GlowStoryCardView: View {
    /// ⛔ THE GEOMETRY IS FaceTime's CALL GRID, MEASURED — owner, 2026-09-02, sending that screen
    /// beside ours: "size and rounded corners, I want like image one but you did image two, make it
    /// like image one exactly". What was here was a guess at his earlier reference and it read as a
    /// squatter, tighter grid: 0.74 against 0.655 is about 30pt of height on a card this wide, and
    /// 10pt gutters against 16 is what made four cards read as a block rather than four cards.
    ///
    /// ⚠️ STATED ONCE BECAUSE THREE GRIDS DRAW THEM. Friends, Glowing, and the full Glowing page all
    /// build the same card, and the Glowing section also draws a PLACEHOLDER that has to be the
    /// identical size or the real cards jump when they land. Four copies of 22 is four places for a
    /// corner to drift, which is the thing this file's own header warns about.
    static let aspect: CGFloat = 0.655
    static let corner: CGFloat = 26
    /// The grid around the card, from the same screen: a 20pt margin each side and 16 between, which
    /// on a 393pt phone leaves cards ~168pt wide.
    static let gutter: CGFloat = 16
    static let margin: CGFloat = 20

    let thumbUrl: String
    let name: String
    let authorPhoto: String?
    /// Draws the small ⊕ on the face, which marks YOUR OWN card — his reference has it on My Story
    /// and nowhere else.
    var isMine: Bool = false
    /// ⛔ THE FACE IS ITS OWN TAP TARGET — his correction, 2026-09-02. The CARD opens the story;
    /// the face on it opens the person. Nil leaves the face inert, which is what the friends grid
    /// wants (its whole card is one story door).
    var onAvatarTap: (() -> Void)? = nil

    init(thumbUrl: String, name: String, authorPhoto: String?, isMine: Bool = false,
         onAvatarTap: (() -> Void)? = nil) {
        self.thumbUrl = thumbUrl
        self.name = name
        self.authorPhoto = authorPhoto
        self.isMine = isMine
        self.onAvatarTap = onAvatarTap
    }

    /// The Glowing grid's convenience spelling.
    init(card: GlowStoryCard, onAvatarTap: (() -> Void)? = nil) {
        self.init(thumbUrl: card.story.thumbUrl, name: card.person.name,
                  authorPhoto: card.person.photoUrl, onAvatarTap: onAvatarTap)
    }

    var body: some View {
        Color.clear
            // His reference's proportion: a tall card, a touch shorter than a full 9:16 story, so
            // two columns of them leave room for a third row to peek and invite a scroll.
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay { StoryImage(url: thumbUrl) }
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(alignment: .bottom) {
                // The name has to survive a bright photograph, and a scrim is what does that
                // without dimming the whole card — the same trick the story caption uses.
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    .padding(.trailing, 54)   // clear of the face
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: name, photoUrl: authorPhoto, size: 40)
                        .overlay {
                            Circle().strokeBorder(
                                LinearGradient(colors: [Color(hex: 0x34C76F), Color(hex: 0x3DA1FD)],
                                               startPoint: .bottomLeading, endPoint: .topTrailing),
                                lineWidth: 2)
                        }
                    if isMine {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.black, in: Circle())
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
                .padding(10)
                // ⚠️ HIGH PRIORITY, or the card's own tap underneath wins the touch and the face
                // opens the story instead of the person — the same rule the chat list's ringed
                // avatar follows for exactly this reason.
                .highPriorityGesture(TapGesture().onEnded { onAvatarTap?() },
                                     including: onAvatarTap == nil ? .subviews : .all)
            }
    }
}
