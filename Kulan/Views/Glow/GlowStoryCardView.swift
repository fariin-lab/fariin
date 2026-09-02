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
    /// ⛔ 48, HIS NUMBER — owner, 2026-09-02, after ringing the face on these cards three separate
    /// times: "make it 48". It was 40. 48 is the same diameter the story ring wears on a chat list
    /// row, so the face reads at one size wherever the app draws a person with a live story.
    ///
    /// ⚠️ The name's trailing padding is DERIVED from this, not typed beside it. The two are one
    /// measurement — the text has to stop before the face starts — and the day this number moves
    /// again a typed 62 would let the name run under the picture.
    static let avatar: CGFloat = 48
    /// The face's inset from the card's bottom and trailing edges.
    static let avatarInset: CGFloat = 10

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
    /// ⛔ THE ANCHOR THE STORY FLIES OUT OF AND BACK INTO — owner, 2026-09-02: "when I open a story
    /// it opens and closes good, because it goes back where I came from… make it like that for the
    /// Glowing story row, and when I scroll down it must work like the friends story".
    ///
    /// This file's own note said the grid cards had no anchor registered, so they got `StoryDoor`'s
    /// plain presentation instead of the morph, and named registering them as the fix. This is that.
    /// It costs one modifier: `MediaRectReporter` files the card's rect under a `.storyRow` key, and
    /// `StoryDoor.open(from:)` given the same key flies the viewer out of that rectangle, hides the
    /// card underneath while it is up, and lands back on it.
    ///
    /// ⚠️ IT REPORTS A LIVE RECT, WHICH IS THE WHOLE OF WHY SCROLLING WORKS. The rect is re-captured
    /// on every frame change, so the anchor is wherever the card IS, not where it was when the page
    /// was built. Nil (or empty) registers nothing and degrades to the plain presentation.
    var rectKey: String? = nil

    init(thumbUrl: String, name: String, authorPhoto: String?, isMine: Bool = false,
         rectKey: String? = nil, onAvatarTap: (() -> Void)? = nil) {
        self.thumbUrl = thumbUrl
        self.name = name
        self.authorPhoto = authorPhoto
        self.isMine = isMine
        self.rectKey = rectKey
        self.onAvatarTap = onAvatarTap
    }

    /// The Glowing grid's convenience spelling.
    init(card: GlowStoryCard, rectKey: String? = nil, onAvatarTap: (() -> Void)? = nil) {
        self.init(thumbUrl: card.story.thumbUrl, name: card.person.name,
                  authorPhoto: card.person.photoUrl, rectKey: rectKey, onAvatarTap: onAvatarTap)
    }

    var body: some View {
        Color.clear
            // His reference's proportion: a tall card, a touch shorter than a full 9:16 story, so
            // two columns of them leave room for a third row to peek and invite a scroll.
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay { StoryImage(url: thumbUrl) }
            .overlay(alignment: .bottom) {
                // The name has to survive a bright photograph, and a scrim is what does that
                // without dimming the whole card — the same trick the story caption uses.
                //
                // ⚠️ NO CLIP OF ITS OWN ANY MORE. It used to round ITS 90pt box, which rounds the
                // scrim's TOP corners as well — two little notches partway up the card — and only
                // matched the card's bottom corners by both numbers happening to be the same. The
                // card is clipped once, below, and this is a plain rectangle inside it.
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    // clear of the face: its width, its inset, and 4 of daylight between the two
                    .padding(.trailing, Self.avatar + Self.avatarInset + 4)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: name, photoUrl: authorPhoto, size: Self.avatar)
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
                .padding(Self.avatarInset)
                // ⚠️ HIGH PRIORITY, or the card's own tap underneath wins the touch and the face
                // opens the story instead of the person — the same rule the chat list's ringed
                // avatar follows for exactly this reason.
                .highPriorityGesture(TapGesture().onEnded { onAvatarTap?() },
                                     including: onAvatarTap == nil ? .subviews : .all)
            }
            // ⛔ ONE CLIP, OVER THE FINISHED CARD — owner, 2026-09-02: "when I scroll down to close,
            // as it goes back to position I see something at the story card's bottom corners; in a
            // second they're gone".
            //
            // The clip used to sit halfway up the chain, right after the picture, so it rounded the
            // PICTURE and nothing else. Everything added afterwards — the scrim, the name, the face
            // — drew on top of a rounded card with square corners of their own, each rounding itself
            // or not. At rest that mostly reads fine because the picture is what you see; under the
            // landing transform, when the whole thing is being scaled and composited, the layers
            // that were never clipped are the ones that show up in the corners.
            //
            // ⚠️ `compositingGroup()` IS THE HALF THAT MATTERS HERE. Without it the clip is applied
            // to each layer as it is drawn; with it the card is flattened FIRST and the rounded rect
            // cuts the finished image. That is what survives being scaled by a transform, which is
            // exactly what the close does.
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            // LAST, so the rect it files is the whole card including its overlays — the flight lands
            // on a rectangle, and half a rectangle would land short.
            .modifier(MediaRectReporter(id: rectKey ?? "", scope: .storyRow,
                                        cornerRadius: Self.corner))
    }
}
