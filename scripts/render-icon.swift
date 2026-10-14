import AppKit

// Backtrace: an open book with a ribbon that retraces its path.
// Render into explicit pixel buffers: NSImage.lockFocus() otherwise doubles
// dimensions on Retina hosts and drops the intended small ICNS representations.
// Usage: swift scripts/render-icon.swift path/to/Backtrace.iconset
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawIcon(_ c: CGContext) {
    // The same generous, transparent macOS inset as the original app icon.
    let tile = CGPath(roundedRect: CGRect(x: 70, y: 70, width: 884, height: 884),
                      cornerWidth: 196, cornerHeight: 196, transform: nil)
    c.saveGState()
    c.addPath(tile); c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x4D6A53), color(0x304F3E)] as CFArray,
                              locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 70),
                         end: CGPoint(x: 512, y: 954), options: [])
    c.restoreGState()

    // Two broad pages, not a book-shaped button. The negative-space gutter
    // remains visible at Dock size; no tiny page rules or decorative lettering.
    let left = CGMutablePath()
    left.move(to: CGPoint(x: 489, y: 348))
    left.addCurve(to: CGPoint(x: 261, y: 294), control1: CGPoint(x: 422, y: 303), control2: CGPoint(x: 340, y: 282))
    left.addQuadCurve(to: CGPoint(x: 242, y: 316), control: CGPoint(x: 242, y: 297))
    left.addLine(to: CGPoint(x: 242, y: 655))
    left.addQuadCurve(to: CGPoint(x: 265, y: 678), control: CGPoint(x: 242, y: 680))
    left.addCurve(to: CGPoint(x: 489, y: 732), control1: CGPoint(x: 350, y: 671), control2: CGPoint(x: 428, y: 689))
    left.closeSubpath()

    let right = CGMutablePath()
    right.move(to: CGPoint(x: 535, y: 348))
    right.addCurve(to: CGPoint(x: 763, y: 294), control1: CGPoint(x: 602, y: 303), control2: CGPoint(x: 684, y: 282))
    right.addQuadCurve(to: CGPoint(x: 782, y: 316), control: CGPoint(x: 782, y: 297))
    right.addLine(to: CGPoint(x: 782, y: 655))
    right.addQuadCurve(to: CGPoint(x: 759, y: 678), control: CGPoint(x: 782, y: 680))
    right.addCurve(to: CGPoint(x: 535, y: 732), control1: CGPoint(x: 674, y: 671), control2: CGPoint(x: 596, y: 689))
    right.closeSubpath()

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 8), blur: 16,
                color: CGColor(srgbRed: 0.08, green: 0.16, blue: 0.11, alpha: 0.18))
    c.setFillColor(color(0xF7F1DD)); c.addPath(left); c.fillPath()
    c.setFillColor(color(0xFFFAE9)); c.addPath(right); c.fillPath()
    c.restoreGState()

    // A bookmark emerges from the top edge, follows the page, then turns back
    // toward its starting place. The return gesture is the ribbon itself.
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 700, y: 294))
    ribbon.addLine(to: CGPoint(x: 700, y: 528))
    ribbon.addCurve(to: CGPoint(x: 599, y: 528), control1: CGPoint(x: 700, y: 596), control2: CGPoint(x: 599, y: 596))
    ribbon.addLine(to: CGPoint(x: 599, y: 441))
    c.setStrokeColor(color(0xBD8650)); c.setLineWidth(37)
    c.setLineCap(.butt); c.setLineJoin(.round)
    c.addPath(ribbon); c.strokePath()
    let tip = CGMutablePath()
    tip.move(to: CGPoint(x: 559, y: 479)); tip.addLine(to: CGPoint(x: 599, y: 438))
    tip.addLine(to: CGPoint(x: 639, y: 479))
    c.setLineWidth(29); c.setLineCap(.round)
    c.addPath(tip); c.strokePath()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
        drawIcon(context)
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
