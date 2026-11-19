import AppKit
import PDFKit
import UniformTypeIdentifiers

// "Text" (text boxes typed on a page) and "Signature" (PNG signatures dragged onto a page). Both are PDF annotations:
// text is a FreeText annotation (its font is embedded when the file is saved), a signature a Stamp whose picture
// is drawn by `ImageAnnotation` and saved as its appearance. Every change is one undoable step.

extension Notification.Name {
    /// Posted by a PDFDoc after an annotation was added, removed or moved; `object` is the doc, userInfo["page"] the page.
    static let annotationsChanged = Notification.Name("Papiro.annotationsChanged")
}

extension NSPasteboard.PasteboardType {
    /// A signature dragged from the panel: the path of its PNG file.
    static let papiroSignature = NSPasteboard.PasteboardType("az.papiro.signature")
}

// MARK: - signature annotation

/// A picture on a page (a signature). PDFKit saves what `draw` draws as the annotation's appearance, so the picture
/// is in the saved file; a file opened later has an ordinary Stamp annotation with that appearance.
final class ImageAnnotation: PDFAnnotation {
    var image: CGImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    /// A real copy (a plain copy would lose the picture).
    override func copy(with zone: NSZone? = nil) -> Any {
        let c = ImageAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
        c.image = image
        c.stampName = stampName
        return c
    }

    static func make(_ image: CGImage, bounds: CGRect) -> ImageAnnotation {
        let a = ImageAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
        a.image = image
        a.stampName = "Imza"            // not "Draft": a viewer that ignores the picture shows no "DRAFT" stamp
        return a
    }
}

/// `c` is a copy of `p` for a new file ("Split into Documents", "Export"), already inside its new PDFDocument (changing
/// a copy before that would reach the original document's views). Signatures placed since the file was opened are
/// drawn by code, which `PDFPage.copy()` does not carry over: they are put back as real copies. Pages without such
/// signatures are not touched.
func restoreSignatures(of p: PDFPage, in c: PDFPage) {
    for a in p.annotations where a is ImageAnnotation {
        let same = c.annotations.filter { $0.type == a.type && $0.bounds == a.bounds }
        if same.contains(where: { $0 is ImageAnnotation }) { continue }      // copied with its picture already
        same.forEach(c.removeAnnotation)                                      // copied without it: replace
        c.addAnnotation(a.copy() as! PDFAnnotation)
    }
}

// MARK: - undoable changes

extension PDFDoc {
    /// Put `new` on the page in place of `old` (either may be nil) as one undoable step.
    func swapAnnotation(_ old: PDFAnnotation?, _ new: PDFAnnotation?, on page: PDFPage, name: String) {
        if let old { page.removeAnnotation(old) }
        if let new { page.addAnnotation(new) }
        undoManager?.registerUndo(withTarget: self) { doc in doc.swapAnnotation(new, old, on: page, name: name) }
        undoManager?.setActionName(name)
        NotificationCenter.default.post(name: .annotationsChanged, object: self, userInfo: ["page": page])
    }

    /// The annotation was moved or resized from `from` to where it is now: make that one undoable step.
    func movedAnnotation(_ a: PDFAnnotation, from: CGRect, on page: PDFPage, name: String) {
        let to = a.bounds
        undoManager?.registerUndo(withTarget: self) { doc in
            a.bounds = from
            doc.movedAnnotation(a, from: to, on: page, name: name)
        }
        undoManager?.setActionName(name)
        NotificationCenter.default.post(name: .annotationsChanged, object: self, userInfo: ["page": page])
    }
}

// MARK: - text style

struct TextStyle: Equatable {
    var family = "Times New Roman"
    var size: CGFloat = 12
    var color = NSColor.black
    var bold = false
    var italic = false

    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]

    func font(size s: CGFloat? = nil) -> NSFont {
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let sz = s ?? size
        return fm.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: sz)
            ?? fm.font(withFamily: family, traits: [], weight: 5, size: sz)
            ?? .systemFont(ofSize: sz)
    }

    init() {}

    /// The style of an existing text box.
    init(of a: PDFAnnotation) {
        if let f = a.font {
            family = f.familyName ?? family
            size = f.pointSize
            let t = NSFontManager.shared.traits(of: f)
            bold = t.contains(.boldFontMask)
            italic = t.contains(.italicFontMask)
        }
        color = a.fontColor ?? .black
    }

    /// The last style used (kept for the next text box).
    static var saved: TextStyle {
        get {
            let d = UserDefaults.standard
            var s = TextStyle()
            if let f = d.string(forKey: "textFamily"), NSFontManager.shared.availableFontFamilies.contains(f) { s.family = f }
            let size = d.double(forKey: "textSize"); if size > 0 { s.size = size }
            if let rgba = d.array(forKey: "textColor") as? [Double], rgba.count == 4 {
                s.color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            }
            s.bold = d.bool(forKey: "textBold")
            s.italic = d.bool(forKey: "textItalic")
            return s
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.family, forKey: "textFamily")
            d.set(Double(newValue.size), forKey: "textSize")
            if let c = newValue.color.usingColorSpace(.sRGB) {
                d.set([c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init), forKey: "textColor")
            }
            d.set(newValue.bold, forKey: "textBold")
            d.set(newValue.italic, forKey: "textItalic")
        }
    }
}

// MARK: - text tool

/// Drawn over the page view while "Text" is on: drag (or click) on a page to make a text box and type into it;
/// click a text box to edit it, drag it to move it. A box left empty is removed.
final class TextOverlay: NSView, NSTextViewDelegate {
    weak var pdfView: PDFView?
    weak var cover: NSView?
    var style = TextStyle.saved
    /// Put an annotation in place of another (either nil) as one undoable step.
    var swap: ((PDFAnnotation?, PDFAnnotation?, PDFPage, String) -> Void)?
    /// An annotation was dragged from the given bounds.
    var moved: ((PDFAnnotation, CGRect, PDFPage) -> Void)?
    /// Editing an existing box: the tool bar shows its style.
    var showStyle: ((TextStyle) -> Void)?
    var onEscape: (() -> Void)?

    private var editor: NSTextView?
    /// The box being edited: page, frame in page space (its width and top stay; it grows downwards), the old box.
    private var editing: (page: PDFPage, rect: CGRect, old: PDFAnnotation?)?
    private var rubber: (page: PDFPage, start: CGPoint, end: CGPoint)?    // page space
    private var pressed: (a: PDFAnnotation, page: PDFPage, start: CGPoint, from: CGRect, moved: Bool)?

    override var acceptsFirstResponder: Bool { true }
    var isEditing: Bool { editing != nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        area(below: cover).contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
    override func resetCursorRects() { addCursorRect(area(below: cover), cursor: .iBeam) }
    override func scrollWheel(with ev: NSEvent) {
        if let sv = pdfView?.documentView?.enclosingScrollView { sv.scrollWheel(with: ev) } else { pdfView?.scrollWheel(with: ev) }
    }
    override func magnify(with ev: NSEvent) { pdfView?.magnify(with: ev) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    private func viewRect(_ r: CGRect, on page: PDFPage) -> CGRect? {
        guard let pv = pdfView else { return nil }
        return convert(pv.convert(r, from: page), from: pv)
    }
    private func pagePoint(_ ev: NSEvent, _ page: PDFPage) -> CGPoint? {
        guard let pv = pdfView else { return nil }
        return pv.convert(pv.convert(ev.locationInWindow, from: nil), to: page)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: area(below: cover)).addClip()
        if let r = rubber, let v = viewRect(CGRect(x: min(r.start.x, r.end.x), y: min(r.start.y, r.end.y),
                                                    width: abs(r.start.x - r.end.x), height: abs(r.start.y - r.end.y)), on: r.page) {
            dashed(v)
        }
        if let e = editor { dashed(e.frame.insetBy(dx: -3, dy: -3)) }
    }

    private func dashed(_ r: CGRect) {
        let p = NSBezierPath(rect: r)
        p.lineWidth = 1.5
        p.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        p.stroke()
    }

    // MARK: mouse

    override func mouseDown(with ev: NSEvent) {
        if editing != nil { finishEditing(); return }      // a click outside the box ends typing
        guard let pv = pdfView, let page = pv.page(for: pv.convert(ev.locationInWindow, from: nil), nearest: false),
              let pt = pagePoint(ev, page) else { return }
        if let a = page.annotation(at: pt), a.type == "FreeText" {
            pressed = (a, page, pt, a.bounds, false)
            return
        }
        rubber = (page, pt, pt)
    }

    override func mouseDragged(with ev: NSEvent) {
        if var p = pressed, let pt = pagePoint(ev, p.page) {
            let dx = pt.x - p.start.x, dy = pt.y - p.start.y
            if p.moved || hypot(dx, dy) > 3 {
                p.moved = true
                p.a.bounds = p.from.offsetBy(dx: dx, dy: dy)
                pressed = p
                pdfView?.annotationsChanged(on: p.page)
            }
            return
        }
        if var r = rubber, let pt = pagePoint(ev, r.page) {
            let b = r.page.bounds(for: .cropBox)
            r.end = CGPoint(x: min(max(pt.x, b.minX), b.maxX), y: min(max(pt.y, b.minY), b.maxY))
            rubber = r
            needsDisplay = true
        }
    }

    override func mouseUp(with ev: NSEvent) {
        if let p = pressed {
            pressed = nil
            if p.moved { moved?(p.a, p.from, p.page) } else { beginEditing(p.page, rect: p.a.bounds, old: p.a) }
            return
        }
        guard let r = rubber else { return }
        rubber = nil
        needsDisplay = true
        var rect = CGRect(x: min(r.start.x, r.end.x), y: min(r.start.y, r.end.y),
                          width: abs(r.start.x - r.end.x), height: abs(r.start.y - r.end.y))
        if rect.width < 20 {          // a click (or a thin drag): a box of usual width starting at the click
            let b = r.page.bounds(for: .cropBox)
            let w = min(260, b.maxX - r.start.x - 4)
            rect = CGRect(x: r.start.x, y: r.start.y - style.size * 1.4, width: max(w, 40), height: style.size * 1.4)
        }
        rect.size.height = max(rect.height, style.size * 1.4)
        beginEditing(r.page, rect: rect, old: nil)
    }

    // MARK: editing

    private func beginEditing(_ page: PDFPage, rect: CGRect, old: PDFAnnotation?) {
        if let old {
            style = TextStyle(of: old)
            showStyle?(style)
            old.shouldDisplay = false
            pdfView?.annotationsChanged(on: page)
        }
        let tv = NSTextView()
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        tv.allowsUndo = true
        tv.isVerticallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 2
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        tv.string = old?.contents ?? ""
        addSubview(tv)
        editor = tv
        editing = (page, rect, old)
        layoutEditor()
        window?.makeFirstResponder(tv)
    }

    /// Place the editor over its box at the current zoom, tall enough for its text.
    func layoutEditor() {
        guard let tv = editor, let e = editing, let pv = pdfView, var v = viewRect(e.rect, on: e.page) else { return }
        let scale = pv.scaleFactor
        tv.font = style.font(size: style.size * scale)
        tv.textColor = style.color
        tv.insertionPointColor = style.color
        let need = textHeight(tv.string, font: style.font(size: style.size * scale), width: v.width) + 4
        if need > v.height { v.origin.y -= need - v.height; v.size.height = need }   // grows downwards
        tv.frame = v
        needsDisplay = true
    }

    private func textHeight(_ s: String, font: NSFont, width: CGFloat) -> CGFloat {
        let text = s.isEmpty || s.hasSuffix("\n") ? s + "X" : s
        let r = (text as NSString).boundingRect(with: NSSize(width: max(width - 4, 1), height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return ceil(r.height)
    }

    func textDidChange(_ notification: Notification) { layoutEditor() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { finishEditing(); return true }   // Esc ends typing
        return false
    }

    /// The tool bar changed the style: the box being typed follows it.
    func styleChanged(_ s: TextStyle) {
        style = s
        layoutEditor()
    }

    /// Put the typed box on its page (one undoable step); an empty box is removed.
    func finishEditing() {
        guard let e = editing, let tv = editor else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : tv.string
        tv.removeFromSuperview()
        editor = nil
        editing = nil
        needsDisplay = true
        e.old?.shouldDisplay = true
        if text.isEmpty {
            if let old = e.old { swap?(old, nil, e.page, L("Delete Text")) }
            else { pdfView?.annotationsChanged(on: e.page) }
        } else {
            let h = max(e.rect.height, textHeight(text, font: style.font(), width: e.rect.width) + 4)
            let bounds = CGRect(x: e.rect.minX, y: e.rect.maxY - h, width: e.rect.width, height: h)
            if let old = e.old, old.contents == text, old.bounds == bounds, TextStyle(of: old) == style {
                pdfView?.annotationsChanged(on: e.page)       // nothing changed
            } else {
                let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                a.contents = text
                a.font = style.font()
                a.fontColor = style.color
                a.color = .clear
                a.alignment = .left
                let border = PDFBorder()
                border.lineWidth = 0
                a.border = border
                swap?(e.old, a, e.page, e.old == nil ? L("Text") : L("Edit Text"))
            }
        }
        window?.makeFirstResponder(self)
    }
}

// MARK: - signature selection

/// Draws the frame and corner handles of the selected signature; the page view does the dragging.
final class SelectionOverlay: NSView {
    weak var pdfView: PDFView?
    weak var cover: NSView?
    var selected: (a: PDFAnnotation, page: PDFPage)? { didSet { needsDisplay = true } }
    static let handle: CGFloat = 9

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func viewRect() -> CGRect? {
        guard let pv = pdfView, let s = selected else { return nil }
        return convert(pv.convert(s.a.bounds, from: s.page), from: pv)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = viewRect() else { return }
        NSBezierPath(rect: area(below: cover)).addClip()
        let p = NSBezierPath(rect: r)
        p.lineWidth = 1.5
        p.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        p.stroke()
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let h = NSBezierPath(ovalIn: CGRect(x: c.x - Self.handle / 2, y: c.y - Self.handle / 2, width: Self.handle, height: Self.handle))
            NSColor.white.setFill(); h.fill()
            NSColor.controlAccentColor.setStroke(); h.lineWidth = 1.5; h.stroke()
        }
    }
}

// MARK: - stored signatures

/// The signatures added to the panel: PNG copies in ~/Library/Application Support/Papiro/Signatures.
enum SignatureStore {
    static var folder: URL {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Papiro/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// Oldest first.
    static func all() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
    }

    /// Copy a PNG in; nil when it is not a readable picture.
    @discardableResult
    static func add(_ url: URL) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { return nil }
        let dest = folder.appendingPathComponent(UUID().uuidString + ".png")
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        return dest
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - signature panel

/// The panel on the right ("Signature"): the signatures one under another; "+" adds a PNG (a PNG dropped on the panel
/// too); drag one onto a page to sign; right-click → "Delete".
final class SignaturePanel: NSViewController {
    private let list = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: L("Add a signature as a PNG, then drag it onto a page."))

    override func loadView() {
        let v = SignatureDropView()
        v.panel = self
        view = v

        let title = NSTextField(labelWithString: L("Signatures"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("Add Signature"))!, target: self, action: #selector(addSignature(_:)))
        add.bezelStyle = .glass
        add.borderShape = .circle
        add.toolTip = L("Add PNG Signature")
        let header = NSStackView(views: [title, NSView(), add])
        header.spacing = 6

        list.orientation = .vertical
        list.alignment = .centerX
        list.spacing = 12
        let doc = FlippedView()
        doc.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        doc.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)

        for x in [header, scroll, empty] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 14),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -14),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -14),
            empty.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 30),
            empty.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
        ])
        reload()
    }

    func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = SignatureStore.all()
        for url in urls {
            let tile = SignatureTile(url: url)
            tile.panel = self
            list.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        empty.isHidden = !urls.isEmpty
    }

    @objc func addSignature(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png]
        p.allowsMultipleSelection = true
        p.message = L("Choose a signature picture (PNG, best with a transparent background)")
        p.prompt = L("Add")
        guard let w = view.window else { return }
        p.beginSheetModal(for: w) { r in
            guard r == .OK else { return }
            self.add(p.urls)
        }
    }

    func add(_ urls: [URL]) {
        let bad = urls.filter { SignatureStore.add($0) == nil }
        reload()
        if !bad.isEmpty, let w = view.window {
            let a = NSAlert()
            a.messageText = L("This file could not be added as a signature")
            a.informativeText = bad.map(\.lastPathComponent).joined(separator: "\n")
            a.beginSheetModal(for: w)
        }
    }

    func remove(_ url: URL) {
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = L("Remove this signature from the panel?")
        a.informativeText = L("Signatures already placed on pages are not changed.")
        a.addButton(withTitle: L("Delete")); a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            SignatureStore.remove(url)
            self.reload()
        }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The panel accepts PNG files dropped from Finder.
private final class SignatureDropView: NSView {
    weak var panel: SignaturePanel?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    private func pngs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "png" }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { pngs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = pngs(sender)
        guard !u.isEmpty else { return false }
        panel?.add(u)
        return true
    }
}

/// One signature in the panel: drag it onto a page.
private final class SignatureTile: NSView, NSDraggingSource {
    let url: URL
    weak var panel: SignaturePanel?
    private let image: NSImage?

    init(url: URL) {
        self.url = url
        image = NSImage(contentsOf: url)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.cgColor           // signatures are usually dark ink on transparency
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 92).isActive = true
        toolTip = L("Drag onto a page · right-click: Delete")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let area = bounds.insetBy(dx: 12, dy: 10)
        let s = min(area.width / image.size.width, area.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        image.draw(in: CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(url.path, forType: .papiroSignature)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: image ?? NSImage(size: bounds.size))
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let del = m.addItem(withTitle: L("Delete"), action: #selector(removeMe(_:)), keyEquivalent: "")
        del.target = self
        return m
    }

    @objc private func removeMe(_ sender: Any?) { panel?.remove(url) }
}
