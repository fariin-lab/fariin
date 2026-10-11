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

/// ⛔ THE NAVIGATION BAR'S SEARCH FIELD OWNS ITS GREY (owner, 2026-10-11, reported on Stories,
/// Chats and Calls: "the search bar's grey disappears during the back swipe and comes back when the
/// page finishes").
///
/// The field's fill is a separate background view the system draws BEHIND the text field, and on
/// an interactive pop the system takes that view away for the length of the transition: the icon
/// and the placeholder stay, the grey goes. Declaring the bar's colour scheme (the 2026-09-29 fix,
/// which holds on Chats) did not stop it on Stories, so the fill is no longer the system's to drop.
///
/// `borderStyle = .none` stands the system background down and the field draws its own: the SAME
/// colour (`tertiarySystemFill`, measured off his light-mode screenshot at 238 on white, which is
/// exactly that fill) as a capsule with the system's continuous corner. Done once per field; the
/// corner follows the field's height as the bar folds it.
enum SearchFieldFill {
    private static var key = 0

    static func own(_ field: UISearchTextField) {
        guard objc_getAssociatedObject(field, &key) == nil else { return }
        field.borderStyle = .none
        field.backgroundColor = .tertiarySystemFill
        field.layer.cornerCurve = .continuous
        field.layer.cornerRadius = field.bounds.height / 2
        field.clipsToBounds = true
        let watch = field.layer.observe(\.bounds, options: [.new]) { layer, _ in
            layer.cornerRadius = layer.bounds.height / 2
        }
        objc_setAssociatedObject(field, &key, watch, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The search controller SwiftUI's `.searchable` installed, found from any view controller
    /// inside the page.
    static func own(from vc: UIViewController) {
        var page: UIViewController? = vc
        while let p = page {
            if let bar = p.navigationItem.searchController?.searchBar {
                own(bar.searchTextField)
                return
            }
            if p is UINavigationController { break }
            page = p.parent
        }
        if let top = vc.navigationController?.viewControllers.first,
           let bar = top.navigationItem.searchController?.searchBar {
            own(bar.searchTextField)
        }
    }
}

/// Put this in a page that uses `.searchable`; it finds that page's field and hands it to
/// `SearchFieldFill`. Asked again on every appearance, which costs nothing once a field is owned.
private struct SearchFieldFillHook: UIViewControllerRepresentable {
    final class VC: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            SearchFieldFill.own(from: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            SearchFieldFill.own(from: self)
        }
    }
    func makeUIViewController(context: Context) -> VC {
        let vc = VC()
        vc.view.isUserInteractionEnabled = false
        vc.view.backgroundColor = .clear
        return vc
    }
    func updateUIViewController(_ vc: VC, context: Context) {}
}

extension View {
    /// This page's navigation-bar search field draws its own grey. See `SearchFieldFill`.
    func searchFieldOwnsFill() -> some View {
        background(SearchFieldFillHook().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
