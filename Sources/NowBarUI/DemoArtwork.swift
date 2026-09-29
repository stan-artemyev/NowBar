import CoreGraphics
import Foundation
import ImageIO

/// Abstract covers for the demo playlist, drawn with CoreGraphics (no image assets).
/// Each cover is a small scene on a 100 x 100 canvas, rendered as a 640 px PNG.
enum DemoArtwork {
    static let coverCount = 5
    static let pixelSize = 640

    static func pngData(forCover index: Int) -> Data? {
        let count = coverCount
        let cover = ((index % count) + count) % count
        let size = pixelSize
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CoverCanvas.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Work in a 100 x 100 space with y pointing down, like the prototype's SVG covers.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: CGFloat(size) / 100, y: -CGFloat(size) / 100)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        let canvas = CoverCanvas(context: context)
        switch cover {
        case 0: drawMidnightCircuit(canvas)
        case 1: drawPaperSatellites(canvas)
        case 2: drawGlasshouse(canvas)
        case 3: drawNorthbound(canvas)
        default: drawHoneyAndStatic(canvas)
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: 1. Midnight Circuit: a retro sun setting behind a neon grid

    private static func drawMidnightCircuit(_ c: CoverCanvas) {
        c.linear(angle: 180, [.init(0, 0x0F0838), .init(0.42, 0x3C1275), .init(0.64, 0xA1228F), .init(1, 0xFF5C8A)])
        for (x, y, r) in [(16.0, 14.0, 0.7), (82.0, 20.0, 0.5), (63.0, 9.0, 0.6), (33.0, 24.0, 0.35), (92.0, 9.0, 0.4), (7.0, 33.0, 0.4)] {
            c.disc(at: CGPoint(x: x, y: y), radius: CGFloat(r), color: CoverCanvas.color(0xFFFFFF))
        }
        c.glow(at: CGPoint(x: 50, y: 64), rx: 72, ry: 44, [.init(0, 0xFF4F9A, 0.55), .init(0.72, 0xFF4F9A, 0)])
        // The sun has a crisp, anti-aliased rim: clip to the disc, then fill it with the gradient.
        c.context.saveGState()
        c.context.addEllipse(in: CGRect(x: 23, y: 37, width: 54, height: 54))
        c.context.clip()
        c.glow(at: CGPoint(x: 50, y: 64), rx: 27, ry: 27, [.init(0, 0xFFE27A), .init(0.55, 0xFFA06F), .init(1, 0xFF4F9A)])
        c.context.restoreGState()
        // The ground covers the lower half of the sun.
        c.linear(angle: 180, [.init(0, 0x2C0F66), .init(1, 0x0C0526)], in: CGRect(x: 0, y: 64, width: 100, height: 36))

        c.stroke(width: 0.6, color: CoverCanvas.color(0xFFD6F4)) { $0.line(from: CGPoint(x: 0, y: 64), to: CGPoint(x: 100, y: 64)) }
        c.stroke(width: 0.4, color: CoverCanvas.color(0xFF8BDC, 0.9)) { path in
            for y in [66.4, 69.6, 74.0, 80.4, 90.0] as [CGFloat] {
                path.line(from: CGPoint(x: 0, y: y), to: CGPoint(x: 100, y: y))
            }
            for x in [-60.0, -15.0, 12.0, 31.0, 50.0, 69.0, 88.0, 115.0, 160.0] as [CGFloat] {
                path.line(from: CGPoint(x: 50, y: 64), to: CGPoint(x: x, y: 100))
            }
        }
    }

    // MARK: 2. Paper Satellites: cream paper, a blue planet, a thin orbit

    private static func drawPaperSatellites(_ c: CoverCanvas) {
        c.linear(angle: 155, [.init(0, 0xF6EFE1), .init(1, 0xE7DAC0)])
        // Planet: radial light from the upper left.
        let context = c.context
        context.saveGState()
        context.addEllipse(in: CGRect(x: 19, y: 31, width: 54, height: 54))
        context.clip()
        context.drawRadialGradient(
            c.gradient([.init(0, 0x86B6E0), .init(0.5, 0x3A6D9F), .init(1, 0x15345A)]),
            startCenter: CGPoint(x: 37.4, y: 47.2), startRadius: 0,
            endCenter: CGPoint(x: 37.4, y: 47.2), endRadius: 45.9,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
        // Orbit.
        context.saveGState()
        context.translateBy(x: 46, y: 58)
        context.rotate(by: -30 * .pi / 180)
        context.setStrokeColor(CoverCanvas.color(0x22344A, 0.8))
        context.setLineWidth(0.7)
        context.strokeEllipse(in: CGRect(x: -40, y: -12, width: 80, height: 24))
        context.restoreGState()
        c.disc(at: CGPoint(x: 73, y: 35.5), radius: 3.4, color: CoverCanvas.color(0xE4572E))
        c.disc(at: CGPoint(x: 11.4, y: 73.2), radius: 2.4, color: CoverCanvas.color(0xF2B632))
    }

    // MARK: 3. Glasshouse: teal panes, mullions, shafts of light

    private static func drawGlasshouse(_ c: CoverCanvas) {
        c.linear(angle: 150, [.init(0, 0x0C4A4A), .init(0.48, 0x1F8D7A), .init(1, 0x8FE0C0)])
        c.glow(at: CGPoint(x: 20, y: 88), rx: 55, ry: 55, [.init(0, 0x06282D, 0.75), .init(0.7, 0x06282D, 0)])
        c.glow(at: CGPoint(x: 78, y: 24), rx: 45, ry: 45, [.init(0, 0xD6FFE8, 0.75), .init(0.7, 0xD6FFE8, 0)])
        // Shafts of light fanning out from the sun (angles clockwise from up, spread in degrees).
        for (angle, spread, alpha) in [(196.0, 9.0, 0.30), (214.0, 5.0, 0.20), (232.0, 12.0, 0.26), (254.0, 6.0, 0.18), (276.0, 10.0, 0.22)] {
            c.shaft(from: CGPoint(x: 78, y: 24), angle: CGFloat(angle), spread: CGFloat(spread), length: 130, alpha: CGFloat(alpha))
        }
        c.stroke(width: 0.9, color: CoverCanvas.color(0xFFFFFF, 0.55)) { path in
            for x in [25.0, 50.0, 75.0] as [CGFloat] {
                path.line(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: 100))
            }
            for y in [33.4, 66.7] as [CGFloat] {
                path.line(from: CGPoint(x: 0, y: y), to: CGPoint(x: 100, y: y))
            }
        }
    }

    // MARK: 4. Northbound: dusk over the sea, layered coastline, a compass

    private static func drawNorthbound(_ c: CoverCanvas) {
        c.linear(angle: 180, [.init(0, 0x25246A), .init(0.28, 0x6C3A94), .init(0.52, 0xE4635F), .init(0.66, 0xFFB86E), .init(1, 0xFFD9A0)])
        c.glow(at: CGPoint(x: 70, y: 47), rx: 36, ry: 36, [.init(0, 0xFFD696, 0.7), .init(1, 0xFFD696, 0)])
        c.glow(at: CGPoint(x: 70, y: 47), rx: 8, ry: 8, [.init(0, 0xFFF6D8), .init(0.88, 0xFFE6A8), .init(1, 0xFFE6A8, 0)])
        c.wave(baseline: 62, amplitude: 1.6, wavelength: 46, phase: 0.2, color: CoverCanvas.color(0x3F63A3))
        c.wave(baseline: 72, amplitude: 2.2, wavelength: 52, phase: 1.4, color: CoverCanvas.color(0x2B4D8C))
        c.wave(baseline: 82, amplitude: 2.4, wavelength: 58, phase: 2.6, color: CoverCanvas.color(0x1C3670))
        c.wave(baseline: 92, amplitude: 1.6, wavelength: 44, phase: 3.9, color: CoverCanvas.color(0x111F4A))
        c.stroke(width: 0.9, color: CoverCanvas.color(0xFFE6A8, 0.75), round: true) { path in
            path.line(from: CGPoint(x: 63, y: 66), to: CGPoint(x: 77, y: 66))
            path.line(from: CGPoint(x: 65.5, y: 70.2), to: CGPoint(x: 74.5, y: 70.2))
            path.line(from: CGPoint(x: 67.5, y: 75), to: CGPoint(x: 72.5, y: 75))
        }
        // Compass rose, top left.
        let context = c.context
        context.setStrokeColor(CoverCanvas.color(0xFFFFFF, 0.85))
        context.setLineWidth(0.6)
        context.strokeEllipse(in: CGRect(x: 8, y: 10, width: 18, height: 18))
        context.setFillColor(CoverCanvas.color(0xFFFFFF))
        context.beginPath()
        context.move(to: CGPoint(x: 17, y: 11.5))
        context.addLine(to: CGPoint(x: 20.6, y: 21.5))
        context.addLine(to: CGPoint(x: 17, y: 19.4))
        context.addLine(to: CGPoint(x: 13.4, y: 21.5))
        context.closePath()
        context.fillPath()
    }

    // MARK: 5. Honey & Static: a honey swirl, velvet corner, scanlines and honeycomb

    private static func drawHoneyAndStatic(_ c: CoverCanvas) {
        c.conic(at: CGPoint(x: 34, y: 62), from: 200, [.init(0, 0xFFD23A), .init(0.25, 0xFF9D1A), .init(0.5, 0xCF5C08), .init(0.75, 0xFF9D1A), .init(1, 0xFFD23A)])
        c.glow(at: CGPoint(x: 90, y: 96), rx: 58, ry: 58, [.init(0, 0x680E60, 0.92), .init(1, 0x680E60, 0)])
        c.glow(at: CGPoint(x: 14, y: 12), rx: 42, ry: 42, [.init(0, 0xFFF4B0, 0.9), .init(1, 0xFFF4B0, 0)])
        // Scanlines.
        let context = c.context
        context.setFillColor(CoverCanvas.color(0x1E001E, 0.09))
        var y: CGFloat = 0.4
        while y < 100 {
            context.fill(CGRect(x: 0, y: y, width: 100, height: 0.4))
            y += 1.1
        }
        // Honeycomb: kind 0 outline only, 1 frosted, 2 velvet.
        let cells: [(CGFloat, CGFloat, Int)] = [(63, 28, 0), (81.2, 28, 1), (53.9, 43.8, 1), (72.1, 43.8, 0), (90.3, 43.8, 0), (63, 59.5, 0), (81.2, 59.5, 2)]
        for (x, y, kind) in cells {
            let hexagon = CGMutablePath()
            let r: CGFloat = 9.6
            let k = r * 0.866
            let h = r / 2
            hexagon.move(to: CGPoint(x: x, y: y - r))
            hexagon.addLine(to: CGPoint(x: x + k, y: y - h))
            hexagon.addLine(to: CGPoint(x: x + k, y: y + h))
            hexagon.addLine(to: CGPoint(x: x, y: y + r))
            hexagon.addLine(to: CGPoint(x: x - k, y: y + h))
            hexagon.addLine(to: CGPoint(x: x - k, y: y - h))
            hexagon.closeSubpath()
            if kind == 1 {
                context.setFillColor(CoverCanvas.color(0xFFFFFF, 0.16))
                context.addPath(hexagon)
                context.fillPath()
            } else if kind == 2 {
                context.setFillColor(CoverCanvas.color(0x6E1064, 0.78))
                context.addPath(hexagon)
                context.fillPath()
            }
            context.setStrokeColor(CoverCanvas.color(0xFFF0B4, 0.85))
            context.setLineWidth(0.6)
            context.setLineJoin(.round)
            context.addPath(hexagon)
            context.strokePath()
        }
    }
}

// MARK: - Drawing helpers

/// A CoreGraphics context in the cover's 100 x 100, y-down space, with small helpers for the
/// gradients the covers are made of.
private struct CoverCanvas {
    struct Stop {
        var at: CGFloat
        var hex: UInt32
        var alpha: CGFloat

        init(_ at: CGFloat, _ hex: UInt32, _ alpha: CGFloat = 1) {
            self.at = at
            self.hex = hex
            self.alpha = alpha
        }
    }

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    let context: CGContext

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
        )!
    }

    func gradient(_ stops: [Stop]) -> CGGradient {
        CGGradient(
            colorsSpace: Self.colorSpace,
            colors: stops.map { Self.color($0.hex, $0.alpha) } as CFArray,
            locations: stops.map(\.at)
        )!
    }

    /// CSS-style linear gradient (0 degrees points up, angles run clockwise) across `rect`.
    func linear(angle: CGFloat, _ stops: [Stop], in rect: CGRect = CoverCanvas.bounds) {
        let a = angle * .pi / 180
        let length = abs(rect.width * sin(a)) + abs(rect.height * cos(a))
        let dx = sin(a) * length / 2
        let dy = -cos(a) * length / 2
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient(stops),
            start: CGPoint(x: rect.midX - dx, y: rect.midY - dy),
            end: CGPoint(x: rect.midX + dx, y: rect.midY + dy),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    /// An elliptical radial gradient that fades out at its edge.
    func glow(at center: CGPoint, rx: CGFloat, ry: CGFloat, _ stops: [Stop]) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: rx, y: ry)
        context.drawRadialGradient(gradient(stops), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }

    func disc(at center: CGPoint, radius: CGFloat, color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// A soft-edged beam of light: a narrow wedge that fades out with distance.
    func shaft(from origin: CGPoint, angle: CGFloat, spread: CGFloat, length: CGFloat, alpha: CGFloat) {
        func point(_ degrees: CGFloat) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: origin.x + sin(r) * length, y: origin.y - cos(r) * length)
        }
        context.saveGState()
        context.beginPath()
        context.move(to: origin)
        context.addLine(to: point(angle - spread / 2))
        context.addLine(to: point(angle + spread / 2))
        context.closePath()
        context.clip()
        context.drawRadialGradient(
            gradient([.init(0, 0xFFFFFF, alpha), .init(1, 0xFFFFFF, 0)]),
            startCenter: origin, startRadius: 0, endCenter: origin, endRadius: length * 0.8, options: []
        )
        context.restoreGState()
    }

    /// A rolling band that fills from its top edge down to the bottom of the cover.
    func wave(baseline: CGFloat, amplitude: CGFloat, wavelength: CGFloat, phase: CGFloat, color: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -1, y: 101))
        var x: CGFloat = -1
        while x <= 101 {
            path.addLine(to: CGPoint(x: x, y: baseline + amplitude * sin(x / wavelength * 2 * .pi + phase)))
            x += 1.25
        }
        path.addLine(to: CGPoint(x: 101, y: 101))
        path.closeSubpath()
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
    }

    /// CSS-style conic gradient (0 degrees points up, angles run clockwise), drawn as thin wedges.
    func conic(at center: CGPoint, from startAngle: CGFloat, _ raw: [Stop]) {
        let slices = 720
        let radius: CGFloat = 200
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        func colorAt(_ t: CGFloat) -> CGColor {
            var lower = raw[0]
            var upper = raw[raw.count - 1]
            for index in 0..<(raw.count - 1) where t >= raw[index].at && t <= raw[index + 1].at {
                lower = raw[index]
                upper = raw[index + 1]
            }
            let span = max(upper.at - lower.at, 0.0001)
            let f = min(max((t - lower.at) / span, 0), 1)
            let (r0, g0, b0) = rgb(lower.hex)
            let (r1, g1, b1) = rgb(upper.hex)
            return CGColor(colorSpace: Self.colorSpace, components: [r0 + (r1 - r0) * f, g0 + (g1 - g0) * f, b0 + (b1 - b0) * f, 1])!
        }
        context.saveGState()
        context.clip(to: Self.bounds)
        for index in 0..<slices {
            let t0 = CGFloat(index) / CGFloat(slices)
            let t1 = CGFloat(index + 1) / CGFloat(slices)
            let a0 = (startAngle + t0 * 360) * .pi / 180
            // Overlap the next wedge slightly so no seams show between neighbours.
            let a1 = (startAngle + t1 * 360 + 0.6) * .pi / 180
            context.setFillColor(colorAt((t0 + t1) / 2))
            context.beginPath()
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + sin(a0) * radius, y: center.y - cos(a0) * radius))
            context.addLine(to: CGPoint(x: center.x + sin(a1) * radius, y: center.y - cos(a1) * radius))
            context.closePath()
            context.fillPath()
        }
        context.restoreGState()
    }

    /// Strokes the lines added to the path by `build`.
    func stroke(width: CGFloat, color: CGColor, round: Bool = false, _ build: (CGMutablePath) -> Void) {
        let path = CGMutablePath()
        build(path)
        context.saveGState()
        context.clip(to: Self.bounds)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(round ? .round : .butt)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

private extension CGMutablePath {
    func line(from start: CGPoint, to end: CGPoint) {
        move(to: start)
        addLine(to: end)
    }
}
