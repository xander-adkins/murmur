// Renders the Murmur app icon and builds AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size: CGFloat = 1024

func render() -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icon grid: the squircle sits on an 824pt square inside the 1024 canvas.
    let inset: CGFloat = 100
    let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the plate.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.45))
    context.addPath(platePath)
    context.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Plate gradient: charcoal to deep indigo.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.20, green: 0.21, blue: 0.32, alpha: 1),
            CGColor(red: 0.09, green: 0.09, blue: 0.14, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])

    // Subtle top highlight.
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(highlight, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.midY), options: [])
    context.restoreGState()

    // Remote body: tall rounded pill, slightly left of centre to leave room for the sound waves.
    let remote = CGRect(x: 318, y: 232, width: 210, height: 560)
    let remotePath = CGPath(roundedRect: remote, cornerWidth: 70, cornerHeight: 70, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.5))
    context.addPath(remotePath)
    context.setFillColor(CGColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(remotePath)
    context.clip()
    let bodyGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [CGColor(gray: 0.97, alpha: 1), CGColor(gray: 0.82, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(bodyGradient, start: CGPoint(x: remote.minX, y: 0), end: CGPoint(x: remote.maxX, y: 0), options: [])
    context.restoreGState()

    // Click pad ring near the top.
    let padCenter = CGPoint(x: remote.midX, y: remote.maxY - 120)
    context.setLineWidth(16)
    context.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
    context.strokeEllipse(in: CGRect(x: padCenter.x - 66, y: padCenter.y - 66, width: 132, height: 132))
    context.setFillColor(CGColor(gray: 0.70, alpha: 1))
    context.fillEllipse(in: CGRect(x: padCenter.x - 30, y: padCenter.y - 30, width: 60, height: 60))

    // Small buttons.
    for (dx, dy) in [(-46, -240), (46, -240), (-46, -330), (46, -330), (-46, -420), (46, -420)] {
        let center = CGPoint(x: remote.midX + CGFloat(dx), y: remote.maxY + CGFloat(dy))
        context.setFillColor(CGColor(gray: 0.66, alpha: 1))
        context.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
    }

    // Mic button, glowing red: the push-to-talk key.
    let mic = CGPoint(x: remote.midX, y: remote.minY + 74)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 28, color: CGColor(red: 1, green: 0.30, blue: 0.30, alpha: 0.9))
    context.setFillColor(CGColor(red: 0.98, green: 0.25, blue: 0.27, alpha: 1))
    context.fillEllipse(in: CGRect(x: mic.x - 30, y: mic.y - 30, width: 60, height: 60))
    context.restoreGState()
    // Mic glyph: capsule, U-shaped cradle below it, short stem.
    context.setFillColor(CGColor(gray: 1, alpha: 0.95))
    context.addPath(CGPath(roundedRect: CGRect(x: mic.x - 7, y: mic.y - 4, width: 14, height: 26), cornerWidth: 7, cornerHeight: 7, transform: nil))
    context.fillPath()
    context.setLineWidth(4.5)
    context.setLineCap(.round)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    context.addArc(center: CGPoint(x: mic.x, y: mic.y + 2), radius: 14, startAngle: .pi, endAngle: 0, clockwise: false)
    context.strokePath()
    context.move(to: CGPoint(x: mic.x, y: mic.y - 12))
    context.addLine(to: CGPoint(x: mic.x, y: mic.y - 19))
    context.strokePath()

    // Sound waves leaving the mic button, in the same red.
    context.setLineCap(.round)
    for (index, radius) in [125, 185, 245].enumerated() {
        context.setLineWidth(CGFloat(26 - index * 4))
        context.setStrokeColor(CGColor(red: 0.98, green: 0.25, blue: 0.27, alpha: 1 - CGFloat(index) * 0.22))
        context.addArc(center: mic, radius: CGFloat(radius), startAngle: -0.55, endAngle: 0.55, clockwise: false)
        context.strokePath()
    }

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func resized(_ image: CGImage, to pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return context.makeImage()!
}

let master = render()
let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    writePNG(resized(master, to: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(resized(master, to: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
writePNG(master, to: outputDir.appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(outputDir.appendingPathComponent("AppIcon.icns").path)" : "iconutil failed")
