import SwiftUI
import UIKit

// ⛔ THE PHONE IS NEARLY FULL — owner 2026-10-27, with the reference app's sheet: when the iPhone runs
// out of room nothing downloads, and the person should be told why and what to do, not left with
// photos that never open.
//
// The reference app's rules, kept as they are:
// · Free space is "available for important usage" (what iOS will free up for an app the person is
//   using, purgeable caches counted), not the raw free figure, which reads lower than the truth.
// · WARN below 5% of the phone's total, capped at 2 GB (2 GB alone is too much to ask of a 32 GB
//   phone). Asked to clear that much.
// · ONCE IN 3 DAYS at most, on the chat list (and on coming back to the app).
// · BELOW 400 MB IS CRITICAL. Theirs stops the app there; ours stops downloading instead: a download
//   tapped then is held (tap again once there is room) and the sheet comes up at once, cooldown or not.
//   Automatic downloads are held quietly.

@MainActor
enum LowStorage {
    private static let criticalBytes: Int64 = 400 * 1_000_000
    private static let warnCap: Int64 = 2 * 1_000_000_000
    private static let cooldown: TimeInterval = 3 * 86_400
    private static let lastShownKey = "lowStorage.lastWarningAt"
    /// A tapped download asks again at most once a minute, so a row of taps is one sheet.
    private static var lastForcedAt = Date.distantPast
    private static var started = false

    /// (free, total) in bytes, or nil when iOS will not say.
    static func space() -> (free: Int64, total: Int64)? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, free >= 0,
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return (free, Int64(total))
    }

    static func warnBelow(total: Int64) -> Int64 { min(Int64(Double(total) * 0.05), warnCap) }

    /// A download of `size` bytes (nil when not known yet) should not start: under the critical
    /// floor, or the file would take the phone below it.
    static func tooFullToDownload(size: Int64?) -> Bool {
        guard let s = space() else { return false }
        return s.free < criticalBytes + (size ?? 0)
    }

    /// Watch from the chat list: now, and every time the app comes back.
    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { checkAndWarn() }
        }
        // After the list has drawn, so the sheet is not the first thing to fight the launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { checkAndWarn() }
    }

    /// The 3-day warning.
    static func checkAndWarn() {
        guard let s = space(), s.free < warnBelow(total: s.total) else { return }
        let last = UserDefaults.standard.object(forKey: lastShownKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > cooldown else { return }
        if present(s) { UserDefaults.standard.set(Date(), forKey: lastShownKey) }
    }

    /// A tapped download that could not start.
    static func warnForDownload() {
        guard Date().timeIntervalSince(lastForcedAt) > 60, let s = space() else { return }
        if present(s) {
            lastForcedAt = Date()
            UserDefaults.standard.set(Date(), forKey: lastShownKey)
        }
    }

    /// On top of whatever is showing (a chat, a photo viewer). False when nothing could present it.
    @discardableResult
    private static func present(_ s: (free: Int64, total: Int64)) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { return false }
        while let next = top.presentedViewController { top = next }
        if top is LowStorageSheetHost { return false }
        let host = LowStorageSheetHost(rootView: LowStorageSheet(need: warnBelow(total: s.total)) {
            top.presentedViewController?.dismiss(animated: true)
        })
        host.view.backgroundColor = .clear
        if let sheet = host.sheetPresentationController {
            let h = host.sizeThatFits(in: CGSize(width: window.bounds.width, height: .greatestFiniteMagnitude)).height
            sheet.detents = [.custom { _ in h }]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 38
        }
        top.present(host, animated: true)
        return true
    }
}

final class LowStorageSheetHost: UIHostingController<LowStorageSheet> {}

/// The sheet: a warning sign, the title, what is wrong, three things to do, and OK.
struct LowStorageSheet: View {
    let need: Int64
    let onDone: () -> Void

    private var needText: String { ByteCountFormatter.string(fromByteCount: need, countStyle: .file) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.red.opacity(0.16)).frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .padding(.top, 34)
            Text("Your iPhone Is Almost Full")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Text("Photos, videos and voice messages can't download until there is more room, and a full iPhone can lose data. Clear at least \(needText).")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 14) {
                step(1, "In Settings, open General, then iPhone Storage, and remove apps you no longer use")
                step(2, "Delete large videos from Photos and from your chats")
                step(3, "Remove downloaded music, podcasts or films")
            }
            .padding(.top, 22)
            Button(action: onDone) {
                Text("OK")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.onFariinAction)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Capsule().fill(Color.fariinAction))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 26)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(.tertiarySystemFill)))
            Text(text)
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
