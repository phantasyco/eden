import SwiftUI

/// SVG path data ("M9.2 8.6v-2.26c0-.19…") as a SwiftUI shape, so a brand
/// mark draws as vectors at whatever size it shows, crisp at 13 points and at
/// 64, and takes the foreground style like text. Marks are drawn on a square
/// canvas (LobeHub's are 24 by 24) and scale to fit the rect.
struct SVGShape: Shape {
    let path: Path
    var canvas: CGFloat = 24

    init(_ data: String, canvas: CGFloat = 24) {
        path = SVGPath.parse(data)
        self.canvas = canvas
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / canvas
        let x = rect.minX + (rect.width - canvas * scale) / 2
        let y = rect.minY + (rect.height - canvas * scale) / 2
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }
}

/// The path grammar from the SVG spec: every command, absolute and relative,
/// with implicit repeats, smooth curves, and elliptical arcs (as cubic curves).
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var scanner = Scanner(Array(data.utf8))
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        // The last control point, for S and T, which reflect it.
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0

        while let next = scanner.command(after: command) {
            command = next
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var cubic: CGPoint?, quad: CGPoint?

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p
                // Pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p); current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current.x = origin.x + x; path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current.y = origin.y + y; path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2; current = p
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return path }
                let c1 = lastCubic.map { reflect($0, over: current) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2; current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c; current = p
            case UInt8(ascii: "t"):
                guard let p = point() else { return path }
                let c = lastQuad.map { reflect($0, over: current) } ?? current
                path.addQuadCurve(to: p, control: c)
                quad = c; current = p
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(to: &path, from: current, to: p, radii: CGSize(width: rx, height: ry),
                       rotation: angle, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return path
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return path
    }

    private static func reflect(_ point: CGPoint, over center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// An elliptical arc as cubic curves: the SVG spec's endpoint-to-center
    /// conversion (appendix B.2.4), then one curve per quarter turn or less.
    private static func addArc(to path: inout Path, from p1: CGPoint, to p2: CGPoint, radii: CGSize,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0, p1 != p2 else {
            path.addLine(to: p2)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Radii too small to reach the end point grow until they do.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (large == sweep ? -1 : 1) * max(0, numerator / denominator).squareRoot()
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2,
                             y: sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2)

        func angle(_ u: CGPoint, _ v: CGPoint) -> CGFloat {
            atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
        }
        let from = CGPoint(x: (x1 - cx1) / rx, y: (y1 - cy1) / ry)
        let to = CGPoint(x: (-x1 - cx1) / rx, y: (-y1 - cy1) / ry)
        let theta = angle(CGPoint(x: 1, y: 0), from)
        var delta = angle(from, to)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * u - ry * sinPhi * v,
                    y: center.y + rx * sinPhi * u + ry * cosPhi * v)
        }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        var a = theta
        for index in 0..<segments {
            let b = a + step
            let end = index == segments - 1 ? p2 : map(cos(b), sin(b))
            path.addCurve(to: end,
                          control1: map(cos(a) - handle * sin(a), sin(a) + handle * cos(a)),
                          control2: map(cos(b) + handle * sin(b), sin(b) - handle * cos(b)))
            a = b
        }
    }

    /// Numbers the way SVG writes them: "-.19", ".072-.333" (two numbers),
    /// "1e-3", and arc flags packed without separators ("0 00-.856").
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || (0x09...0x0D).contains(bytes[index]) {
                index += 1
            }
        }

        private static func isLetter(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }

        /// The next command letter, or the last one again when numbers follow
        /// it directly (an implicit repeat). Nil at the end.
        mutating func command(after last: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            // "e" only appears inside numbers, never as a command.
            if Self.isLetter(byte), byte | 0x20 != UInt8(ascii: "e") {
                index += 1
                return byte
            }
            return last == 0 ? nil : last
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { return nil }
            defer { index += 1 }
            return bytes[index] == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = false, dot = false
            while index < bytes.count {
                let byte = bytes[index]
                if (0x30...0x39).contains(byte) {
                    digits = true
                } else if byte == UInt8(ascii: "."), !dot {
                    dot = true
                } else {
                    break
                }
                index += 1
            }
            if digits, index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
                var look = index + 1
                if look < bytes.count, bytes[look] == UInt8(ascii: "-") || bytes[look] == UInt8(ascii: "+") { look += 1 }
                if look < bytes.count, (0x30...0x39).contains(bytes[look]) {
                    index = look
                    while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                }
            }
            guard digits, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
