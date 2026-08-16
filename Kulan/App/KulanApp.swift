import SwiftUI
import StoryUI   // StoryPosterSource: lets the story player read the app's image cache

@main
struct KulanApp: App {
    // Firebase config + APNs/FCM handshake live in the app delegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    /// ⚠️ THE UIKit HALF OF `.tint(.primary)` BELOW, AND WITHOUT IT THAT LINE IS ONLY HALF TRUE —
    /// his 2026-08-16 report, with both long-press menus circled: "the context menu icons is blue…
    /// restore the white color icons".
    ///
    /// `.tint()` is a SwiftUI ENVIRONMENT value. A long-press menu is not a SwiftUI view: SwiftUI
    /// hands `.contextMenu` to UIKit, which builds a real `UIMenu`, and UIKit tints a menu's images
    /// with the presenting view's `tintColor` — a thing the SwiftUI environment never reaches. That
    /// is why those menus came out with white lettering and SYSTEM-BLUE glyphs: the text is drawn by
    /// `label`, the icons by a tint nobody had set. Everywhere the app draws its OWN menu
    /// (`CMContextMenu`) both are `.label`, which is what he is comparing them against.
    ///
    /// `.label` rather than white, so it is black on a light-mode phone — the ink, not a colour.
    ///
    /// ⚠️ IT IS THE WINDOW'S, SO IT REACHES EVERY UIKit CONTROL THAT HAS NOT SET ITS OWN: menus,
    /// carets, the buttons of any system alert. That is the same rule the SwiftUI line already
    /// states, and several places (`AuthFlowViews`, `NativeMessageList`) had already set `.label` by
    /// hand for exactly this reason — this is that fix stopped being done one view at a time.
    init() {
        UIWindow.appearance().tintColor = .label
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.primary)   // monochrome: no iOS system-blue anywhere
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
                .onOpenURL { url in handleDeepLink(url) }
                // Someone still on one of the removed tri-arrow icons has a name iOS can no longer
                // resolve — put them back on the default rather than leave them with a broken icon.
                .task { RetiredAppIcons.resetIfInUse() }
                // STORYUI CAN SEE THE APP'S DECODED-IMAGE CACHE, through one closure.
                //
                // A story video is hidden until its first frame is ready for display, the way
                // the reference app's is, and what shows in the meantime is the clip's cover. The player only
                // ever asked StoryUI's own two caches for that cover, and those are cold for a story
                // whose cover came down for the ROW rather than for the viewer — so there was nothing
                // to hold the frame and you saw black. See `StoryPosterSource`.
                //
                // Installed HERE rather than in `StoriesService.init` for two reasons: that singleton
                // is lazy and is not necessarily touched before the viewer opens, and it is not
                // main-actor isolated, which this is. Memory only and synchronous, which is what the
                // hook asks for; a miss falls through to the old path unchanged.
                .task { StoryPosterSource.provider = { DiskImageCache.shared.memoryImage($0) } }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await PresenceService.set(online: phase == .active) }
        }
    }

    // TWO SHAPES, ONE MEANING.
    //   https://fariin.com/u/<handle>  ·  kulan://u/<handle>   open (or start) a chat with them
    //   https://fariin.com/g/<code>    ·  kulan://g/<code>     open the "Join group" sheet
    //
    // The https form is what we now put in every share sheet, because a custom scheme is only a
    // link on a phone that already has the app. Sent to anybody else it is dead text: no page, no
    // preview, nothing to tap. For a messenger, where invites are how anyone new arrives, that is
    // a hole in the product rather than a rough edge. An https link works for all of them, and
    // opens the app for the people who have it.
    //
    // kulan:// is KEPT, not replaced. Links already sent live in other people's chat histories
    // forever, and the fallback pages on fariin.com use the scheme themselves to hop into the app
    // (an https link back to the domain you are already on does not re-trigger a Universal Link).
    private func handleDeepLink(_ url: URL) {
        guard let route = Self.route(from: url) else { return }
        switch route {
        case .group(let code):
            guard Flags.groupsEnabled else { return }
            AppRouter.shared.pendingInviteCode = code
        case .user(let handle):
            Task {
                guard let user = await ChatService.findByHandle(handle),
                      let cid = try? await ChatService.openConversation(other: user) else { return }
                await MainActor.run { AppRouter.shared.pendingChatId = cid }
            }
        }
    }

    enum DeepLink: Equatable { case user(String), group(String) }

    /// The web host every shared link points at. One constant, because the entitlement, the
    /// apple-app-site-association file on fariin.com and the parser below must all name the same
    /// host or the link quietly opens Safari with no error anywhere.
    static let linkHost = "https://fariin.com"

    /// Built HERE, beside the parser that reads them back, so a change to one shape cannot leave
    /// the other behind. Percent-encoded because a handle is user-supplied text.
    static func userLink(handle: String) -> String {
        "\(linkHost)/u/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)"
    }

    static func groupLink(code: String) -> String {
        "\(linkHost)/g/\(code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code)"
    }

    /// Reads either link shape into one answer. Static and pure so it can be tested without a
    /// running app, and so the two shapes cannot drift apart the way parallel parsers do.
    static func route(from url: URL) -> DeepLink? {
        let kind: String
        let value: String

        switch url.scheme?.lowercased() {
        case "kulan":
            // kulan://u/<handle> — the host carries the kind, the path carries the value.
            kind = url.host ?? ""
            value = url.pathComponents.last(where: { $0 != "/" }) ?? ""

        case "https":
            // Only our own domain, and only the two paths the site actually claims. Anything
            // else reaching this method is not ours to act on.
            let host = (url.host ?? "").lowercased()
            guard host == "fariin.com" || host == "www.fariin.com" else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2 else { return nil }
            kind = parts[0]
            value = parts[1]

        default:
            return nil
        }

        guard !value.isEmpty else { return nil }
        switch kind {
        case "u": return .user(value)
        case "g": return .group(value)
        default:  return nil
        }
    }
}
