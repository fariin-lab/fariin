import SwiftUI
import UIKit   // `UIApplication`, for the window's safe-area inset — see `barBottom`

/// THE GLOW PROFILE — his fifth screenshot, 2026-09-02.
///
/// Full-bleed photo, then name + tick, @handle, bio, then two cards: the Glow statistics and
/// Posted stories with a See All. His words: "do NOT use a generic or placeholder profile layout,
/// show the user's real profile information", and "redesigned to look cleaner and more modern".
///
/// ⛔ IT IS THE APP'S OWN PROFILE LANGUAGE, NOT A SECOND ONE. The page takes its colour from the
/// photograph through `ProfilePalette`, exactly as `ContactInfoView` does, which is what makes a
/// Glow profile feel like the app rather than a bolted-on screen (his requirement 11). The palette
/// is the one that already exists; nothing here computes a colour of its own.
///
/// ⚠️ THIS IS THE PROFILE FOR A GLOW RELATIONSHIP, not a replacement for the contact profile. It is
/// reached from the Glow section and the Glow lists — people you are very often NOT in a chat with,
/// which is the whole feature — so it carries no chat, call or media affordances. Those belong to
/// `ContactInfoView`, which owns a conversation.
struct GlowProfileView: View {
    let uid: String
    var initialName: String = ""
    var initialPhoto: String?

    /// ⚠️ AN EXPLICIT INIT, AND IT IS NOT DECORATION — the same trap `StoriesTabView` records in
    /// its own header. A struct with ANY private stored property gets a PRIVATE memberwise
    /// initializer, so `GlowProfileView(uid:)` from another file does not compile: "initializer is
    /// inaccessible due to 'private' protection level". The `private var glow` below is what does
    /// it. The compile check caught this on the first run of these screens.
    init(uid: String, initialName: String = "", initialPhoto: String? = nil) {
        self.uid = uid
        self.initialName = initialName
        self.initialPhoto = initialPhoto
    }

    @State private var profile: UserProfile?
    @State private var failed = false
    @State private var stories = PostedStoriesLoader()
    /// The three faces on the stats card — my own glow people, resolved for their pictures.
    @State private var faces = GlowPeopleLoader()
    @State private var palette: ProfilePalette?
    private var glow = GlowService.shared
    /// The Edit sheet — my own profile only. See `editItem`, the trailing bar button.
    @State private var showEdit = false
    /// Is the photograph still the thing behind the navigation bar? Drives whether the bar keeps
    /// its own material or gets out of the picture's way — see the note on the scroll view.
    ///
    /// ⚠️ TRUE ON THE FIRST FRAME, and that is not an optimistic guess: the page always opens with
    /// the photograph at the top, and starting at `false` would flash a bar background over it for
    /// one frame. `ContactInfoView` seeds the same answer the same way.
    @State private var photoUnderBar = true

    /// The bottom of the navigation bar in screen coordinates — the status strip plus the bar's own
    /// 44pt. Read from the window, because a view whose ancestor has given up the top safe area
    /// cannot read it back from a `GeometryReader`: it has been consumed.
    private static var barBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .max() ?? 59) + 44
    }

    /// The photograph's height. Named because three things now measure against it — the header's
    /// own frame, the name that tucks up into its fade, and the bar's material — and a stray copy
    /// of the number is how those three drift apart.
    private static var photoHeight: CGFloat { UIScreen.main.bounds.width }

    /// ⛔ THE HERO IS ONLY BIG WHEN THERE IS A PHOTOGRAPH TO BE BIG — owner, 2026-09-11, with the
    /// page screenshotted: "my profile, when I am not using a profile photo it is showing big size,
    /// the size a user with a profile picture gets. Make it not a circle, no profile colour, use
    /// light and dark mode. But when I have a profile picture, that time use the big size and the
    /// profile colour."
    ///
    /// ⚠️ WHAT IT WAS DOING. `photoHeight` is the screen's WIDTH — a full-bleed square — and the
    /// no-photo branch filled that whole square with the palette's card colour and set the initial
    /// at `w * 0.34`, which is about 130pt. On an account with no picture the page opened on a
    /// screen-wide slab of colour carrying one enormous letter, and the name it belongs to was
    /// below the fold. The big square is right for a PHOTOGRAPH — it is the page's subject — and
    /// there is nothing to be the subject of here.
    ///
    /// ⚠️ IT IS NOT "THE PHOTO HEIGHT, SMALLER". It is a different thing: no palette colour, the
    /// plain system background so it answers to light and dark the way he asked, and a letter sized
    /// to this slot rather than to the screen. `photoHeight` is untouched and still the number the
    /// photograph uses.
    private static var letterHeroHeight: CGFloat { 132 }

    /// Is there a picture to draw at all? Read by everything that measures the header, so the three
    /// call sites cannot disagree about which hero is on screen — the same reason `photoHeight`
    /// has a name.
    private var hasHeroPhoto: Bool {
        let url = profile?.photoUrl ?? initialPhoto
        return !(url ?? "").isEmpty
    }

    /// The header's real height, whichever of the two it is.
    private var heroHeight: CGFloat { hasHeroPhoto ? Self.photoHeight : Self.letterHeroHeight }

    /// ⚠️ THE BAR'S SCHEME IS PINNED, AND ON iOS 26 IT IS `.light` — the same switch, and the same
    /// reasoning, as `ContactInfoView.barScheme`, which was settled with him on 2026-08-19. The
    /// page's own `\.colorScheme` never reaches the bar (the back item belongs to the navigation
    /// stack, not to this view), so without this the chrome resolves in whatever the phone is set
    /// to and a light-mode phone puts a black chevron on a photograph. iOS 27 draws the items'
    /// glass from the backdrop and ignores the scheme, so `.dark` is right there; iOS 26 obeys it
    /// for the material too and `.dark` gives the near-black discs he photographed and rejected.
    private static var barScheme: ColorScheme {
        if #available(iOS 27.0, *) { return .dark }
        return .light
    }

    private var isMe: Bool { uid == (AuthService.shared.uid ?? "") }
    private var pageColor: Color { palette.map { Color($0.page) } ?? Theme.bg(true) }
    private var cardColor: Color { palette.map { Color($0.card) } ?? Color.white.opacity(0.10) }

    var body: some View {
        ZStack {
            pageColor.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    identity
                    statsCard.padding(.horizontal, 16).padding(.top, 18)
                    postedStoriesCard.padding(.horizontal, 16).padding(.top, 22)
                    Color.clear.frame(height: 32)
                }
            }
            // The space the header measures its overscroll against — see `stretch` in `header`.
            .coordinateSpace(.named("profileScroll"))
            // ⛔ THE PHOTOGRAPH RUNS TO THE TOP OF THE SCREEN — owner, 2026-09-02: "when I enter my
            // profile the top header looks a different colour". It was not a colour, it was a gap:
            // the scroll content started BELOW the status bar, so the strip behind the clock was
            // `pageColor` — a flat tone pulled from the photo — while the photo itself began an inch
            // lower. Two versions of the same colour meeting in a line is exactly what he saw.
            //
            // A full-bleed header means full bleed.
            .ignoresSafeArea(edges: .top)

            // ⛔ THE BAR IS TRANSPARENT WHILE THE PHOTOGRAPH IS BEHIND IT, THEN TAKES ITS MATERIAL
            // BACK — the same rule `ContactInfoView` follows, and this page has to measure it
            // rather than let `.automatic` decide. `.automatic` asks "has content scrolled under
            // me"; this page gives up the top safe area so the picture can reach the screen edge,
            // so the answer is yes from the first frame and the bar would drop a material over the
            // photograph immediately.
            //
            // The photograph starts at y = 0 and is `photoHeight` tall, so its bottom edge on
            // screen is that height less however far the page has been scrolled. Tied to where the
            // PICTURE is, never to a scroll threshold: the two part company on a wide screen.
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentOffset.y + g.contentInsets.top
            } action: { _, scrolled in
                // ⚠️ FALSE OUTRIGHT WITH NO PHOTOGRAPH. This flag exists to hide the bar's material
                // while a picture is passing behind it; a letter hero IS the page background, so
                // hiding the bar there would leave the back and Edit items floating on nothing.
                photoUnderBar = hasHeroPhoto && (heroHeight - scrolled > Self.barBottom)
            }
        }
        // ⛔ NO TAB BAR ON THIS PAGE — owner, same report: "when I enter, hide the nav bottom bar".
        // It is a profile opened from a story, not a tab, and the bar was sitting over the Posted
        // stories card. `.tabBar` is the placement; hiding it here restores it on the way back.
        .toolbar(.hidden, for: .tabBar)
        // Refreshes on the way back out: `load()` re-reads the profile, so a new name, bio or photo
        // is on screen the moment the sheet closes rather than on the next visit.
        .sheet(isPresented: $showEdit, onDismiss: { Task { await load() } }) { EditProfileView() }
        // The page is a coloured photograph whatever the phone is set to — the same rule the chat
        // with a wallpaper follows, and for the same reason: light chrome on a lit picture washes
        // out. `\.colorScheme`, never `preferredColorScheme` — see the note in ThreadView.
        .environment(\.colorScheme, .dark)
        // ⛔ THE PAGE HAS A REAL NAVIGATION BAR AGAIN — owner, 2026-09-09: "my profile page looks
        // fake page or custom page, fix, make real apple page not custom", and beside it "top
        // buttons Back button and Edit button is wrong position, fix".
        //
        // ⚠️ THE BAR WAS HIDDEN AND THE CHROME WAS HAND-DRAWN ON THE PHOTOGRAPH. A round glass
        // chevron and a glass "Edit" capsule were laid out by this file, at a status-bar inset it
        // had to read off the window by hand, pinned over the scroll view — our own answer to a
        // question the system already answers, and the two are never quite the same: the position,
        // the size, the material, the press feel and the back label all come out slightly off,
        // which is what reads as a custom page.
        //
        // Both are bar items now. Back is the SYSTEM's own — the page is pushed from Settings, so
        // the stack already has one, carrying the previous screen's title the way every other push
        // in the app does. Edit is a plain `Button` and the bar draws its own glass around it,
        // which is the ruling he gave on the sibling profile page on 2026-08-22: he does not want
        // the colour managed, he wants Apple's material.
        //
        // ⚠️ NO TITLE IN THE MIDDLE, and that is also his ruling (2026-08-20, `ContactInfoView`):
        // you are already on the person's page with their picture filling the top of it and their
        // name written underneath, so a second copy riding the bar is the same thing twice.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editItem }
        // The system back chevron takes its colour from the tint, not from the page's
        // `\.colorScheme` — that value stops at this view's own content and the back item belongs
        // to the navigation stack. Same line, same reason, as `ContactInfoView`.
        .tint(.white)
        .toolbarBackground(photoUnderBar ? .hidden : .automatic, for: .navigationBar)
        .toolbarColorScheme(Self.barScheme, for: .navigationBar)
        // ⛔ THE SWIPE BACK — owner, 2026-09-02: "swiping back doesn't work on this page, only the
        // arrow button works". Hiding the navigation bar took the interactive pop gesture with it,
        // because UIKit hangs that gesture off the bar's back item: no back item, no swipe.
        //
        // ⚠️ IT STAYS EVEN THOUGH THE BAR IS BACK. With a real back item the system restores the
        // gesture on its own, so this is belt and braces now rather than the only thing holding it
        // up — but it is also what lets the swipe run alongside the page's own scrolling, and the
        // swipe is a thing he has already had to report once. It comes out when he can test it, not
        // on a guess from a machine that cannot build the app.
        .background(RestoreSwipeBack())
        .task { await load() }
        // Keyed on the relationship, so the faces appear the moment the listeners deliver rather
        // than only if they happened to be there on the first frame. See `faceKey`.
        .task(id: faceKey) { await loadFaces() }
    }

    // MARK: - Header

    /// The picture, full-bleed, running up under the navigation bar. His screenshot's proportions:
    /// the photograph is about the top 45% and the name sits just under it.
    private var header: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let w = geo.size.width
                // ⛔ THE PICTURE STRETCHES INSTEAD OF LEAVING A HOLE — his same report: pulling the
                // page down opened a band of flat colour above the photograph, which is what made a
                // scroll look like a sheet coming loose. A full-bleed header grows with the
                // overscroll; every profile page that does this well does exactly this.
                //
                // ⚠️ ONLY DOWNWARDS. `max(0, minY)` means the image is only ever taller than its
                // slot, never shorter: scrolling UP must let it leave normally, or the page would
                // drag its own header along behind it.
                let stretch = max(0, geo.frame(in: .named("profileScroll")).minY)
                Group {
                    if let url = profile?.photoUrl ?? initialPhoto, !url.isEmpty {
                        StoryImage(url: url)
                    } else {
                        // No photograph: the letter on the plain system background, which is what
                        // "use light and dark mode" means — see `letterHeroHeight`. The palette's
                        // card colour is deliberately NOT used: a palette with no photograph to
                        // read has nothing to be derived from, so it was painting a screen-wide
                        // slab of a colour that means nothing.
                        Color(.systemBackground).overlay {
                            Text(String((profile?.name ?? initialName).prefix(1)).uppercased())
                                // Sized to THIS slot, not to the screen. `w * 0.34` was about 130pt.
                                .font(.system(size: Self.letterHeroHeight * 0.46, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: w, height: heroHeight + stretch)
                .clipped()
                .offset(y: -stretch)
                // The photograph melts into the page rather than ending on a line — the seam
                // `ProfilePalette` exists to kill. See its note on `page`.
                //
                // ⚠️ ONLY UNDER A PHOTOGRAPH. The letter hero is already the page's own background,
                // so there is no seam to hide and a fade over it would draw a band of `pageColor`
                // across a background that is not `pageColor`.
                .overlay(alignment: .bottom) {
                    if hasHeroPhoto {
                        LinearGradient(colors: [pageColor.opacity(0), pageColor],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: w * 0.42)
                    }
                }
            }
            .frame(height: heroHeight)
        }
    }

    /// ⛔ EDIT, TOP RIGHT, MINE ONLY — owner, 2026-09-02: "on my profile top right side add an edit
    /// button; when I click it I can change name, bio, avatar, username like in Settings > Edit
    /// profile". It is a bar item now, not a glass capsule laid on the photograph — owner,
    /// 2026-09-09: "top buttons Back button and Edit button is wrong position, fix".
    ///
    /// ⚠️ THE SAME `EditProfileView` SETTINGS PRESENTS, not a second editor. It already owns the
    /// rules this page must not re-decide: nothing is written until Save, the username has its own
    /// claim-and-release flow, and the avatar is cropped twice (the circle for lists, the tall one
    /// for this very header). A copy of that here would be a second answer to all three.
    ///
    /// ⚠️ THE WORD, NOT A PENCIL — owner, 2026-09-02: "don't use an icon, use Edit text like when I
    /// enter other people's profile; make it a text button, not an icon button". That ruling used
    /// to live on a hand-built glass capsule; the capsule is gone and the ruling is not.
    ///
    /// ⚠️ A `ToolbarItem` PER STATE, and the `if` lives in the builder rather than inside one item.
    /// `ContactInfoView` learned the same thing: an item that is sometimes absent is not the same
    /// object as an item holding an `if`, and the bar animates the two differently.
    ///
    /// ⚠️ `.tint(.white)` ON THE WORD. The page pins the bar's scheme to `.light` on iOS 26 for the
    /// material's sake (see `barScheme`), and a label left to follow that would go black on a
    /// photograph. Only the letters are ours; the capsule behind them is the system's.
    @ToolbarContentBuilder private var editItem: some ToolbarContent {
        if isMe {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }.tint(.white)
            }
        }
    }

    /// Name, tick, @handle, bio — his screenshot's stack, centred.
    ///
    /// ⛔ TEXT STYLES AND SEMANTIC COLOURS, NOT POINT SIZES AND WHITE OPACITIES — owner,
    /// 2026-09-09: "make real apple page not custom". Every line here was a hand-set number
    /// (28/17/15) in a hand-mixed white, which is the same three sizes the system already names
    /// and the same two greys it already owns:
    ///
    ///   • 28 bold → `.title.bold()`   • 17 → `.body`   • 15 → `.subheadline`
    ///   • white 0.75 / 0.85 → `.secondary`, which IS white at that weight on a dark page
    ///
    /// The look is where it was, to the point. What changes is that the page now grows with the
    /// phone's text size the way every Apple page does — a fixed 28 is the one thing a native
    /// screen never has — and the greys are the system's, so they stay right if the page's colour
    /// ever moves under them.
    ///
    /// ⚠️ `.primary`/`.secondary` ARE SAFE HERE because nothing in this stack is a button label.
    /// They are hierarchical and resolve against a Button's TINT, which has bitten this app before
    /// (2026-08-18); the page's forced `\.colorScheme` of `.dark` is what pins them to white.
    private var identity: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(profile?.name ?? initialName)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                if OfficialChannel.isOfficial(uid) { VerifiedTick(size: 20) }
                else { VerifiedMark(uid: uid, size: 20) }
            }
            .multilineTextAlignment(.center)

            if let h = profile?.handle, !h.isEmpty {
                Text("@\(h)").font(.body)
                    .foregroundStyle(.secondary)
            }
            if let about = profile?.about, !about.isEmpty {
                Text(about)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
            }
            // ⛔ "Joined May 2026" — his concept, 2026-09-09, a small pill under the bio and above
            // the stats card.
            //
            // ⚠️ ABSENT WHEN THE DATE IS UNKNOWN, AND THAT IS NOT A BUG. It reads the account
            // document's own creation stamp. An account written before anything recorded one has
            // no answer, and a profile page must not invent a joining date — a wrong one is worse
            // than no line. Month and year only, which is what his picture shows and as much as
            // this ever needs to say.
            if let joined = profile?.joinedAt {
                Text("Joined \(joined.formatted(.dateTime.month(.wide).year()))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(cardColor, in: Capsule())
                    .padding(.top, 8)
            }
            if !isMe { glowButton.padding(.top, 12) }
        }
        // The name tucks up into the photograph's fade. With no photograph there is no fade and
        // nothing to tuck into, so the pull-up is proportional to whichever hero is actually there.
        .padding(.top, -heroHeight * 0.10)
    }

    /// GIVE OR TAKE BACK A GLOW — the one action this page has, and the only place in the app where
    /// a glow can be given (his flow starts "User A gives User B a Glow").
    private var glowButton: some View {
        Button {
            if glow.isGlowing(uid) { glow.remove(to: uid) } else { glow.give(to: uid) }
        } label: {
            Label {
                Text(glow.isGlowing(uid) ? "Glowing" : "Glow")
            } icon: {
                // The tick stays for "already glowing" — his mockup shows a tick there, and a mark
                // that is the same drawing in both states says nothing about which state it is in.
                if glow.isGlowing(uid) {
                    Image(systemName: "checkmark")
                } else {
                    GlowStyle.mark(18)
                }
            }
            .font(.headline)
            .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .tint(glow.isGlowing(uid) ? Color.white.opacity(0.18) : Color.white)
        .controlSize(.large)
    }

    // MARK: - The two cards

    /// GLOW STATISTICS — "235.5k Glowers · 5.5k Glowing" over a row of faces, with a chevron.
    ///
    /// ⚠️ THE NUMBERS COME FROM THE USER DOCUMENT, not from counting rows. `glowerCount` and
    /// `glowingCount` are written by the server and are in `serverOnlyUserFields`, so they are the
    /// one number nobody can inflate — and counting client-side would need the very list the rules
    /// refuse to hand over for anybody but yourself.
    ///
    /// ⚠️ TAPPABLE ONLY ON MY OWN PROFILE. Same ruling as the lists it opens.
    private var statsCard: some View {
        // ⛔ MY OWN COUNTS ARE COUNTED HERE, NOT READ FROM THE SERVER — and that is not a shortcut,
        // it is the more truthful of the two answers. `GlowService` holds my complete glow sets,
        // live, off two listeners; the user-document fields are a denormalised copy that a function
        // maintains and that is stale for as long as the write takes.
        //
        // ⚠️ SOMEBODY ELSE'S COUNTS STILL COME FROM THE DOCUMENT, and they read ZERO until
        // `onGlowWrite` is deployed. They cannot be counted here for the reason the whole privacy
        // model rests on: the rules refuse to list anybody's glows but your own, so a client CANNOT
        // count a stranger's glowers. That is the design working, not a gap in it.
        let glowers = isMe ? glow.displayGlowers.count : (profile?.glowerCount ?? 0)
        let glowing = isMe ? glow.displayGlowing.count : (profile?.glowingCount ?? 0)
        return Group {
            if isMe {
                NavigationLink { GlowPeopleListView(side: .glowers, title: profile?.handle ?? profile?.name ?? "Glow") } label: { statsCardBody(glowers, glowing) }
                    .buttonStyle(.plain)
            } else {
                statsCardBody(glowers, glowing)
            }
        }
    }

    private func statsCardBody(_ glowers: Int, _ glowing: Int) -> some View {
        HStack(spacing: 12) {
            // ⛔ OVERLAPPING FACES, NOT A GLYPH — his reference has three small avatars tucked into
            // each other at the card's leading edge, and the line under the numbers names two of
            // them ("by sophieraiin, stefdraper_raper_"). A symbol in a circle was my first pass
            // and it loses what the faces are for: the card says WHO, not just how many.
            //
            // ⚠️ Falls back to the glyph when there is nobody to draw, rather than three empty
            // circles — an account with no glowers must not look like an account with three
            // faceless ones.
            if facePeople.isEmpty {
                // Filled here: this disc is a solid little badge, and the outline's 1.5pt strokes
                // disappear against a tinted circle at 18pt.
                GlowStyle.mark(18, filled: true)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
            } else {
                faceCluster
            }
            VStack(alignment: .leading, spacing: 2) {
                // ⛔ THE SYSTEM'S OWN PAIR — owner, 2026-09-09: "make real apple page not custom".
                // A hand-set 16 semibold over a 0.7 white is what `.headline` over `.secondary`
                // already is, and unlike the numbers it follows the phone's text size.
                // ⛔ ROOM FOR THE WHOLE LINE — his report, 2026-09-09: "make good size for enough
                // text". With counts in the hundreds of thousands this line is long, and it was
                // being squeezed between the faces and the chevron until it truncated. It may wrap
                // to a second line now and the card grows to hold it, which is what his concept
                // shows; the size follows the phone's text setting either way.
                Text("\(GlowCount.short(glowers)) Glowers  ·  \(GlowCount.short(glowing)) Glowing")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                // His reference's own second line: "by <name>, <name>". Named people beat a generic
                // sentence, and it falls back to one when there are no names yet.
                Text(byLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isMe {
                // The grouped-list disclosure indicator, at the weight and colour the system draws
                // it. `.secondary` rather than a mixed white so it sits at the same weight as the
                // line beside it whatever colour the photograph gives the card.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // ⛔ THE PILL IS FLATTER — owner, 2026-09-11: this card is "too tall", with his reference
        // beside it showing a pill whose two lines of text sit close together over tight vertical
        // padding and whose faces are no taller than those two lines.
        //
        // ⚠️ HEIGHT ONLY. The 14 on the leading and trailing edges is exactly where it was, so the
        // card's width, its margins, its corner, its type sizes and its chevron are all untouched —
        // that was the whole of his instruction.
        //
        // The arithmetic, so the number is not a guess. The tallest thing in this row is the text
        // stack: `.headline` over `.subheadline` with 2 between them, about 43pt at the default
        // text size. `.padding(14)` added 28 on top of that for a pill of about 71. 9 a side brings
        // it to about 61. The other half of the same fix is the face cluster below, which measured
        // 44 and so was setting the card's height by itself; a row of faces is 24.
        .padding(.horizontal, StatsPill.padH)
        .padding(.vertical, StatsPill.padV)
        .background(cardColor, in: RoundedRectangle(cornerRadius: ProfileCard.corner,
                                                    style: .continuous))
    }

    /// ⛔ ONE CORNER FOR EVERY CARD ON THIS PAGE — his report, 2026-09-09: "fix rounded corners, use
    /// apple corners". The stats card was cut at 20 and the posted stories card at 22, which is the
    /// kind of difference you cannot name but can see when two cards sit one above the other.
    ///
    /// 22 rather than a smaller radius because these are wide content cards on a photograph, not
    /// rows in a grouped list, and `.continuous` because every other rounded surface in this app is
    /// the squircle rather than the circular arc.
    private enum ProfileCard {
        static let corner: CGFloat = 22
    }

    /// ⛔ THREE OVERLAPPING FACES IN A ROW — owner, 2026-09-11, with his reference beside ours: the
    /// pill's leading edge carries up to three circles tucked into each other from left to right,
    /// the frontmost on top, each ringed in the card's own colour so they read as separate discs
    /// rather than one merged shape. Fewer than three people available draws however many there
    /// are; nothing is padded out with blanks, because an empty circle claims somebody who is not
    /// there.
    ///
    /// ⚠️ WHAT WAS HERE WAS A CLUSTER — a 34pt face centred with a 22 tucked under each of its
    /// lower corners, his 2026-09-02 choice, kept here so it is not quietly reinstated later. The
    /// newer picture overturns it, and the cluster is also half of why the card was tall: it
    /// measured 44 against text of about 43, so the faces were setting the pill's height on their
    /// own. A row never does.
    ///
    /// The geometry, so it can be adjusted without guessing: every face is `StatsPill.face` across
    /// and the next one starts `StatsPill.step` further along, which makes the overlap the
    /// difference between the two — 10pt, about 40% of a face, enough to read as a stack without
    /// turning the one behind into a sliver. Three of them come to exactly 52pt, which is the width
    /// the old cluster occupied, so the sentence beside them keeps every point of room it had.
    ///
    /// ⚠️ DRAWN BACK TO FRONT. Later views in a `ZStack` are painted over earlier ones, so the row
    /// is built in reverse — the last face first — to leave the FIRST one on top. Natural order
    /// would tuck the leading face behind its neighbour, which is the same trap the old cluster's
    /// "the big one last" note recorded.
    ///
    /// ⚠️ `.offset` MOVES THE PAINT, NOT THE LAYOUT, so the `ZStack` measures one face wide however
    /// many are in it. The explicit frame is what reserves the row's real width; without it the
    /// second and third faces would hang over the text.
    @ViewBuilder private var faceCluster: some View {
        let shown = Array(facePeople.prefix(StatsPill.maxFaces))
        let width = StatsPill.face + CGFloat(max(0, shown.count - 1)) * StatsPill.step
        ZStack(alignment: .leading) {
            ForEach(Array(shown.indices.reversed()), id: \.self) { i in
                AvatarView(name: shown[i].name, photoUrl: shown[i].photoUrl, size: StatsPill.face)
                    .overlay(Circle().strokeBorder(cardColor, lineWidth: StatsPill.ring))
                    .offset(x: CGFloat(i) * StatsPill.step)
            }
        }
        .frame(width: width, height: StatsPill.face, alignment: .leading)
    }

    /// The stats pill's own geometry — owner, 2026-09-11. Named rather than typed into the views
    /// because his note is about HEIGHT and nothing else, and a stray number in here is exactly how
    /// a height-only change quietly becomes a width one.
    private enum StatsPill {
        /// Unchanged at 14, deliberately: the side inset is what fixes the card's width and its
        /// margins, and he asked for neither to move.
        static let padH: CGFloat = 14
        /// Was 14, the other half of the old `.padding(14)`. The arithmetic is at the foot of
        /// `statsCardBody`: 9 a side puts the pill at about 61pt instead of about 71.
        static let padV: CGFloat = 9
        /// A face's diameter. Derived rather than chosen — three faces `step` apart have to come to
        /// the 52pt the old cluster occupied, so the line beside them loses nothing.
        static let face: CGFloat = 24
        /// How far along the next face starts, so `face - step` is the overlap. 24 + 14 + 14 = 52.
        static let step: CGFloat = 14
        /// The ring that separates one disc from the next, in the card's own colour. The same 2pt
        /// the cluster drew, and it is what stops three circles reading as one blob.
        static let ring: CGFloat = 2
        /// How many faces the pill draws. His reference shows three.
        static let maxFaces: Int = 3
    }

    /// The faces on the stats card — a few of the people in the glow relationship. Only ever drawn
    /// on MY OWN profile, because those are the only names the rules will hand over (his ruling:
    /// counts public, names private), and the card is the door to my own lists.
    private var facePeople: [GlowPerson] { isMe ? (faces.state.value ?? []) : [] }

    private var byLine: String {
        let names = facePeople.prefix(2).map(\.name).filter { !$0.isEmpty }
        if names.isEmpty { return isMe ? "See who glowed you" : "Glow activity" }
        return "by " + names.joined(separator: ", ")
    }

    /// POSTED STORIES — three tiles filling the card, the heading and See All sharing the top line.
    ///
    /// ⛔ HIS CONCEPT IMAGE, 2026-09-09: "make it the image concept I sent you exactly". Three
    /// changes from what was here, and two of them overturn earlier decisions of his, which is worth
    /// naming so neither is quietly undone later:
    ///
    ///   1. THE HEADING MOVED INSIDE THE CARD and See All moved up beside it. It used to sit above
    ///      the card as a free-standing title with See All as a row at the bottom behind a divider.
    ///      The All Media card was moved the same way on 2026-09-05, so the two now match, which is
    ///      what his two concept images show side by side.
    ///   2. ⚠️ SEE ALL IS ALWAYS THERE NOW. His 2026-09-02 rule was "more than 3 stories show the
    ///      See All button", on the reasoning that under four the rail already showed everything.
    ///      His concept draws exactly three tiles WITH See All, so the newer picture wins. If he
    ///      wants the old rule back it is one `if rows.count > 3` around the link.
    ///   3. ⚠️ THE RAIL NO LONGER SCROLLS. Three tiles are sized to fill the card's width, the way
    ///      the picture shows them, so a fourth story is reached through See All rather than by
    ///      dragging sideways.
    private var postedStoriesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // ⛔ THE STATS CARD'S TYPE, NOT A BIGGER ONE — his report, 2026-09-09: "posted
                // stories text size and type make it like glower text". The card above it says
                // "4 Glowers · 9 Glowing" in `.headline`, and a 20pt bold heading beside it made the
                // two cards look like they came from different screens. A system style also answers
                // the phone's text size, which a frozen 20 never did.
                Text("Posted stories")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                NavigationLink {
                    PostedStoriesView(uid: uid, isMe: isMe,
                                      title: profile?.name ?? initialName)
                } label: {
                    HStack(spacing: 3) {
                        Text("See All").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PostedCard.pad)
            .padding(.top, PostedCard.pad)

            VStack(spacing: 0) {
                switch stories.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).frame(height: 150)
                case .failed:
                    cardMessage("Could not load stories", retry: true)
                case .loaded(let rows) where rows.isEmpty:
                    cardMessage(isMe ? "You have no live stories." : "No live stories.", retry: false)
                case .loaded(let rows):
                    // Three across, each taking an equal share of what the card's padding leaves,
                    // so the row ends flush with the heading above it however wide the screen is.
                    //
                    // ⛔ AND THERE ARE THREE COLUMNS WHETHER OR NOT THERE ARE THREE STORIES —
                    // owner, 2026-09-11: with a single story posted, this card grew until it filled
                    // the screen.
                    //
                    // ⚠️ THE ROW USED TO LET THE STORIES DECIDE THE COLUMNS. An `HStack` hands its
                    // whole width to whatever happens to be inside it, so one tile was offered the
                    // card's entire content width instead of a third of it — and a tile solves its
                    // HEIGHT from the width it is given (`PostedStoryTile` lays itself out on a
                    // `Color.clear` carrying `GlowStoryCardView.aspect`, a portrait 0.655, so the
                    // height is about 1.5x the width). One story therefore came out three times as
                    // wide AND three times as tall as the same story sitting in a full row, which
                    // is the card he photographed. Nothing was wrong with the tile: it was
                    // answering the question it was asked.
                    //
                    // A grid states its columns up front, so "how wide is a tile" stops depending
                    // on how many there are and the card is the same size with one story as with
                    // ten. It is also the recipe the page behind See All already uses
                    // (`PostedStoriesView.columns`), which is why that page never had this.
                    //
                    // ⚠️ THE COLUMNS ARE BUILT HERE, NOT STORED. A stored `let` of `[GridItem]` on
                    // a view runs its initialiser outside the view's main-actor context, and these
                    // Glow screens have already failed the compiler on that class of mistake three
                    // times; `PostedStoriesView` computes its own for the same reason.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                                spacing: PostedCard.gap),
                                             count: PostedCard.tiles),
                              spacing: PostedCard.gap) {
                        ForEach(rows.prefix(PostedCard.tiles)) { s in
                            PostedStoryTile(story: s) { openPosted() }
                        }
                    }
                    .padding(.horizontal, PostedCard.pad)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, PostedCard.pad)
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: ProfileCard.corner,
                                                    style: .continuous))
    }

    /// The posted stories card's own spacing, named because his concept fixes all three and a
    /// stray number here shows up as a tile that does not reach the card's edge.
    private enum PostedCard {
        static let pad: CGFloat = 14
        /// The same air the page behind See All puts between two tiles, so the three on the card and
        /// the three at the top of that page are spaced alike.
        static var gap: CGFloat { StoryTileGrid.gap }
        /// How many fit across. The rest are behind See All.
        static let tiles: Int = 3
    }

    private func cardMessage(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 10) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            if retry {
                Button("Try Again") { stories.invalidate(); Task { await loadStories() } }
                    .font(.subheadline.weight(.semibold))
                    .tint(GlowStyle.accent)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 150)
    }

    // MARK: - Loading

    private func load() async {
        // ⛔ THE COLOUR IS PAINTED BEFORE THE ROUND TRIP, NOT AFTER IT — owner, 2026-09-02: "first
        // time I enter my profile my colour never appears, after seconds it appears".
        //
        // ⚠️ IT WAS QUEUED BEHIND A FETCH IT DID NOT NEED. Every read of the palette below sat after
        // `await ProfileStore.shared.fetch(uid)`, so even a palette this device had already computed
        // and cached waited on a network answer to a question it was not asking — the photo's URL
        // arrived with the push (`initialPhoto`) and was in hand the whole time. Until that returned
        // the page fell back to `Theme.bg(true)`, which is the flat dark he saw, and then repainted.
        //
        // Cached: synchronous, so the first frame is already the right colour. Not cached: resolved
        // in its own task, so it lands when it lands instead of adding itself to the fetch's wait.
        if palette == nil, let url = initialPhoto, !url.isEmpty {
            if let hit = ProfilePalette.cached(for: url) {
                palette = hit
            } else {
                Task { palette = await ProfilePalette.resolve(url: url) }
            }
        }
        // ⛔ THE HANDLE AND THE BIO ARE PAINTED BEFORE THE ROUND TRIP TOO — owner, 2026-09-02: "when
        // I click my profile the bio and username appear AFTER opening the page".
        //
        // Same shape as the palette above and the same cause: `profile` was only ever set from the
        // network fetch, so the page opened with the name it was pushed with and nothing else, then
        // grew a handle and a bio when the answer came back. On MY OWN profile that wait is for
        // information already sitting in memory.
        //
        //   • mine  → `ProfileStore.me`, synchronous, already loaded and kept current.
        //   • other → `cachedPeer`, Firestore's on-disk copy with no network. Its own note says it
        //             exists for exactly this: "lets a profile paint its @handle and bio on the
        //             first frame for anyone we've loaded before, instead of the bio arriving a
        //             moment later and shoving the whole page down".
        if profile == nil {
            if isMe {
                profile = ProfileStore.shared.me
            } else if let hit = await ProfileStore.shared.cachedPeer(uid) {
                profile = hit
            }
        }
        if let p = await ProfileStore.shared.fetch(uid) {
            profile = p
            // The server's photo may differ from the one the push carried (changed since, or none
            // was passed), so this still runs — it is the correction, no longer the first paint.
            //
            // ⚠️ NOT `cached(...) ?? (await resolve(...))`. The right side of `??` is an AUTOCLOSURE,
            // which cannot be async — "'async' call in an autoclosure that does not support
            // concurrency". Written out, the cheap synchronous hit still short circuits the round
            // trip, which was the whole point of the `??`.
            if let url = p.photoUrl, !url.isEmpty, url != initialPhoto {
                if let hit = ProfilePalette.cached(for: url) {
                    palette = hit
                } else {
                    palette = await ProfilePalette.resolve(url: url)
                }
            }
        } else if profile == nil {
            failed = true
        }
        await loadStories()
    }

    /// The three uids whose faces the card draws, as a key.
    ///
    /// ⛔ THE FACES USED TO LOAD ONCE, INSIDE `load()`, AND THAT IS WHY HE SAW THE GLYPH — owner,
    /// 2026-09-02: "remove the icon on my profile, change it to 3 people avatars; that icon should
    /// only show when glowers is 0". His card said 4 Glowers and drew the fallback anyway.
    ///
    /// ⚠️ IT WAS A RACE, NOT A MISSING FEATURE. `load()` runs in `.task`, which fires on the first
    /// frame — often before `GlowService`'s two listeners have delivered anything. So `ids` was
    /// empty, the loader was asked for nobody, and it recorded that as its loaded answer; when the
    /// relationship arrived a moment later nothing asked again. Keyed on the relationship instead,
    /// so the arrival IS the trigger — the same fix the Stories page's `hasGlowGrid` needed.
    private var faceKey: String {
        isMe ? Array(glow.glowRelationship).sorted().prefix(3).joined(separator: ",") : ""
    }

    private func loadFaces() async {
        guard isMe else { return }
        let ids = Array(glow.glowRelationship).sorted().prefix(3)
        await faces.load(Array(ids), key: "faces-" + faceKey)
    }

    /// Open the story set this rail is showing.
    ///
    /// ⚠️ THE WHOLE SET, NOT THE ONE TILE. `StoryDoor` opens a person's group and pages through it;
    /// there is no "start at index three" and inventing one would be a second way into the viewer.
    /// Opening the group is what the story row does from every other surface in the app, and the
    /// viewer starts on the first unseen story, which is the answer somebody tapping a rail wants
    /// far more often than "this exact one".
    ///
    /// ⚠️ TWO DOORS BECAUSE THERE ARE TWO SITUATIONS. My own stories are already in memory as a
    /// group; somebody else's have to be fetched and mapped, which is what `GlowStoryOpen` does.
    private func openPosted() {
        if isMe {
            guard let mine = StoriesRepository.shared.mine, !mine.stories.isEmpty else { return }
            StoryDoor.open(mine, among: [mine], from: mine.id, pinned: true, deliveredToMe: true)
        } else {
            let p = GlowPerson(id: uid,
                               name: profile?.name ?? initialName,
                               handle: profile?.handle ?? "",
                               photoUrl: profile?.photoUrl ?? initialPhoto)
            Task { await GlowStoryOpen.open(p) }
        }
    }

    private func loadStories() async {
        await stories.load(uid: uid)
        await stories.loadViewCounts(isMe: isMe)
    }
}

/// The two-list destination behind the stats card. A tiny screen on purpose: his spec asks for both
/// values to be tappable, and one push carrying a segmented pair is fewer taps than two rows.
/// The stats card pushes straight to the list now — the list owns its own tabs (his fourth
/// reference), so the wrapper that used to carry a segmented picker above it is gone.

/// One story in the profile's rail: the poster, and the view badge from his screenshot.
/// The corner the card's tiles and the page's tiles share, so a story keeps its shape when he
/// taps See All. The number itself lives on `StoryTileGrid`, with the rest of the tile geometry.
enum PostedTile {
    static var corner: CGFloat { StoryTileGrid.corner }
}

struct PostedStoryTile: View {
    let story: PostedStory
    /// ⛔ THE TILE OPENS THE STORY — owner, 2026-09-02: "when I click a story it is not opening,
    /// fix". It never could: this was a plain `ZStack` inside a `ForEach`, with no button and no
    /// gesture anywhere on it. Nothing was broken; the tap had simply never been wired.
    ///
    /// Nil leaves the tile inert, which is what a screen that only displays them wants.
    var onTap: (() -> Void)? = nil

    init(story: PostedStory, onTap: (() -> Void)? = nil) {
        self.story = story
        self.onTap = onTap
    }

    var body: some View {
        Button { onTap?() } label: { tile }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
    }

    /// ⛔ NO FIXED WIDTH ANY MORE — his concept, 2026-09-09. The tile was 104 by 150 because it
    /// lived on a rail that scrolled; it now takes whatever share of the card three tiles and two
    /// gaps leave, and its height follows from the story shape the rest of the app uses, so the
    /// same picture is the same shape here, on the grids and on the page behind See All.
    ///
    /// ⚠️ THE COUNT LOST ITS CAPSULE. His image reads it as plain white on the picture, so what
    /// carries it now is a short gradient along the bottom edge. A scrim is what keeps it legible
    /// over a bright photograph; the capsule was doing that job and is the thing his picture does
    /// not have.
    private var tile: some View {
        // ⛔ THE SHAPE IS DECIDED BY AN EMPTY BOX, NOT BY THE PICTURE — his report, 2026-09-09:
        // "fix images looks long". A `.frame(maxWidth:)` followed by `.aspectRatio(_, .fit)` asks
        // the IMAGE to solve its own shape against an unbounded height, so a tall photograph kept
        // its own proportions and the tile grew with it. Three tiles of different heights in one
        // row is what he is looking at.
        //
        // `Color.clear` carrying the aspect ratio is the layout-defining view, and the picture fills
        // it as an overlay — the same recipe `ChatWallpaperBackground` uses, and for the same reason:
        // a fill must never be allowed to feed layout back.
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(GlowStoryCardView.aspect, contentMode: .fit)
                .overlay { StoryImage(url: story.thumbUrl).scaledToFill() }
                .clipped()

            if story.views != nil {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: 52)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if let v = story.views {
                Label(GlowCount.short(v), systemImage: "eye.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
            }

            if story.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: PostedTile.corner, style: .continuous))
    }
}

/// Keeps the interactive pop gesture alive on a page whose picture runs under the navigation bar.
///
/// ⚠️ IT WAS WRITTEN FOR A PAGE WITH NO BAR AT ALL and the bar came back on 2026-09-09, so the
/// system now hands this page a back item and the gesture with it. What is left that is still ours
/// is the simultaneous recognition below, which lets the edge drag run without having to win a
/// fight with the page's own scrolling.
///
/// ⚠️ THE DELEGATE IS BORROWED AND PUT BACK. A `UINavigationController`'s pop recognizer is one
/// object shared by every page on the stack, so taking its delegate and walking away would hand our
/// answer to whatever screen came next. The old delegate is remembered on the way in and restored on
/// the way out, which is also why this is a controller rather than a `.onAppear`.
///
/// ⚠️ `viewControllers.count > 1` IS THE WHOLE POLICY. Swiping on the root of a stack with nothing
/// to pop is what freezes a navigation controller mid-transition, and the system's own delegate
/// exists to say no to exactly that.
private struct RestoreSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Holder { Holder() }
    func updateUIViewController(_ vc: Holder, context: Context) {}

    final class Holder: UIViewController, UIGestureRecognizerDelegate {
        private weak var previous: UIGestureRecognizerDelegate?
        private var claimed = false

        /// The nav controller is not ours — this view is buried in the SwiftUI hosting tree, so the
        /// stack sits somewhere above us and the depth is not fixed.
        private var nav: UINavigationController? {
            var p: UIViewController? = self
            while let cur = p {
                if let n = cur.navigationController { return n }
                p = cur.parent
            }
            return nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !claimed, let pop = nav?.interactivePopGestureRecognizer else { return }
            previous = pop.delegate
            pop.delegate = self
            pop.isEnabled = true
            claimed = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard claimed, let pop = nav?.interactivePopGestureRecognizer else { return }
            pop.delegate = previous
            claimed = false
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1
        }

        /// The page scrolls, and a horizontal drag from the edge must not have to win a fight with
        /// it. Letting the two run together is what makes the swipe feel native here.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
