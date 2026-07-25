import SwiftUI

// A real BOTTOM-SHEET action dialog.
//
// WHY THIS EXISTS: iOS 26 renders `confirmationDialog` as a small bubble ANCHORED to the view it's
// attached to — tapping a profile avatar or "Edit Photo" popped a callout with a little arrow instead
// of a sheet rising from the bottom. There's no placement knob on `confirmationDialog`, so the two
// choosers that want the classic bottom sheet are built here as a real `.sheet` with a fitted detent.
//
// The picked action runs in the sheet's `onDismiss`, never inline: presenting another sheet or a
// full-screen cover from inside a sheet that is still dismissing is the classic "nothing happens"
// bug (the same one that made Edit Photo dead before).

struct SheetAction {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.action = action
    }
}

extension View {
    /// Bottom-sheet replacement for `confirmationDialog`. Cancel is added for you.
    func bottomActionSheet(_ title: String, isPresented: Binding<Bool>,
                           actions: [SheetAction]) -> some View {
        modifier(BottomActionSheetModifier(title: title, isPresented: isPresented, actions: actions))
    }
}

private struct BottomActionSheetModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let actions: [SheetAction]
    // Index, not an id: SheetAction is rebuilt on every body pass, so any generated identity would
    // no longer match by the time onDismiss runs.
    @State private var chosen: Int?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            guard let i = chosen, actions.indices.contains(i) else { return }
            chosen = nil
            actions[i].action()
        }) {
            BottomActionSheetBody(title: title, actions: actions, chosen: $chosen)
        }
    }
}

private struct BottomActionSheetBody: View {
    let title: String
    let actions: [SheetAction]
    @Binding var chosen: Int?
    @Environment(\.dismiss) private var dismiss

    private let rowHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 20).padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                    if i > 0 { Divider().padding(.leading, 16) }
                    Button {
                        chosen = i
                        dismiss()
                    } label: {
                        Text(a.title)
                            .font(.body)
                            .foregroundStyle(a.role == .destructive ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity).frame(height: rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            // Cancel sits on its own card, like a native action sheet.
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity).frame(height: rowHeight)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    // Fitted so the sheet is exactly as tall as its content — no empty space under Cancel.
    private var height: CGFloat {
        let separators = CGFloat(max(0, actions.count - 1))
        return 24 + 24 + 10                       // title block
            + CGFloat(actions.count) * rowHeight + separators
            + 10 + rowHeight                       // gap + Cancel
            + 20                                   // bottom breathing room
    }
}
