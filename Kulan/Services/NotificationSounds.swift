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
    var systemID: SystemSoundID? = nil   // built-in tone (fallback playback)
    var customPath: String? = nil        // imported file (app support dir)
    var bundleFile: String? = nil        // ringtone shipped in the app bundle (CallKit needs a
                                         // bundle FILENAME, which is why ringtones can't be
                                         // system tones or imported files)

    // The on-device .caf file backing a built-in tone. Playing THIS through an AVAudioPlayer on a
    // .playback session makes the tone actually audible (even on the mute switch) — the fix for
    // "it only vibrates". The `id`s below already ARE the system file base-names (aurora, bloom…);
    // the default "tritone" maps to Note.caf.
    var cafPath: String? {
        guard systemID != nil else { return nil }
        let base = (id == "tritone") ? "Note" : id.prefix(1).uppercased() + id.dropFirst()
        return "/System/Library/Audio/UISounds/New/\(base).caf"
    }

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

    // No app-wide `default` any more: message and call have their own, below. A single shared
    // default is what made a call and a message play the same Apple blip.

    // RINGTONES — a separate list from the message tones above, which is the actual bug the user hit:
    // both pickers were fed `builtIn`, so a call and a message played the identical short alert blip.
    // A ring has to be a LONG, LOOPING, melodic phrase, and CallKit will only play a file that ships
    // in the app bundle. These are our own synthesised tones (Kulan/Resources/Ringtones), so there's
    // no licensing question and nothing is copied from another app.
    static let ringtones: [NotificationSound] = [
        NotificationSound(id: "kulan",   name: "Kulan (default)", bundleFile: "kulan_ringtone.wav"),
        NotificationSound(id: "ascend",  name: "Ascend",  bundleFile: "ring_ascend.wav"),
        NotificationSound(id: "beacon",  name: "Beacon",  bundleFile: "ring_beacon.wav"),
        NotificationSound(id: "ripple",  name: "Ripple",  bundleFile: "ring_ripple.wav"),
        NotificationSound(id: "lantern", name: "Lantern", bundleFile: "ring_lantern.wav"),
        NotificationSound(id: "nomad",   name: "Nomad",   bundleFile: "ring_nomad.wav"),
    ]

    static let defaultRingtone = ringtones[0]

    // MESSAGE TONES — OUR OWN bundled sounds, and deliberately the SAME list Settings > Notifications >
    // Sound offers. Those two screens used to show completely different catalogues for the same setting:
    // Settings offered these bundled files (and stores the choice in `notif.sound`, which the server puts
    // in the APNs payload), while the per-chat picker offered Apple's system alert tones. So a per-chat
    // choice could never match what a notification actually played, and the two lists shared no names.
    // The user asked for the Settings list everywhere, which is also the correct one: it is what pushes use.
    ///
    /// EVERY ENTRY IS OURS. The list used to open with a "Default" that was Apple's Note
    /// (systemID 1007) — iMessage's tone. Kulan then sounded like iMessage in the foreground
    /// while the server's push played our Rebound, so one message made two different noises
    /// depending on whether the app happened to be open. A messenger's alert is how people
    /// know which app buzzed without looking, so it has to be ours and it has to be one sound.
    static let messageTones: [NotificationSound] = [
        NotificationSound(id: "rebound", name: "Rebound (default)", bundleFile: "rebound.wav"),
        NotificationSound(id: "chime",   name: "Chime",   bundleFile: "chime.wav"),
        NotificationSound(id: "pop",     name: "Pop",     bundleFile: "pop.wav"),
        NotificationSound(id: "pulse",   name: "Pulse",   bundleFile: "pulse.wav"),
        NotificationSound(id: "marimba", name: "Marimba", bundleFile: "marimba.wav"),
    ]

    static let defaultMessageTone = messageTones[0]

    /// Resolve a stored id against the MESSAGE tone list — ours FIRST, which matters because
    /// "pulse" exists in both lists and the Apple one used to win. `builtIn` stays as a fallback
    /// for a choice made before this list existed. A legacy "default" lands on Rebound.
    static func resolveMessageTone(_ id: String?) -> NotificationSound {
        guard let id, id != "default" else { return .defaultMessageTone }
        if id == "none" { return .none }
        return messageTones.first { $0.id == id }
            ?? builtIn.first { $0.id == id }
            ?? .defaultMessageTone
    }

    /// Resolve a stored id against the RINGTONE list (calls), not the alert list.
    static func resolveRingtone(_ id: String?) -> NotificationSound {
        guard let id else { return .defaultRingtone }
        if id == "none" { return .none }
        if id.hasPrefix("custom:") {
            let path = String(id.dropFirst("custom:".count))
            return NotificationSound(id: id, name: (path as NSString).lastPathComponent, customPath: path)
        }
        return ringtones.first { $0.id == id } ?? .defaultRingtone
    }

    // NOTE: the old generic `resolve(_:)` is gone. It searched Apple's system tones for a
    // message-tone id and was the bug above; custom imported sounds were removed earlier, so
    // it had no honest caller left. Use `resolveMessageTone` or `resolveRingtone`.
}

// Per-chat sound preferences, stored locally (UserDefaults). Keyed by cid + kind (message/call).
enum SoundStore {
    enum Kind: String, Identifiable { case message, call; var id: String { rawValue } }
    private static func key(_ cid: String, _ kind: Kind) -> String { "sound_\(kind.rawValue)_\(cid)" }

    /// Message and call have DIFFERENT defaults — the old shared default is why both rows read
    /// "Note (default)" and both played the same blip.
    static func defaultSound(_ kind: Kind) -> NotificationSound {
        kind == .call ? .defaultRingtone : .defaultMessageTone
    }
    static func soundId(_ cid: String, _ kind: Kind) -> String {
        UserDefaults.standard.string(forKey: key(cid, kind)) ?? defaultSound(kind).id
    }
    static func sound(_ cid: String, _ kind: Kind) -> NotificationSound {
        let id = soundId(cid, kind)
        // `resolveMessageTone`, NOT `resolve`: the generic one searches Apple's system tones,
        // so a per-chat choice of Chime returned Note, and Pulse returned Apple's Sherwood
        // (that id exists in both lists). The picker previewed the right tone and playback used
        // a different one — the preview was already calling resolveMessageTone; this was not.
        return kind == .call ? NotificationSound.resolveRingtone(id) : NotificationSound.resolveMessageTone(id)
    }
    /// The bundle filename CallKit should ring for this chat (nil → the app default).
    static func ringtoneFile(_ cid: String?) -> String? {
        guard let cid else { return NotificationSound.defaultRingtone.bundleFile }
        let s = sound(cid, .call)
        if s.id == "none" { return nil }                     // muted ring for this chat
        return s.bundleFile ?? NotificationSound.defaultRingtone.bundleFile
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

    func play(_ sound: NotificationSound, loop: Bool = false) {
        guard sound.id != "none" else { return }
        // A bundled ringtone is a real file — play it directly (this is the preview you hear in the
        // Call Sound picker; CallKit plays the same file when the phone actually rings).
        if let file = sound.bundleFile,
           let url = Bundle.main.url(forResource: (file as NSString).deletingPathExtension,
                                     withExtension: (file as NSString).pathExtension) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.duckOthers])
                try session.setActive(true)
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = loop ? -1 : 0
                player = p
                p.play()
                return
            } catch { /* fall through */ }
        }
        // Prefer a real audio file (custom import, else the tone's on-device .caf) played through a
        // .playback session so it's AUDIBLE — the system-alert route (AudioServicesPlaySystemSound)
        // is muted by the ring/silent switch, which is why it only vibrated. Fall back to the system
        // sound if the file is missing.
        let path = sound.customPath ?? sound.cafPath
        if let path, FileManager.default.fileExists(atPath: path) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.duckOthers])
                try session.setActive(true)
                let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                player = p          // retain so it isn't deallocated mid-play
                p.play()
                return
            } catch { /* fall through to the system tone */ }
        }
        if let sid = sound.systemID { AudioServicesPlaySystemSound(sid) }
    }
}
