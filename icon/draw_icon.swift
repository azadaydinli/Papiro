// Draws the Papiro app icon (1024×1024 PNG): a papyrus sheet with a rolled foot and a serif "P",
// on a deep teal tile in the macOS icon shape. Usage: swift draw_icon.swift out.png
import AppKit
import CoreText

let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// --- tile (macOS grid: 824 px rounded square, centred) ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x123B47)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x2A6F7C), rgb(0x174654), rgb(0x0D2A33)], [0, 0.55, 1]),
                       start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// soft light from the top
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 420, y: 900), startRadius: 0, endCenter: CGPoint(x: 420, y: 900), endRadius: 620, options: [])
ctx.restoreGState()

// --- papyrus sheet, slightly turned ---
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: -0.06)
let W: CGFloat = 470, H: CGFloat = 590, fold: CGFloat = 104
let sheet = CGMutablePath()
sheet.move(to: CGPoint(x: -W/2, y: -H/2))
sheet.addLine(to: CGPoint(x: W/2, y: -H/2))
sheet.addLine(to: CGPoint(x: W/2, y: H/2 - fold))
sheet.addLine(to: CGPoint(x: W/2 - fold, y: H/2))
sheet.addLine(to: CGPoint(x: -W/2, y: H/2))
sheet.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: -22), blur: 34, color: rgb(0x000000, 0.45))
ctx.addPath(sheet); ctx.setFillColor(rgb(0xEFDDB0)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(sheet); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFBF1D5), rgb(0xF1DFB2), rgb(0xE3C990)], [0, 0.55, 1]),
                       start: CGPoint(x: -W/2, y: H/2), end: CGPoint(x: W/2, y: -H/2), options: [])
// papyrus fibres: faint horizontal and vertical strands
ctx.setLineWidth(2)
for i in stride(from: -H/2 + 18, to: H/2, by: 22) {
    ctx.setStrokeColor(rgb(0xB8925A, 0.10 + 0.06 * CGFloat(Int(i) % 3 == 0 ? 1 : 0)))
    ctx.move(to: CGPoint(x: -W/2, y: i)); ctx.addLine(to: CGPoint(x: W/2, y: i + 3)); ctx.strokePath()
}
for i in stride(from: -W/2 + 30, to: W/2, by: 46) {
    ctx.setStrokeColor(rgb(0xB8925A, 0.07))
    ctx.move(to: CGPoint(x: i, y: -H/2)); ctx.addLine(to: CGPoint(x: i + 4, y: H/2)); ctx.strokePath()
}
ctx.restoreGState()

// folded corner
let flap = CGMutablePath()
flap.move(to: CGPoint(x: W/2, y: H/2 - fold))
flap.addLine(to: CGPoint(x: W/2 - fold, y: H/2))
flap.addLine(to: CGPoint(x: W/2 - fold + 10, y: H/2 - fold + 10))
flap.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -6, height: -6), blur: 12, color: rgb(0x000000, 0.25))
ctx.addPath(flap); ctx.setFillColor(rgb(0xD6B97C)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(flap); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xF6E6BF), rgb(0xC9A764)], [0, 1]),
                       start: CGPoint(x: W/2 - fold, y: H/2), end: CGPoint(x: W/2, y: H/2 - fold), options: [])
ctx.restoreGState()

// rolled foot of the scroll
let rollH: CGFloat = 74
let roll = CGRect(x: -W/2 - 22, y: -H/2 - rollH/2 + 6, width: W + 44, height: rollH)
let rollPath = CGPath(roundedRect: roll, cornerWidth: rollH/2, cornerHeight: rollH/2, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: rgb(0x000000, 0.4))
ctx.addPath(rollPath); ctx.setFillColor(rgb(0xC9A764)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rollPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xF4E2B6), rgb(0xD9BC80), rgb(0xA9844A), rgb(0xD1B072)], [0, 0.35, 0.8, 1]),
                       start: CGPoint(x: 0, y: roll.maxY), end: CGPoint(x: 0, y: roll.minY), options: [])
ctx.restoreGState()
// roll ends
for x in [roll.minX + rollH/2, roll.maxX - rollH/2] {
    let e = CGRect(x: x - 16, y: roll.midY - rollH/2 + 4, width: 32, height: rollH - 8)
    ctx.setFillColor(rgb(0x8E6B37)); ctx.fillEllipse(in: e)
    ctx.setFillColor(rgb(0x5E4423)); ctx.fillEllipse(in: e.insetBy(dx: 9, dy: 18))
}

// the letter
let font = CTFontCreateWithName("Georgia-Bold" as CFString, 360, nil)
let attr = NSAttributedString(string: "P", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x174654),
])
let line = CTLineCreateWithAttributedString(attr)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 2, color: rgb(0x5E4423, 0.35))
ctx.textPosition = CGPoint(x: -bounds.midX - 70, y: -bounds.midY + 70)
CTLineDraw(line, ctx)
ctx.restoreGState()

// lines of writing to the right of and under the letter
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0x174654, 0.55))
ctx.setLineWidth(15)
for (y, x0, x1) in [(150.0, 105.0, 175.0), (95.0, 105.0, 185.0), (40.0, 105.0, 160.0), (-120.0, -170.0, 175.0), (-175.0, -170.0, 110.0)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
}
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
