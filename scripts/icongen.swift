import AppKit

// Generates the "Stack" app icon at all AppIcon.appiconset sizes.
// Design (1024 base): dark charcoal squircle, three stacked video cards
// rising to the upper right, orange play triangle on the front card.

let outDir = CommandLine.arguments[1]

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r/255, g/255, b/255, a])!
}

let bgTop = rgba(46, 50, 58)      // #2E323A
let bgBottom = rgba(26, 29, 35)   // #1A1D23
let cardBack = rgba(59, 65, 75)   // #3B414B
let cardMid = rgba(92, 100, 112)  // #5C6470
let cardFront = rgba(243, 244, 247) // #F3F4F7
let orange = rgba(255, 138, 0)    // #FF8A00

func roundedRect(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, fill: CGColor, s: CGFloat, shadow: Bool) {
    let rect = CGRect(x: x*s, y: y*s, width: w*s, height: h*s)
    let path = CGPath(roundedRect: rect, cornerWidth: r*s, cornerHeight: r*s, transform: nil)
    cg.saveGState()
    if shadow {
        cg.setShadow(offset: CGSize(width: 0, height: -14*s), blur: 30*s, color: rgba(0, 0, 0, 0.35))
    }
    cg.addPath(path)
    cg.setFillColor(fill)
    cg.fillPath()
    cg.restoreGState()
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = CGFloat(pixels) / 1024.0

    // Flip to top-left coordinates.
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: 1, y: -1)

    // Squircle background (Apple margin: 824pt icon on 1024 canvas) with a
    // subtle top-lit vertical gradient.
    let iconRect = CGRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s)
    let bgPath = CGPath(roundedRect: iconRect, cornerWidth: 186*s, cornerHeight: 186*s, transform: nil)
    cg.saveGState()
    cg.addPath(bgPath)
    cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 100*s), end: CGPoint(x: 0, y: 924*s), options: [])
    cg.restoreGState()

    // At menu-bar/Finder-list sizes three cards turn to mush — draw two.
    let simple = pixels <= 32

    // All cards share the icon's horizontal center (x = 512), stepping back
    // and up like a centered deck.
    if !simple {
        roundedRect(cg, 307, 177, 410, 287, 55, fill: cardBack, s: s, shadow: true)
    }
    roundedRect(cg, 259.5, 253, 505, 355, 61, fill: cardMid, s: s, shadow: true)
    roundedRect(cg, 191, 341, 642, 451, 68, fill: cardFront, s: s, shadow: true)

    // Play triangle on the front card (rounded joins for a friendlier read).
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: 451*s, y: 478*s))
    tri.addLine(to: CGPoint(x: 451*s, y: 655*s))
    tri.addLine(to: CGPoint(x: 628*s, y: 566.5*s))
    tri.closeSubpath()
    cg.saveGState()
    cg.setLineJoin(.round)
    cg.setLineWidth(26*s)
    cg.setStrokeColor(orange)
    cg.setFillColor(orange)
    cg.addPath(tri)
    cg.drawPath(using: .fillStroke)
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in files {
    let rep = drawIcon(pixels: px)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("wrote \(name) (\(px)px)")
}
