// Draws the CPU Fan app icon: fan blades inside a cool-to-hot temperature arc.
// Usage: swift make_icon.swift out.png
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon tile: 824pt rounded square centred on the 1024 canvas, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.20, green: 0.27, blue: 0.40, alpha: 1).cgColor,
    NSColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Temperature arc: 270 degrees, open at the bottom, green -> yellow -> orange -> red.
let center = CGPoint(x: 512, y: 512)
let radius = 300.0, width = 46.0
let start = 225.0, sweep = 270.0, steps = 270
let stops: [(Double, NSColor)] = [(0, .systemGreen), (0.45, .systemYellow), (0.72, .systemOrange), (1, .systemRed)]
func color(_ t: Double) -> NSColor {
    for i in 1..<stops.count where t <= stops[i].0 {
        let (a, ca) = stops[i - 1], (b, cb) = stops[i]
        return ca.usingColorSpace(.deviceRGB)!.blended(withFraction: (t - a) / (b - a), of: cb.usingColorSpace(.deviceRGB)!)!
    }
    return stops.last!.1
}
// Faint track first, then the coloured arc in small segments.
ctx.setLineCap(.round)
ctx.setLineWidth(width)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
ctx.addArc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: (start - sweep) * .pi / 180, clockwise: true)
ctx.strokePath()
ctx.setLineCap(.butt)
for i in 0..<steps {
    let t0 = Double(i) / Double(steps), t1 = Double(i + 1) / Double(steps)
    let a0 = (start - sweep * t0) * .pi / 180, a1 = (start - sweep * t1 - 0.3) * .pi / 180
    ctx.setStrokeColor(color(t0).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
}
// Round end caps in the end colours.
for (t, ang) in [(0.0, start), (1.0, start - sweep)] {
    let p = CGPoint(x: center.x + radius * cos(ang * .pi / 180), y: center.y + radius * sin(ang * .pi / 180))
    ctx.setFillColor(color(t).cgColor)
    ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
}
// Needle dot near the cool end: the fan is calm.
let needle = (start - sweep * 0.18) * .pi / 180
let np = CGPoint(x: center.x + radius * cos(needle), y: center.y + radius * sin(needle))
ctx.setFillColor(NSColor.white.cgColor)
ctx.setShadow(offset: .zero, blur: 10, color: NSColor.black.withAlphaComponent(0.5).cgColor)
ctx.fillEllipse(in: CGRect(x: np.x - 30, y: np.y - 30, width: 60, height: 60))
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Fan blades in the middle.
let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let blades = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let bs = blades.size
blades.draw(in: CGRect(x: 512 - bs.width / 2, y: 512 - bs.height / 2, width: bs.width, height: bs.height))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
