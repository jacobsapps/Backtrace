import AppKit

// Breadcrumb: the chosen concept 06. One vector drawing drives the app icon,
// the transparent header logo, and the monochrome menu-bar template.
// Usage: swift scripts/render-icon.swift path/to/Backtrace.iconset
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawMark(_ c: CGContext, line: CGColor, nodes: CGColor) {
    let route = CGMutablePath()
    route.move(to: CGPoint(x: 69, y: 191))
    route.addLine(to: CGPoint(x: 69, y: 153))
    route.addQuadCurve(to: CGPoint(x: 95, y: 128), control: CGPoint(x: 69, y: 128))
    route.addLine(to: CGPoint(x: 158, y: 128))
    route.addQuadCurve(to: CGPoint(x: 185, y: 100), control: CGPoint(x: 185, y: 128))
    route.addLine(to: CGPoint(x: 185, y: 93))
    route.addQuadCurve(to: CGPoint(x: 158, y: 66), control: CGPoint(x: 185, y: 66))
    route.addLine(to: CGPoint(x: 126, y: 66))
    // The middle breadcrumb is a real cutout, including on transparent PDFs.
    c.saveGState()
    c.addRect(CGRect(x: 0, y: 0, width: 256, height: 256))
    c.addEllipse(in: CGRect(x: 116, y: 118, width: 20, height: 20))
    c.clip(using: .evenOdd)
    c.setStrokeColor(line); c.setLineWidth(22); c.setLineCap(.round)
    c.addPath(route); c.strokePath()
    c.restoreGState()
    c.setFillColor(nodes)
    c.fillEllipse(in: CGRect(x: 55, y: 177, width: 28, height: 28))
    c.fillEllipse(in: CGRect(x: 112, y: 52, width: 28, height: 28))
}

func drawIcon(_ c: CGContext) {
    c.setFillColor(color(0xB74F3E))
    c.addPath(CGPath(roundedRect: CGRect(x: 13, y: 13, width: 230, height: 230),
                     cornerWidth: 53, cornerHeight: 53, transform: nil))
    c.fillPath()
    drawMark(c, line: color(0xF9EFD8), nodes: color(0xE9B772))
}

// Explicit pixel buffers prevent Retina hosts doubling the intended sizes.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 256, y: -CGFloat(pixels) / 256)
        drawIcon(context)
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}

func writeLogo(_ name: String, line: CGColor, nodes: CGColor) {
    let url = folder.deletingLastPathComponent().appendingPathComponent(name + ".pdf")
    var box = CGRect(x: 0, y: 0, width: 154, height: 165)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: box.height)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -49, y: -46)
    drawMark(context, line: line, nodes: nodes)
    context.endPDFPage(); context.closePDF()
}
writeLogo("BrandMark", line: color(0xB74F3E), nodes: color(0xD6A25D))
writeLogo("MenuBarMark", line: color(0x000000), nodes: color(0x000000))
