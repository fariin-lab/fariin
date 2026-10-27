import SwiftUI
import UIKit

// ⛔ DELETE A GROUP FROM THE CHAT LIST — owner 2026-10-27, with the reference app's alert: the group's
// photo on top, "Delete Group", "Are you sure you want to leave <name>?", a red Delete Group and a
// Cancel. A SwiftUI `.alert` has no room for a picture, so this is its own centred card.
//
// Confirming leaves the group the way the group page's Leave does (`LeaveGroupUndo`: out of the list
// at once, an Undo bar, the real leave 5 s later). The owner is told who takes over first, the same
// line the group page shows, so leaving from the list never hands a group on unannounced.

/// Its own window over everything (the `AppUpdateGate` way), so the dim covers the tab bar too and
/// no sheet slides up underneath it.
@MainActor enum LeaveGroupAlertDoor {
    private static var window: UIWindow?

    static func show(_ conv: Conversation) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: LeaveGroupAlert(conv: conv) { close() })
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    private static func close() {
        window?.isHidden = true
        window = nil
    }
}

struct LeaveGroupAlert: View {
    let conv: Conversation
    let onClose: () -> Void

    @State private var shown = false
    private var me: String { AuthService.shared.uid ?? "" }
    private var name: String { conv.displayName(me) }

    /// The heir `ChatService.leaveGroup` picks: the longest-serving admin still a member, else the
    /// longest-serving member.
    private var ownerLine: String? {
        guard conv.isOwner(me) else { return nil }
        guard let heir = conv.admins.first(where: { $0 != me && conv.users.contains($0) })
                ?? conv.users.first(where: { $0 != me }) else { return nil }
        let who = conv.names[heir].flatMap { $0.isEmpty ? nil : $0 } ?? "another member"
        return "You own this group, so \(who) will become the owner."
    }

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }
            if shown {
                card
                    .transition(.scale(scale: 1.08).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: shown)
        .onAppear { shown = true }
    }

    private var card: some View {
        VStack(spacing: 0) {
            AvatarView(name: name, photoUrl: conv.displayPhoto(me), size: 64)
                .padding(.top, 22)
            Text("Delete Group")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 12)
            (Text("Are you sure you want to leave ") + Text(name).bold() + Text("?"))
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .padding(.top, 6).padding(.horizontal, 20)
            if let ownerLine {
                Text(ownerLine)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6).padding(.horizontal, 20)
            }
            VStack(spacing: 8) {
                button("Delete Group", color: .red, weight: .semibold) {
                    LeaveGroupUndo.shared.start(cid: conv.id, title: name)
                    close()
                }
                button("Cancel", color: .primary, weight: .regular) { close() }
            }
            .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 14)
        }
        .frame(width: 290)
        // Liquid glass, as the system's own alerts (owner 2026-10-27).
        .liquidGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func button(_ title: String, color: Color, weight: Font.Weight,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: weight))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func close() {
        shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onClose() }
    }
}
