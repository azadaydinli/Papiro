// Draws the Papiro app icon (1024×1024 PNG): a white glass "P" over a frosted page, on a blue tile in the
// macOS icon shape. Usage: swift draw_icon.swift out.png
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// draw with the y axis going down (as the design was made); shadow offsets stay in device space (negative = down)
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
    ctx.move(to: CGPoint(x: x0, y: y0)); ctx.addLine(to: CGPoint(x: x1, y: y1)); ctx.strokePath()
}

// --- tile (macOS grid: 824 px rounded square, centred) ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.3))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x3A69D0)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x4FA2FF), rgb(0x2730A0)], [0, 1]),
                       start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
// glass sheen from the top
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// --- frosted page behind the letter, slightly turned ---
ctx.saveGState()
ctx.translateBy(x: 640, y: 660)
ctx.rotate(by: 8 * .pi / 180)
ctx.translateBy(x: -640, y: -660)
let page = CGPath(roundedRect: CGRect(x: 505, y: 500, width: 270, height: 320), cornerWidth: 32, cornerHeight: 32, transform: nil)
ctx.addPath(page); ctx.setFillColor(rgb(0xFFFFFF, 0.24)); ctx.fillPath()
ctx.addPath(page); ctx.setStrokeColor(rgb(0xFFFFFF, 0.5)); ctx.setLineWidth(3); ctx.strokePath()
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(16)
line(610, 650, 730, 650); line(610, 700, 730, 700); line(550, 750, 690, 750)
ctx.restoreGState()

// --- the glass P ---
let P = CGMutablePath()
P.move(to: CGPoint(x: 360, y: 400))
P.addArc(tangent1End: CGPoint(x: 360, y: 250), tangent2End: CGPoint(x: 560, y: 250), radius: 40)
P.addLine(to: CGPoint(x: 560, y: 250))
P.addArc(center: CGPoint(x: 560, y: 410), radius: 160, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
P.addLine(to: CGPoint(x: 470, y: 570))
P.addArc(tangent1End: CGPoint(x: 470, y: 780), tangent2End: CGPoint(x: 360, y: 780), radius: 40)
P.addArc(tangent1End: CGPoint(x: 360, y: 780), tangent2End: CGPoint(x: 360, y: 250), radius: 40)
P.closeSubpath()
// the counter (hole of the bowl)
P.move(to: CGPoint(x: 470, y: 340))
P.addLine(to: CGPoint(x: 555, y: 340))
P.addArc(center: CGPoint(x: 555, y: 410), radius: 70, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
P.addLine(to: CGPoint(x: 470, y: 480))
P.closeSubpath()

ctx.saveGState()
ctx.translateBy(x: -28, y: 0)
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.saveGState()
ctx.addPath(P); ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.98), rgb(0xDCE6FF, 0.85)], [0, 1]),
                       start: CGPoint(x: 360, y: 250), end: CGPoint(x: 720, y: 780), options: [])
ctx.restoreGState()
ctx.addPath(P); ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(3); ctx.strokePath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// --- glass rim of the tile ---
let rim = CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil)
ctx.addPath(rim); ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
