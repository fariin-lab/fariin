import UIKit

/// HOW BIG A SENT PHOTO IS (owner 2026-10-23, build 1015: "sending a photo takes long").
///
/// Two levels, chosen per send with the HD button on the editor and the album screen:
///
/// - Standard, the default: long side at most 1280 px. This is what the reference app sends unless
///   HD is on, and a 12 MP photo comes out around 150-300 KB, so it is gone in a second or two on a
///   normal connection.
/// - High (HD): long side at most 2560 px, the reference app's HD size. Roughly four times the
///   bytes of Standard.
///
/// JPEG quality 0.6 on both. Both reference apps encode at 0.6 through ImageIO (the second one
/// lowers it to 0.55 only above 3072 px, which we never reach), and it is visibly fine at these
/// sizes. We used to send 1600 px at 0.72, which was bigger than either reference's default.
///
/// Byte ceilings are the second reference's: 1.5 MB for Standard, 3 MB for HD. A photo that still
/// comes out over its ceiling (heavy noise, a scan of fine print) is redrawn smaller, a quarter off
/// the long side each try, rather than refused.
///
/// The HD button starts in the state of Settings > Storage and Data > Sent Media Quality and is NOT
/// remembered after the send. That is the second reference's rule; the first one keeps the last
/// choice, which is how somebody ends up sending every photo in HD weeks after one tap.
enum PhotoQuality: Equatable, Sendable {
    case standard
    case high

    /// The level a send starts at when nobody touched the HD button.
    static var `default`: PhotoQuality {
        UserDefaults.standard.string(forKey: "sentMediaQuality") == "high" ? .high : .standard
    }

    init(hd: Bool) { self = hd ? .high : .standard }

    var isHD: Bool { self == .high }

    /// Longest side of the sent photo, in pixels.
    var maxSide: CGFloat {
        switch self {
        case .standard: return 1280
        case .high:     return 2560
        }
    }

    /// JPEG compression quality (UIKit/ImageIO scale, 0...1).
    var jpegQuality: CGFloat { 0.6 }

    /// Above this the photo is redrawn smaller.
    var maxBytes: Int {
        switch self {
        case .standard: return 1_572_864   // 1.5 MB
        case .high:     return 3_145_728   // 3 MB
        }
    }

    /// Never shrink below this while chasing the byte ceiling; send what we have instead.
    static let minSide: CGFloat = 640

    /// The pixel size a photo of `pixels` is drawn at for this level, before any byte-ceiling retry.
    /// Never enlarges. Aspect kept; each side rounded and at least 1.
    func targetSize(for pixels: CGSize) -> CGSize {
        Self.fit(pixels, longSide: maxSide)
    }

    /// The next, smaller long side to try when an encode came out over `maxBytes`, or nil when there
    /// is no smaller size worth trying (send the last encode as it is).
    static func nextSide(after side: CGFloat) -> CGFloat? {
        let next = (side * 0.75).rounded()
        return next >= minSide ? next : nil
    }

    /// `pixels` scaled so its long side is at most `longSide`.
    static func fit(_ pixels: CGSize, longSide: CGFloat) -> CGSize {
        let long = max(pixels.width, pixels.height)
        guard long > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(1, longSide / long)
        return CGSize(width: max(1, (pixels.width * scale).rounded()),
                      height: max(1, (pixels.height * scale).rounded()))
    }
}
