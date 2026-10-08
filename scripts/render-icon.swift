import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let image = NSImage(size: NSSize(width: px, height: px))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        let rect = NSRect(x: 70, y: 70, width: 884, height: 884)
        let path = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
        NSColor(red: 0.66, green: 0.39, blue: 0.27, alpha: 1).setFill(); path.fill()
        NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 0, alpha: 0.06))!.draw(in: path, angle: -90)
        let spine = NSBezierPath()
        spine.move(to: NSPoint(x: 190, y: 145)); spine.line(to: NSPoint(x: 190, y: 875))
        spine.lineWidth = 9
        NSColor(white: 0, alpha: 0.12).setStroke(); spine.stroke()
        let pages = NSBezierPath(roundedRect: NSRect(x: 205, y: 112, width: 637, height: 25), xRadius: 12, yRadius: 12)
        NSColor(red: 0.95, green: 0.89, blue: 0.77, alpha: 1).setFill(); pages.fill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 350, y: 685)); p.line(to: NSPoint(x: 590, y: 685))
        p.curve(to: NSPoint(x: 590, y: 315), controlPoint1: NSPoint(x: 838, y: 685), controlPoint2: NSPoint(x: 838, y: 315))
        p.line(to: NSPoint(x: 435, y: 315))
        p.lineWidth = 78; p.lineCapStyle = .round; p.lineJoinStyle = .round
        NSColor(red: 0.96, green: 0.93, blue: 0.82, alpha: 1).setStroke(); p.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 445, y: 810)); arrow.line(to: NSPoint(x: 310, y: 685)); arrow.line(to: NSPoint(x: 445, y: 560))
        arrow.lineWidth = 78; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
