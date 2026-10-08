// Renders the app icon: swift scripts/make-icon.swift <out.png>
// A light bulb filled with spring water, the feed mark inside: a fount of ideas.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
}

let teal: UInt32 = 0x0B4F6B

// Rounded-square body with a drop shadow, per the macOS icon grid (824pt body on 1024 canvas).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(teal))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(gradient(0x2CC7C1, teal), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// Bulb glass: a circle narrowing into a neck.
let center = CGPoint(x: 512, y: 560)
let radius: CGFloat = 250
let end = -CGFloat.pi * 0.22
let glass = CGMutablePath()
glass.addArc(center: center, radius: radius, startAngle: end, endAngle: .pi - end, clockwise: false)
glass.addCurve(to: CGPoint(x: center.x - 96, y: 300), control1: CGPoint(x: center.x - 200, y: 380),
               control2: CGPoint(x: center.x - 110, y: 350))
glass.addLine(to: CGPoint(x: center.x + 96, y: 300))
glass.addCurve(to: CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end)),
               control1: CGPoint(x: center.x + 110, y: 350), control2: CGPoint(x: center.x + 200, y: 380))
glass.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.25))
ctx.addPath(glass)
ctx.setFillColor(.white)
ctx.fillPath()
ctx.restoreGState()

// Water filling the lower half of the bulb, with a wavy surface.
ctx.saveGState()
ctx.addPath(glass)
ctx.clip()
let water = CGMutablePath()
let x0 = center.x - radius - 20, x1 = center.x + radius + 20
water.move(to: CGPoint(x: x0, y: 200))
var x = x0
while x <= x1 {
    water.addLine(to: CGPoint(x: x, y: 520 + 22 * sin((x - x0) / 260 * 2 * .pi + 0.6)))
    x += 4
}
water.addLine(to: CGPoint(x: x1, y: 200))
water.closeSubpath()
ctx.addPath(water)
ctx.clip()
ctx.drawLinearGradient(gradient(0x9BE7FA, 0x46AEEB), start: CGPoint(x: 0, y: 560), end: CGPoint(x: 0, y: 300), options: [])
ctx.restoreGState()

// The feed mark, rising out of the water.
let origin = CGPoint(x: center.x - 120, y: 420)
ctx.setFillColor(rgb(teal))
ctx.fillEllipse(in: CGRect(x: origin.x - 34, y: origin.y - 34, width: 68, height: 68))
ctx.setStrokeColor(rgb(teal))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
for r: CGFloat in [120, 220] {
    ctx.addArc(center: origin, radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
    ctx.strokePath()
}

// Screw base: two bands, kept simple so it survives small sizes.
ctx.setFillColor(rgb(0xD8DEEA))
for k in 0..<2 {
    let inset = CGFloat(k) * 8
    let band = CGRect(x: center.x - 92 + inset, y: 246 - CGFloat(k) * 56, width: 184 - inset * 2, height: 42)
    ctx.addPath(CGPath(roundedRect: band, cornerWidth: 21, cornerHeight: 21, transform: nil))
    ctx.fillPath()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
