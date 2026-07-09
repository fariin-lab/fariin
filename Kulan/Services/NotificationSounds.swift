import Foundation
import AudioToolbox
import AVFoundation

// A notification tone the user can pick for a chat's message / call alerts.
//
// These are REAL, playable tones: built-in iOS alert sounds addressed by SystemSoundID (so nothing
// has to be bundled — they actually play), plus user-imported custom sounds. Tapping one in the
// picker previews it; the chosen message sound plays for FOREGROUND alerts (see PushManager). The
// BACKGROUND push sound is set by the server in the APNs payload — wiring that per-chat is a
// follow-up, so this is honestly foreground-only for now.
struct NotificationSound: Identifiable, Equatable {
    let id: String            // stable key stored in prefs
    let name: String
    var systemID: SystemSoundID? = nil   // built-in tone
    var customPath: String? = nil        // imported file (app support dir)

    static let none = NotificationSound(id: "none", name: "None")

    // Real Apple alert tones (IDs 1020–1036 are the named "alert" sounds; 1007 is the classic
    // tri-tone). All play via AudioServicesPlaySystemSound with no bundled file.
    static let builtIn: [NotificationSound] = [
        NotificationSound(id: "tritone",  name: "Note (default)", systemID: 1007),
        NotificationSound(id: "aurora",   name: "Aurora",     systemID: 1020),
        NotificationSound(id: "bloom",    name: "Bloom",      systemID: 1021),
        NotificationSound(id: "calypso",  name: "Calypso",    systemID: 1022),
        NotificationSound(id: "chord",    name: "Chord",      systemID: 1023),
        NotificationSound(id: "circles",  name: "Descent",    systemID: 1024),
        NotificationSound(id: "complete", name: "Fanfare",    systemID: 1025),
        NotificationSound(id: "hello",    name: "Ladder",     systemID: 1026),
        NotificationSound(id: "input",    name: "Minuet",     systemID: 1027),
        NotificationSound(id: "keys",     name: "News Flash", systemID: 1028),
        NotificationSound(id: "popcorn",  name: "Noir",       systemID: 1029),
        NotificationSound(id: "pulse",    name: "Sherwood",   systemID: 1030),
        NotificationSound(id: "synth",    name: "Spell",      systemID: 1031),
        NotificationSound(id: "telegraph",name: "Telegraph",  systemID: 1033),
        NotificationSound(id: "update",   name: "Update",     systemID: 1036),
    ]

    static let `default` = builtIn[0]

    // Resolve a stored id (built-in or "custom:<path>") back to a sound.
    static func resolve(_ id: String?) -> NotificationSound {
        guard let id, id != "none" else { return id == "none" ? .none : .default }
        if id.hasPrefix("custom:") {
            let path = String(id.dropFirst("custom:".count))
            let name = (path as NSString).lastPathComponent
            return NotificationSound(id: id, name: name, customPath: path)
        }
        return builtIn.first { $0.id == id } ?? .default
    }
}

// Per-chat sound preferences, stored locally (UserDefaults). Keyed by cid + kind (message/call).
enum SoundStore {
    enum Kind: String, Identifiable { case message, call; var id: String { rawValue } }
    private static func key(_ cid: String, _ kind: Kind) -> String { "sound_\(kind.rawValue)_\(cid)" }

    static func soundId(_ cid: String, _ kind: Kind) -> String {
        UserDefaults.standard.string(forKey: key(cid, kind)) ?? NotificationSound.default.id
    }
    static func sound(_ cid: String, _ kind: Kind) -> NotificationSound {
        NotificationSound.resolve(soundId(cid, kind))
    }
    static func set(_ cid: String, _ kind: Kind, _ sound: NotificationSound) {
        let stored = sound.customPath.map { "custom:\($0)" } ?? sound.id
        UserDefaults.standard.set(stored, forKey: key(cid, kind))
    }

    // Save an imported audio file into app support and return its stored path.
    static func importCustom(from url: URL) -> String? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let sounds = dir.appendingPathComponent("CustomSounds", isDirectory: true)
        try? fm.createDirectory(at: sounds, withIntermediateDirectories: true)
        let dest = sounds.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        // Security-scoped access for files coming from the Files app / iCloud.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try fm.copyItem(at: url, to: dest); return dest.path } catch { return nil }
    }
}

// Plays a tone for previewing / foreground alerts. Holds the AVAudioPlayer so custom sounds
// aren't deallocated mid-play.
final class SoundPlayer {
    static let shared = SoundPlayer()
    private init() {}
    private var player: AVAudioPlayer?
    private var registered: [String: SystemSoundID] = [:]

    func play(_ sound: NotificationSound) {
        if let sid = sound.systemID {
            AudioServicesPlaySystemSound(sid)
            return
        }
        if let path = sound.customPath {
            // Short custom sounds: AVAudioPlayer gives us full-length playback + retention.
            player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player?.play()
        }
    }
}
