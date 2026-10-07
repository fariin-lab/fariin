import SwiftUI

/// The "…" button's panel on the group call screen (owner, 2026-10-06: the one button the controls
/// capsule was allowed to gain). A small glass panel just above the capsule, not a system sheet, the
/// way the reference app's "more" panel sits over its controls:
///
/// - a row of quick emojis: a tap sends that reaction to everyone and closes the panel;
/// - "Raise Hand" / "Lower Hand";
/// - "Flip Camera", only while my camera is on;
/// - "Share Screen" / "Stop Sharing", once in the room and never on a voice call link.
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
            if service.cameraOn {
                divider
                row("Flip Camera", icon: "arrow.triangle.2.circlepath.camera") { service.flipCamera() }
            }
            // Screen sharing, 2026-10-07. Starting opens the system's broadcast sheet (the SDK
            // presents it); the person taps Start there. Not on a voice call link, and only once
            // the room is up.
            if service.isActive, !service.cameraLocked {
                divider
                row(service.screenSharing ? "Stop Sharing" : "Share Screen",
                    icon: service.screenSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle") {
                    service.toggleScreenShare()
                }
            }
        }
        .liquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var handTitle: String { social.myHandUp ? "Lower Hand" : "Raise Hand" }
    private var handIcon: String { social.myHandUp ? "hand.raised.slash" : "hand.raised" }

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
