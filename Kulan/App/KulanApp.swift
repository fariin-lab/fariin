import SwiftUI
import StoryUI   // StoryPosterSource: lets the story player read the app's image cache

@main
struct KulanApp: App {
    // Firebase config + APNs/FCM handshake live in the app delegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

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
                .task {
                    StoryPosterSource.provider = { DiskImageCache.shared.memoryImage($0) }
                    // ⛔ AND THE SAME CACHE FOR THE STORY HEADER'S AVATAR, for the same reason one
                    // level down. That view knew only `URLCache.shared`, which nothing else in this
                    // app writes to — so the profile picture the app had just seeded on disk when
                    // the person changed it was invisible to it, and the story header drew a grey
                    // disc and then downloaded a file it already had. The owner's report: "already I
                    // have cache, why is it grey".
                    //
                    // `cachedNow` is memory-only and synchronous so the first frame can already have
                    // the picture; `cached` adds the disk read for the far more common case of a
                    // photo cached in a previous session; `store` hands a fresh download back so the
                    // next surface to ask gets a hit rather than a second fetch.
                    // `smallImageSync`, not `memoryImage`: it is the reader written for avatars,
                    // and it adds a gated disk read to the memory lookup. That is what removes the
                    // grey frame outright rather than shortening it — a photo cached in an earlier
                    // session is on disk with memory cold, which is every cold launch.
                    StoryUIImages.cachedNow = { DiskImageCache.shared.smallImageSync($0) }
                    StoryUIImages.cached = { await DiskImageCache.shared.image(for: $0) }
                    StoryUIImages.store = { image, data, url in
                        DiskImageCache.shared.store(image, data: data, for: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await PresenceService.set(online: phase == .active) }
            // "Last active" on the Devices screen is only as true as this. Foreground beats,
            // background stops. See DeviceRegistry.startHeartbeat.
            if phase == .active { DeviceRegistry.shared.startHeartbeat() }
            else { DeviceRegistry.shared.stopHeartbeat() }
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
