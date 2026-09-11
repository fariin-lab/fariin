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
    /// ⛔ 34, UP FROM 26 — owner, 2026-09-02, with his reference and ours side by side: "the rounded
    /// corners still are not the same, make it exactly like picture one".
    ///
    /// Measured off the pair rather than nudged: on cards of the same width, his reference's corner
    /// curve runs about a third longer than ours did. 26 × 1.3 is 34, and at that radius the card
    /// reads as the soft tile his screenshot shows instead of a rectangle with the corners taken
    /// off.
    ///
    /// ⚠️ THE CLIP IS OVER THE WHOLE CARD NOW, so a bigger radius eats into the bottom corners where
    /// the name and the face sit. Both were checked against the arc rather than assumed: the face's
    /// nearest point lands 24 from the corner's centre against a 34 radius, and the name's padding
    /// went to 14 below to keep the same clearance on its side.
    static let corner: CGFloat = 34
    /// ⛔ 20 AND 16, MEASURED OFF HIS REFERENCE — owner, 2026-09-02: "the corners are correct now,
    /// don't touch them, only fix the height and width, make it exactly like image 2".
    ///
    /// His FaceTime screenshot and ours at the same scale: their card is 400px wide in a 924px
    /// shot — 170pt — on a 20pt margin with 17 between the columns. Ours was 423px, because the
    /// margins had come down to 12 and 10. The ASPECT was already right (0.657 against their
    /// 0.662), so the only thing wrong was how much width the card was being given.
    ///
    /// ⚠️ THIS REVERSES HIS EARLIER "use the Friends strip's edges", AND THE STRIP MOVES WITH IT
    /// rather than being left behind. He asked for one left edge across the page and he has now
    /// asked for this card size; those are only in conflict if the strip stays at 12. So
    /// `StoryRowMetrics.hPad` goes to 20 in the same commit, and the page keeps its single column
    /// while the cards match his reference.
    ///
    /// ⚠️ NOT copied by reference from `StoryRowMetrics`. That enum is `@MainActor` and these are
    /// plain statics; naming the source in writing is what keeps them honest.
    static let gutter: CGFloat = 16
    static let margin: CGFloat = 20
    /// ⛔ 48, HIS NUMBER — owner, 2026-09-02, after ringing the face on these cards three separate
    /// times: "make it 48". It was 40. 48 is the same diameter the story ring wears on a chat list
    /// row, so the face reads at one size wherever the app draws a person with a live story.
    ///
    /// ⚠️ The name's trailing padding is DERIVED from this, not typed beside it. The two are one
    /// measurement — the text has to stop before the face starts — and the day this number moves
    /// again a typed 62 would let the name run under the picture.
    /// ⛔ 44, DOWN FROM 48 — owner, 2026-09-11, with both Glowing faces ringed: "make it 44". Still
    /// the two-column measurement; `avatarRatio` below carries it to every other card size.
    static let avatar: CGFloat = 44
    /// The face's inset from the card's bottom and trailing edges.
    static let avatarInset: CGFloat = 10
    /// ⛔ THE FACE IS A FRACTION OF THE CARD'S WIDTH NOW, NOT A TYPED 48 — owner, 2026-09-11, with
    /// the ⊕ badge ringed on My Story: "why are you using a different type when the story is big".
    ///
    /// It was never a different TYPE, which is worth saying because the fix follows from the real
    /// cause: it was ONE hardcoded size drawn on cards of two different widths. His 48 was measured
    /// on the two-column card, which this file's own note above puts at 168 wide — the face is
    /// 28.6% of it. The three-column tile page draws the SAME card about 114 wide, where a 48 face
    /// is 42% of the width, so the two cards really do read as two different designs.
    ///
    /// 48/168 reproduces his 48 exactly on the grid he measured it on and shrinks the face in step
    /// everywhere else. The story ring, the ⊕ badge and the ⊕'s glyph all hang off this one number
    /// below, so a card's face is the same drawing at every card size.
    ///
    /// ⚠️ `Self.avatar` STAYS as the measured value it always was. It is the numerator here and the
    /// fallback when the card has not been measured yet; nothing outside this file reads it.
    static let avatarRatio: CGFloat = avatar / 168.0
    /// The ring the face wears, as a fraction of the face. 2 on the measured face, so the wide
    /// cards keep the exact stroke they have and the tile cards stop wearing a proportionally
    /// fatter one.
    static let ringRatio: CGFloat = 2.0 / avatar

    /// ⛔ 65% OF THE ⊕ INSIDE THE FACE — owner, 2026-09-11, and it is HIS number rather than a
    /// nudge: "the + badge must be inside 65% in the circle avatar". Read as AREA, which is what
    /// the eye actually judges on two overlapping discs.
    static let badgeInsideFraction: CGFloat = 0.65
    /// The ⊕'s diameter as a fraction of the face's. 16 on a 48 face is exactly a third, so this
    /// keeps the badge the size it already was on the two-column card and scales it with the face
    /// everywhere else.
    ///
    /// ⚠️ `badgeCentreOverRadius` BELOW IS SOLVED FOR THIS EXACT RATIO. Two discs do not overlap
    /// linearly in their sizes, so if this third ever moves, that number is stale — re-solve it
    /// with the formula written there, do not scale it.
    ///
    /// ⛔ 0.42, UP FROM A THIRD — owner, 2026-09-11: "+ badge looks too small". A third was set when
    /// the face was 48 and read as 16pt; the face is 44 now, which took the badge to 14.7 without
    /// anybody choosing that. 0.42 draws it at 18.5 on the same face — bigger than it has ever been
    /// rather than merely restored.
    static let badgeRatio: CGFloat = 0.42
    /// HOW FAR THE ⊕'s CENTRE SITS FROM THE FACE'S CENTRE, as a fraction of the face's RADIUS, so
    /// that exactly `badgeInsideFraction` of the badge's area lands on the face.
    ///
    /// THE DERIVATION, because a number this specific is worth nothing without it. Face radius R,
    /// badge radius ρ = `badgeRatio`·R = R/3, centres d apart along the 45° diagonal. The area the
    /// two discs share is the standard circle-circle lens:
    ///
    ///     A(d) = ρ²·acos((d² + ρ² − R²) / (2dρ))
    ///          + R²·acos((d² + R² − ρ²) / (2dR))
    ///          − ½·√((−d + ρ + R)(d + ρ − R)(d − ρ + R)(d + ρ + R))
    ///
    /// and his ask is A(d) = 0.65·πρ². Divide both sides by R² and every term is in x = d/R alone,
    /// so it is scale-free and solved ONCE here instead of per card size.
    ///
    /// ⛔ RE-SOLVED FOR ρ = 0.42R, NOT SCALED — 2026-09-11, when the badge grew. The note above
    /// `badgeRatio` says this number goes stale the moment that fraction moves, and it did. At
    /// x = 0.870760 both sides are 0.360215·R²: 65.00% of the badge on the face, 35.00% hanging off
    /// it, the same split he asked for at the old size. (The previous pair was ρ = R/3, x = 0.9025.)
    ///
    /// ⚠️ THE FLAT-CHORD SHORTCUT IS STILL NOT GOOD ENOUGH, and it is worse at this ratio than it
    /// was at the last one. Treating the face's edge as a straight line across the badge gives
    /// x = 0.9001, which really leaves 60.6% inside — it was 61.5% wrong before, so a bigger badge
    /// makes the shortcut less forgiving, not more.
    ///
    /// ⚠️ THE CARD'S CORNER WAS RE-CHECKED, since a bigger badge sits closer to it. On the
    /// two-column card the face's centre is `avatarInset` + R = 32 from both edges and the 34pt
    /// arc's centre is at 34, so the badge's centre lands √2·(2 + 13.55) = 21.99 from that centre
    /// and its far edge at 21.99 + 9.24 = 31.23 against 34 — 2.77pt of clearance. Tighter than the
    /// 3.98 a third left, and five times the 0.55 that he photographed as "tucking at an angle".
    static let badgeCentreOverRadius: CGFloat = 0.870760
    /// The same distance split over the two axes, because the badge sits at 45° on the face's
    /// lower-trailing side: each axis gets d/√2.
    static let badgeAxisOffsetRatio: CGFloat = badgeCentreOverRadius / CGFloat(2).squareRoot()
    /// The ⊕ glyph and the badge's own stroke, both as fractions of the badge. 9pt and 1.5pt on a
    /// 16pt badge, which is what the wide cards already draw.
    static let badgePlusRatio: CGFloat = 9.0 / 16.0
    static let badgeStrokeRatio: CGFloat = 1.5 / 16.0

    let thumbUrl: String
    let name: String
    let authorPhoto: String?
    /// Draws the small ⊕ on the face, which marks YOUR OWN card — his reference has it on My Story
    /// and nowhere else.
    var isMine: Bool = false
    /// ⛔ THE CARD WITH NO STORY BEHIND IT — the compose button on the Friends grid, for an account
    /// that has not posted yet. It draws the Glowing grid's own placeholder surface where the photo
    /// would be and is otherwise this card exactly: same aspect, same corner, same face, same ring,
    /// same badge, same name treatment.
    ///
    /// ⚠️ THIS EXISTS BECAUSE AN EMPTY `thumbUrl` IS NOT AN EMPTY CARD. The picture layer is
    /// `StoryImage`, and with no image it draws the shimmer skeleton and retries the load with
    /// backoff — deliberately, so a real card never shows a dead black photo. A card that never had
    /// a url would therefore shimmer for ever, which is worse than the blank page it replaces.
    var isAdd: Bool = false
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

    /// ⛔ THE CORNER THIS ONE CARD IS CUT WITH — owner, 2026-09-09, of the all-friends page: "cards
    /// and corners it will be same like page posted stories". That page moved to three tighter
    /// columns, and `Self.corner` is 34 because it was measured against a card twice this wide; the
    /// same arc on a third of the width eats the picture.
    ///
    /// ⚠️ A PARAMETER, NOT A SECOND CARD VIEW. This file's own header says two card views would be
    /// two places for a corner radius to drift, and that still holds. Defaulting to `Self.corner`
    /// means every existing call site keeps the number it was measured with.
    var corner: CGFloat = GlowStoryCardView.corner

    /// How far the name sits from the card's left and bottom edges. One number for both, and it
    /// tracks the corner: text inset by `d` from two edges only clears a corner of radius `r` when
    /// `d > r(1 - 1/√2)`, about `0.293r`. The floor of 10 keeps the tighter tile cards from pushing
    /// the name flat against the picture's edge.
    private var nameInset: CGFloat { max(10, ceil(0.41 * corner)) }

    /// The face's diameter on a card of this width — see `Self.avatarRatio` for why it is a
    /// fraction and not the typed 48 it used to be.
    ///
    /// ⚠️ ROUNDED TO WHOLE POINTS so the ring's stroke and the badge's circle land on the pixel
    /// grid the same way on every card, and guarded at zero because a `GeometryReader` can report
    /// an empty size on the pass before the card has been measured. Falling back to the measured
    /// 48 for that one frame is invisible; a face of size 0 would not be.
    private func avatarSize(cardWidth: CGFloat) -> CGFloat {
        guard cardWidth > 0 else { return Self.avatar }
        return (cardWidth * Self.avatarRatio).rounded()
    }

    /// ⛔ THE PRESS DIP, AND IT LIVES ON THE CARD RATHER THAN AT THE FOUR CALL SITES — his report the
    /// last time a press was wired up on a SwiftUI card ("now long press is working but there's no
    /// animation", 2026-08-21). The UIKit strip's cards are `UIControl`s and get `isHighlighted` on
    /// touch-down for free; a SwiftUI card has no pressed state of its own at all, so the press
    /// publishes one and the card reads it.
    ///
    /// ⚠️ ONE READER, NOT FOUR. Every grid in the app draws this same view, so putting the dip here
    /// gives the Glowing section, the Glowing page, the Friends grid and the Friends page the same
    /// press with nothing to keep in step by hand — the rule this file's own header states.
    ///
    /// `StoryPressVisual` is deliberately not `@MainActor` for exactly this: `shared` has to be
    /// reachable from a stored-property initialiser. See the note on that type.
    @ObservedObject private var pressVisual = StoryPressVisual.shared

    /// The key this card files its rectangle under, and the same one the press squeezes by.
    private var pressKey: String? {
        guard let rectKey, !rectKey.isEmpty else { return nil }
        return MediaOpenRects.key(.storyRow, rectKey)
    }

    init(thumbUrl: String, name: String, authorPhoto: String?, isMine: Bool = false,
         isAdd: Bool = false,
         rectKey: String? = nil, corner: CGFloat = GlowStoryCardView.corner,
         onAvatarTap: (() -> Void)? = nil) {
        self.thumbUrl = thumbUrl
        self.name = name
        self.authorPhoto = authorPhoto
        self.isMine = isMine
        self.isAdd = isAdd
        self.rectKey = rectKey
        self.corner = corner
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
            // The compose card has no photo to draw and must not be handed to `StoryImage` — see
            // `isAdd`. Same fill the Glowing grid waits behind, so the two read as one family.
            .overlay { if isAdd { Color.primary.opacity(0.08) } else { StoryImage(url: thumbUrl) } }
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
            .overlay {
                // ⚠️ A READER, AND THE BOTTOM-LEADING MOVED ONTO THE `.frame` BELOW — 2026-09-11,
                // the same change as the face's overlay and for the same reason. The name's
                // trailing padding is derived from the face, the face is now derived from the
                // card's width, so this overlay has to know the card's width too. A
                // `GeometryReader` always takes every point it is offered, so an `alignment:` on
                // the overlay itself would have nothing left to align.
                GeometryReader { geo in
                    // ⛔ TWO LINES, NOT AN ELLIPSIS — owner, 2026-09-02, with "Ayaan Warsa…" ringed
                    // and his reference beside it, where a long label wraps rather than truncating.
                    //
                    // ⚠️ ONE LINE WAS THE WRONG ECONOMY. A card is 168 wide less the face and its
                    // margins, so about 100 points of room — which cuts most people off mid-surname,
                    // and a name you cannot read is the one thing this card has to get right. Two
                    // lines of 15pt is 36 points inside a 90pt scrim, so nothing else has to move.
                    // ⛔ 13, DOWN FROM 15 — owner, 2026-09-09, with two names ringed on the Glowing
                    // grid: "now is looks big make small". Two lines of 13 is 32 points inside the
                    // 90pt scrim, so it still clears and nothing around it moves.
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        // ⛔ EQUAL ON BOTH EDGES, BUT NOT 10 — his second report on this,
                        // 2026-09-09: "glowing stories names is tucking angels, bottom angel and
                        // left angel".
                        //
                        // ⚠️ I CAUSED THAT. His first note asked for the left and bottom gaps to be
                        // one number, and I took the face's 10 for both. On a 34pt corner that puts
                        // the text's own corner INSIDE the curve: a point inset by d from both
                        // edges clears an arc of radius r only when d is greater than about 0.293r,
                        // which is 10.0 at r = 34. Exactly on the boundary, which is what tucking
                        // looks like.
                        //
                        // So the inset is derived from the arc it has to clear, and stays equal on
                        // both edges. The wide grids get their old 14 back; the three-column pages,
                        // drawn at an 18pt corner, keep 10 because 10 clears 18 with room to spare.
                        .padding(.leading, nameInset)
                        .padding(.bottom, nameInset)
                        // clear of the face: its width, its inset, and 4 of daylight between the
                        // two
                        //
                        // ⚠️ STILL DERIVED, WHICH IS THE WHOLE POINT OF THE NOTE ON `Self.avatar`.
                        // The face is a fraction of the card as of 2026-09-11, so a typed 62 here
                        // would let the name run under the picture on the tile page and leave a
                        // hole on the wide grid. On the tile card this now asks for 46 instead of
                        // 62, which hands the name 16 more points to wrap in.
                        .padding(.trailing, avatarSize(cardWidth: geo.size.width)
                                            + Self.avatarInset + 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                }
            }
            .overlay {
                // ⚠️ A READER, BECAUSE THE FACE IS A FRACTION OF THE CARD NOW — 2026-09-11.
                // `geo.size` here is the card's own size, so one line settles the face, its ring,
                // the badge and the badge's glyph on whichever grid this card was built for. The
                // bottom-trailing alignment moved off the overlay and onto the `.frame` at the
                // bottom of this block, because a `GeometryReader` always takes every point it is
                // offered and would leave the overlay's own alignment nothing to do.
                GeometryReader { geo in
                    let face = avatarSize(cardWidth: geo.size.width)
                    // ⚠️ CENTRED, NOT BOTTOM-TRAILING, AND THAT IS THE FIX ITSELF. See the badge.
                    ZStack {
                        AvatarView(name: name, photoUrl: authorPhoto, size: face)
                            .overlay {
                                Circle().strokeBorder(
                                    LinearGradient(colors: [Color(hex: 0x34C76F), Color(hex: 0x3DA1FD)],
                                                   startPoint: .bottomLeading, endPoint: .topTrailing),
                                    lineWidth: face * Self.ringRatio)
                            }
                        if isMine {
                            // ⛔ PLACED FROM THE FACE'S CENTRE ALONG THE 45° DIAGONAL — owner,
                            // 2026-09-11, with the badge ringed on My Story: "the add + button and
                            // avatar looks wrong. the + button is tucking at an angle, fix. also
                            // the positioning is wrong. give space. and the + badge must be inside
                            // 65% in the circle avatar".
                            //
                            // ⚠️ WHAT WAS WRONG, because it explains all three of his complaints at
                            // once. The badge was the ZStack's bottom-trailing child with an
                            // `.offset(x: 2, y: 2)` on top, so it hung off the CORNER OF THE FACE'S
                            // SQUARE BOX rather than off the face's CIRCLE. That corner is √2·18 =
                            // 25.5 from the face's centre against a radius of 24, and the lens area
                            // at that distance leaves about 65% of the badge OUTSIDE the face — the
                            // exact inverse of the number he asked for.
                            //
                            // The box's corner is also the point nearest the card's own corner, so
                            // the same mistake caused the tucking: the badge's outer edge landed 8
                            // in from both card edges, where a disc of radius 8 clears a 34pt arc
                            // by 0.55pt. Half a point is what "tucking at an angle" looks like, and
                            // it is the identical arithmetic that bit the name two reports ago at
                            // the other corner of this card.
                            //
                            // So nothing is aligned to a box corner any more. The badge is centred
                            // on the face and pushed out by the solved fraction of the face's
                            // RADIUS, split over the two axes — see `Self.badgeCentreOverRadius`
                            // for the lens equation and the solve.
                            //
                            // ⚠️ IT NO LONGER LEAVES THE FACE'S BOX AT ALL, which is worth knowing
                            // before anyone adds a `.frame` or a clip here. The badge's far edge
                            // sits R·0.9025/√2 + ρ = 15.32 + 8 = 23.3 from the centre on each axis,
                            // inside the face's own 24. It pokes out of the CIRCLE, which is what
                            // he wants, and out of nothing else.
                            let badge = face * Self.badgeRatio
                            let push = face / 2 * Self.badgeAxisOffsetRatio
                            Image(systemName: "plus")
                                .font(.system(size: badge * Self.badgePlusRatio, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: badge, height: badge)
                                .background(Color.black, in: Circle())
                                .overlay(Circle().strokeBorder(.black,
                                                               lineWidth: badge * Self.badgeStrokeRatio))
                                .offset(x: push, y: push)
                        }
                    }
                    .padding(Self.avatarInset)
                    // ⚠️ HIGH PRIORITY, or the card's own tap underneath wins the touch and the face
                    // opens the story instead of the person — the same rule the chat list's ringed
                    // avatar follows for exactly this reason.
                    .highPriorityGesture(TapGesture().onEnded { onAvatarTap?() },
                                         including: onAvatarTap == nil ? .subviews : .all)
                    // ⛔ THE SPACE HE ASKED FOR, CHECKED AGAINST THE CARD'S OWN ARC INSTEAD OF
                    // EYEBALLED — "give space", same report. A disc of radius ρ whose centre sits e
                    // from the corner arc's centre is inside a corner of radius `corner` when
                    // e + ρ ≤ corner.
                    //
                    // Two-column card: the face's centre lands `avatarInset` + R = 10 + 24 = 34
                    // from both edges, which IS the 34pt arc's centre, so e is just the badge's own
                    // offset d and the test reads d + ρ ≤ corner: 21.66 + 8 = 29.7 against 34,
                    // clear by 4.3pt where the old placement cleared by 0.55.
                    //
                    // Three-column tile card (16pt corner, a 114pt card, so a 32pt face): the
                    // badge's centre lands 15.8 from both edges against an arc centre at 16, so
                    // e = 0.3 and 0.3 + 5.3 = 5.6 against 16. Clear at both sizes, which is the
                    // whole reason for deriving it rather than typing an offset.
                    //
                    // ⚠️ THIS `.frame` COMES AFTER THE GESTURE ON PURPOSE. Put it before and the
                    // tap target becomes the whole card, and a tap anywhere on the picture would
                    // open the person instead of the story.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
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
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // 0.92 on a 0.28/0.7 spring, which is the chat row's dip and not the reference app's
            // ramp — his order after seeing the two side by side. No `.animation` modifier: the
            // spring lives in `fingerDown`/`fingerUp`, so the press and the release cannot drift
            // apart from each other here.
            //
            // BEFORE the reporter, the same order the archive strip uses, so the rectangle the lift
            // is cropped from is the card as it is DRAWN mid-dip rather than as the model says.
            .scaleEffect(pressKey != nil && pressVisual.squeezedKey == pressKey
                         ? StoryPressVisual.dipScale : 1)
            // LAST, so the rect it files is the whole card including its overlays — the flight lands
            // on a rectangle, and half a rectangle would land short.
            .modifier(MediaRectReporter(id: rectKey ?? "", scope: .storyRow,
                                        cornerRadius: corner))
    }
}

/// THE LONG PRESS FOR EVERY GRID OF THESE CARDS — his report, 2026-09-05: pressing a Glowing card,
/// a card on the pushed Friends page, or one in the Friends grid that replaces the strip does
/// nothing, while the friends strip beside it lifts.
///
/// ⛔ THE STRIP'S OWN PRESS, NOT A SECOND ONE. `StoryRowLongPress` is the app's story press —
/// one `UILongPressGestureRecognizer` on the enclosing scroll view, the lift a photograph of the
/// card that is really on screen, the menu `CMOverlay`. It was built as a representable for exactly
/// this shape of caller and had no call site left after the archive strip took its own scroller;
/// this is that call site. A `.contextMenu` here would be the thing that file exists to prevent: it
/// does not lift the card, it BUILDS A SECOND ONE from a `preview:` closure, which on these cards
/// means a `StoryImage` that starts loading again and an avatar in a different place.
///
/// ⚠️ IT DOES NOT FIGHT THE BUTTON, and that is the one thing to know before touching it. Each card
/// sits in a SwiftUI `Button` inside a `LazyVGrid`, and a Button is backed by a recogniser that
/// BEGINS ON TOUCH-DOWN — which is what killed this press on the archive strip five times over.
/// `shouldBeRequiredToFailBy` in the coordinator is the fix that settled it: the Button waits for
/// our press to fail, so a quick tap still opens the story the instant the finger lifts, and a hold
/// past 0.32s cancels the Button so nothing opens behind the menu. The avatar's own
/// `highPriorityGesture` is a recogniser inside the same scroller and is held to the same rule, so
/// the face still opens the person on a tap.
enum GlowCardPress {
    /// The target for one card, if the finger is on it.
    ///
    /// ⚠️ THE HIT USES THE MODEL RECT AND THE LIFT USES THE DRAWN ONE, which is the rule the strip's
    /// own `menuTarget` is built on: at press time the card is mid-dip, so a crop taken with the
    /// model rectangle magnifies the picture. Both rectangles come from the registry the story
    /// flight flies to, so the lift and the flight can never disagree about where a card is.
    ///
    /// No `labelRect`: these cards carry their name INSIDE the picture, so the crop already has it
    /// and there is no second strip to photograph.
    /// `corner` is the radius the LIFTED picture is cut with, and it has to be the one the card on
    /// screen was drawn with or the lift is a different shape from the thing under the finger. The
    /// all-friends page draws its cards at the tighter tile corner, the grids at the card's own.
    ///
    /// ⛔ `assumeIsolated`, AND NOT AN `@MainActor` ANNOTATION. This was three compile errors on the
    /// first build that ever reached this code (2026-09-09) — the helper was written a day earlier
    /// and had no call sites, so nothing had made the compiler look at it: "call to main
    /// actor-isolated static method 'key' in a synchronous nonisolated context", and the same for
    /// `liveRect` and `drawnRect`.
    ///
    /// ⚠️ ANNOTATING THIS `@MainActor` DOES NOT WORK, and it is worth saying why so the next session
    /// does not try it. The closure this feeds is stored as a plain `(CGPoint) -> StoryMenuTarget?`
    /// on `StoryRowLongPress`, and it is called from `gestureRecognizerShouldBegin` on a
    /// `Coordinator: NSObject` that is not actor-annotated either. Isolating this end would just
    /// move the same three errors to that call site, and isolating THAT end means annotating a
    /// `UIGestureRecognizerDelegate` conformance.
    ///
    /// The whole chain is main-thread by construction: every caller is a UIKit gesture callback.
    /// `StoryPressVisual` in `StoryRowLongPress.swift` records the identical decision for the
    /// identical reason and stays unannotated. This asserts at runtime what that file asserts in
    /// prose.
    static func target(_ rectKey: String, at p: CGPoint, actions: [CMAction],
                       corner: CGFloat = GlowStoryCardView.corner) -> StoryMenuTarget? {
        guard !rectKey.isEmpty else { return nil }
        return MainActor.assumeIsolated {
            let key = MediaOpenRects.key(.storyRow, rectKey)
            guard let r = MediaOpenRects.liveRect(key), r.contains(p) else { return nil }
            return StoryMenuTarget(key: key, rect: MediaOpenRects.drawnRect(key) ?? r,
                                   actions: actions, cornerRadius: corner)
        }
    }
}

extension View {
    /// Mount the story press over a grid of `GlowStoryCardView`s.
    ///
    /// ⚠️ A `.background`, WHICH IS HOW THE RECOGNISER FINDS ITS SCROLL VIEW. The representable
    /// climbs its superviews for the enclosing `UIScrollView` and installs there; a `.background` is
    /// inside the grid, so the climb is one page's worth of views and lands on the page's own
    /// scroller. It draws nothing and takes no touches.
    ///
    /// ⛔ `requiresCard`, ALWAYS, AND IT IS NOT OPTIONAL HERE. On the Stories tab this scroll view
    /// also holds the friends strip, which runs a press of its own; without the flag ours would
    /// begin on a strip press and cancel it. See `StoryRowLongPress.requiresCard`.
    func glowCardLongPress(_ target: @escaping (CGPoint) -> StoryMenuTarget?) -> some View {
        background { StoryRowLongPress(target: target, requiresCard: true) }
    }
}
