import EdenRendering
import SwiftUI
import Testing

@Suite("SVG paths")
struct SVGPathTests {
    @Test func absoluteAndRelativeCommandsDrawTheSameBox() {
        let absolute = SVGPath.parse("M4 2H20V22H4Z").boundingRect
        let relative = SVGPath.parse("m4 2h16v20h-16z").boundingRect
        #expect(absolute == CGRect(x: 4, y: 2, width: 16, height: 20))
        #expect(relative == absolute)
    }

    @Test func packedNumbersAndArcFlagsParse() {
        // ".072-.333" is two numbers, and "0 00-.856 0" packs the arc's flags.
        let path = SVGPath.parse("M1 1l.5-.25a.797.797 0 00-.856 0z")
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width > 0)
    }

    @Test func aShapeScalesToFitItsRect() {
        let shape = SVGShape("M0 0H24V24H0Z")
        #expect(shape.path(in: CGRect(x: 0, y: 0, width: 12, height: 12)).boundingRect == CGRect(x: 0, y: 0, width: 12, height: 12))
    }
}
