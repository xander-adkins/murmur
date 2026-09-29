// Renders the Murmur app icon and builds AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output-dir>
//
// The mark is a heavy geometric lowercase m with three arches, warped sideways along a gentle
// sine so every stem bends like an italic caught mid-hum. Every stem ends in the same flat cut.
// White on black, pure geometry, no typeface; one shape, so it scales from 16 px to 1024 px.
import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

let plateColor = CGColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1)
let inkColor = CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1)

// Letter proportions in canvas units (1024 canvas).
let strokeWidth: CGFloat = 118
let stemPitch: CGFloat = 232
let stemHeight: CGFloat = 300
let arches = 3
let markWidthFraction: CGFloat = 0.72

// The hum: sideways displacement as a function of height.
let waveCycles: CGFloat = 1.5
let waveAmplitude: CGFloat = 52
let wavePhase: CGFloat = .pi / 2

/// Heavy m: stems with semicircular arches, as a filled outline of a stroked centreline.
/// Butt caps and bevel joins make every stem bottom the same horizontal cut.
func heavyM() -> CGPath {
    let radius = stemPitch / 2
    let centreline = CGMutablePath()
    centreline.move(to: CGPoint(x: 0, y: 0))
    centreline.addLine(to: CGPoint(x: 0, y: stemHeight))
    for arch in 0..<arches {
        let cx = CGFloat(arch) * stemPitch + radius
        centreline.addArc(center: CGPoint(x: cx, y: stemHeight), radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
        centreline.addLine(to: CGPoint(x: cx + radius, y: 0))
        if arch < arches - 1 {
            centreline.addLine(to: CGPoint(x: cx + radius, y: stemHeight))
        }
    }
    return centreline.copy(strokingWithWidth: strokeWidth, lineCap: .butt, lineJoin: .bevel, miterLimit: 1)
}

/// Sideways displacement of the hum at a given height of the letter.
func hum(at y: CGFloat, in box: CGRect) -> CGFloat {
    sin((y - box.minY) / box.height * .pi * waveCycles + wavePhase) * waveAmplitude
}

/// Moves every point of the outline sideways by the hum at its height. Curves and long lines are
/// subdivided first so the displacement stays smooth.
func warp(_ path: CGPath, box: CGRect) -> CGPath {
    let out = CGMutablePath()
    var cursor = CGPoint.zero   // current point in the unwarped outline
    func emit(_ p: CGPoint) {
        out.addLine(to: CGPoint(x: p.x + hum(at: p.y, in: box), y: p.y))
        cursor = p
    }

    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint:
            cursor = e.points[0]
            out.move(to: CGPoint(x: cursor.x + hum(at: cursor.y, in: box), y: cursor.y))
        case .addLineToPoint:
            let to = e.points[0], from = cursor
            let steps = max(1, Int(abs(to.y - from.y) / 6))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                emit(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        case .addQuadCurveToPoint:
            let c = e.points[0], to = e.points[1], from = cursor
            for s in 1...24 {
                let t = CGFloat(s) / 24, mt = 1 - t
                emit(CGPoint(x: mt * mt * from.x + 2 * mt * t * c.x + t * t * to.x,
                             y: mt * mt * from.y + 2 * mt * t * c.y + t * t * to.y))
            }
        case .addCurveToPoint:
            let c1 = e.points[0], c2 = e.points[1], to = e.points[2], from = cursor
            for s in 1...24 {
                let t = CGFloat(s) / 24, mt = 1 - t
                emit(CGPoint(x: mt * mt * mt * from.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * to.x,
                             y: mt * mt * mt * from.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * to.y))
            }
        case .closeSubpath:
            out.closeSubpath()
        @unknown default:
            break
        }
    }
    return out
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon grid: the squircle sits on an 824pt square inside the 1024 canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.addPath(platePath)
    context.setFillColor(plateColor)
    context.fillPath()

    let straight = heavyM()
    let letterBox = straight.boundingBoxOfPath
    let letter = warp(straight, box: letterBox)

    let bounds = letter.boundingBoxOfPath
    let scale = min(plate.width * markWidthFraction / bounds.width, plate.height * markWidthFraction / bounds.height)
    var place = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: plate.midX, y: plate.midY))

    context.addPath(letter.copy(using: &place)!)
    context.setFillColor(inkColor)
    context.fillPath(using: .winding)

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
writePNG(render(pixels: 1024), to: outputDir.appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(outputDir.appendingPathComponent("AppIcon.icns").path)" : "iconutil failed")
