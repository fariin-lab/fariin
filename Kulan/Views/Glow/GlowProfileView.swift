import SwiftUI

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
    @Environment(\.dismiss) private var dismiss
    private var glow = GlowService.shared

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
        }
        // The page is a coloured photograph whatever the phone is set to — the same rule the chat
        // with a wallpaper follows, and for the same reason: light chrome on a lit picture washes
        // out. `\.colorScheme`, never `preferredColorScheme` — see the note in ThreadView.
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    // MARK: - Header

    /// The picture, full-bleed, with the back button floating on it. His screenshot's proportions:
    /// the photograph is about the top 45% and the name sits just under it.
    private var header: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let w = geo.size.width
                Group {
                    if let url = profile?.photoUrl ?? initialPhoto, !url.isEmpty {
                        StoryImage(url: url)
                    } else {
                        // No photograph: the letter, on the palette's own card colour, so an account
                        // with no picture still gets a page rather than a hole.
                        cardColor.overlay {
                            Text(String((profile?.name ?? initialName).prefix(1)).uppercased())
                                .font(.system(size: w * 0.34, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .frame(width: w, height: w)
                .clipped()
                // The photograph melts into the page rather than ending on a line — the seam
                // `ProfilePalette` exists to kill. See its note on `page`.
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [pageColor.opacity(0), pageColor],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: w * 0.42)
                }
            }
            .frame(height: UIScreen.main.bounds.width)

            HStack {
                CircleGlyphButton(system: "chevron.left") { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    /// Name, tick, @handle, bio — his screenshot's stack, centred.
    private var identity: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(profile?.name ?? initialName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                if OfficialChannel.isOfficial(uid) { VerifiedTick(size: 20) }
                else { VerifiedMark(uid: uid, size: 20) }
            }
            .multilineTextAlignment(.center)

            if let h = profile?.handle, !h.isEmpty {
                Text("@\(h)").font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if let about = profile?.about, !about.isEmpty {
                Text(about)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
            }
            if !isMe { glowButton.padding(.top, 12) }
        }
        .padding(.top, -UIScreen.main.bounds.width * 0.10)
    }

    /// GIVE OR TAKE BACK A GLOW — the one action this page has, and the only place in the app where
    /// a glow can be given (his flow starts "User A gives User B a Glow").
    private var glowButton: some View {
        Button {
            if glow.isGlowing(uid) { glow.remove(to: uid) } else { glow.give(to: uid) }
        } label: {
            Label(glow.isGlowing(uid) ? "Glowing" : "Glow",
                  systemImage: glow.isGlowing(uid) ? "checkmark" : GlowStyle.symbol)
                .font(.headline)
                .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .tint(glow.isGlowing(uid) ? Color.white.opacity(0.18) : GlowStyle.accent)
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
        let glowers = profile?.glowerCount ?? 0
        let glowing = profile?.glowingCount ?? 0
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
                Image(systemName: GlowStyle.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GlowStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
            } else {
                HStack(spacing: -12) {
                    ForEach(facePeople.prefix(3)) { p in
                        AvatarView(name: p.name, photoUrl: p.photoUrl, size: 30)
                            .overlay(Circle().strokeBorder(cardColor, lineWidth: 2))
                    }
                }
                .frame(height: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(GlowCount.short(glowers)) Glowers  ·  \(GlowCount.short(glowing)) Glowing")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                // His reference's own second line: "by <name>, <name>". Named people beat a generic
                // sentence, and it falls back to one when there are no names yet.
                Text(byLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isMe {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    /// POSTED STORIES — a horizontal rail of live stories with a view badge, and a See All row.
    private var postedStoriesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Posted stories")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                switch stories.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).frame(height: 150)
                case .failed:
                    cardMessage("Could not load stories", retry: true)
                case .loaded(let rows) where rows.isEmpty:
                    cardMessage(isMe ? "You have no live stories." : "No live stories.", retry: false)
                case .loaded(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(rows) { s in PostedStoryTile(story: s) }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 172)
                    .padding(.top, 12)

                    Divider().overlay(Color.white.opacity(0.12)).padding(.top, 10)
                    NavigationLink {
                        PostedStoriesView(uid: uid, isMe: isMe,
                                          title: profile?.name ?? initialName)
                    } label: {
                        HStack {
                            Text("See All").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(cardColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func cardMessage(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 10) {
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.75))
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
        if let p = await ProfileStore.shared.fetch(uid) {
            profile = p
            if let url = p.photoUrl, !url.isEmpty {
                // ⚠️ NOT `cached(...) ?? (await resolve(...))`. The right side of `??` is an
                // AUTOCLOSURE, which cannot be async — "'async' call in an autoclosure that does
                // not support concurrency". Written out, the cheap synchronous hit still short
                // circuits the round trip, which was the whole point of the `??`.
                if let hit = ProfilePalette.cached(for: url) {
                    palette = hit
                } else {
                    palette = await ProfilePalette.resolve(url: url)
                }
            }
        } else if profile == nil {
            failed = true
        }
        if isMe {
            let ids = Array(glow.glowRelationship).sorted()
            await faces.load(Array(ids.prefix(3)), key: "faces-" + ids.prefix(3).joined())
        }
        await loadStories()
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
struct PostedStoryTile: View {
    let story: PostedStory

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StoryImage(url: story.thumbUrl)
                .frame(width: 104, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let v = story.views {
                Label(GlowCount.short(v), systemImage: "eye.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
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
        .frame(width: 104, height: 150)
    }
}

/// The app's round glass glyph button, at the size this page's chrome uses. Local because the
/// design-system `CloseXButton` is an X and this needs a chevron; same 44pt metric.
private struct CircleGlyphButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
        }
    }
}
