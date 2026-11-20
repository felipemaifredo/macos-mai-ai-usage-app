import AppKit

// Draws the AI Usage app icon at 1024x1024 and writes icon_1024.png next to this script's cwd.

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt squircle centered in 1024 canvas.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1B1838))
ctx.fillPath()
ctx.restoreGState()

// Background gradient
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2A2350), rgb(0x141228)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: size / 2, y: tile.maxY),
                       end: CGPoint(x: size / 2, y: tile.minY), options: [])
// Soft top glow
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x8B7CF6, 0.35), rgb(0x8B7CF6, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: tile.maxY - 60), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: tile.maxY - 60), endRadius: 520, options: [])
ctx.restoreGState()

let center = CGPoint(x: size / 2, y: size / 2 - 6)

// Gauge arcs: start at 225° and sweep clockwise 270° (a speedometer shape).
func arc(radius: CGFloat, width: CGFloat, fraction: CGFloat, colors: [CGColor]) {
    let start = CGFloat.pi * 1.25
    let end = start - CGFloat.pi * 1.5 * fraction

    // Track
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.09))
    ctx.addArc(center: center, radius: radius, startAngle: start,
               endAngle: start - CGFloat.pi * 1.5, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // Gradient-filled value arc
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    ctx.restoreGState()
}

arc(radius: 300, width: 64, fraction: 0.72, colors: [rgb(0xF4A06B), rgb(0xD97757), rgb(0xC2553A)])
arc(radius: 204, width: 56, fraction: 0.45, colors: [rgb(0x5B8CFF), rgb(0x8B7CF6), rgb(0xC084FC)])

// Four-pointed sparkle in the middle
func sparkle(at c: CGPoint, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 0.22 // waist
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - r * k, y: c.y + r * k))
    p.closeSubpath()
    return p
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFFFFFF, 0.55))
ctx.addPath(sparkle(at: center, r: 104))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Tiny companion sparkle
ctx.saveGState()
ctx.addPath(sparkle(at: CGPoint(x: center.x + 92, y: center.y + 96), r: 30))
ctx.setFillColor(rgb(0xFFFFFF, 0.85))
ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon_1024.png written")
