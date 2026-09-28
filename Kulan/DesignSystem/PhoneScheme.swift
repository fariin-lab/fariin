import SwiftUI
import UIKit

/// ⛔ WHAT THE PHONE IS SET TO, asked of the phone and not of the environment — the same answer
/// `MediaGalleryView.pageScheme` gives, shared. A pushed page's `colorScheme` can be a parent's
/// override, and a navigation bar keeps whatever scheme it was last handed, so a page that
/// declares nothing can come up with somebody else's dark bar: owner, 2026-09-28, light mode, the
/// Chat Key, Message Requests and Archive pages from the chat list's filter menu, each with a
/// white title and white chevron on pale glass.
///
/// The app's own setting answers first (Light, Dark); System defers to the window's trait, which
/// no SwiftUI subtree override reaches.
enum PhoneScheme {
    static var current: ColorScheme {
        let raw = UserDefaults.standard.string(forKey: "appearance") ?? AppAppearance.system.rawValue
        if let fixed = AppAppearance(rawValue: raw)?.colorScheme { return fixed }
        let style = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
    }
}

private struct BarFollowsPhone: ViewModifier {
    // Read so a change of the in-app setting redraws the page and re-asks `PhoneScheme`.
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        let _ = appearanceRaw
        let _ = inherited
        content.toolbarColorScheme(PhoneScheme.current, for: .navigationBar)
    }
}

extension View {
    /// This page's navigation bar in the phone's own appearance (see `PhoneScheme`).
    func barFollowsPhone() -> some View { modifier(BarFollowsPhone()) }
}
