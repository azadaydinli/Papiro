import AppKit
import PDFKit

// "Kənarları təmizlə": everything outside a frame is painted white. The frame is found automatically
// (the main text and every sizeable block — signatures, stamps, emblems — but not punch holes, corner
// sheet numbers or specks, which stand apart in white space) and can be adjusted by hand.
// Frames are kept as fractions of the page's crop box (page space, unrotated), so one frame fits every page.

enum Margins {
    /// Content frame of a page, as fractions of its crop box. Falls back to the whole page.
    static func detect(_ page: PDFPage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let ref = page.pageRef else { return full }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return full }
        let W = 320, H = max(1, Int(CGFloat(W) * box.height / box.width))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return full }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.scaleBy(x: CGFloat(W) / box.width, y: CGFloat(H) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(ref)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return full }

        // dark pixels; memory row 0 is the top of the page
        var dark = [Bool](repeating: false, count: W * H)
        // 185, not darker: blue ink of signatures and stamps scans as light grey and must count as content
        for i in 0..<(W * H) { dark[i] = data[i] < 185 }

        // connected components (letters, strokes, specks); the dark scan edge and dust are dropped
        var seen = [Bool](repeating: false, count: W * H)
        var comps: [(r: CGRect, ink: Int)] = []
        var stack: [Int] = []
        for start in 0..<(W * H) where dark[start] && !seen[start] {
            var minX = W, minY = H, maxX = 0, maxY = 0, count = 0
            stack.append(start); seen[start] = true
            while let p = stack.popLast() {
                let x = p % W, y = p / W
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
                    let q = ny * W + nx
                    if dark[q] && !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
            if count < 3 { continue }                                                // dust
            if minX <= 1 || minY <= 1 || maxX >= W - 2 || maxY >= H - 2 { continue } // dark scan edge
            comps.append((CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), count))
        }
        // a blank sheet (only dust): keep just a small spot in the middle, so the whole sheet is cleaned
        let blank = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        guard !comps.isEmpty else { return blank }

        // Group marks that lie close together: letters into lines, lines into paragraphs, a signature with its
        // line. Punch holes and the hand-written sheet number in the corner stand apart, separated by white space.
        let gx = CGFloat(W) * 0.022, gy = CGFloat(H) * 0.018
        var parent = Array(0..<comps.count)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        let order = comps.indices.sorted { comps[$0].r.minY < comps[$1].r.minY }
        for (a, i) in order.enumerated() {
            let ri = comps[i].r
            for j in order[(a + 1)...] {
                let rj = comps[j].r
                if rj.minY - ri.maxY > gy { break }                                  // sorted by top: nothing further down is near
                let dx = max(0, max(ri.minX, rj.minX) - min(ri.maxX, rj.maxX))
                let dy = max(0, max(ri.minY, rj.minY) - min(ri.maxY, rj.maxY))
                if dx <= gx && dy <= gy { parent[root(i)] = root(j) }
            }
        }
        var groups: [Int: (r: CGRect, ink: Int)] = [:]
        for (i, c) in comps.enumerated() {
            let g = root(i)
            groups[g] = groups[g].map { ($0.r.union(c.r), $0.ink + c.ink) } ?? c
        }
        // keep the main body (most ink) and every sizeable block (a signature, a stamp, an emblem);
        // drop small isolated groups: holes, corner page numbers, specks
        let main = groups.values.max { $0.ink < $1.ink }!
        if main.ink < 30 { return blank }
        let big = CGFloat(W) * 0.07
        var keep: CGRect? = nil
        for g in groups.values where g.r == main.r || max(g.r.width, g.r.height) >= big {
            keep = keep.map { $0.union(g.r) } ?? g.r
        }
        guard let k = keep else { return full }
        // to fractions, page space (y up), with a little room around the content
        let pad = 0.006   // just clear of the outermost ink
        var f = CGRect(x: Double(k.minX) / Double(W) - pad,
                       y: 1 - Double(k.maxY) / Double(H) - pad,
                       width: Double(k.width) / Double(W) + 2 * pad,
                       height: Double(k.height) / Double(H) + 2 * pad)
        f = f.intersection(full)
        // the frame tool needs at least 5% each way; grow a very thin frame around its centre
        if f.width < 0.05 { f = f.insetBy(dx: (f.width - 0.05) / 2, dy: 0) }
        if f.height < 0.05 { f = f.insetBy(dx: 0, dy: (f.height - 0.05) / 2) }
        return f.intersection(full)
    }

    /// The frame in page coordinates.
    static func rect(_ frac: CGRect, on page: PDFPage) -> CGRect {
        let b = page.bounds(for: .cropBox)
        return CGRect(x: b.minX + frac.minX * b.width, y: b.minY + frac.minY * b.height,
                      width: frac.width * b.width, height: frac.height * b.height)
    }

    /// A copy of a scanned page with everything outside `frac` white — really removed, not covered (see Scan).
    /// Nil for a page that is not a scan.
    static func cleared(_ page: PDFPage, keep frac: CGRect) -> (page: PDFPage, owner: PDFDocument)? {
        Scan.redrawn(page) { ctx, box in
            ctx.addRect(box)
            ctx.addRect(rect(frac, on: page))
            ctx.fillPath(using: .evenOdd)
        }
    }
}

extension PDFDoc {
    /// Clean the margins of the pages at `idx`; `frame(i)` gives each page's frame. Returns the new pages.
    @discardableResult
    func clearMargins(_ idx: [Int], frame: (Int) -> CGRect) -> [PDFPage] {
        var made: [PDFPage] = []
        perform("Kənarları təmizlə") {
            for i in idx {
                let f = frame(i)
                if f.minX <= 0.001 && f.minY <= 0.001 && f.maxX >= 0.999 && f.maxY >= 0.999 { continue } // nothing to clear
                guard let old = pdf.page(at: i), let (new, owner) = Margins.cleared(old, keep: f) else { continue }
                keepAlive.append(owner)
                pdf.removePage(at: i)
                pdf.insert(new, at: i)
                replaceInGroups(old, with: new)
                made.append(new)
            }
        }
        return made
    }
}

/// Drawn over the page view while cleaning margins. Every visible page shows its own frame (the page view
/// scrolls as usual); dragging a frame's edge, corner or inside changes that page's frame only.
extension NSView {
    /// The part of this view not covered by `cover`: the tool strip floats over the top of the page view, and an
    /// overlay must neither draw nor take the mouse under it (the page there is blurred by the system).
    func area(below cover: NSView?) -> NSRect {
        guard let c = cover, !c.isHiddenOrHasHiddenAncestor, let w = window, c.window === w else { return bounds }
        let r = convert(c.convert(c.bounds, to: nil), from: nil)
        var a = bounds
        a.size.height = max(0, min(a.maxY, r.minY) - a.minY)
        return a
    }
}

final class MarginOverlay: NSView {
    weak var pdfView: PDFView?
    /// The tool strip over the top of the page view (see `area(below:)`).
    weak var cover: NSView?
    /// The frame of a page (fractions of its crop box), and how to store an edited one.
    var frameOf: ((PDFPage) -> CGRect)?
    /// Pages the tool works on (scans); the others show no frame and cannot be edited.
    var editable: ((PDFPage) -> Bool)?
    var setFrame: ((PDFPage, CGRect) -> Void)?
    private enum Grab { case move, left, right, top, bottom, tl, tr, bl, br }
    private var grab: Grab?
    private var grabPage: PDFPage?
    private var startFrac = CGRect.zero
    private var startPoint = CGPoint.zero

    private func viewRect(_ frac: CGRect, _ p: PDFPage) -> CGRect? {
        guard let pv = pdfView else { return nil }
        return convert(pv.convert(Margins.rect(frac, on: p), from: p), from: pv)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pv = pdfView, let frameOf else { return }
        NSBezierPath(rect: area(below: cover)).addClip()
        for p in pv.visiblePages where editable?(p) ?? true {
            guard let r = viewRect(frameOf(p), p) else { continue }
            let pageRect = convert(pv.convert(p.bounds(for: .cropBox), from: p), from: pv)
            guard pageRect.intersects(dirtyRect) else { continue }
            // what will be cleared: transparent, crossed with an X grid so the content under it stays visible
            let shade = NSBezierPath(rect: pageRect)
            shade.append(NSBezierPath(rect: r))
            shade.windingRule = .evenOdd
            NSGraphicsContext.saveGraphicsState()
            shade.addClip()
            let hatch = NSBezierPath()
            let step: CGFloat = 12
            var x = pageRect.minX - pageRect.height
            while x < pageRect.maxX {
                hatch.move(to: CGPoint(x: x, y: pageRect.minY)); hatch.line(to: CGPoint(x: x + pageRect.height, y: pageRect.maxY))
                hatch.move(to: CGPoint(x: x + pageRect.height, y: pageRect.minY)); hatch.line(to: CGPoint(x: x, y: pageRect.maxY))
                x += step
            }
            hatch.lineWidth = 1
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 2
            border.stroke()
            for pt in handles(r).values {
                let h = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
                NSColor.white.setFill(); NSBezierPath(ovalIn: h).fill()
                NSColor.controlAccentColor.setStroke(); NSBezierPath(ovalIn: h).stroke()
            }
        }
    }

    private func handles(_ r: CGRect) -> [Grab: CGPoint] {
        [.tl: CGPoint(x: r.minX, y: r.maxY), .tr: CGPoint(x: r.maxX, y: r.maxY),
         .bl: CGPoint(x: r.minX, y: r.minY), .br: CGPoint(x: r.maxX, y: r.minY),
         .left: CGPoint(x: r.minX, y: r.midY), .right: CGPoint(x: r.maxX, y: r.midY),
         .top: CGPoint(x: r.midX, y: r.maxY), .bottom: CGPoint(x: r.midX, y: r.minY)]
    }

    /// The page under the pointer and what part of its frame is there.
    private func grabAt(_ ev: NSEvent) -> (PDFPage, Grab)? {
        guard let pv = pdfView, let frameOf,
              let p = pv.page(for: pv.convert(ev.locationInWindow, from: nil), nearest: false),
              editable?(p) ?? true, let r = viewRect(frameOf(p), p) else { return nil }
        let pt = convert(ev.locationInWindow, from: nil)
        guard area(below: cover).contains(pt) else { return nil }
        for (g, h) in handles(r) where hypot(h.x - pt.x, h.y - pt.y) < 10 { return (p, g) }
        let near: CGFloat = 6
        if abs(pt.x - r.minX) < near && pt.y > r.minY && pt.y < r.maxY { return (p, .left) }
        if abs(pt.x - r.maxX) < near && pt.y > r.minY && pt.y < r.maxY { return (p, .right) }
        if abs(pt.y - r.maxY) < near && pt.x > r.minX && pt.x < r.maxX { return (p, .top) }
        if abs(pt.y - r.minY) < near && pt.x > r.minX && pt.x < r.maxX { return (p, .bottom) }
        return r.contains(pt) ? (p, .move) : nil
    }

    /// Pointer position in fractions of a page.
    private func fracPoint(_ ev: NSEvent, _ p: PDFPage) -> CGPoint? {
        guard let pv = pdfView else { return nil }
        let pt = pv.convert(pv.convert(ev.locationInWindow, from: nil), to: p)
        let b = p.bounds(for: .cropBox)
        return CGPoint(x: (pt.x - b.minX) / b.width, y: (pt.y - b.minY) / b.height)
    }

    override func mouseDown(with ev: NSEvent) {
        guard let (p, g) = grabAt(ev), let frameOf else { grab = nil; grabPage = nil; return }
        grab = g; grabPage = p
        startFrac = frameOf(p)
        startPoint = fracPoint(ev, p) ?? .zero
    }

    override func mouseDragged(with ev: NSEvent) {
        guard let g = grab, let page = grabPage, let p = fracPoint(ev, page) else { return }
        let dx = p.x - startPoint.x, dy = p.y - startPoint.y
        var minX = startFrac.minX, maxX = startFrac.maxX, minY = startFrac.minY, maxY = startFrac.maxY
        switch g {
        case .move:
            let w = startFrac.width, h = startFrac.height
            minX = max(0, min(1 - w, minX + dx)); maxX = minX + w
            minY = max(0, min(1 - h, minY + dy)); maxY = minY + h
        case .left: minX += dx
        case .right: maxX += dx
        case .top: maxY += dy
        case .bottom: minY += dy
        case .tl: minX += dx; maxY += dy
        case .tr: maxX += dx; maxY += dy
        case .bl: minX += dx; minY += dy
        case .br: maxX += dx; minY += dy
        }
        let m = 0.05
        minX = max(0, min(minX, maxX - m)); maxX = min(1, max(maxX, minX + m))
        minY = max(0, min(minY, maxY - m)); maxY = min(1, max(maxY, minY + m))
        setFrame?(page, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        needsDisplay = true
    }

    override func mouseUp(with ev: NSEvent) { grab = nil; grabPage = nil }

    override func mouseMoved(with ev: NSEvent) {
        switch grabAt(ev)?.1 {
        case .left?, .right?: NSCursor.resizeLeftRight.set()
        case .top?, .bottom?: NSCursor.resizeUpDown.set()
        case .move?: NSCursor.openHand.set()
        case .tl?, .tr?, .bl?, .br?: NSCursor.crosshair.set()
        case nil: NSCursor.arrow.set()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        area(below: cover).contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // the page view keeps scrolling smoothly; the overlay follows it
    // the wheel goes to the scroll view inside the page view (PDFView itself does not scroll on it)
    override func scrollWheel(with ev: NSEvent) {
        if let sv = pdfView?.documentView?.enclosingScrollView { sv.scrollWheel(with: ev) } else { pdfView?.scrollWheel(with: ev) }
    }
    override func magnify(with ev: NSEvent) { pdfView?.magnify(with: ev) }
}
