import AppKit
import PDFKit

// "White Out": the user draws rectangles over unwanted parts of the text; "White Out" paints them white for good.
// Rectangles are kept in page space (unrotated PDF points) per page until they are applied.

enum Whiteout {
    /// A copy of a scanned page with the rectangles white — really removed, not covered (see Scan).
    /// Nil for a page that is not a scan. The new page lives in its own PDF, which must be kept alive with it.
    static func painted(_ page: PDFPage, _ rects: [CGRect]) -> (page: PDFPage, owner: PDFDocument)? {
        guard !rects.isEmpty else { return nil }
        return Scan.redrawn(page) { ctx, _ in rects.forEach { ctx.fill($0) } }
    }
}

extension PDFDoc {
    /// Paint the given rectangles white, page by page, as one undoable step.
    func whiteout(_ marks: [(index: Int, rects: [CGRect])]) {
        perform(L("White Out")) {
            for m in marks {
                guard let old = pdf.page(at: m.index), let (new, owner) = Whiteout.painted(old, m.rects) else { continue }
                keepAlive.append(owner)
                pdf.removePage(at: m.index)
                pdf.insert(new, at: m.index)
                replaceInGroups(old, with: new)
            }
        }
    }
}

/// Drawn over the page view in "White Out" mode: press and drag to draw a rectangle; on release it is painted white.
final class WhiteoutOverlay: NSView {
    weak var pdfView: PDFView?
    /// The tool strip over the top of the page view (see `area(below:)`).
    weak var cover: NSView?
    /// Called on mouse-up with the page and the rectangle (page space) to paint white.
    var onDraw: ((PDFPage, CGRect) -> Void)?
    /// Pages that can be whitened (scans); drawing on any other page does nothing.
    var editable: ((PDFPage) -> Bool)?
    private var dragStart: CGPoint?      // page space
    private var dragRect: CGRect?        // page space, while drawing
    private var dragPage: PDFPage?

    private func pagePoint(_ ev: NSEvent, _ p: PDFPage) -> CGPoint? {
        guard let pv = pdfView else { return nil }
        let pt = pv.convert(pv.convert(ev.locationInWindow, from: nil), to: p)
        let b = p.bounds(for: .cropBox)
        return CGPoint(x: min(max(pt.x, b.minX), b.maxX), y: min(max(pt.y, b.minY), b.maxY))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pv = pdfView, let p = dragPage, let r = dragRect else { return }
        NSBezierPath(rect: area(below: cover)).addClip()
        let v = convert(pv.convert(r, from: p), from: pv)
        NSColor.white.withAlphaComponent(0.85).setFill()
        v.fill()
        let border = NSBezierPath(rect: v.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        border.stroke()
    }

    override func mouseDown(with ev: NSEvent) {
        guard let pv = pdfView, let p = pv.page(for: pv.convert(ev.locationInWindow, from: nil), nearest: true),
              editable?(p) ?? true else { return }
        dragPage = p
        dragStart = pagePoint(ev, p)
    }

    override func mouseDragged(with ev: NSEvent) {
        guard let p = dragPage, let a = dragStart, let b = pagePoint(ev, p) else { return }
        dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        needsDisplay = true
    }

    override func mouseUp(with ev: NSEvent) {
        let p = dragPage, r = dragRect
        dragStart = nil; dragRect = nil; dragPage = nil
        needsDisplay = true
        if let p, let r, r.width > 2, r.height > 2 { onDraw?(p, r) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        area(below: cover).contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
    override func resetCursorRects() { addCursorRect(area(below: cover), cursor: .crosshair) }
    // the wheel goes to the scroll view inside the page view (PDFView itself does not scroll on it)
    override func scrollWheel(with ev: NSEvent) {
        if let sv = pdfView?.documentView?.enclosingScrollView { sv.scrollWheel(with: ev) } else { pdfView?.scrollWheel(with: ev) }
    }
    override func magnify(with ev: NSEvent) { pdfView?.magnify(with: ev) }
}
