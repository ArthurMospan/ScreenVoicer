import CoreGraphics
import Foundation

/// A minimal SVG path-data parser (M L H V C S Q T A Z, absolute and relative), so the Mac app draws its icons and
/// logo from the very same path strings as App.xaml on Windows. Coordinates stay y-down, like SVG.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var parser = Parser(Array(d.utf8))
        return parser.run()
    }

    private struct Parser {
        let c: [UInt8]
        var i = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?

        init(_ chars: [UInt8]) { c = chars }

        mutating func run() -> CGPath {
            var command: UInt8 = 0
            while true {
                skip()
                if i >= c.count { break }
                if isCommand(c[i]) {
                    command = c[i]
                    i += 1
                } else if command == 0 || !isNumberStart(c[i]) {
                    break // malformed: stop rather than loop forever
                }
                guard step(&command) else { break }
            }
            return path
        }

        /// One command's worth of arguments; returns false on malformed data.
        mutating func step(_ command: inout UInt8) -> Bool {
            let relative = command >= 97 // lowercase
            let base = relative ? current : .zero
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = number(), let y = number() else { return false }
                let p = CGPoint(x: base.x + x, y: base.y + y)
                path.move(to: p)
                current = p
                start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // implicit pairs are line-tos
                resetControls()
            case UInt8(ascii: "l"):
                guard let x = number(), let y = number() else { return false }
                lineTo(CGPoint(x: base.x + x, y: base.y + y))
            case UInt8(ascii: "h"):
                guard let x = number() else { return false }
                lineTo(CGPoint(x: relative ? current.x + x : x, y: current.y))
            case UInt8(ascii: "v"):
                guard let y = number() else { return false }
                lineTo(CGPoint(x: current.x, y: relative ? current.y + y : y))
            case UInt8(ascii: "c"):
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return false }
                cubic(CGPoint(x: base.x + x1, y: base.y + y1), CGPoint(x: base.x + x2, y: base.y + y2),
                      CGPoint(x: base.x + x, y: base.y + y))
            case UInt8(ascii: "s"):
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return false }
                let c1 = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                cubic(c1, CGPoint(x: base.x + x2, y: base.y + y2), CGPoint(x: base.x + x, y: base.y + y))
            case UInt8(ascii: "q"):
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return false }
                quad(CGPoint(x: base.x + x1, y: base.y + y1), CGPoint(x: base.x + x, y: base.y + y))
            case UInt8(ascii: "t"):
                guard let x = number(), let y = number() else { return false }
                let c1 = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                quad(c1, CGPoint(x: base.x + x, y: base.y + y))
            case UInt8(ascii: "a"):
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = flag(), let sweep = flag(), let x = number(), let y = number() else { return false }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                arc(to: end, rx: rx, ry: ry, rotation: rotation, largeArc: large, sweep: sweep)
                current = end
                resetControls()
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                resetControls()
                // Z takes no arguments: a number right after it would be malformed
                skip()
                if i < c.count && !isCommand(c[i]) { return false }
            default:
                return false
            }
            return true
        }

        mutating func resetControls() {
            lastCubic = nil
            lastQuad = nil
        }

        mutating func lineTo(_ p: CGPoint) {
            path.addLine(to: p)
            current = p
            resetControls()
        }

        mutating func cubic(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) {
            path.addCurve(to: end, control1: c1, control2: c2)
            current = end
            lastCubic = c2
            lastQuad = nil
        }

        mutating func quad(_ control: CGPoint, _ end: CGPoint) {
            path.addQuadCurve(to: end, control: control)
            current = end
            lastQuad = control
            lastCubic = nil
        }

        /// SVG implementation notes F.6.5: endpoint → centre parameterization, then ≤90° cubic pieces.
        mutating func arc(to end: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
            let p1 = current
            if p1 == end { return }
            var rx = abs(rxIn), ry = abs(ryIn)
            if rx == 0 || ry == 0 {
                path.addLine(to: end)
                return
            }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx2 = (p1.x - end.x) / 2, dy2 = (p1.y - end.y) / 2
            let x1p = cosPhi * dx2 + sinPhi * dy2
            let y1p = -sinPhi * dx2 + cosPhi * dy2

            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                rx *= lambda.squareRoot()
                ry *= lambda.squareRoot()
            }
            let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            let coef = (largeArc != sweep ? 1 : -1) * (den == 0 ? 0 : max(0, num / den).squareRoot())
            let cxp = coef * rx * y1p / ry
            let cyp = coef * -ry * x1p / rx
            let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + end.y) / 2

            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            }
            let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
            let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
            let theta1 = angle(1, 0, ux, uy)
            var delta = angle(ux, uy, vx, vy)
            if !sweep && delta > 0 { delta -= 2 * .pi }
            if sweep && delta < 0 { delta += 2 * .pi }

            let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
            let step = delta / CGFloat(segments)
            let t = 4.0 / 3.0 * tan(step / 4)
            func point(_ th: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * cos(th) - ry * sinPhi * sin(th),
                        y: cy + rx * sinPhi * cos(th) + ry * cosPhi * sin(th))
            }
            func derivative(_ th: CGFloat) -> CGPoint {
                CGPoint(x: -rx * cosPhi * sin(th) - ry * sinPhi * cos(th),
                        y: -rx * sinPhi * sin(th) + ry * cosPhi * cos(th))
            }
            for k in 0..<segments {
                let th1 = theta1 + CGFloat(k) * step
                let th2 = th1 + step
                let a = point(th1), b = point(th2)
                let da = derivative(th1), db = derivative(th2)
                path.addCurve(to: k == segments - 1 ? end : b,
                              control1: CGPoint(x: a.x + t * da.x, y: a.y + t * da.y),
                              control2: CGPoint(x: b.x - t * db.x, y: b.y - t * db.y))
            }
        }

        // MARK: tokens

        func isCommand(_ ch: UInt8) -> Bool {
            switch ch | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"), UInt8(ascii: "c"),
                 UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "z"):
                return (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)
            default:
                return false
            }
        }

        func isNumberStart(_ ch: UInt8) -> Bool {
            (ch >= 48 && ch <= 57) || ch == UInt8(ascii: "-") || ch == UInt8(ascii: "+") || ch == UInt8(ascii: ".")
        }

        mutating func skip() {
            while i < c.count, c[i] == 32 || c[i] == 44 || c[i] == 9 || c[i] == 10 || c[i] == 13 {
                i += 1
            }
        }

        mutating func flag() -> Bool? {
            skip()
            guard i < c.count, c[i] == 48 || c[i] == 49 else { return nil }
            defer { i += 1 }
            return c[i] == 49
        }

        mutating func number() -> CGFloat? {
            skip()
            let begin = i
            if i < c.count, c[i] == UInt8(ascii: "-") || c[i] == UInt8(ascii: "+") { i += 1 }
            var digits = false
            while i < c.count, c[i] >= 48 && c[i] <= 57 { i += 1; digits = true }
            if i < c.count, c[i] == UInt8(ascii: ".") {
                i += 1
                while i < c.count, c[i] >= 48 && c[i] <= 57 { i += 1; digits = true }
            }
            guard digits else {
                i = begin
                return nil
            }
            if i < c.count, c[i] == UInt8(ascii: "e") || c[i] == UInt8(ascii: "E") {
                var j = i + 1
                if j < c.count, c[j] == UInt8(ascii: "-") || c[j] == UInt8(ascii: "+") { j += 1 }
                if j < c.count, c[j] >= 48 && c[j] <= 57 {
                    i = j
                    while i < c.count, c[i] >= 48 && c[i] <= 57 { i += 1 }
                }
            }
            return Double(String(decoding: c[begin..<i], as: UTF8.self)).map { CGFloat($0) }
        }
    }
}
