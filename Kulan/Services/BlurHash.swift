import UIKit

// BlurHash (the standard public algorithm Signal uses, our own compact implementation): a ~28-char
// string that encodes a 4×3-component DCT of the image. It travels WITH the message (sealed like the
// caption), so the recipient's bubble shows a recognizable blur of the actual photo instantly —
// before a single byte of the real image has downloaded. Decode renders tiny (32px) and is scaled up
// by the view; encode downsamples to ≤32px first so both directions are sub-millisecond.
enum BlurHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static var charValue: [Character: Int] = {
        var d: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { d[c] = i }
        return d
    }()

    // MARK: - Encode (at send)

    static func encode(_ image: UIImage, componentsX: Int = 4, componentsY: Int = 3) -> String? {
        guard let pixels = rgbaPixels(image, maxDimension: 32) else { return nil }
        let (w, h, data) = pixels
        guard w > 0, h > 0 else { return nil }

        var factors: [(Float, Float, Float)] = []
        for j in 0..<componentsY {
            for i in 0..<componentsX {
                let normalization: Float = (i == 0 && j == 0) ? 1 : 2
                var r: Float = 0, g: Float = 0, b: Float = 0
                for y in 0..<h {
                    for x in 0..<w {
                        let basis = normalization
                            * cos(Float.pi * Float(i) * Float(x) / Float(w))
                            * cos(Float.pi * Float(j) * Float(y) / Float(h))
                        let p = (y * w + x) * 4
                        r += basis * sRGBToLinear(data[p])
                        g += basis * sRGBToLinear(data[p + 1])
                        b += basis * sRGBToLinear(data[p + 2])
                    }
                }
                let scale = 1 / Float(w * h)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        let dc = factors[0]
        let ac = Array(factors.dropFirst())
        var hash = ""
        hash += encode83((componentsX - 1) + (componentsY - 1) * 9, length: 1)

        var maxValue: Float = 1
        if !ac.isEmpty {
            let actualMax = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max() ?? 0
            let quantised = max(0, min(82, Int(floor(actualMax * 166 - 0.5))))
            maxValue = Float(quantised + 1) / 166
            hash += encode83(quantised, length: 1)
        } else {
            hash += encode83(0, length: 1)
        }

        hash += encode83(encodeDC(dc), length: 4)
        for f in ac { hash += encode83(encodeAC(f, maxValue: maxValue), length: 2) }
        return hash
    }

    private static func encodeDC(_ v: (Float, Float, Float)) -> Int {
        (linearTosRGB(v.0) << 16) + (linearTosRGB(v.1) << 8) + linearTosRGB(v.2)
    }
    private static func encodeAC(_ v: (Float, Float, Float), maxValue: Float) -> Int {
        func q(_ x: Float) -> Int {
            max(0, min(18, Int(floor(signPow(x / maxValue, 0.5) * 9 + 9.5))))
        }
        return q(v.0) * 19 * 19 + q(v.1) * 19 + q(v.2)
    }
    private static func encode83(_ value: Int, length: Int) -> String {
        var out = ""
        for i in stride(from: length, to: 0, by: -1) {
            let digit = (value / pow83(i - 1)) % 83
            out.append(alphabet[digit])
        }
        return out
    }
    private static func pow83(_ n: Int) -> Int { (0..<n).reduce(1) { a, _ in a * 83 } }

    // MARK: - Decode (at receive) — cached, tiny render

    private static let decodeCache = NSCache<NSString, UIImage>()

    static func decode(_ hash: String, punch: Float = 1) -> UIImage? {
        if let hit = decodeCache.object(forKey: hash as NSString) { return hit }
        guard hash.count >= 6 else { return nil }
        let chars = Array(hash)
        guard let sizeFlag = value(chars[0]) else { return nil }
        let cy = (sizeFlag / 9) + 1
        let cx = (sizeFlag % 9) + 1
        guard hash.count == 4 + 2 * cx * cy, let qMax = value(chars[1]) else { return nil }
        let maxValue = Float(qMax + 1) / 166

        var colors: [(Float, Float, Float)] = []
        for i in 0..<(cx * cy) {
            if i == 0 {
                let v = decode83(Array(chars[2..<6]))
                colors.append((sRGBToLinear(UInt8((v >> 16) & 255)),
                               sRGBToLinear(UInt8((v >> 8) & 255)),
                               sRGBToLinear(UInt8(v & 255))))
            } else {
                let start = 4 + i * 2
                let v = decode83(Array(chars[start..<(start + 2)]))
                func dq(_ q: Int) -> Float { signPow((Float(q) - 9) / 9, 2) * maxValue * punch }
                colors.append((dq(v / (19 * 19)), dq((v / 19) % 19), dq(v % 19)))
            }
        }

        let W = 32, H = 32
        var pixels = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<cy {
                    for i in 0..<cx {
                        let basis = cos(Float.pi * Float(x) * Float(i) / Float(W))
                            * cos(Float.pi * Float(y) * Float(j) / Float(H))
                        let c = colors[i + j * cx]
                        r += c.0 * basis; g += c.1 * basis; b += c.2 * basis
                    }
                }
                let p = (y * W + x) * 4
                pixels[p] = UInt8(linearTosRGB(r)); pixels[p + 1] = UInt8(linearTosRGB(g)); pixels[p + 2] = UInt8(linearTosRGB(b))
            }
        }
        guard let img = imageFromRGBA(pixels, width: W, height: H) else { return nil }
        decodeCache.setObject(img, forKey: hash as NSString)
        return img
    }

    private static func decode83(_ chars: [Character]) -> Int {
        chars.reduce(0) { acc, c in acc * 83 + (value(c) ?? 0) }
    }
    private static func value(_ c: Character) -> Int? { charValue[c] }

    // MARK: - Color math + pixel helpers

    private static func sRGBToLinear(_ v: UInt8) -> Float {
        let x = Float(v) / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    private static func linearTosRGB(_ v: Float) -> Int {
        let x = max(0, min(1, v))
        let s = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        return Int(s * 255 + 0.5)
    }
    private static func signPow(_ v: Float, _ e: Float) -> Float { copysign(pow(abs(v), e), v) }

    private static func rgbaPixels(_ image: UIImage, maxDimension: CGFloat) -> (Int, Int, [UInt8])? {
        let w0 = image.size.width, h0 = image.size.height
        guard w0 > 0, h0 > 0 else { return nil }
        let f = min(1, maxDimension / max(w0, h0))
        let w = max(1, Int(w0 * f)), h = max(1, Int(h0 * f))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, data)
    }

    private static func imageFromRGBA(_ pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        var px = pixels
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }
}
