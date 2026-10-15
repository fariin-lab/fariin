import SwiftUI
import UIKit
import FirebaseFunctions

/// ⛔ APP UPDATE CAMPAIGNS, THE PHONE'S HALF — owner 2026-10-15: "force only V1 to update, V2-V4 carry
/// on; optional notices with Not Now; the server decides; changes from the admin panel without a new
/// release". The admin panel writes campaigns; the server function `appUpdateCheck` judges this phone
/// (its build, version, iOS, device id, and the signed-in account from the auth token) and answers
/// none / optional / mandatory. This class asks, remembers the answer and shows it.
///
/// WHEN IT ASKS: at launch, whenever the app comes back to the front, and every 10 minutes while open.
///
/// THE CACHE (what makes it hold across restarts and bad networks):
///   • The last good answer is kept on disk and shown at once on the next launch, before any network.
///     A mandatory answer therefore cannot be skipped by closing the app or going offline.
///   • A failed check keeps the last answer; only a real answer from the server replaces it.
///   • A mandatory answer stops applying the moment the installed build reaches its minimum, even
///     before the server is asked again: installing the update is always the way back in.
///   • An answer that does not make sense (unknown action, no minimum build) is treated as none, so
///     broken data can never lock anyone out.
///
/// WHERE IT SHOWS: its own window above everything (chats, sheets, calls, the sign-in screen), so a
/// mandatory update covers the whole app and nothing under it can be reached.
@MainActor final class AppUpdateGate {
    static let shared = AppUpdateGate()

    struct Decision: Codable, Equatable {
        var action: String          // "none" | "optional" | "mandatory"
        var campaignId: String
        var title: String
        var message: String
        var minBuild: Int
        var storeUrl: String
    }

    static let build = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    private static let cacheKey = "appUpdate.decision.v1"
    private static let notNowKey = "appUpdate.notNow.v1"          // [campaignId: Date]
    private static let notNowFor: TimeInterval = 3 * 24 * 3600

    private var decision: Decision?
    private var window: UIWindow?
    private var shown: String?         // "<action>:<campaignId>" now on screen
    private var started = false
    private var ticker: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let d = try? JSONDecoder().decode(Decision.self, from: data) {
            decision = Self.sane(d)
        }
    }

    /// Called once at launch. Shows the remembered answer at once, then asks the server.
    func start() {
        guard !started else { return }
        started = true
        present()
        Task { await check() }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in await AppUpdateGate.shared.check() }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard let self, UIApplication.shared.applicationState == .active else { continue }
                await self.check()
            }
        }
    }

    /// Asks the server; on any failure the remembered answer stays.
    func check() async {
        let callable = Functions.functions(region: "me-central1").httpsCallable("appUpdateCheck")
        callable.timeoutInterval = 10
        let payload: [String: Any] = [
            "build": Self.build,
            "version": Self.version,
            "ios": UIDevice.current.systemVersion,
            "deviceId": DeviceRegistry.thisDeviceId,
        ]
        guard let res = try? await callable.call(payload), let d = res.data as? [String: Any] else { return }
        let next = Self.sane(Decision(
            action: d["action"] as? String ?? "none",
            campaignId: d["campaignId"] as? String ?? "",
            title: d["title"] as? String ?? "",
            message: d["message"] as? String ?? "",
            minBuild: (d["minBuild"] as? NSNumber)?.intValue ?? 0,
            storeUrl: d["storeUrl"] as? String ?? ""))
        decision = next
        if let next, let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
        present()
    }

    /// Nil for "none" and for anything that does not make sense.
    private static func sane(_ d: Decision) -> Decision? {
        guard d.action == "mandatory" || d.action == "optional", d.minBuild > 0,
              !d.title.isEmpty else { return nil }
        return d
    }

    /// What applies right now, given the remembered answer and the installed build.
    private var current: Decision? {
        guard let d = decision, Self.build < d.minBuild else { return nil }
        if d.action == "optional" {
            let notNow = UserDefaults.standard.dictionary(forKey: Self.notNowKey) as? [String: Date] ?? [:]
            if let at = notNow[d.campaignId], Date().timeIntervalSince(at) < Self.notNowFor { return nil }
        }
        return d
    }

    private func present() {
        let d = current
        let key = d.map { "\($0.action):\($0.campaignId):\($0.title):\($0.message)" }
        guard key != shown else { return }
        shown = key
        window?.isHidden = true
        window = nil
        guard let d, let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let root = UpdatePromptView(decision: d, onUpdate: { [weak self] in self?.openStore(d) },
                                    onNotNow: { [weak self] in self?.notNow(d) })
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    private func openStore(_ d: Decision) {
        let url = URL(string: d.storeUrl).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(string: "itms-apps://apps.apple.com")!
        UIApplication.shared.open(url)
    }

    private func notNow(_ d: Decision) {
        guard d.action == "optional" else { return }   // a mandatory update has no Not Now
        var map = UserDefaults.standard.dictionary(forKey: Self.notNowKey) as? [String: Date] ?? [:]
        map[d.campaignId] = Date()
        UserDefaults.standard.set(map, forKey: Self.notNowKey)
        shown = nil
        present()
    }
}

/// The two screens, in Kulan's own sheet layout (centred icon, bold title, grey text, the blue capsule).
private struct UpdatePromptView: View {
    let decision: AppUpdateGate.Decision
    let onUpdate: () -> Void
    let onNotNow: () -> Void

    private var mandatory: Bool { decision.action == "mandatory" }

    var body: some View {
        ZStack(alignment: .bottom) {
            if mandatory {
                // The whole app is behind this; nothing under it can be touched.
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer()
                    content
                    Spacer()
                    updateButton.padding(.horizontal, 24).padding(.bottom, 12)
                }
            } else {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }   // the card is the only thing to answer while it is up
                VStack(spacing: 0) {
                    content.padding(.top, 28)
                    updateButton.padding(.horizontal, 20).padding(.top, 24)
                    Button(action: onNotNow) {
                        Text("Not Now").font(.body.weight(.semibold)).foregroundStyle(Color.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                }
                .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 72, height: 72)
                .background(Color.blue.opacity(0.14), in: Circle())
            Text(decision.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Text(decision.message)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 28)
    }

    private var updateButton: some View {
        Button(action: onUpdate) {
            Text("Update Now")
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.blue, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
