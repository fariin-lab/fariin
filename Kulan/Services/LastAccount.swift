import UIKit
import FirebaseAuth

/// ⛔ THE ACCOUNTS THIS PHONE HAS USED — owner, 2026-09-25: "when I tap Log In, show the account I
/// logged in with before", then, the same day, a design with EVERY saved account as its own card
/// above "Add another account". The large apps' saved-accounts screen: a face, a name and the
/// handle per account, and one tap goes back in through that account's own door.
///
/// What is kept per account, and why only this: the name, the handle, the door (Apple, Google or
/// email), a small copy of the photo, and for the email door the address, so the field is filled in.
/// Nothing that signs anybody in: every tap still goes through Apple, Google or the password. It
/// survives sign-out on purpose (that is the whole feature). An account is forgotten when it is
/// deleted, or from its card's menu. Newest first, at most `limit`.
enum LastAccount {
    struct Info: Codable, Equatable, Identifiable {
        let uid: String
        let name: String
        let handle: String
        /// `AuthService.SignInMethod.rawValue`
        let method: String
        let email: String?
        var id: String { uid }
    }

    static let limit = 5
    private static let key = "lastAccounts.v1"
    /// The single-account key of the first version, read once so nobody loses their card.
    private static let legacyKey = "lastAccount.info"

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LastAccount", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var copy = d; try? copy.setResourceValues(values)
        return d
    }
    private static func photoURL(_ uid: String) -> URL {
        let safe = uid.filter { $0.isLetter || $0.isNumber }
        return dir.appendingPathComponent("\(safe).jpg")
    }

    /// Every saved account, newest first.
    static func all() -> [Info] {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Info].self, from: data) {
            return list
        }
        // First run after the upgrade: carry the single saved account over.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let one = try? JSONDecoder().decode(Info.self, from: data) {
            save([one])
            UserDefaults.standard.removeObject(forKey: legacyKey)
            let old = dir.appendingPathComponent("avatar.jpg")
            if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.moveItem(at: old, to: photoURL(one.uid))
            }
            return [one]
        }
        return []
    }

    /// The most recent one (kept for callers that only need that).
    static func load() -> Info? { all().first }

    static func photo(for uid: String) -> UIImage? {
        guard let data = try? Data(contentsOf: photoURL(uid)) else { return nil }
        return UIImage(data: data)
    }

    private static func save(_ list: [Info]) {
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Called while signed in, whenever the profile or its photo changes. Cheap and idempotent:
    /// moves the signed-in account to the front and refreshes its card.
    static func remember() {
        guard let user = Auth.auth().currentUser, let me = ProfileStore.shared.me, me.id == user.uid,
              !me.handle.isEmpty, let method = AuthService.lastSignInMethod else { return }
        let info = Info(uid: user.uid, name: me.name, handle: me.handle, method: method.rawValue,
                        email: method == .email ? user.email : nil)
        var list = all()
        if list.first != info {
            list.removeAll { $0.uid == info.uid }
            list.insert(info, at: 0)
            // An account pushed off the end takes its photo with it.
            for dropped in list.dropFirst(limit) { try? FileManager.default.removeItem(at: photoURL(dropped.uid)) }
            save(list)
        }
        // The photo as it is drawn right now; a removed photo removes the copy.
        if let img = ProfilePhotoLoader.shared.cachedAvatar(me.photoUrl),
           let jpeg = img.preparingThumbnail(of: CGSize(width: 160, height: 160))?.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: photoURL(user.uid), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if (me.photoUrl ?? "").isEmpty {
            try? FileManager.default.removeItem(at: photoURL(user.uid))
        }
    }

    /// One account off this phone (its card's menu, or the account was deleted).
    static func forget(_ uid: String) {
        save(all().filter { $0.uid != uid })
        try? FileManager.default.removeItem(at: photoURL(uid))
    }
}
