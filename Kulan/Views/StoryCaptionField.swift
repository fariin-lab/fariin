import SwiftUI
import UIKit

/// THE STORY CAPTION'S WORDS, A `UITextView`.
///
/// ⛔ NOT `TextField(axis: .vertical)` (owner 2026-11-02, builds 1093 and 1094: tapping the emoji key
/// while typing a caption freezes the app until iOS kills it, 0x8BADF00D). Both crash files and the
/// CPU report show the main thread going round one path at 88%: the keyboard's window lays out, tells
/// its tracking clients, the editor's hosting view lays out, and the keyboard's window lays out again.
/// That SwiftUI field was the only keyboard client on this screen SwiftUI owned. The Aa editor and the
/// chat composer are both `UITextView`s.
///
/// Grows to five lines, then scrolls. `updateUIView` touches the view only when something really
/// differs, so a redraw of the editor says nothing to the keyboard.
struct StoryCaptionField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    private static let font = UIFont.preferredFont(forTextStyle: .body)

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.font = Self.font
        v.textColor = .white
        v.tintColor = .white
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.showsVerticalScrollIndicator = false
        v.keyboardAppearance = .dark
        // A hairline shadow on the words, so they read on a white photo.
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.45
        v.layer.shadowRadius = 1.5
        v.layer.shadowOffset = .zero
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text, v.markedTextRange == nil { v.text = text }
        if focused != v.isFirstResponder {
            // Not inside SwiftUI's update: first responder changes start the keyboard.
            let want = focused
            DispatchQueue.main.async {
                guard want != v.isFirstResponder else { return }
                if want { v.becomeFirstResponder() } else { v.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(ceil(fit), ceil(Self.font.lineHeight * 5)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StoryCaptionField
        init(_ p: StoryCaptionField) { parent = p }

        func textViewDidChange(_ v: UITextView) {
            if parent.text != v.text { parent.text = v.text }
        }
        func textViewDidBeginEditing(_ v: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ v: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}
