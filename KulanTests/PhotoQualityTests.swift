import XCTest
import UIKit
@testable import Kulan

// How big a sent photo is: Standard 1280 px / HD 2560 px at JPEG 0.6, byte ceilings 1.5 MB / 3 MB,
// HD starts from Settings > Sent Media Quality (`PhotoQuality`, `ChatService.sendJPEG`).
final class PhotoQualityTests: XCTestCase {

    private typealias Q = PhotoQuality
    private let key = "sentMediaQuality"
    private var savedSetting: String?

    override func setUp() {
        super.setUp()
        savedSetting = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let savedSetting { UserDefaults.standard.set(savedSetting, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    // MARK: The numbers

    func testLevels() {
        XCTAssertEqual(Q.standard.maxSide, 1280)
        XCTAssertEqual(Q.high.maxSide, 2560)
        XCTAssertEqual(Q.standard.jpegQuality, 0.6, accuracy: 0.0001)
        XCTAssertEqual(Q.high.jpegQuality, 0.6, accuracy: 0.0001)
        XCTAssertEqual(Q.standard.maxBytes, 1_572_864)
        XCTAssertEqual(Q.high.maxBytes, 3_145_728)
        XCTAssertEqual(Q(hd: false), .standard)
        XCTAssertEqual(Q(hd: true), .high)
        XCTAssertTrue(Q.high.isHD)
        XCTAssertFalse(Q.standard.isHD)
    }

    // MARK: Where the HD button starts

    func testDefaultFollowsSetting() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Q.default, .standard, "nothing chosen = small")
        UserDefaults.standard.set("standard", forKey: key)
        XCTAssertEqual(Q.default, .standard)
        UserDefaults.standard.set("high", forKey: key)
        XCTAssertEqual(Q.default, .high)
        XCTAssertTrue(ChatService.highQualitySends)
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(Q.default, .standard)
    }

    // MARK: Target size

    func testTwelveMegapixelLandscape() {
        let px = CGSize(width: 4032, height: 3024)
        XCTAssertEqual(Q.standard.targetSize(for: px), CGSize(width: 1280, height: 960))
        XCTAssertEqual(Q.high.targetSize(for: px), CGSize(width: 2560, height: 1920))
    }

    func testPortraitUsesLongSide() {
        let px = CGSize(width: 3024, height: 4032)
        XCTAssertEqual(Q.standard.targetSize(for: px), CGSize(width: 960, height: 1280))
        XCTAssertEqual(Q.high.targetSize(for: px), CGSize(width: 1920, height: 2560))
    }

    func testNeverEnlarges() {
        let small = CGSize(width: 800, height: 600)
        XCTAssertEqual(Q.standard.targetSize(for: small), small)
        XCTAssertEqual(Q.high.targetSize(for: small), small)
        let between = CGSize(width: 2000, height: 1000)   // bigger than Standard, smaller than HD
        XCTAssertEqual(Q.standard.targetSize(for: between), CGSize(width: 1280, height: 640))
        XCTAssertEqual(Q.high.targetSize(for: between), between)
    }

    func testPanoramaAndDegenerate() {
        XCTAssertEqual(Q.standard.targetSize(for: CGSize(width: 16000, height: 3000)),
                       CGSize(width: 1280, height: 240))
        XCTAssertEqual(Q.standard.targetSize(for: CGSize(width: 100_000, height: 10)),
                       CGSize(width: 1280, height: 1), "a side never rounds to zero")
        XCTAssertEqual(Q.standard.targetSize(for: .zero), CGSize(width: 1, height: 1))
    }

    // MARK: Byte-ceiling retries

    func testNextSideSteps() {
        XCTAssertEqual(Q.nextSide(after: 2560), 1920)
        XCTAssertEqual(Q.nextSide(after: 1920), 1440)
        XCTAssertEqual(Q.nextSide(after: 1280), 960)
        XCTAssertEqual(Q.nextSide(after: 960), 720)
        XCTAssertNil(Q.nextSide(after: 720), "540 is under the 640 floor: send what we have")
    }

    func testRetriesAreBounded() {
        var side = Q.high.maxSide, steps = 0
        while let next = Q.nextSide(after: side) { side = next; steps += 1 }
        XCTAssertEqual(steps, 4)   // 2560 -> 1920 -> 1440 -> 1080 -> 810
        XCTAssertGreaterThanOrEqual(side, Q.minSide)
    }

    // MARK: The real encoder, on a 12 MP picture

    /// A 4032x3024 picture with smooth colour and some grain, as a stand-in for a phone photo.
    /// Prints the bytes so the run log shows Standard against HD.
    func testSendJPEGOnTwelveMegapixels() throws {
        let size = CGSize(width: 4032, height: 3024)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.systemTeal.cgColor, UIColor.systemOrange.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<40_000 {
                let x = CGFloat.random(in: 0..<size.width, using: &rng)
                let y = CGFloat.random(in: 0..<size.height, using: &rng)
                UIColor(white: CGFloat.random(in: 0...1, using: &rng), alpha: 0.5).setFill()
                cg.fill(CGRect(x: x, y: y, width: 6, height: 6))
            }
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))

        let standard = ChatService.sendJPEG(original, quality: .standard)
        let hd = ChatService.sendJPEG(original, quality: .high)
        let sPx = try XCTUnwrap(UIImage(data: standard)).size
        let hPx = try XCTUnwrap(UIImage(data: hd)).size
        print("PHOTOQ# original=\(original.count)B standard=\(standard.count)B \(sPx) hd=\(hd.count)B \(hPx)")

        XCTAssertEqual(max(sPx.width, sPx.height), 1280)
        XCTAssertEqual(max(hPx.width, hPx.height), 2560)
        XCTAssertLessThanOrEqual(standard.count, Q.standard.maxBytes)
        XCTAssertLessThanOrEqual(hd.count, Q.high.maxBytes)
        XCTAssertLessThan(standard.count, hd.count)
        XCTAssertLessThan(hd.count, original.count)
    }
}
