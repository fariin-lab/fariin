import SwiftUI

/// MESSAGE REQUESTS, AS A PAGE — owner, 2026-09-09: "Message Requests put when users click ... Chats
/// Open comtext menu inside chats and Message Requests when users click ... change page to make
/// requests message page". So: an entry in the chat list's own menu, and a page behind it.
///
/// ⚠️ THIS INVENTS NOTHING. A message request already exists and has since the feature was built —
/// see [MessageRequests], which owns the whole concept in two fields on the conversation
/// (`startedBy` and `accepted`) and answers "what is this chat" with one value. A conversation whose
/// stance is `.incoming` IS a message request, everywhere in the app, and that is the exact set this
/// page lists. There is no requests collection, no mirrored inbox and nothing new stored for this
/// screen, so the page cannot come to disagree with the thread, the chat list or the rules.
///
/// ⛔ IT DOES NOT REPLACE THE BAR INSIDE THE CONVERSATION. His original spec put Accept and Delete
/// "inside the conversation" rather than in a separate inbox, and ThreadView's `requestBar` still
/// does that. This page is a way to FIND them, not a second place to answer them: tapping a row
/// opens the chat, where the bar already is. Accept and Delete are also on the swipe and the long
/// press here, because a list you open in order to clear it should let you clear it — both call the
/// same two functions the bar calls, so there is one implementation of each answer.
///
/// ⚠️ AN ARCHIVED REQUEST IS STILL A REQUEST, AND THAT IS THE REASON THIS PAGE EARNS ITS KEEP.
/// Settings > Chats > "Automatically Archive New Chats From Unknown Users" moves a request into the
/// archive and mutes it (`UnknownChatArchiver`). Filtering on `isArchived` the way the chat list does
/// would hand an empty page to the one person most likely to come looking for this — the person who
/// turned that setting on. So the archive is deliberately NOT filtered out here.
struct MessageRequestsView: View {
    /// ⚠️ PUSHED INSIDE THE CHAT LIST'S STACK, so this view builds no `NavigationStack` and declares
    /// no `navigationDestination` of its own. Two registrations for `ChatTarget` in one stack is a
    /// fight over which one answers the push — the same rule, and the same reason, written on
    /// `ArchivedChatsView`. The tap goes up to the chat list, which owns the destination.
    let onOpenChat: (ChatTarget) -> Void

    /// ⚠️ SPELLED OUT. Every other stored property below is `private`, which makes the synthesised
    /// memberwise initializer private too — and `private` does not reach the view that presents this
    /// one, even in the same module. Without this, `MessageRequestsView(onOpenChat:)` resolves to
    /// nothing and the compiler says the call takes no arguments. `ArchivedChatsView` carries the
    /// same init for the same reason; it has cost this project a CI round trip before.
    init(onOpenChat: @escaping (ChatTarget) -> Void) {
        self.onOpenChat = onOpenChat
    }

    /// `@Observable`, so a plain stored property is the whole subscription: reading `conversations`
    /// inside `body` is what registers this view for the next snapshot. ⛔ NOT `@ObservedObject` —
    /// this app's views that reach for `ObservableObject` draw once and then freeze.
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    /// The question, not the answer — the alert reads it and the destructive button acts on it. Same
    /// shape as the chat list's own `pendingDelete`.
    @State private var pendingDecline: Conversation?

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    /// Every conversation the app already treats as somebody's unanswered request to me.
    ///
    /// The stance test carries most of this on its own: it refuses groups, refuses a chat from
    /// before requests existed, refuses an accepted one, and refuses a chat that was opened but never
    /// written in — so nothing here has to re-state any of that, and none of it can drift out of step
    /// with the thread. Two filters are ours:
    ///
    ///   • BLOCKED IS OUT. Blocking is a separate action from declining, on purpose, but a person I
    ///     have blocked is not waiting on an answer from me and their name does not belong on a page
    ///     whose whole job is "who is waiting". The chat list and the tab badge exclude them too.
    ///   • CLEARED IS OUT, matching the chat list. `isCleared` is a timestamp comparison, so a new
    ///     message from them un-clears it and the request comes back — which is the behaviour that
    ///     is wanted, rather than a deletion that hides someone permanently.
    private var requests: [Conversation] {
        let me = self.me
        guard !me.isEmpty else { return [] }
        var out = repo.conversations.filter { !$0.isCleared(me) && !$0.isBlockedByMe(me) }
        out = out.filter { MessageRequests.stance($0, myUid: me) == .incoming }
        return out.sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        List {
            ForEach(requests) { conv in
                requestRow(conv)
            }
        }
        // `.plain`, like the archive — the other pushed page that lists these same rows. A grouped
        // list paints every cell on `secondarySystemGroupedBackground`, and that grey card under a
        // chat row is the exact thing the owner had removed from the chat list on 2026-09-02.
        .listStyle(.plain)
        .overlay { emptyLine }
        .navigationTitle("Message Requests")
        .navigationBarTitleDisplayMode(.inline)
        // A pushed sub page has no business under the floating tab pill — ThreadView, ContactInfoView
        // and the archive all hide it, and this arrives by the same route they do.
        .toolbar(.hidden, for: .tabBar)
        .alert("Delete this request?",
               isPresented: Binding(get: { pendingDecline != nil },
                                    set: { if !$0 { pendingDecline = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = pendingDecline { Task { try? await MessageRequests.decline(c.id) } }
                pendingDecline = nil
            }
            Button("Cancel", role: .cancel) { pendingDecline = nil }
        } message: {
            // Says what it does and what it does not do. Declining is not blocking — that is its own
            // action with its own button, and quietly conflating the two would tell someone they had
            // done something they had not.
            // ...and the cooldown (owner's spec §10), so the sentence says what actually happens.
            Text("The conversation is deleted and they can’t send you another request for \(MessageRequests.declineCooldownDays) days. This does not block them.")
        }
    }

    /// One request. The chat list's own row, unchanged — a request is an ordinary conversation and
    /// showing it as anything else would be a second idea of what these are.
    @ViewBuilder private func requestRow(_ conv: Conversation) -> some View {
        Button {
            onOpenChat(ChatTarget(id: conv.id, name: conv.displayName(me),
                                  photo: conv.displayPhoto(me)))
        } label: {
            ChatRow(conv: conv, me: me, dark: dark)
                // ⚠️ BOTH LINES, OR THE ROW ONLY OPENS WHERE THE TEXT IS. A Button's target is its
                // label's shape and a bare `ChatRow` is only as wide as its content, so the empty
                // band between the preview and the date would be dead to a finger — his 2026-08-25
                // report about the archive, which had lost these same two lines.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // Accept outermost, so it is both the first button and the one a full swipe fires: saying yes
        // is what this page is for. Delete is the deliberate one, behind a confirmation.
        .swipeActions(edge: .trailing) {
            Button { Task { try? await MessageRequests.accept(conv.id) } } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .tint(.green)
            // `.tint(.red)` rather than leaving it to `role: .destructive`. The role only colours a
            // swipe action while the app has not tinted itself, and this app tints `.primary`
            // app-wide — so the button took WHITE at night and drew a white glyph on it. Every other
            // Delete in the app forces red for this reason.
            Button(role: .destructive) { pendingDecline = conv } label: {
                Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill") }
            }
            .tint(.red)
        }
        // A row with no menu keeps the press highlight it lit on touch-down, and that grey then has
        // nothing to clear it. Giving the row a menu takes the gesture and takes the highlight with
        // it — the archive's own note, learned there the hard way.
        .contextMenu {
            Button { Task { try? await MessageRequests.accept(conv.id) } } label: {
                Label { Text("Accept") } icon: { MenuIcon(system: "checkmark", ink: .label) }
            }
            Button(role: .destructive) { pendingDecline = conv } label: {
                Label { Text("Delete") } icon: { MenuIcon(system: "trash", ink: .systemRed) }
            }
            // The third answer (owner's spec §14). The same write the profile's Block makes; the
            // row leaves this page on its own because `requests` filters `isBlockedByMe`. Their
            // request is not deleted and they are not told — a blocked person's writes still land
            // and are simply never shown, which is how blocking has always worked here.
            Button(role: .destructive) { Task { await ChatService.setBlocked(conv.id, true) } } label: {
                Label { Text("Block") } icon: { MenuIcon("ic_block", ink: .systemRed) }
            }
        }
    }

    /// A line, not a picture. There is nothing to illustrate here and an empty inbox is good news.
    @ViewBuilder private var emptyLine: some View {
        if requests.isEmpty {
            Text("No message requests.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}
