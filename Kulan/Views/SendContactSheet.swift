import SwiftUI
import UIKit

// "Share with" — the sheet that sends a profile link into one or more chats.
//
// ⛔ REDESIGNED 2026-08-21 TO HIS REFERENCE, WHICH HE ASKED TO BE FOLLOWED EXACTLY. Three things
// moved and they are all in the frame he sent:
//
//   • A HEADER ROW, not a search field. A glass search circle on the left, a two-line title in the
//     middle ("Share with" over "Select chats"), a glass share circle on the right. The field only
//     appears when the circle is tapped — the reference opens on faces, not on a keyboard prompt,
//     because the thing you want is nearly always in the first row.
//   • FIVE PER ROW, not four. That is what makes three rows of people fit above the fold, which is
//     the shape of the whole sheet: you see fifteen chats without scrolling.
//   • ONE WIDE BUTTON AT THE BOTTOM, not a row of small circles. Copy Link fills the width.
//
// ⚠️ THE BOTTOM BUTTON HAS A SECOND STATE AND THE REFERENCE CANNOT SHOW IT. His frame has nobody
// selected, so it reads "Copy Link"; the moment a face is picked that button is the only way to
// send, because the redesign removed the send arrow that used to live in the old bottom row. So it
// becomes Send. Without that, picking somebody would do nothing at all.
struct SendContactSheet: View {
    let contactText: String   // e.g. "Chat with Kasim on Fariin: kulan://u/abdi1"

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var searching = false
    @State private var selected = Set<String>()
    @State private var sending = false
    @State private var copied = false
    @State private var showSystemShare = false
    /// The grid's own width, so the bottom button can line its edges up with the avatar circles
    /// rather than with the page margin. See `sideInset`.
    @State private var gridWidth: CGFloat = 0
    @FocusState private var searchFocused: Bool
    /// Told what was sent and to whom, so the page underneath can say so. The sheet does not show it
    /// itself — it is closing, and a message that leaves with the thing it is about is not a message.
    var onSent: (String) -> Void = { _ in }

    /// ⛔ LIGHT MODE NEEDS DIFFERENT PAINT ON THE QUIET BUTTON, and this is the risk I flagged when
    /// the fill went from a blue wash to a neutral one (owner 2026-08-22: "in dark mode it is good,
    /// in light mode the grey I cannot see very well… also make the text black").
    ///
    /// White on a translucent wash works over a dark sheet and disappears over a light one — the
    /// wash has no colour of its own to push against. So light mode gets a fill with real presence
    /// and ink to match it, and dark mode keeps exactly what he already approved.
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { ((Flags.groupsEnabled && $0.isGroup) || !$0.otherUid(me).isEmpty) && !$0.isCleared(me) && (Flags.groupsEnabled || !$0.isGroup) }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching { searchRow.transition(.move(edge: .top).combined(with: .opacity)) }
            peopleGrid
            // ⚠️ GONE WHILE THE KEYBOARD IS UP (owner 2026-08-22). The sheet is lifted above the
            // keys as one piece, so this button was not hidden BY the keyboard — it was parked on
            // top of it, eating the room the search results need while you are still typing.
            //
            // Safe to drop rather than disable: picking anybody goes through `toggle(_:)`, which
            // already resigns the field for exactly this reason, so the moment the button has
            // something to send the keyboard is on its way down and the button is on its way back.
            if !searchFocused {
                bottomButton.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: searching)
        .animation(.easeOut(duration: 0.2), value: searchFocused)
        // ⛔ NO `presentationBackground` AT ALL, AND THE ABSENCE IS THE FIX.
        //
        // This line has now been `.regularMaterial` (read as grey), then `.ultraThinMaterial` (still
        // read as grey), and the reason neither worked is that BOTH of them replace the sheet's own
        // chrome. A system sheet on iOS 26 already draws Liquid Glass; setting any background at all
        // — material or colour — takes that away and paints a flat pane where the glass was. Two
        // rounds of picking a thinner material were two rounds of choosing between shades of the
        // wrong thing.
        //
        // His instruction, 2026-08-21: "make it liquid glass exactly like chat wallpaper sheet". So
        // the answer is literally what that sheet does — `WallpaperPickerSheet` sets no presentation
        // background whatsoever, keeps `.presentationDragIndicator(.visible)`, and lets the system
        // own the surface. Copied here by deleting rather than by adding.
        //
        // ⚠️ DO NOT PUT A MATERIAL BACK TO "FIX" CONTRAST. If the names are ever hard to read over a
        // busy photograph, the fix is on the labels (a shadow), not on the surface — covering the
        // glass is what he has rejected twice.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(sending)
        // ⛔ NO SPINNER (owner 2026-08-22: "when I send, it is loading — no need loading"). A wheel
        // over the faces said "wait" for something nobody is waiting on: the sheet is about to close
        // and the sending is the app's problem, not his. The confirmation now arrives afterwards, on
        // the page he lands back on, which is where it is actually read — see `onSent`.
        //
        // `sending` still guards the button and the drag-to-dismiss, so a double tap cannot send
        // twice; it simply no longer draws anything.
        .sheet(isPresented: $showSystemShare) { SystemShareSheet(items: [link]) }
    }

    // MARK: - Header

    /// Search · title · share. The two circles are the same size and the same glass, so the title
    /// sits centred between two equal weights rather than being pushed off by one heavy corner.
    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("Share with").font(.system(size: 17, weight: .semibold))
                Text("Select chats").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack {
                circleButton(searching ? "xmark" : "magnifyingglass") {
                    searching.toggle()
                    if searching { searchFocused = true } else { query = ""; searchFocused = false }
                }
                Spacer()
                circleButton("square.and.arrow.up") { showSystemShare = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func circleButton(_ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .liquidGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Only on screen once the search circle is tapped — see the note at the top.
    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .liquidGlass(Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - The people

    /// ⛔ FOUR ACROSS (his order, 2026-08-21). It was five, counted off his own earlier reference
    /// frame, and he has changed it having seen ours at the reference's real 60pt avatar.
    ///
    /// The two decisions are connected and that is worth saying: at five, a 60pt avatar left about
    /// 3pt of slack per side and the faces nearly touched. At four the cell is roughly 84pt, so the
    /// same 60pt avatar sits with about 12pt either side — which is close to what the reference's
    /// own grid gives it. The avatar size does NOT change with this; `face` stays 60 and `sideInset`
    /// re-derives itself, so the first face still lines up under the header's search button.
    private static let perRow = 4
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: gutter), count: perRow)
    private static let gutter: CGFloat = 8
    private static let pageInset: CGFloat = 16

    /// ⛔ 60. THEIR NUMBER, FLAT, AND THE 52 THAT STOOD HERE WAS REASONED FROM A LAYOUT THEY DO NOT USE.
    ///
    /// The note this replaces argued that their 60pt avatar lives in an 86pt cell, that the avatar is
    /// therefore 0.70 of its cell, and that five across on a 393pt phone leaves only 66pt of cell — so
    /// holding the RATIO meant shrinking the avatar to 52. Every one of those numbers is real. The
    /// conclusion still does not follow, because their cell has two avatar frames and the reasoning
    /// only ever looked at one:
    ///
    ///     let iconFrame = CGRect(x: 13.0, y: 4.0, width: 60.0, height: 60.0)                 // 86pt cell
    ///     let iconFrame = CGRect(x: (bounds.width - 60.0) / 2.0, y: 4.0, width: 60.0, height: 60.0)
    ///
    /// The second is the one that runs when the cell is not 86 wide, and it CENTRES a 60pt avatar in
    /// whatever width it is given. The size is a constant in both. So their avatar does not scale with
    /// the cell at all, the 0.70 ratio is an artifact of one particular width, and five across on a
    /// phone gives them exactly what it gives us: 60pt faces with the slack spent on the gaps.
    ///
    /// Owner, 2026-08-21, holding the two sheets side by side: "avatars look too small, I think it is
    /// 60pt, check first". He was right, and this is the check.
    ///
    /// The name is 11pt regular and the gap is 4pt, which ARE their numbers exactly, and `sideInset`
    /// re-derives itself from this constant so the first face still lines up with the header button.
    private static let face: CGFloat = 64   // owner 2026-08-22, up from 60

    private var peopleGrid: some View {
        // THE ORDER IS THE CHAT LIST'S: `people` sorts on `displayUpdatedAt`, the same key MainShell
        // sorts the chat list by, so the most recent conversation is first here for the same reason
        // it is first there. Not alphabetical, not arbitrary.
        ScrollView {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
                ForEach(people) { c in
                    Button { toggle(c.id) } label: { personTile(c) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Self.pageInset)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { gridWidth = $0 }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func personTile(_ c: Conversation) -> some View {
        let picked = selected.contains(c.id)
        VStack(spacing: 4) {   // their gap, from source: avatar, 4pt, name
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: Self.face)
                    .overlay {
                        // The ring is the selection, not a tick floating over a face.
                        Circle().strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 3)
                    }
                if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: Self.face, height: Self.face)
            HStack(spacing: 2) {
                Text(c.displayName(me))
                    // ⚠️ 13, UP FROM 11 — AND I TOOK IT THE WRONG WAY FIRST. His "also name add size"
                    // alongside the 64pt avatars meant make it BIGGER; I read it as "add a small
                    // size" and took it to 10, which is what he then could not read (2026-08-22).
                    //
                    // A name under a 64pt face is not a caption to be tucked away, it is the only
                    // thing telling you who you are about to send to.
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                if !c.isGroup { VerifiedMark(uid: c.otherUid(me), size: 9) }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - The one button

    /// ⛔ WHERE THE AVATARS ACTUALLY START, which is not where the page margin is.
    ///
    /// His second note: the Copy Link button's left and right edges must line up with the circles
    /// above it. They did not, and the reason is that a `.flexible()` column is wider than the
    /// avatar in it — the first face is centred in its cell, so it begins a few points inside the
    /// margin the grid itself is padded to. A button padded to the same 16 therefore reaches past
    /// every circle above it on both sides.
    ///
    /// The gap is the cell's own leftover, halved. Measured rather than assumed: the grid reports
    /// its width and the cell is that width less the two page insets and the four gutters, over
    /// five — the same arithmetic `columns` performs, from the same numbers, so the two cannot drift.
    private var sideInset: CGFloat {
        guard gridWidth > 0 else { return Self.pageInset }
        // Derived from `perRow` rather than written out, because this arithmetic and `columns` have
        // to agree and they drifted the last time the count changed by hand.
        let cell = (gridWidth - Self.pageInset * 2 - Self.gutter * CGFloat(Self.perRow - 1)) / CGFloat(Self.perRow)
        return Self.pageInset + max(0, (cell - Self.face) / 2)
    }

    /// ⛔ ONE WIDE BUTTON, which in his frame says Copy Link. It says Send once anybody is picked,
    /// because the redesign took away the row of small circles that used to hold the send arrow and
    /// this is now the only way to send — a selection with no way to act on it is worse than either
    /// design. Tinted rather than grey when it sends, so the two states are not one button that
    /// silently changed its mind.
    private var bottomButton: some View {
        Button {
            if selected.isEmpty { copyLink() } else { Task { await sendAll() } }
        } label: {
            Text(selected.isEmpty ? (copied ? "Copied" : "Copy Link")
                                  : "Send to \(selected.count)")
                .font(.system(size: 17, weight: .semibold))
                // ⛔ WHITE IN BOTH STATES (his order, 2026-08-21). It was the accent colour while
                // nothing was picked, which made "Copy Link" the only blue text on a sheet whose
                // every other label is white — it read as a link inside a button rather than as the
                // button's own title. The tinted fill behind it already says the button is the
                // quieter of the two states; the text does not have to say it twice.
                // Black on the light-mode Copy Link, white everywhere else — on the blue Send in
                // both themes, and on the dark-mode wash his 2026-08-21 white-text rule was about.
                .foregroundStyle(selected.isEmpty && !dark ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                // ⛔ GREY WHILE IT COPIES, BLUE ONCE IT SENDS (owner 2026-08-22: "make it grey
                // after select, send button blue, don't touch that"). The quiet state was a wash of
                // the accent colour, which made the resting button a paler version of the acting one
                // — two blues saying different things. A neutral wash says "this is the other thing
                // you could do" without borrowing the send button's meaning.
                //
                // `tertiarySystemFill` rather than a grey of ours: it is the system's own wash for
                // exactly this, it follows the theme, and it carries the same visual weight as the
                // 0.14 it replaces, so nothing but the hue changes.
                // ⚠️ `systemGray3`, TWO STEPS DARKER THAN MY FIRST ANSWER (owner 2026-08-22: "that
                // button you made too white, make it grey"). `systemGray5` is 229 of 255 — a grey on
                // paper, and effectively white against the pale glass this sheet actually sits on.
                // The sheet's own tint is what decides whether a light grey reads as grey at all, and
                // it does not. 199 does.
                //
                // Dark keeps the system's own wash, which reads perfectly well there and is what he
                // signed off.
                .background(selected.isEmpty
                            ? (dark ? Color(.tertiarySystemFill) : Color(.systemGray3))
                            : Color.accentColor,
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .animation(.easeOut(duration: 0.18), value: selected.isEmpty)
        // ⛔ THE AVATARS EDGES, NOT THE PAGE MARGIN. See sideInset above.
        .padding(.horizontal, sideInset)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func copyLink() {
        UIPasteboard.general.string = link
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.18)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.18)) { copied = false }
        }
    }

    /// Just the url. `contactText` is the sentence that goes into a CHAT bubble; a clipboard or
    /// another app wants the link on its own, or whoever pastes it gets our sentence too.
    private var link: String {
        contactText.split(separator: " ").last.map(String.init) ?? contactText
    }

    private func toggle(_ id: String) {
        // ⚠️ AND IT DROPS THE KEYBOARD. Send lives in the button the keyboard hides, so picking
        // somebody while searching would otherwise select them into a control you cannot see.
        // Tapping a face means you have found who you were looking for; the search is over.
        searchFocused = false
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func sendAll() async {
        sending = true
        // The first name is captured BEFORE the sending, while the selection is still whole and in
        // the order the grid shows it — afterwards there is nothing left to name.
        let firstName = selected.compactMap { id in
            repo.conversations.first { $0.id == id }
        }.first.map { $0.displayName(me) } ?? "chat"
        let count = selected.count
        for cid in selected {
            let conv = repo.conversations.first { $0.id == cid }
            try? await ChatService.sendText(cid: cid, text: contactText,
                                            group: conv?.isGroup == true ? conv?.users : nil)
        }
        sending = false
        onSent(Self.sentMessage(first: firstName, count: count))
        dismiss()
    }

    /// "Link sent to Vzet and 5 other chats." — his wording, 2026-08-22.
    ///
    /// Singular and plural both spelled out rather than an "s" glued on a number: one other chat is
    /// a sentence people read, and "1 other chats" is the kind of thing that makes an app look
    /// unfinished for the sake of one branch.
    static func sentMessage(first: String, count: Int) -> String {
        switch count {
        case ..<1:  return "Link sent."
        case 1:     return "Link sent to \(first)."
        case 2:     return "Link sent to \(first) and 1 other chat."
        default:    return "Link sent to \(first) and \(count - 1) other chats."
        }
    }
}

/// UIActivityViewController bridge. `ShareLink` is a button, and this row needs to PRESENT one from
/// a tap. There is an identical private bridge in `OfficialChatView`; it is private, so this is a
/// second one rather than a shared type nothing else asked for.
struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
