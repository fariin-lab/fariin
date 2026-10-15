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
    /// A refused Accept or Delete (offline, or the server said no). `try?` used to swallow this
    /// silently, so the row looked answered when nothing had happened; the request itself is left
    /// untouched either way, since nothing here removes it until the data actually changes.
    @State private var acceptFailed = false
    @State private var declineFailed = false
    /// ⛔ THE FIRST-TIME CARD — owner 2026-10-15, with the reference app's picture: shown the first
    /// time this page opens and never again; deleting the app and installing it again shows it again.
    /// That is exactly UserDefaults: it lives with the install and goes with it.
    @AppStorage("messageRequests.introSeen") private var introSeen = false
    @State private var showIntro = false

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
            // 2026-09-24 feature-audit: the loading state while older chats (and any request among
            // them) are still being fetched. The Archive page's own row.
            if repo.loadingWholeList {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        // 2026-09-24 feature-audit: a request whose chat sits below the newest page was unreachable
        // here. This page needs every chat, so the repository pages until there is nothing older.
        .onAppear { repo.needWholeList("requests", true) }
        .onDisappear { repo.needWholeList("requests", false) }
        // `.plain`, like the archive — the other pushed page that lists these same rows. A grouped
        // list paints every cell on `secondarySystemGroupedBackground`, and that grey card under a
        // chat row is the exact thing the owner had removed from the chat list on 2026-09-02.
        .listStyle(.plain)
        .overlay { emptyLine }
        .overlay(alignment: .bottom) {
            if showIntro {
                introCard
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            guard !introSeen else { return }
            try? await Task.sleep(for: .milliseconds(350))   // after the push has landed
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showIntro = true }
        }
        .navigationTitle("Message Requests")
        .navigationBarTitleDisplayMode(.inline)
        // A pushed sub page has no business under the floating tab pill — ThreadView, ContactInfoView
        // and the archive all hide it, and this arrives by the same route they do.
        .toolbar(.hidden, for: .tabBar)
        .alert("Delete this request?",
               isPresented: Binding(get: { pendingDecline != nil },
                                    set: { if !$0 { pendingDecline = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = pendingDecline {
                    Task {
                        do { try await MessageRequests.decline(c.id) }
                        catch { await MainActor.run { declineFailed = true } }
                    }
                }
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
        .alert("Couldn't accept", isPresented: $acceptFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
        .alert("Couldn't delete", isPresented: $declineFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
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
            Button {
                Task {
                    do { try await MessageRequests.accept(conv.id) }
                    catch { await MainActor.run { acceptFailed = true } }
                }
            } label: {
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
            Button {
                Task {
                    do { try await MessageRequests.accept(conv.id) }
                    catch { await MainActor.run { acceptFailed = true } }
                }
            } label: {
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

    /// ⛔ AN ICON, A TITLE AND A LINE — owner 2026-10-15, with the reference app's empty page: the
    /// single grey sentence read as unfinished. Its inbox glyph, a bold title, the explanation under it.
    @ViewBuilder private var emptyLine: some View {
        // 2026-09-24 feature-audit: not while older chats are still arriving; the row above says so.
        if requests.isEmpty, !repo.loadingWholeList {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)
                Text("No message requests")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Messages from people you haven't chatted with yet will appear here.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
        }
    }

    /// The first-time explanation card, the reference app's: icon, ✕, title, text, Learn more / Got it.
    private var introCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image("ic_message_request")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.primary)
                Spacer()
                Button { dismissIntro() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .offset(x: 10, y: -8)
            }
            Text("Message requests")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 14)
            // Kulan has no follow: a request is a chat from someone you haven't chatted with before.
            Text("Messages from people you haven\u{2019}t chatted with before arrive here as requests. To reply, accept the request.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button {
                    if let u = URL(string: "https://fariin.com/help") { WebLink.open(u) }
                } label: {
                    Text("Learn more")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                Button { dismissIntro() } label: {
                    Text("Got it")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 24)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    private func dismissIntro() {
        introSeen = true
        withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) { showIntro = false }
    }
}
