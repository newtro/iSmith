// Draws the iSmith app icon: the space rail beside a browser window tinted to the active space.
// Run: swift Tools/make-icon.swift <out.png> [--dev]
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon.png")
let dev = args.contains("--dev")
let size = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext
// Top-left origin, so the layout reads like the app.
cg.translateBy(x: 0, y: CGFloat(size))
cg.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// Squircle body (Apple's grid: 824 pt body inside a 1024 canvas) with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35).cgColor)
rgb(0.08, 0.09, 0.15).setFill()
rounded(body, 185).fill()
cg.restoreGState()
rounded(body, 185).addClip()
NSGradient(colors: [rgb(0.10, 0.12, 0.22), rgb(0.16, 0.19, 0.34)])!.draw(in: body, angle: -90)

// Space rail: one icon per space, the first one active.
let spaces = [rgb(0.29, 0.52, 0.98), rgb(0.20, 0.70, 0.48), rgb(0.62, 0.42, 0.98), rgb(0.95, 0.62, 0.18)]
for (i, color) in spaces.enumerated() {
    let rect = CGRect(x: 168, y: 214 + CGFloat(i) * 150, width: 116, height: 116)
    (i == 0 ? color : color.withAlphaComponent(0.55)).setFill()
    rounded(rect, 30).fill()
}
rgb(1, 1, 1, 0.9).setFill()
rounded(CGRect(x: 132, y: 238, width: 14, height: 68), 7).fill()

// Browser window tinted to the active space.
let window = CGRect(x: 334, y: 214, width: 520, height: 566)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0, 0, 0, 0.35).cgColor)
rgb(0.93, 0.95, 0.99).setFill()
rounded(window, 44).fill()
cg.restoreGState()
rounded(window, 44).addClip()
spaces[0].setFill()
NSBezierPath(rect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 104)).fill()
rgb(1, 1, 1, 0.95).setFill()
rounded(CGRect(x: window.minX + 30, y: window.minY + 34, width: 168, height: 46), 14).fill()
rgb(1, 1, 1, 0.45).setFill()
rounded(CGRect(x: window.minX + 214, y: window.minY + 34, width: 168, height: 46), 14).fill()
rgb(0.62, 0.67, 0.78).setFill()
for (i, width) in [400.0, 330.0, 370.0, 250.0].enumerated() {
    rounded(CGRect(x: window.minX + 44, y: window.minY + 168 + CGFloat(i) * 84, width: width, height: 36), 18).fill()
}
cg.resetClip()
rounded(body, 185).addClip()

if dev {
    let band = CGRect(x: 100, y: 760, width: 824, height: 164)
    rgb(0.95, 0.45, 0.10).setFill()
    NSBezierPath(rect: band).fill()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 110, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style,
        .kern: 18,
    ]
    // Text draws in a flipped-aware context.
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped
    ("DEV" as NSString).draw(in: CGRect(x: 100, y: 778, width: 824, height: 140), withAttributes: attrs)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
