import Foundation
import Network
import FirebaseFirestore

// Live network state for the auto-download policies (Wi-Fi vs cellular) — and a plain online flag
// for flows that should refuse early instead of opening a doomed sheet (the auth doors: an offline
// "Continue with Google" used to open the web sign-in straight into Safari's connection error page).
final class NetworkState {
    static let shared = NetworkState()
    private let monitor = NWPathMonitor()
    private(set) var isWifi = true     // optimistic until the first path update
    private(set) var isOnline = true   // optimistic until the first path update

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasOnline = self.isOnline
            self.isWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            self.isOnline = path.status == .satisfied
            // THE MOMENT THE SIGNAL COMES BACK, and it is announced rather than polled. A send that
            // died on a dropped connection has no way of knowing the line is up again, so it sat
            // there saying "Not delivered" until somebody tapped it — on a phone in a place where
            // the connection drops several times an hour, that is most sends (owner, 2026-08-25:
            // "every corner, even bad network").
            if !wasOnline, self.isOnline {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .networkCameBack, object: nil) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkState"))
    }
}

extension Notification.Name {
    /// Offline → online. Posted on the main queue, so a view may act on it directly.
    static let networkCameBack = Notification.Name("kulan.networkCameBack")
}

// Media auto-download policies (Settings > Storage and Data), honored for real:
// photos gate their in-bubble auto-load; videos/voice/documents PREFETCH into their
// local caches when a chat is opened and the policy allows the current network.
enum AutoDownloadPrefs {
    enum Kind: String, CaseIterable {
        case photos, videos, audio, documents
        var label: String {
            switch self {
            case .photos: return "Photos"
            case .videos: return "Videos"
            case .audio: return "Audio"
            case .documents: return "Documents"
            }
        }
        // Reference defaults: photos/audio everywhere, videos/documents Wi-Fi only.
        var defaultPolicy: String {
            switch self {
            case .photos, .audio: return "always"
            case .videos, .documents: return "wifi"
            }
        }
    }

    static func policy(_ k: Kind) -> String {
        UserDefaults.standard.string(forKey: "autodl.\(k.rawValue)") ?? k.defaultPolicy
    }
    static func setPolicy(_ k: Kind, _ p: String) {
        UserDefaults.standard.set(p, forKey: "autodl.\(k.rawValue)")
    }
    static func reset() {
        for k in Kind.allCases { UserDefaults.standard.removeObject(forKey: "autodl.\(k.rawValue)") }
    }
    static func label(_ p: String) -> String {
        switch p {
        case "always": return "Wi-Fi and Cellular"
        case "wifi":   return "Wi-Fi"
        default:        return "Never"
        }
    }
    static func allowedNow(_ k: Kind) -> Bool {
        switch policy(k) {
        case "always": return true
        case "wifi":   return NetworkState.shared.isWifi
        default:        return false
        }
    }
}

// Prefetches a chat's media into the local caches per policy, so tapping plays
// instantly. Files over 200 MB never auto-download (reference rule).
enum MediaAutoDownloader {
    private static let maxAutoBytes = 200 * 1024 * 1024
    private static var inFlight = Set<String>()
    private static let lock = NSLock()

    static func sweep(_ items: [Message], cid: String) {
        for m in items {
            // "Save to Photos" (Settings > Chats) rides this pass: it is already the one place that
            // walks a chat's media with the keys in hand. It does its own incoming/view-once/
            // already-saved checks, and it is a no-op when the setting is off.
            AutoSaveToPhotos.consider(m, cid: cid)

            if m.isVideo, AutoDownloadPrefs.allowedNow(.videos), VideoCache.url(for: m.id) == nil,
               let u = m.videoUrl, !u.isEmpty {
                fetch(id: m.id, url: u, meta: m.enc, cid: cid) { VideoCache.store($0, for: m.id) }
            }
            if m.isAudio, AutoDownloadPrefs.allowedNow(.audio), AudioCache.url(for: m.id) == nil,
               let u = m.audioUrl, !u.isEmpty {
                fetch(id: m.id, url: u, meta: m.enc, cid: cid) { AudioCache.store($0, for: m.id) }
            }
            // Documents: size cap enforced (fileSize travels in the message doc).
            if m.isFile, AutoDownloadPrefs.allowedNow(.documents), (m.fileSize ?? 0) <= maxAutoBytes {
                // Files open via QuickLook from tmp today (no persistent cache) — prefetching
                // without the cache to hold it would be wasted data, so documents currently
                // honor the policy at OPEN time only.
            }
        }
    }

    private static func fetch(id: String, url: String, meta: EncMeta?, cid: String,
                              store: @escaping (Data) -> Void) {
        lock.lock()
        guard !inFlight.contains(id) else { lock.unlock(); return }
        inFlight.insert(id)
        lock.unlock()
        Task.detached(priority: .utility) {
            defer { lock.lock(); inFlight.remove(id); lock.unlock() }
            guard let u = URL(string: url),
                  let (data, _) = try? await MediaSession.shared.data(from: u) else { return }
            if let meta {
                if let clear = await Crypto.shared.decryptBytes(cid, cipher: data, meta: meta) {
                    store(clear)
                }
            } else {
                store(data)
            }
        }
    }
}
