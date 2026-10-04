import SwiftUI

/// ⛔ RESTRICTED CHAT — owner, 2026-10-03. First built as "Disable Sharing" with three switches; the
/// same day he renamed it and made it ONE switch, with the reference app's restricted-chat page as
/// the model for the page (not copied): one toggle, then what it stops.
///
/// HOW IT BEHAVES, AND WHY:
///   • ONE SETTING FOR THE CHAT, NOT FOR ONE PERSON. It is stored on the conversation, so either
///     member may set it and it binds both. A restriction only one side honours protects nothing.
///   • ONE SWITCH, THREE FIELDS UNDER IT. `noScreenshots`, `noForwarding` and `noSaving` are kept
///     apart because each is enforced in a different place; `ChatService.setRestricted` writes all
///     three together, so they only ever move as one.
///   • NEVER SILENT. Every change posts a notice naming who made it, the disappearing timer's rule:
///     nobody turns this on or off behind the other's back.
///   • ENFORCED WHERE THE ACTION IS OFFERED. Forward, Copy, Save and Share disappear from every
///     menu and viewer in the chat, and each action re-checks before it runs, so a menu opened just
///     before the switch flipped cannot slip one through.
///   • SCREENSHOTS AS FAR AS IOS ALLOWS. No public API refuses a screenshot. Screen recording and
///     mirroring are hidden for certain (`UIScreen.isCaptured`); a still screenshot comes out blank
///     through the system's secure canvas, the mechanism the one-time photo already uses
///     (`CaptureProtected`). That canvas is undocumented, so on an iOS that stops handing it over
///     the chat is shown, not hidden.
///
/// ⚠️ 1:1 CHATS. The 1:1 rule lets either member write these fields; groups are switched off in the
/// app (`Flags.groupsEnabled`) and would need an admin rule first.
enum ChatRestriction: String, CaseIterable, Identifiable {
    case noScreenshots, noForwarding, noSaving

    var id: String { rawValue }
}

@MainActor enum ChatRestrictions {
    /// How long a request to turn it off stays open. The reference app reads its value from server
    /// config and does not publish it; a day is our choice.
    nonisolated static let requestLifetime: TimeInterval = 24 * 60 * 60

    /// Whether `r` is on for the chat `cid`, read from the live chat list. Viewers and sheets that
    /// only know the chat id ask here, so every screen reads the same value.
    static func isOn(_ r: ChatRestriction, cid: String) -> Bool {
        guard let c = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) else {
            return false
        }
        return c.isOn(r)
    }
}

extension Conversation {
    func isOn(_ r: ChatRestriction) -> Bool {
        switch r {
        case .noScreenshots: return noScreenshots
        case .noForwarding: return noForwarding
        case .noSaving: return noSaving
        }
    }

    /// Restricted while anyone's own switch is on (or an older build's shared fields say so).
    var isRestricted: Bool { ChatRestriction.allCases.contains { isOn($0) } }

    /// My own switch.
    func restrictedByMe(_ me: String) -> Bool { restrictedBy[me] == true }

    /// Whether the other person's switch is on: the part I cannot turn off, only ask about. An
    /// older build's shared switch counts here too, since nobody can say whose it was.
    func restrictedByThem(_ me: String) -> Bool {
        restrictedBy.contains { $0.key != me && $0.value } || (isRestricted && restrictedBy.isEmpty)
    }

    /// A request to turn it off that is still open: made, not answered, not lapsed.
    var pendingRestrictRequestBy: String? {
        guard let by = restrictRequestBy else { return nil }
        if let at = restrictRequestAt, Date().timeIntervalSince(at) > ChatRestrictions.requestLifetime { return nil }
        return by
    }
}

/// The page behind Restricted Chat on a contact's info.
struct RestrictedChatView: View {
    let cid: String
    @State private var repo = ConversationsRepository.shared
    /// What was tapped, shown at once while the write travels; the live value takes over after.
    @State private var pending: Bool?
    @State private var askToRequest = false

    private var me: String { AuthService.shared.uid ?? "" }
    private var conv: Conversation? { repo.conversations.first(where: { $0.id == cid }) }
    private var them: String { conv?.displayName(me) ?? "They" }
    private var isOn: Bool { pending ?? (conv?.isRestricted ?? false) }
    private var mine: Bool { conv?.restrictedByMe(me) ?? false }
    private var theirs: Bool { conv?.restrictedByThem(me) ?? false }
    /// A request to turn it off, waiting for ME to answer.
    private var requestForMe: Bool {
        guard let by = conv?.pendingRestrictRequestBy else { return false }
        return by != me && mine
    }
    /// A request I made, still waiting for them.
    private var myRequestOpen: Bool { conv?.pendingRestrictRequestBy == me }

    /// ⛔ THE REFERENCE APP'S RULE, NOT A SHARED SWITCH — owner, 2026-10-03: "the other user can
    /// close it, that is not what I want". On: my own switch, at once. Off: my own switch if it is
    /// on; if theirs is on as well the chat stays restricted, and if only theirs is, I can only ask.
    private func flip(_ on: Bool) {
        if on {
            pending = true
            Task { await ChatService.setMyRestriction(cid, on: true); pending = nil }
            return
        }
        if mine {
            pending = theirs ? nil : false
            Task { await ChatService.setMyRestriction(cid, on: false); pending = nil }
        } else if theirs {
            askToRequest = true
        }
    }

    private var footer: String {
        if mine && theirs { return "You and \(them) both turned this on. Turning yours off keeps it on until \(them) turns theirs off." }
        if mine { return "You turned this on. Only you can turn it off. It applies to both of you." }
        if theirs { return "\(them) turned this on. You can ask \(them) to turn it off." }
        return "When either of you turns this on, it applies to both of you. Only the person who turned it on can turn it off."
    }

    /// What the switch stops, in the order a person would try it.
    private static let effects: [(icon: String, text: String)] = [
        ("camera.metering.none", "Can't take screenshots or record the screen in this chat"),
        ("arrowshape.turn.up.right", "Can't forward messages to other chats"),
        ("doc.on.doc", "Can't copy text from this chat"),
        ("square.and.arrow.down", "Can't save or share photos and videos from this chat"),
        ("photo", "Can't save media from this chat to their device gallery automatically"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Restricted chat", isOn: Binding(get: { isOn }, set: { flip($0) }))
                VStack(alignment: .leading, spacing: 14) {
                    Text("If this is on, people:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(Self.effects, id: \.text) { e in
                        // ⛔ CENTRED, NOT ON THE BASELINE — owner, 2026-10-04: "icons and text not on
                        // the same line". A 17pt glyph on a subheadline baseline rode high; the
                        // glyph now matches the text's size and sits on the middle of its lines.
                        HStack(alignment: .center, spacing: 14) {
                            Image(systemName: e.icon)
                                .font(.subheadline)
                                .imageScale(.large)
                                .frame(width: 26)
                            Text(e.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text(footer)
            }
            if requestForMe {
                Section {
                    Button("Turn Off") { Task { await ChatService.answerUnrestrict(cid, accept: true) } }
                    Button("Keep On", role: .cancel) { Task { await ChatService.answerUnrestrict(cid, accept: false) } }
                } header: {
                    Text("\(them) asked you to turn this off")
                }
            } else if myRequestOpen {
                Section {
                    Text("Waiting for \(them) to answer your request.").foregroundStyle(.secondary)
                }
            }
        }
        // Owner, 2026-10-04: "the header and the card have too much space". The first section
        // starts where a system settings page's does, not under an empty header band.
        .contentMargins(.top, 12, for: .scrollContent)
        .navigationTitle("Restricted chat")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Ask \(them) to turn it off?", isPresented: $askToRequest) {
            Button("Send Request") { Task { await ChatService.requestUnrestrict(cid) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(them) turned on Restricted chat, so only they can turn it off. They'll see your request in the chat.")
        }
    }
}
