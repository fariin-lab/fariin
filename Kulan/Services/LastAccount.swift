import UIKit
import FirebaseAuth

/// ⛔ THE ACCOUNT THIS PHONE LAST USED — owner, 2026-09-25: "when I tap Log In, show the account I
/// logged in with before". The large apps' saved-account row: a face, a name and the handle, and one
/// tap goes back in through the same door.
///
/// What is kept, and why only this: the name, the handle, the door (Apple, Google or email), a small
/// copy of the photo, and for the email door the address, so the field is filled in. Nothing that
/// signs anybody in: every tap still goes through Apple, Google or the password. It survives sign-out
/// on purpose (that is the whole feature) and is forgotten when the account is deleted, or from the
/// row's own menu.
enum LastAccount {
    struct Info: Codable, Equatable {
        let uid: String
        let name: String
        let handle: String
        /// `AuthService.SignInMethod.rawValue`
        let method: String
        let email: String?
    }

    private static let key = "lastAccount.info"

    private static var photoURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LastAccount", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(values)
        return dir.appendingPathComponent("avatar.jpg")
    }

    static func load() -> Info? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    static func photo() -> UIImage? {
        guard load() != nil, let data = try? Data(contentsOf: photoURL) else { return nil }
        return UIImage(data: data)
    }

    /// Called while signed in, whenever the profile or its photo changes. Cheap and idempotent.
    static func remember() {
        guard let user = Auth.auth().currentUser, let me = ProfileStore.shared.me, me.id == user.uid,
              !me.handle.isEmpty, let method = AuthService.lastSignInMethod else { return }
        let info = Info(uid: user.uid, name: me.name, handle: me.handle, method: method.rawValue,
                        email: method == .email ? user.email : nil)
        if info != load(), let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // The photo as it is drawn right now; a removed photo removes the copy.
        if let img = ProfilePhotoLoader.shared.cachedAvatar(me.photoUrl),
           let jpeg = img.preparingThumbnail(of: CGSize(width: 160, height: 160))?.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: photoURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if (me.photoUrl ?? "").isEmpty {
            try? FileManager.default.removeItem(at: photoURL)
        }
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: photoURL)
    }
}
