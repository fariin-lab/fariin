import SwiftUI

// "Set nickname" sheet — the local, device-only contact rename (Edit on a profile). X / checkmark
// header, a big text field, and an honest note. The nickname is stored locally (ContactNames),
// never sent, so it's private to this device.
struct SetNicknameView: View {
    @State private var text: String
    var onSave: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(current: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: current)
        self.onSave = onSave
    }

    private var dark: Bool { scheme == .dark }
    private var fieldBg: Color { dark ? Color(hex: 0x1C1C1E) : .white }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Nickname", text: $text)
                    .font(.title3)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { onSave(text); dismiss() }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .background(fieldBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 20)
                Text("This nickname is saved only on your device and visible only to you.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Spacer()
            }
            .padding(.horizontal, 16)
            .navigationTitle("Set nickname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onSave(text); dismiss() } label: { Image(systemName: "checkmark").font(.headline) }
                }
            }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
        }
    }
}
