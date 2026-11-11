import Foundation
import AudioToolbox
import AVFoundation
import FirebaseAuth
import FirebaseFirestore

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
    /// ⛔ A CHAT WITH NO TONE OF ITS OWN FOLLOWS SETTINGS › NOTIFICATIONS › SOUND — owner,
    /// 2026-09-25: "I chose a different sound and a message still plays Note". The foreground push
    /// path reads this, and it fell straight to Note, skipping the Settings pick. Same order as the
    /// server's `apsSoundFor`: the chat's own tone, then the Settings pick, then Note.
    static func soundId(_ cid: String, _ kind: Kind) -> String {
        if let own = UserDefaults.standard.string(forKey: key(cid, kind)) { return own }
        if kind == .message, let pick = UserDefaults.standard.string(forKey: "notif.sound") { return pick }
        return defaultSound(kind).id
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
        if kind == .message { syncPushSound(cid, sound) }
    }

    /// 2026-09-24 fix-all #174: a push that arrives while the app is in the background plays the
    /// sound NAMED IN THE PAYLOAD, which the server set to "default" for every chat, so a per-chat
    /// tone only ever played in the foreground. The choice is mirrored to `users/{me}/push/sounds`
    /// (owner-only, like the push tokens beside it; the public user doc would reveal my chat ids),
    /// one field per chat: the tone's bundle filename, "none" for silence, or no field for the
    /// default. onNewMessage reads it for the recipient. The system tones have no file in our bundle
    /// that APNs can name, so they (and the Note default) stay "default".
    private static func syncPushSound(_ cid: String, _ sound: NotificationSound) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = FirestoreHub.db.document("users/\(uid)/push/sounds")
        let value: Any
        if sound.id == NotificationSound.none.id { value = "none" }
        else if let file = sound.bundleFile { value = file }
        else { value = FieldValue.delete() }
        Task { try? await ref.setData([cid: value], merge: true) }
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
        // 2026-09-24 fix-all #174: and the server's copy, so background pushes go back to default too.
        if let uid = Auth.auth().currentUser?.uid {
            Task { try? await FirestoreHub.db.document("users/\(uid)/push/sounds").delete() }
        }
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

// Plays a tone for previewing / foreground alerts.
//
// Two paths, and neither runs on the main thread (perf audit 2026-11-11, E1):
//
// - `playAlert`: a message arriving while the app is open. Done the way the reference app does its
//   in-app tones: the file is registered once as a system sound and played as one. A system sound
//   never touches the app's audio session, so music or a podcast in another app keeps playing at
//   full volume (it used to stay ducked after the first alert), a voice note or call in this app is
//   not disturbed, and there is no 100-300 ms `setActive` on the main thread while the banner slides
//   in. Like every iOS alert it follows the ring/silent switch.
// - `play`: the preview in the sound picker, which the user asked to hear, so it still plays through
//   a .playback session (audible on silent). The session is now let go when the tone ends, with
//   `.notifyOthersOnDeactivation`, so other apps' audio comes back up.
final class SoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SoundPlayer()
    private override init() {}
    private let queue = DispatchQueue(label: "SoundPlayer", qos: .userInitiated)
    // Touched only on `queue`.
    private var player: AVAudioPlayer?
    private var registered: [String: SystemSoundID] = [:]

    /// The file behind a tone: a bundled ringtone, an imported file, or the tone's on-device .caf.
    private func fileURL(_ sound: NotificationSound) -> URL? {
        if let file = sound.bundleFile,
           let url = Bundle.main.url(forResource: (file as NSString).deletingPathExtension,
                                     withExtension: (file as NSString).pathExtension) {
            return url
        }
        if let path = sound.customPath ?? sound.cafPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Foreground message alert. Safe to call from any thread.
    func playAlert(_ sound: NotificationSound) {
        guard sound.id != "none", sound.id != "system" else { return }
        queue.async { [self] in
            if let url = fileURL(sound) {
                let key = url.path
                var sid = registered[key] ?? 0
                if sid == 0, AudioServicesCreateSystemSoundID(url as CFURL, &sid) == kAudioServicesNoError {
                    registered[key] = sid
                }
                if sid != 0 { AudioServicesPlaySystemSound(sid); return }
            }
            // A file the system cannot take as an alert (too long, odd format): the built-in tone.
            if let sid = sound.systemID { AudioServicesPlaySystemSound(sid) }
        }
    }

    /// Picker preview. Safe to call from any thread.
    func play(_ sound: NotificationSound, loop: Bool = false) {
        // Neither of these is a file we hold. "None" is silence by definition, and the phone's own
        // ringtone cannot be read by an app at all, let alone played. See `systemRingtone`.
        guard sound.id != "none", sound.id != "system" else { return }
        queue.async { [self] in
            if let url = fileURL(sound) {
                do {
                    player?.stop()
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, options: [.duckOthers])
                    try session.setActive(true)
                    let p = try AVAudioPlayer(contentsOf: url)
                    p.numberOfLoops = loop ? -1 : 0
                    p.delegate = self
                    player = p      // retain so it isn't deallocated mid-play
                    p.play()
                    return
                } catch { /* fall through to the system tone */ }
            }
            if let sid = sound.systemID { AudioServicesPlaySystemSound(sid) }
        }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        queue.async { [self] in
            guard player === p else { return }   // a newer preview took over; it releases the session
            player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
