import SwiftUI
import UIKit

// MARK: - An alert that is dark wherever it is asked to be

/// ⛔ A SwiftUI `.alert` CANNOT BE MADE DARK FROM THE SCREEN THAT SHOWS IT.
///
/// The profile page is always dark by the owner's standing rule, photo or no photo, and its
/// confirmations came up in the phone's own appearance — a white card over a dark green page
/// (2026-08-20, "this Dialog in profile plz use always dark mode").
///
/// Nothing written on the profile's side can fix that, and this is worth stating because it has been
/// tried twice on this app already. `\.colorScheme` is a SwiftUI environment value and a
/// `UIAlertController` does not read it. `overrideUserInterfaceStyle` on the presenting controller
/// only reaches what is UNDER that controller, and an alert is presented into a presentation context
/// of its own, so the trait set on the page never gets a vote. Setting it on the WINDOW does reach
/// the alert and also everything else in the app, which is the dark flash on the chat list that had
/// to be reverted.
///
/// So the alert is presented as UIKit and the style is set on the ALERT ITSELF, which is the one
/// place that cannot be overruled and reaches nothing else. Everything else is stock: same title,
/// same message, same destructive red, same cancel role.
///
/// `AddStorySheet.DarkConfirm` is the same idea, written before this one and for one fixed pair of
/// buttons. This takes a list, because the Report confirmation has three.
struct DarkAlertAction {
    let title: String
    let style: UIAlertAction.Style
    let run: () -> Void

    static func cancel(_ title: String = "Cancel", _ run: @escaping () -> Void = {}) -> DarkAlertAction {
        DarkAlertAction(title: title, style: .cancel, run: run)
    }
    static func destructive(_ title: String, _ run: @escaping () -> Void) -> DarkAlertAction {
        DarkAlertAction(title: title, style: .destructive, run: run)
    }
    static func plain(_ title: String, _ run: @escaping () -> Void) -> DarkAlertAction {
        DarkAlertAction(title: title, style: .default, run: run)
    }
}

/// Zero-sized host. It draws nothing and takes no touches; all it does is own a controller that can
/// present from wherever it has been placed.
private struct DarkAlertHost: UIViewControllerRepresentable {
    let title: String
    let message: String?
    @Binding var isPresented: Bool
    let actions: [DarkAlertAction]

    func makeCoordinator() -> Coordinator { Coordinator() }
    /// ⚠️ A LATCH, AND IT HAS TO BE ONE. `updateUIViewController` runs many times for a single state
    /// change, and presenting an alert that is already up either throws or stacks two of them.
    final class Coordinator { var presented = false }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, !context.coordinator.presented, host.view.window != nil else {
            // Every button dismisses the alert itself, so there is nothing to take down here — only
            // the latch to re-arm once the binding comes back down.
            if !isPresented { context.coordinator.presented = false }
            return
        }
        context.coordinator.presented = true
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        // THE LINE THE WHOLE TYPE EXISTS FOR.
        alert.overrideUserInterfaceStyle = .dark
        for a in actions {
            alert.addAction(UIAlertAction(title: a.title, style: a.style) { _ in
                isPresented = false
                context.coordinator.presented = false
                a.run()
            })
        }
        // ⚠️ FROM WHATEVER IS ACTUALLY ON SCREEN, not from this host. The host sits at zero size
        // inside a page that may itself be inside a sheet or a cover, and presenting from a
        // controller that is not the top one is how an alert ends up never appearing.
        var top: UIViewController? = host
        while let next = top?.presentedViewController { top = next }
        (top ?? host).present(alert, animated: true)
    }
}

extension View {
    /// A confirmation that is dark whatever the phone is set to. Same shape as `.alert`, minus the
    /// builder: the actions are a list because the type presents UIKit's own alert.
    func darkAlert(_ title: String,
                   message: String? = nil,
                   isPresented: Binding<Bool>,
                   actions: [DarkAlertAction]) -> some View {
        background(
            DarkAlertHost(title: title, message: message, isPresented: isPresented, actions: actions)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
