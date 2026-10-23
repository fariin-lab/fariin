import Foundation
import CryptoKit

/// Group call black box (2026-10-23, controls round 2). Until today a group call wrote one line to the
/// diagnostics log, JOIN#, and only on success. A report like "the mic came back on by itself" or "the
/// share froze for the others" could only be answered by reading code. Now every button action,
/// publish result, reconnect step and join failure writes one `GC#` line into `DiagLog`.
///
/// Privacy, the same rule as Telemetry: the room id is hashed (salted SHA-256, first 6 bytes), and a
/// line never carries a uid, a name, message text or a token. Callers pass fixed words only
/// (`"mic"`, `"off"`, `"fail"`), plus short codes such as `Telemetry.errorCode`.
///
/// `GCLog.event("tap", room: id, ["what": "mic", "to": "off"])` writes
/// `GC# tap room=3fa91c0d2b4e to=off what=mic`. Fields are sorted so lines read the same every time.
enum GCLog {
    static func event(_ name: String, room: String?, _ fields: [String: String] = [:]) {
        var line = "GC# \(clean(name, 24))"
        if let room, !room.isEmpty { line += " room=\(hashRoom(room))" }
        for key in fields.keys.sorted() {
            line += " \(clean(key, 16))=\(clean(fields[key] ?? "", 40))"
        }
        DiagLog.add(line)
    }

    /// A failure the user saw or will see: write the line and send the log in a few seconds, so it
    /// reaches us the same day instead of waiting for some later stall to flag it.
    static func failure(_ name: String, room: String?, _ fields: [String: String] = [:]) {
        event(name, room: room, fields)
        DiagLog.flagForUpload()
    }

    /// Same room, same hash on every phone, so two phones' logs of one call line up; the id itself
    /// cannot be read back from it.
    static func hashRoom(_ room: String) -> String {
        let digest = SHA256.hash(data: Data(("kulan.gc.v1:" + room).utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps a value to one short token: no spaces or `=` (they would break the line's shape), and a
    /// length cap so nothing long slips in by mistake.
    private static func clean(_ s: String, _ max: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.:/"))
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(mapped.prefix(max))
    }
}
