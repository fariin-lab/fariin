import Foundation

/// What the Home Screen widgets show, written by the app into the App Group and read by the widget
/// extension. Names and photo addresses only, never message text. Faces are the files the app leaves
/// through `NotifShared.saveAvatar`.
enum WidgetShared {
    static let chatsKind = "FariinChats"
    static let storiesKind = "FariinStories"

    struct Person: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var photo: String?
        var unseen = false
        var channel = false
    }

    struct Snapshot: Codable, Equatable {
        var signedIn = false
        /// App Lock is on: the widgets show no names or faces.
        var locked = false
        var me: Person?
        var chats: [Person] = []
        var stories: [Person] = []
    }

    static func read() -> Snapshot {
        guard let d = NotifShared.defaults?.data(forKey: NotifShared.widgetKey),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return Snapshot() }
        return s
    }

    static func write(_ s: Snapshot) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        NotifShared.defaults?.set(d, forKey: NotifShared.widgetKey)
    }

    private static func link(_ kind: String, _ value: String) -> URL {
        let v = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        return URL(string: "kulan://\(kind)/\(v)") ?? URL(string: "kulan://wadd/new")!
    }
    static func chatLink(_ id: String) -> URL { link("wchat", id) }
    static func storyLink(_ id: String) -> URL { link("wstory", id) }
    static var addStoryLink: URL { link("wadd", "new") }
}
