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

    /// The one switch. On when any part is on, so a chat left half-set by an earlier build still
    /// reads as restricted and one tap turns all of it off.
    var isRestricted: Bool { ChatRestriction.allCases.contains { isOn($0) } }
}

/// The page behind Restricted Chat on a contact's info.
struct RestrictedChatView: View {
    let cid: String
    @State private var repo = ConversationsRepository.shared
    /// What was tapped, shown at once while the write travels; the live value takes over after.
    @State private var pending: Bool?

    private var isOn: Bool {
        pending ?? (repo.conversations.first(where: { $0.id == cid })?.isRestricted ?? false)
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
                Toggle("Restricted chat", isOn: Binding(get: { isOn }, set: { on in
                    pending = on
                    Task {
                        await ChatService.setRestricted(cid, on: on)
                        pending = nil
                    }
                }))
                VStack(alignment: .leading, spacing: 14) {
                    Text("If this is on, people:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(Self.effects, id: \.text) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Image(systemName: e.icon)
                                .font(.system(size: 17))
                                .frame(width: 26)
                            Text(e.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text("This applies to both of you. Either of you can change it, and the chat shows who did.")
            }
        }
        .navigationTitle("Restricted chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}
