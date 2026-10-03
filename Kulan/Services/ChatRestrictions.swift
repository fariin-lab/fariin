import SwiftUI

/// ⛔ RESTRICTED CHAT — owner, 2026-10-03: "No Screenshots, No Forwarding, No Saving", with the
/// reference app's per-chat switch as the model for how it behaves (not how it looks).
///
/// HOW IT BEHAVES, AND WHY:
///   • ONE SETTING FOR THE CHAT, NOT FOR ONE PERSON. Each switch is a field on the conversation, so
///     either member may set it and it binds both. A restriction only one side honours protects
///     nothing.
///   • NEVER SILENT. Every change posts a notice naming who made it (`ChatService.setRestriction`),
///     the disappearing timer's rule: nobody turns these on or off behind the other's back.
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

    var title: String {
        switch self {
        case .noScreenshots: return "No Screenshots"
        case .noForwarding: return "No Forwarding"
        case .noSaving: return "No Saving"
        }
    }

    /// His wording, 2026-10-03.
    var detail: String {
        switch self {
        case .noScreenshots: return "Disable screenshots and screen recordings in this chat."
        case .noForwarding: return "Disable forwarding messages to other chats."
        case .noSaving: return "Disable copying text and saving photos or videos."
        }
    }

    var icon: String {
        switch self {
        case .noScreenshots: return "camera.metering.none"
        case .noForwarding: return "arrowshape.turn.up.right"
        case .noSaving: return "square.and.arrow.down"
        }
    }
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
}

/// The page behind Disable Sharing on a contact's info.
struct DisableSharingView: View {
    let cid: String
    @State private var repo = ConversationsRepository.shared
    /// What was tapped, shown at once while the write travels; the live value takes over after.
    @State private var pending: [ChatRestriction: Bool] = [:]

    private func value(_ r: ChatRestriction) -> Bool {
        if let p = pending[r] { return p }
        return repo.conversations.first(where: { $0.id == cid })?.isOn(r) ?? false
    }

    var body: some View {
        Form {
            Section {
                ForEach(ChatRestriction.allCases) { r in
                    Toggle(isOn: Binding(get: { value(r) }, set: { on in
                        pending[r] = on
                        Task {
                            await ChatService.setRestriction(cid, r, on: on)
                            pending[r] = nil
                        }
                    })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title)
                                Text(r.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: r.icon)
                        }
                    }
                }
            } footer: {
                Text("These apply to both of you. Either of you can change them, and the chat shows who did.")
            }
        }
        .navigationTitle("Disable Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
