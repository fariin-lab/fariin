import SwiftUI

/// The "…" button's panel on the group call screen. The "..." is the first button of the controls
/// capsule (owner 2026-10-28, in Share Screen's place) and this small glass panel opens just above
/// it, not a system sheet:
///
/// - a row of quick emojis: a tap sends that reaction to everyone and closes the panel;
/// - "Raise Hand" / "Lower Hand";
/// - "Share Screen" / "Cancel Sharing" / "Stop Sharing", once in the room and never on a voice call link;
/// - "Flip Camera", only while my camera is on.
///
/// `GroupCallView` places it, draws the tap-outside catcher under it and keeps the chrome up while
/// it is open. Every choice closes the panel (`onClose`).
@MainActor
struct GroupCallMoreMenu: View {
    @ObservedObject private var service = GroupCallService.shared
    @ObservedObject private var social = GroupCallSocial.shared
    let onClose: () -> Void

    /// Narrower than the controls capsule (354pt with five buttons), so it reads as belonging to it.
    static let width: CGFloat = 300

    var body: some View {
        VStack(spacing: 8) {
            emojiRow
            rows
        }
        .frame(width: Self.width)
    }

    // MARK: - Reactions

    private var emojiRow: some View {
        HStack(spacing: 0) {
            ForEach(GroupCallSocial.quickEmojis, id: \.self) { emoji in
                emojiButton(emoji)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .liquidGlass(Capsule())
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button {
            social.react(emoji)
            onClose()
        } label: {
            Text(emoji)
                .font(.system(size: 28))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("React with \(emoji)")
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(spacing: 0) {
            row(handTitle, icon: handIcon) { social.setHand(!social.myHandUp) }
            // Back in this menu (owner 2026-10-28; it was a bar button from 2026-10-22). Never on a
            // voice call link. Pending (the system sheet is up) says that a tap cancels.
            if shareOn || (service.isActive && !service.cameraLocked) {
                divider
                row(shareTitle, icon: shareOn ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle") {
                    service.toggleScreenShare()
                }
            }
            if service.cameraOn {
                divider
                row("Flip Camera", icon: "arrow.triangle.2.circlepath.camera") { service.flipCamera() }
            }
        }
        .liquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var handTitle: String { social.myHandUp ? "Lower Hand" : "Raise Hand" }
    private var handIcon: String { social.myHandUp ? "hand.raised.slash" : "hand.raised" }

    private var shareOn: Bool { service.screenSharing || service.sharePending }
    private var shareTitle: String {
        service.screenSharing ? "Stop Sharing" : service.sharePending ? "Cancel Sharing" : "Share Screen"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onClose()
        } label: {
            HStack(spacing: 12) {
                Text(title).font(.body)
                Spacer(minLength: 12)
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
