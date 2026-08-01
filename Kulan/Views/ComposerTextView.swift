import SwiftUI
import UIKit

// The composer's text field, as a real UITextView.
//
// Why it exists: the sticker panel is a `UIInputView` handed to a first responder (see
// ComposerKeyboardPanel). SwiftUI's TextField never gives you one, so the field this replaces had
// nothing to hang an `inputView` on. Everything here is in service of owning a responder while the
// field stays exactly what it was — `TextField("Message", text:, axis: .vertical)` with
// `.font(.system(size: 17))`, `.lineLimit(1...6)` and the composer's 14/9 padding.
//
// Focus is a plain Bool binding, NOT @FocusState. That is deliberate: ThreadView reads and writes
// `inputFocused` in twenty places and watches it with `.onChange`. A Bool binding keeps every one of
// those call sites working untouched — SwiftUI writes it to open or close the keyboard, the delegate
// writes it back when the user does, and neither direction knows about the other.
struct ComposerTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var isFocused: Bool

    var placeholder: String = "Message"
    var fontSize: CGFloat = 17
    var minLines: Int = 1
    var maxLines: Int = 6

    /// Hand it a panel and that panel takes the system keyboard's place; nil is the system keyboard.
    var customInputView: UIInputView? = nil

    /// Tapping the field while a panel is up. With `inputView` overridden the text view cannot
    /// receive an ordinary editing tap, so without this there is no way back to typing — you would
    /// be stuck in the panel. Signal adds the same recogniser, and only while the panel is up.
    var onTapWhileCustomInput: (() -> Void)? = nil

    // Matches the padding the SwiftUI field carried on the outside. Moving it inside means the whole
    // pill is tappable rather than just the text's own frame; the text sits in exactly the same place.
    private static let inset = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 0)

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        configure(tv)
        tv.delegate = context.coordinator

        // Measured off-screen, never shown. Sizing the live view during layout means measuring text
        // it has not been given yet (a programmatic set — draft restore, seeding an edit — reaches
        // the binding first), so a three-line edit would open one line tall and correct a frame later.
        configure(context.coordinator.sizer)
        context.coordinator.sizer.isScrollEnabled = false

        // Off unless a panel is up. Left always-on it would swallow taps meant for placing the caret.
        let tap = context.coordinator.panelTap
        tap.addTarget(context.coordinator, action: #selector(Coordinator.panelTapped))
        tap.isEnabled = false
        tv.addGestureRecognizer(tap)

        let ph = context.coordinator.placeholderLabel
        ph.text = placeholder
        ph.font = tv.font
        ph.textColor = .placeholderText
        ph.isUserInteractionEnabled = false
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        // frameLayoutGuide, not the text view's own anchors: a UITextView is a scroll view, and a
        // subview pinned to its edges would join the content-size calculation and fight the text.
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.frameLayoutGuide.leadingAnchor, constant: Self.inset.left),
            ph.topAnchor.constraint(equalTo: tv.frameLayoutGuide.topAnchor, constant: Self.inset.top),
            ph.trailingAnchor.constraint(lessThanOrEqualTo: tv.frameLayoutGuide.trailingAnchor),
        ])
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self

        // Never while composing: mid-composition (IME, dictation, a predictive candidate) the text
        // view holds marked text the binding has not seen, and assigning would drop it.
        if tv.markedTextRange == nil, tv.text != text {
            tv.text = text
            tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        c.syncPlaceholder(tv)

        if tv.inputView !== customInputView {
            // MEASURE THE KEYBOARD NOW, in the one instant it can be measured: we are switching away
            // from the system keyboard and are still first responder, so the keyboard is up and at
            // rest. A notification's frame cannot be trusted for this — it also fires for undocked,
            // floating and half-dismissed states, which produce a height that is not a keyboard.
            if customInputView != nil, tv.inputView == nil, tv.isFirstResponder, let window = tv.window {
                ComposerKeyboardPanel.recordKeyboardHeight(window.keyboardLayoutGuide.layoutFrame.height,
                                                           for: tv.traitCollection)
            }
            // The height belongs on the panel BEFORE it becomes an inputView; applied afterwards it
            // is a resize of something already on screen, which is a visible jump.
            (customInputView as? ComposerKeyboardPanel)?.updateHeight(using: tv.traitCollection)
            tv.inputView = customInputView
            if tv.isFirstResponder { tv.reloadInputViews() }
            c.panelTap.isEnabled = customInputView != nil
        }

        // Focus, driven from SwiftUI. The flag stops the delegate writing state back during a view
        // update — we already know the value, it is the one being applied.
        if isFocused != tv.isFirstResponder {
            c.applyingFocus = true
            if isFocused { tv.becomeFirstResponder() } else { tv.resignFirstResponder() }
            c.applyingFocus = false
        }
    }

    // The height is ours; the width belongs to the HStack (the caller makes it greedy the way a
    // TextField is). Clamped to minLines...maxLines, which is what `.lineLimit(1...6)` did.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let proposed = proposal.width
        // Something real to lay text out in. The 0 and infinity the HStack probes with are questions
        // about flexibility, not widths to wrap at.
        let measureWidth: CGFloat = {
            if let p = proposed, p.isFinite, p > 1 { return p }
            return uiView.bounds.width > 1 ? uiView.bounds.width : 240
        }()
        // But hand BACK exactly what was proposed, including that 0: answering it with a guess would
        // claim a minimum width, and on a narrow phone the field would then squeeze the buttons out.
        let width: CGFloat = {
            guard let p = proposed else { return measureWidth }
            return p.isFinite ? p : measureWidth
        }()

        let sizer = context.coordinator.sizer
        if sizer.text != text { sizer.text = text }
        let fitted = sizer.sizeThatFits(CGSize(width: measureWidth, height: .greatestFiniteMagnitude)).height

        let line = (uiView.font ?? .systemFont(ofSize: fontSize)).lineHeight
        let chrome = Self.inset.top + Self.inset.bottom
        let shortest = ceil(line * CGFloat(minLines)) + chrome
        let tallest = ceil(line * CGFloat(maxLines)) + chrome
        return CGSize(width: width, height: min(max(ceil(fitted), shortest), tallest))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func configure(_ tv: UITextView) {
        // UIKitBubbleCell already proves this is the match for SwiftUI's .system(size: 17) — the
        // message text drawn either way has to line up, and does.
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .label
        tv.backgroundColor = .clear
        tv.textContainerInset = Self.inset
        tv.textContainer.lineFragmentPadding = 0
        tv.contentInsetAdjustmentBehavior = .never   // it lives in a bottom bar; let nobody else inset it
        // The app is monochrome (.tint(.primary) at the root). Left alone, the caret and the
        // selection would be the only system blue in it.
        tv.tintColor = .label
        tv.isScrollEnabled = true                    // past maxLines the field stops growing and scrolls
        tv.showsHorizontalScrollIndicator = false
        tv.alwaysBounceHorizontal = false
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        let placeholderLabel = UILabel()
        let sizer = UITextView()
        let panelTap = UITapGestureRecognizer()
        var applyingFocus = false

        init(_ parent: ComposerTextView) { self.parent = parent }

        @objc func panelTapped() { parent.onTapWhileCustomInput?() }

        func syncPlaceholder(_ tv: UITextView) {
            placeholderLabel.isHidden = !tv.text.isEmpty || tv.markedTextRange != nil
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            syncPlaceholder(tv)
            // After the frame has caught up with the new line count. Without it, deleting back down
            // from a scrolling field can leave a stale offset hiding the first line.
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                tv.scrollRangeToVisible(tv.selectedRange)
            }
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            guard !applyingFocus, !parent.isFocused else { return }
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            guard !applyingFocus, parent.isFocused else { return }
            parent.isFocused = false
        }
    }
}
