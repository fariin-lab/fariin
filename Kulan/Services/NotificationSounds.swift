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
    //
    // TIDE IS THE DEFAULT AND IT IS THE NEWEST (owner, 2026-08-21). He asked for one more in the same
    // family, a little different from the six, and sent a recording of the tone he rings with on his
    // own phone. Two things were measured off that recording and both are in this one: its pulse is
    // exactly two a second, and it is far warmer than anything we had. So Tide keeps the house shape
    // and opens an octave and a half below the rest, on a low A3, where none of the others go.
    // `tools/make-ringtone.js` renders it and holds the whole reasoning. Nothing about it is copied:
    // the notes are A major, the chord the app's first ringtone was already built from.
    static let ringtones: [NotificationSound] = [
        NotificationSound(id: "tide",    name: "Tide (default)", bundleFile: "ring_tide.wav"),
        NotificationSound(id: "kulan",   name: "Fariin",  bundleFile: "kulan_ringtone.wav"),
        NotificationSound(id: "ascend",  name: "Ascend",  bundleFile: "ring_ascend.wav"),
        NotificationSound(id: "beacon",  name: "Beacon",  bundleFile: "ring_beacon.wav"),
        NotificationSound(id: "ripple",  name: "Ripple",  bundleFile: "ring_ripple.wav"),
        NotificationSound(id: "lantern", name: "Lantern", bundleFile: "ring_lantern.wav"),
        NotificationSound(id: "nomad",   name: "Nomad",   bundleFile: "ring_nomad.wav"),
    ]

    static let defaultRingtone = ringtones[0]

    /// THE PHONE'S OWN RINGTONE — Reflection, Buoyant, Dreamer, Pond, Surge, whatever the person
    /// has chosen in Settings > Sounds & Haptics > Ringtone.
    ///
    /// This is the ONLY way an app can ring with one of Apple's tones, and it is worth writing down
    /// why the obvious version is impossible. `CXProviderConfiguration.ringtoneSound` is, in Apple's
    /// own words, "the name of the sound resource in the app bundle" — a filename, nothing else. It
    /// cannot take a path, a URL or a system sound id. Apple's ringtones are `.m4r` files under
    /// `/Library/Ringtones`, outside our sandbox, and copying them into our bundle would be shipping
    /// Apple's audio inside our binary. So a picker listing them by name cannot exist.
    ///
    /// What CAN happen: leave `ringtoneSound` nil and CallKit rings whatever the phone is set to.
    /// One row, not seven, and we never learn which tone it is — which is also why tapping this row
    /// previews nothing. There is no API to read the choice, let alone play it.
    ///
    /// ⚠️ NOT DOCUMENTED BY APPLE. The nil case is not written down anywhere; it is how every CallKit
    /// app that never sets a ringtone behaves. NEEDS ONE DEVICE CHECK: pick this, ring yourself, and
    /// confirm you hear the phone's ringtone rather than silence.
    static let systemRingtone = NotificationSound(id: "system", name: "iPhone Ringtone")

    // MESSAGE TONES — OUR OWN bundled sounds, and deliberately the SAME list Settings > Notifications >
    // Sound offers. Those two screens used to show completely different catalogues for the same setting:
    // Settings offered these bundled files (and stores the choice in `notif.sound`, which the server puts
    // in the APNs payload), while the per-chat picker offered Apple's system alert tones. So a per-chat
    // choice could never match what a notification actually played, and the two lists shared no names.
    // The user asked for the Settings list everywhere, which is also the correct one: it is what pushes use.
    ///
    /// ⛔ APPLE'S NOTE IS THE DEFAULT AGAIN — owner, 2026-08-23: "plz chnage defulit message sounde
    /// use apple message a sound by default … Note (Default)".
    ///
    /// ⚠️ THIS REVERSES A DELIBERATE REMOVAL AND HE SHOULD KNOW WHAT IT COSTS. The list used to open
    /// with a "Default" that was this exact tone, and it was taken out because the FOREGROUND alert
    /// and the LOCK-SCREEN push are played by two different things: the app plays the chosen tone
    /// itself, and the server names a sound in the APNs payload. Note is not a file we can ship — it
    /// lives in `/System/Library/Audio/UISounds` and belongs to Apple — so the push cannot name it,
    /// and the two ends can only agree if APNs' own `"sound": "default"` happens to be the same
    /// noise. That is not documented and cannot be checked from here.
    ///
    /// ⚠️ SO THIS IS THE CLIENT HALF ONLY, AND IT NEEDS A DEVICE AND A SERVER CHANGE TO FINISH. Send
    /// yourself a message with the app OPEN, then with it LOCKED, and say whether the two sound the
    /// same. If they do not, either the server sends `"default"` for this tone or the default goes
    /// back to Rebound — that is his call, not one to make in code.
    static let messageTones: [NotificationSound] = [
        NotificationSound(id: "tritone", name: "Note (Default)", systemID: 1007),
        NotificationSound(id: "rebound", name: "Rebound", bundleFile: "rebound.wav"),
        NotificationSound(id: "chime",   name: "Chime",   bundleFile: "chime.wav"),
        NotificationSound(id: "pop",     name: "Pop",     bundleFile: "pop.wav"),
        NotificationSound(id: "pulse",   name: "Pulse",   bundleFile: "pulse.wav"),
        NotificationSound(id: "marimba", name: "Marimba", bundleFile: "marimba.wav"),
    ]

    static let defaultMessageTone = messageTones[0]

    /// Resolve a stored id against the MESSAGE tone list — ours FIRST, which matters because
    /// "pulse" exists in both lists and the Apple one used to win. `builtIn` stays as a fallback
    /// for a choice made before this list existed. A legacy "default" lands on Note, which is the
    /// tone it originally named — see the note on `messageTones`.
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
        if id == "system" { return .systemRingtone }
        // Kept for accounts that picked the old "None" row, which rang the phone's tone anyway.
        if id == "none" { return .systemRingtone }
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
    /// ⛔ THE CALL SOUND PICKER IS HIDDEN, NOT DELETED (owner, 2026-08-21: "call sound Hide that
    /// feature Plz dont delete the code just hide we will use feature but now hide plz and Use only
    /// iphone sound").
    ///
    /// Flip this back to true and the whole feature returns exactly as it was: the row in Sounds &
    /// Notifications, the picker, the seven tones, the per-chat storage. Nothing about it has been
    /// removed and `NotificationSound.ringtones` is still the list it will come back with.
    ///
    /// While it is false, EVERY call rings the phone's own ringtone — `ringtoneFile` returns nil for
    /// every chat, which is what hands the choice to iOS. Any per-chat tone somebody already picked
    /// is left in UserDefaults untouched and starts working again the moment this is true.
    static let callSoundPickerEnabled = false
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
    /// The bundle filename CallKit should ring for this chat, or nil to let the phone choose.
    static func ringtoneFile(_ cid: String?) -> String? {
        // ⛔ HIDDEN MEANS HIDDEN EVERYWHERE, not just on the settings screen. With the picker put
        // away, a chat that was set to Ripple last week must not go on ringing Ripple — he asked for
        // the phone's own sound and this is the one line that delivers it. The stored choice is not
        // erased; it simply is not consulted until the flag comes back.
        guard callSoundPickerEnabled else { return nil }
        guard let cid else { return NotificationSound.defaultRingtone.bundleFile }
        let s = sound(cid, .call)
        // ⚠️ NIL DOES NOT MEAN SILENCE, whatever the old comment here said. CallKit rings SOMETHING
        // for every incoming call, and with no bundle filename to ring it falls back to the tone the
        // phone is set to. That is the whole mechanism behind `systemRingtone`, and it means the old
        // "None" row never muted a call — it handed the ring to iOS. Both ids land here for that
        // reason: they have always done the same thing, and now only one of them is offered.
        if s.id == "none" || s.id == "system" { return nil }
        return s.bundleFile ?? NotificationSound.defaultRingtone.bundleFile
    }
    static func set(_ cid: String, _ kind: Kind, _ sound: NotificationSound) {
        let stored = sound.customPath.map { "custom:\($0)" } ?? sound.id
        UserDefaults.standard.set(stored, forKey: key(cid, kind))
    }
    /// Any chat carrying a custom message/call tone. "Reset All Notifications" promises to undo
    /// every custom notification setting but only ever unmuted, and it was disabled whenever
    /// nothing was muted — so a chat with a custom sound could not be reset at all (audit).
    static var hasAnyCustom: Bool {
        UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix("sound_") }
    }
    static func clearAllCustom() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("sound_") { d.removeObject(forKey: k) }
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
        // Neither of these is a file we hold. "None" is silence by definition, and the phone's own
        // ringtone cannot be read by an app at all, let alone played — see `systemRingtone`.
        guard sound.id != "none", sound.id != "system" else { return }
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
