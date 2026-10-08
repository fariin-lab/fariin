import ReplayKit
import SwiftUI
import UIKit

/// The system broadcast picker, kept invisible in the call screen. Starting a broadcast needs the
/// system's own sheet (its countdown and the red indicator are the user's consent; an app cannot
/// start one silently), so the "Share Screen" menu item presses this view's button for the user.
///
/// `showsMicrophoneButton` is off: the call's own microphone already carries the voice, and the
/// extension takes only the shared app's audio, never the microphone.
struct ScreenSharePickerView: UIViewRepresentable {
    /// Bundle id of the broadcast upload extension.
    static let broadcastExtension = "com.kulan.messenger.native.broadcast"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = Self.broadcastExtension
        picker.showsMicrophoneButton = false
        ScreenSharePicker.current = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        ScreenSharePicker.current = uiView
    }

    static func dismantleUIView(_ uiView: RPSystemBroadcastPickerView, coordinator: ()) {
        if ScreenSharePicker.current === uiView { ScreenSharePicker.current = nil }
    }
}

enum ScreenSharePicker {
    /// The mounted picker, if the call screen is up. Weak: the view owns it.
    static weak var current: RPSystemBroadcastPickerView?

    /// Opens the system sheet. Returns false when no picker is mounted (call screen not shown).
    /// Delayed a beat so the "..." menu has finished dismissing; presenting while it animates
    /// away can be refused by UIKit.
    @discardableResult
    static func show() -> Bool {
        guard current != nil else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let picker = current else { return }
            for case let button as UIButton in picker.subviews {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
        return true
    }
}
