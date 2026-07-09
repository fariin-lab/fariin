import Foundation
import CryptoKit

// A numeric "safety number" for a 1:1 chat — the thing you compare (or scan) with the
// other person to confirm nobody is sitting in the middle of your end-to-end encryption.
//
// It's derived from BOTH participants' identity public keys (+ their uids), so it is
// identical on both phones when the keys are genuine. If a man-in-the-middle swapped
// either side's key, the two phones compute DIFFERENT numbers and the mismatch is visible.
//
// The math follows Signal's NumericFingerprint (iterated SHA-512, five bytes -> five
// decimal digits) because it's a proven construction; the screen around it is Kulan's own.
enum SafetyNumber {
    private static let iterations = 5200          // key-stretch: makes a truncated-digest preimage costly
    private static let version: [UInt8] = [0x00, 0x00]

    /// 60-digit safety number for a 1:1 chat. Deterministic AND symmetric —
    /// compute(me, them) on my phone == compute(them, me) on theirs.
    static func compute(myUid: String, myPub: Data, theirUid: String, theirPub: Data) -> String {
        let a = fingerprint(pub: myPub, id: myUid)
        let b = fingerprint(pub: theirPub, id: theirUid)
        let (first, second) = a <= b ? (a, b) : (b, a)   // stable order → same string on both sides
        return first + second
    }

    /// Display layout: 12 groups of 5 digits ("15123 11491 58743 …").
    static func grouped(_ number: String) -> [String] {
        stride(from: 0, to: number.count, by: 5).map { offset in
            let start = number.index(number.startIndex, offsetBy: offset)
            let end = number.index(start, offsetBy: 5, limitedBy: number.endIndex) ?? number.endIndex
            return String(number[start..<end])
        }
    }

    // What travels in the QR code — a versioned tag so the scanner rejects any other QR.
    static let qrPrefix = "kulanverify:v1:"
    static func qrPayload(_ number: String) -> String { qrPrefix + number }
    static func numberFromQR(_ code: String) -> String? {
        guard code.hasPrefix(qrPrefix) else { return nil }
        let n = String(code.dropFirst(qrPrefix.count))
        return (n.count == 60 && n.allSatisfy(\.isNumber)) ? n : nil
    }

    // MARK: - Internals

    // 30-digit per-identity fingerprint: iterate SHA-512(hash ‖ publicKey), then take the
    // first 30 bytes and turn each 5-byte chunk into 5 decimal digits.
    private static func fingerprint(pub: Data, id: String) -> String {
        var hash = Data(version) + pub + Data(id.utf8)
        for _ in 0..<iterations {
            var h = SHA512()
            h.update(data: hash)
            h.update(data: pub)                 // re-mix the key each round (Signal does the same)
            hash = Data(h.finalize())
        }
        var digits = ""
        for chunk in 0..<6 {
            let lo = hash.startIndex + chunk * 5
            digits += encode(Data(hash[lo ..< lo + 5]))
        }
        return digits
    }

    // Five big-endian bytes → a 5-digit decimal group.
    private static func encode(_ five: Data) -> String {
        var v: UInt64 = 0
        for b in five { v = (v << 8) | UInt64(b) }
        return String(format: "%05llu", v % 100_000)
    }
}
