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
            bottomButton
        }
        .animation(.easeOut(duration: 0.2), value: searching)
        // ⛔ ULTRA-THIN, NOT REGULAR (his second report on this sheet: "now looks grey plz make it
        // liquid glass").
        //
        // `.regularMaterial` IS a real material and that is exactly why it came out grey: a thick
        // material over a dark page resolves to dark grey, because there is barely any of the page
        // left in it to tint the glass. Thin is the one that carries the picture through, and a
        // material you can see the wallpaper in is what reads as glass rather than as a panel.
        //
        // ⚠️ THE COST IS THE ONE I CHOSE AGAINST THIS MORNING, and it is his call to overrule: the
        // names sit over whatever photograph is behind the sheet, and the thinner the material the
        // more of that photograph competes with them. If they turn out hard to read on a busy
        // picture, the answer is a shadow on the labels rather than going back to grey.
        .presentationBackground(.ultraThinMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(sending)
        .overlay {
            if sending {
                ProgressView().padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
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

    /// FIVE ACROSS (his reference, counted off the frame).
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: gutter), count: 5)
    private static let gutter: CGFloat = 8
    private static let pageInset: CGFloat = 16

    /// ⛔ 52, AND THE REFERENCE'S OWN 60 IS WHY IT IS NOT 60.
    ///
    /// Read from their source rather than guessed: their peer cell is a 60pt avatar sitting at x=13
    /// inside an 86pt item, with an 11pt regular name 4pt under it. So the avatar is 0.70 of its
    /// cell — that gap on each side is what stops a row of faces reading as one stripe.
    ///
    /// ⚠️ AT FIVE PER ROW THAT RATIO CANNOT SURVIVE A 60pt AVATAR, and this is the whole of his
    /// "avatar size" note. Five 86pt cells need 430pt and the widest phone gives the sheet 393. Ours
    /// were 60 in a 66pt cell — 0.91 — which is why they nearly touch in his screenshot. He asked
    /// for five per row before he asked for their sizing, so the count is kept and the avatar is
    /// scaled to their PROPORTION instead: 52 in a 66pt cell is 0.79, and 0.84 on the narrowest
    /// phone the app still runs on.
    ///
    /// The name is 11pt regular and the gap is 4pt, which ARE their numbers exactly.
    private static let face: CGFloat = 52

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
                    .font(.system(size: 11))
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
        let cell = (gridWidth - Self.pageInset * 2 - Self.gutter * 4) / 5
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
                .foregroundStyle(selected.isEmpty ? Color.accentColor : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(selected.isEmpty ? Color.accentColor.opacity(0.14) : Color.accentColor,
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
        for cid in selected {
            let conv = repo.conversations.first { $0.id == cid }
            try? await ChatService.sendText(cid: cid, text: contactText,
                                            group: conv?.isGroup == true ? conv?.users : nil)
        }
        sending = false
        dismiss()
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
