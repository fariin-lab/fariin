import SwiftUI

// "Can't Call" — shown when you press a call button on somebody whose settings refuse calls
// (owner 2026-08-04, with his mock).
//
// THE BUTTONS STAY LIVE. Hiding or greying them would tell you what somebody chose in their privacy
// settings before you ever pressed anything, which is not yours to know; the answer arrives when you
// ask, and it says what to do instead.
//
// "Send Message" only closes this. You are already in a place where you can write to them, so the
// button's job is to point at that rather than to open something new.
struct CantCallSheet: View {
    let name: String
    let photoUrl: String?
    var onSendMessage: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14)

            AvatarView(name: name, photoUrl: photoUrl, size: 76)
                .padding(.top, 4)

            Text("Can't Call")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.top, 14)

            Text("This person restricts who can call them")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.top, 6)

            Button {
                dismiss()
                onSendMessage()
            } label: {
                Text("Send message")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.accentColor, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 24)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
    }
}
