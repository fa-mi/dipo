import XCTest
import SwiftUI
@testable import DiPo

/// The hourglass on Home's "This period" card: the drawing ships in the app,
/// every shape in it parses, and the sand splits the money the way the card's
/// own figures do.
@MainActor
final class HourglassTests: XCTestCase {

    /// HourglassArt.json is in the app bundle (DiPo/ is a synchronised folder)
    /// and decodes: without it the card silently goes without the picture.
    func testTheDrawingShipsAndParses() throws {
        let art = try XCTUnwrap(HourglassArt.shared, "HourglassArt.json missing from the app bundle or unreadable")
        XCTAssertGreaterThan(art.box.width, 10)
        XCTAssertGreaterThan(art.box.height, art.box.width, "an hourglass stands taller than it is wide")
        XCTAssertEqual(art.top.count, 21)
        XCTAssertEqual(art.bottom.count, 21)
        XCTAssertGreaterThan(art.back.count, 10)
        XCTAssertGreaterThan(art.front.count, 10)
        // Empty bulbs draw nothing; every other level draws sand.
        XCTAssertTrue(art.top[0].isEmpty)
        XCTAssertTrue(art.bottom[0].isEmpty)
        XCTAssertFalse(art.top[20].isEmpty)
        XCTAssertFalse(art.bottom[20].isEmpty)
        // Every shape is something on the card.
        let everything = art.back + art.front + art.top.flatMap({ $0 }) + art.bottom.flatMap({ $0 })
        for piece in everything {
            XCTAssertFalse(piece.path.isEmpty, "\(piece.shape.m) \(piece.shape.r) parsed to nothing")
            XCTAssertTrue(art.box.insetBy(dx: -40, dy: -40).intersects(piece.path.boundingRect), "\(piece.shape.m) \(piece.shape.r) off the drawing")
        }
        // The money left is green sand; what was spent is the other sand.
        XCTAssertTrue(art.top[10].allSatisfy { $0.shape.m == "left" })
        XCTAssertTrue(art.bottom[10].allSatisfy { $0.shape.m == "spent" })
    }

    /// Drawn for real, off screen: a full top bulb paints green, an empty one
    /// paints none, and the brass frame is there either way.
    func testItPaints() throws {
        func greens(left: Double, used: Double) throws -> (green: Int, brass: Int) {
            let renderer = ImageRenderer(content: HourglassView(left: left, used: used).frame(width: 92, height: 168))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var green = 0, brass = 0
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
                let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
                if g > r + 40 && g > b + 20 { green += 1 }
                if r > b + 50 && g > b + 30 && r >= g - 10 { brass += 1 }
            }
            return (green, brass)
        }
        let full = try greens(left: 1, used: 0)
        let empty = try greens(left: 0, used: 1)
        XCTAssertGreaterThan(full.green, 300, "a full top bulb is green")
        XCTAssertLessThan(empty.green, full.green / 10, "an empty top bulb is not")
        XCTAssertGreaterThan(full.brass, 300, "the brass frame is drawn")
        XCTAssertGreaterThan(empty.brass, 300)
    }

    func testThePathReader() {
        let box = HourglassArt.path("M1 2L5 2L5 8ZM10 10L12 14").boundingRect
        XCTAssertEqual(box.minX, 1, accuracy: 0.001)
        XCTAssertEqual(box.minY, 2, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 12, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 14, accuracy: 0.001)
        XCTAssertTrue(HourglassArt.path("").isEmpty)
    }

    func testALevelIsTheNearestTwentieth() {
        XCTAssertEqual(HourglassArt.level(0), 0)
        XCTAssertEqual(HourglassArt.level(0.42), 8)
        XCTAssertEqual(HourglassArt.level(0.58), 12)
        XCTAssertEqual(HourglassArt.level(1), 20)
        XCTAssertEqual(HourglassArt.level(1.4), 20)
        XCTAssertEqual(HourglassArt.level(-0.2), 0)
        XCTAssertEqual(HourglassArt.level(.nan), 0)
    }

    /// Fahmi's period: Rp 19 jt in, Rp 5.353.060 on living, Rp 5.750.000 to
    /// his cards. 58 % used, the same as the card's figure; 42 % left on top.
    func testTheSandSplitsWhatCameIn() {
        let split = MonthFlowCard.sand(income: 19_000_000, expense: 11_103_060, putAway: 5_750_000, extra: 0)
        XCTAssertEqual(split.used, 11_103_060 / 19_000_000, accuracy: 1e-9)
        XCTAssertEqual(split.left + split.used, 1, accuracy: 1e-9)
        // Past the income: the bottom bulb is full and the top one empty.
        let over = MonthFlowCard.sand(income: 5_000_000, expense: 7_000_000, putAway: 0, extra: 0)
        XCTAssertEqual(over.used, 1)
        XCTAssertEqual(over.left, 0)
        // Added money widens what there is.
        XCTAssertEqual(MonthFlowCard.sand(income: 1_000_000, expense: 1_000_000, putAway: 0, extra: 1_000_000).used, 0.5, accuracy: 1e-9)
        // No money in yet: nothing to show.
        let none = MonthFlowCard.sand(income: 0, expense: 0, putAway: 0, extra: 0)
        XCTAssertEqual(none.used, 0)
        XCTAssertEqual(none.left, 0)
    }

    /// The colours come from the app's tokens, resolved per theme: brass is
    /// lighter on its lit side than in shadow, in both themes.
    func testThePaintFollowsTheTheme() {
        for dark in [false, true] {
            let paint = HourglassPaint(dark: dark)
            let shadow = HourglassArt.Shape(m: "brass", r: "shade0", d: nil, c: nil, t: nil, e: nil, s: nil, a: nil)
            let lit = HourglassArt.Shape(m: "brass", r: "shade3", d: nil, c: nil, t: nil, e: nil, s: nil, a: nil)
            func brightness(_ c: Color) -> CGFloat {
                var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
                UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
                return r + g + b
            }
            XCTAssertLessThan(brightness(paint.fill(shadow)), brightness(paint.fill(lit)), "dark: \(dark)")
        }
    }
}
