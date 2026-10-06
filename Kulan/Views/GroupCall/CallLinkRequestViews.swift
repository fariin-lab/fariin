import SwiftUI
import UIKit

// Link calls with "Require approval to join" on: the people knocking, as the link's creator sees
// them (owner, 2026-10-06: the reference app's look; before this the screen had a "N waiting"
// capsule that opened a list). Three pieces:
//   CallLinkRequestStack        the card(s) directly above the call controls
//   CallLinkBulkRequestsSheet   everyone waiting, with Approve All / Deny All
//   the details sheet           a tap on a card's name or photo: who is asking, large
// Every answer goes through GroupCallService (`answerRequest`, `answerAllRequests`). The service
// takes a person off `pendingRequests` before it asks the server, so a second tap on the same
// card finds nobody to answer and does nothing.

// MARK: - The cards above the controls

/// The join requests above the call controls. One person waiting: one card. Two: the second
/// one's card sits behind the first, a little smaller, its top edge showing. Three or more: the
/// first one's card and a "N more" capsule that opens the whole list.
/// Always in the layout and 0pt tall with nobody waiting, so the sheets it presents and its
/// animations have a home that does not come and go with the cards.
struct CallLinkRequestStack: View {
    @ObservedObject private var service = GroupCallService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is drawn. The service's list is taken over inside an animation (`take`), so the cards
    /// and whatever sits around them on the call screen move together.
    @State private var shown: [CallMember] = []
    @State private var details: CallMember?
    @State private var showAll = false
    /// When I last answered someone here (see `answer`).
    @State private var answeredAt = Date.distantPast
    /// Space kept under the cards, and only while there are cards. A stack with spacing would put
    /// its gap around this view even when it is empty; the screen can mount it with no spacing
    /// and pass the gap here instead, where it opens and closes with the cards' own animation.
    private let gapBelow: CGFloat

    init(gapBelow: CGFloat = 0) {
        self.gapBelow = gapBelow
    }

    /// The reference's spring for every change of the stack: quick, no bounce.
    private static let spring: Animation = .spring(response: 0.3, dampingFraction: 1)
    /// A card comes in from 12pt below; an answered one leaves upwards. Both fade.
    private static let slide: AnyTransition = .asymmetric(
        insertion: AnyTransition.offset(y: 12).combined(with: .opacity),
        removal: AnyTransition.move(edge: .top).combined(with: .opacity))
    /// How much of the second card shows above the first.
    private static let peek: CGFloat = 8

    /// Only the link's creator is sent requests; anyone else has nothing to draw.
    private var waiting: [CallMember] { service.isLinkCreator ? service.pendingRequests : [] }

    /// One or two people get a card each; from three on, only the first.
    private var cards: [CallMember] { shown.count > 2 ? Array(shown.prefix(1)) : shown }
    /// From three on: how many wait besides the one on the card.
    private var moreCount: Int { shown.count > 2 ? shown.count - 1 : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            // By uid: the front card is the same view while people come and go behind it.
            ForEach(cards) { person in card(person) }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, shown.isEmpty ? 0 : gapBelow)
        .onAppear { shown = waiting }
        .onChange(of: waiting) { _, now in take(now) }
        .sheet(item: $details) { person in
            CallLinkRequestDetailsSheet(person: person) { approve in
                details = nil
                answer(person.uid, approve)
            }
        }
        .sheet(isPresented: $showAll) { CallLinkBulkRequestsSheet() }
    }

    private func card(_ person: CallMember) -> some View {
        let two = cards.count == 2
        let isBack = two && person.uid == cards.last?.uid
        let isFront = two && !isBack
        // VoiceOver reads the front card only; it says there who waits behind it.
        let behind: String? = isFront ? cards.last?.name : nil
        return CallLinkRequestCard(
            person: person,
            moreCount: moreCount,
            alsoWaiting: behind,
            onDetails: { details = person },
            onAnswer: { approve in answer(person.uid, approve) },
            onMore: { showAll = true }
        )
        // The peek is exact at any text size: the front card starts 8pt lower, and the one
        // behind shrinks towards its own top edge, so those 8pt are all that shows of it.
        .padding(.top, isFront ? Self.peek : 0)
        .scaleEffect(isBack ? 0.95 : 1, anchor: .top)
        // An answered front card leaves over the card that takes its place, not under it.
        .zIndex(isFront ? 2 : (isBack ? 1 : 0))
        // The card behind is covered: its buttons must not take a touch meant for the front one.
        .allowsHitTesting(!isBack)
        .accessibilityHidden(isBack)
        .transition(reduceMotion ? AnyTransition.opacity : Self.slide)
    }

    private func take(_ now: [CallMember]) {
        withAnimation(reduceMotion ? GroupCallMotion.fade : Self.spring) { shown = now }
        // The person whose details are open was answered on another device, or stopped waiting.
        if let open = details, !now.contains(where: { $0.uid == open.uid }) { details = nil }
    }

    /// The next person's card comes in under the same finger, so a double tap on the green check
    /// would let in someone the creator has not seen yet. An answer this soon after the last one
    /// is dropped; the card stays, and a tap that was meant is simply made again.
    private func answer(_ uid: String, _ approve: Bool) {
        let now = Date()
        guard now.timeIntervalSince(answeredAt) >= CallLinkAnswerButtons.minGap else { return }
        answeredAt = now
        Task { await service.answerRequest(uid: uid, approve: approve) }
    }
}

// MARK: - One card

/// One request: photo, name, "Would like to join", and the two answers. Dark at any appearance,
/// like the rest of the call screen.
private struct CallLinkRequestCard: View {
    let person: CallMember
    /// People waiting besides this one. Above zero the card grows the "N more" capsule.
    let moreCount: Int
    /// Two cards: the name on the card behind this one, for VoiceOver.
    let alsoWaiting: String?
    let onDetails: () -> Void
    let onAnswer: (Bool) -> Void
    let onMore: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var whoLabel: String {
        if let other = alsoWaiting {
            return "\(person.name) would like to join. \(other) is also waiting."
        }
        return "\(person.name) would like to join"
    }
    private var moreLabel: String { "\(moreCount) more waiting to join" }

    var body: some View {
        VStack(spacing: 0) {
            row
            if moreCount > 0 { moreRow }
        }
        .foregroundStyle(.white)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private var row: some View {
        HStack(spacing: 8) {
            // Photo and name are one button: who is this, before I let them in.
            Button(action: onDetails) { who }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(whoLabel)
                .accessibilityHint("Shows who is asking")
                .accessibilityAddTraits(.isButton)
            Spacer(minLength: 8)
            CallLinkAnswerButtons(name: person.name, onAnswer: onAnswer)
        }
        // 8 on the trailing side: the last touch target reaches 4pt past its circle, which
        // leaves the circle the same 12 from the edge as the photo.
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
    }

    private var who: some View {
        HStack(spacing: 8) {
            AvatarView(name: person.name, photoUrl: person.photoUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(person.name).lineLimit(1)
                    Image(systemName: "chevron.forward").font(.caption.weight(.bold))
                }
                .font(.body.bold())
                Text("Would like to join")
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var moreRow: some View {
        Button(action: onMore) {
            Text("\(moreCount) more")
                .contentTransition(.numericText())
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.18), in: Capsule())
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .accessibilityLabel(moreLabel)
        .accessibilityHint("Shows everyone waiting")
    }
}

/// The red X and the green check, the same on a card and on a row of the list.
private struct CallLinkAnswerButtons: View {
    let name: String
    /// true = let in, false = deny.
    let onAnswer: (Bool) -> Void

    /// The shortest time between two answers to different people. An answered card or row makes
    /// way for the next one in about 0.3s, in the same place.
    static let minGap: TimeInterval = 0.5

    private var denyLabel: String { "Deny \(name)" }
    private var approveLabel: String { "Let in \(name)" }

    var body: some View {
        // 36pt circles in 44pt touch targets: 12 between the targets leaves the circles the
        // reference's 20 apart.
        HStack(spacing: 12) {
            button("xmark", tint: Color(.systemRed), approve: false)
                .accessibilityLabel(denyLabel)
            button("checkmark", tint: Color(.systemGreen), approve: true)
                .accessibilityLabel(approveLabel)
        }
    }

    private func button(_ icon: String, tint: Color, approve: Bool) -> some View {
        Button { onAnswer(approve) } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)   // two buttons in one List row: each keeps its own tap
    }
}

/// A full-width capsule button's face: "Let In" / "Deny" and "Approve All" / "Deny All".
private struct CallLinkChoiceLabel: View {
    let title: String
    let text: Color
    let fill: Color

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Who is asking

/// A tap on a card's name or photo: the person large, and the same two answers in words.
/// The stack owns the sheet: it closes it on an answer, and when that person stops waiting.
private struct CallLinkRequestDetailsSheet: View {
    let person: CallMember
    /// true = let in, false = deny.
    let onAnswer: (Bool) -> Void

    private var approveLabel: String { "Let in \(person.name)" }
    private var denyLabel: String { "Deny \(person.name)" }

    var body: some View {
        VStack(spacing: 0) {
            AvatarView(name: person.name, photoUrl: person.photoUrl, size: 88)
            Text(person.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 12)
            Text("Would like to join")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Spacer(minLength: 20)
            answers
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        // Half height holds it all on the smallest phone; .large is there for big text sizes.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var answers: some View {
        VStack(spacing: 10) {
            Button { onAnswer(true) } label: {
                CallLinkChoiceLabel(title: "Let In", text: .white, fill: Color(.systemGreen))
            }
            .accessibilityLabel(approveLabel)
            Button { onAnswer(false) } label: {
                CallLinkChoiceLabel(title: "Deny", text: Color(.systemRed), fill: Color(.tertiarySystemFill))
            }
            .accessibilityLabel(denyLabel)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Everyone waiting

/// Everyone waiting to be let in, each with the two answers, and "Approve All" / "Deny All" under
/// the list, each behind a confirmation that names how many. Opened from the "N more" capsule and
/// from the people sheet's "N waiting to join" row. Closes itself once nobody is waiting.
struct CallLinkBulkRequestsSheet: View {
    @ObservedObject private var service = GroupCallService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmApprove = false
    @State private var confirmDeny = false
    /// "Approve All" / "Deny All" is on its way to the server. Every button waits until it is
    /// back, so nobody is answered a second time by a tap made in between.
    @State private var working = false
    /// When I last answered one row (see `answer`).
    @State private var answeredAt = Date.distantPast

    init() {}

    private var waiting: [CallMember] { service.isLinkCreator ? service.pendingRequests : [] }
    private var title: String { "\(waiting.count) waiting" }
    private var approveTitle: String {
        waiting.count == 1 ? "Let 1 person in?" : "Let all \(waiting.count) people in?"
    }
    private var denyTitle: String {
        waiting.count == 1 ? "Deny 1 request?" : "Deny all \(waiting.count) requests?"
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
                .safeAreaInset(edge: .bottom) { footer }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The last person was answered, here or anywhere else: nothing left to show.
        .onAppear { if waiting.isEmpty { dismiss() } }
        .onChange(of: waiting.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private var list: some View {
        List {
            ForEach(waiting) { row($0) }
        }
        .overlay {
            // Only seen for the moment before the sheet closes itself.
            if waiting.isEmpty {
                Text("No one is waiting").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ person: CallMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: person.name, photoUrl: person.photoUrl, size: 40)
            Text(person.name).lineLimit(1)
            Spacer(minLength: 8)
            CallLinkAnswerButtons(name: person.name) { approve in
                answer(person.uid, approve)
            }
            .disabled(working)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            denyAllButton
            approveAllButton
        }
        .buttonStyle(.plain)
        .disabled(working || waiting.isEmpty)
        .opacity(working ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // Each confirmation hangs on its own button, so it opens from the button that asked for it.
    private var denyAllButton: some View {
        Button { confirmDeny = true } label: {
            CallLinkChoiceLabel(title: "Deny All", text: Color(.systemRed), fill: Color(.tertiarySystemFill))
        }
        .confirmationDialog(denyTitle, isPresented: $confirmDeny, titleVisibility: .visible) {
            Button("Deny All", role: .destructive) { answerAll(false) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var approveAllButton: some View {
        Button { confirmApprove = true } label: {
            CallLinkChoiceLabel(title: "Approve All", text: .white, fill: Color(.systemGreen))
        }
        .confirmationDialog(approveTitle, isPresented: $confirmApprove, titleVisibility: .visible) {
            Button("Approve All") { answerAll(true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// An answered row leaves and the next one moves up under the same finger: as on the cards,
    /// a second answer this soon is dropped, so a double tap never answers two people.
    private func answer(_ uid: String, _ approve: Bool) {
        let now = Date()
        guard !working, now.timeIntervalSince(answeredAt) >= CallLinkAnswerButtons.minGap else { return }
        answeredAt = now
        Task { await service.answerRequest(uid: uid, approve: approve) }
    }

    private func answerAll(_ approve: Bool) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            await service.answerAllRequests(approve: approve)
            working = false
        }
    }
}
