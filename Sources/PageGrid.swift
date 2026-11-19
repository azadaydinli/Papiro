import AppKit
import PDFKit

extension NSPasteboard.PasteboardType {
    static let pageIndex = NSPasteboard.PasteboardType("az.papiro.page-index")
}

/// Colours of the marked documents, repeated in turn.
let groupColors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemBrown, .systemIndigo]

/// One grid cell: a page, or (in split mode) a marked document drawn as a stack of sheets.
final class PageCell: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var pageSize = CGSize(width: 595, height: 842)
    var caption = "" { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var group: Int? { didSet { needsDisplay = true } }   // 0-based document number
    var stackCount = 0 { didSet { needsDisplay = true } } // > 0: a collapsed document of that many pages
    /// Choosing pages ("Apply"): nil = no checkbox; false = left out (the page is dimmed).
    var checked: Bool? { didSet { needsDisplay = true } }
    /// The page cannot be chosen (not a scan): dimmed, no checkbox.
    var disabled = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private let labelH: CGFloat = 26
    /// Where the front page is drawn (also the target of the collapse animation).
    var pageRect: CGRect {
        let area = bounds.insetBy(dx: 6, dy: 6)
        let spread: CGFloat = stackCount > 1 ? 12 : 0   // room for the sheets behind
        let imgArea = CGRect(x: area.minX, y: area.minY + spread, width: area.width - spread, height: area.height - labelH - spread)
        let s = image?.size ?? pageSize
        let scale = min(imgArea.width / max(s.width, 1), imgArea.height / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: imgArea.midX - w / 2, y: imgArea.maxY - h, width: w, height: h).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 6, dy: 6)
        let r = pageRect

        if let g = group {
            groupColors[g % groupColors.count].withAlphaComponent(stackCount > 1 ? 0.10 : 0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }

        // sheets behind the front page: offset up-right and slightly turned, so it reads as a bundle
        if stackCount > 1 {
            let layers = min(stackCount - 1, 3)
            for k in stride(from: layers, through: 1, by: -1) {
                let off = CGFloat(k) * 4
                let sheet = r.offsetBy(dx: off, dy: -off)
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: sheet.midX, yBy: sheet.midY)
                t.rotate(byDegrees: k % 2 == 0 ? -1.6 : 1.8)
                t.translateX(by: -sheet.midX, yBy: -sheet.midY)
                t.concat()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                NSColor(white: 1 - CGFloat(k) * 0.04, alpha: 1).setFill()
                sheet.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.withAlphaComponent(0.2).setStroke()
                NSBezierPath(rect: sheet.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }

        NSGraphicsContext.saveGraphicsState()
        if stackCount > 1 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 4
            shadow.set()
        }
        NSColor.white.setFill(); r.fill()
        NSGraphicsContext.restoreGraphicsState()
        image?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.25).setStroke()
        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if disabled || checked == false {
            NSColor.underPageBackgroundColor.withAlphaComponent(0.65).setFill()   // left out: faded
            r.fill()
        }
        if let on = checked, !disabled { checkbox(on, at: CGPoint(x: r.midX, y: r.maxY - 18)) }

        if selected {
            NSColor.controlAccentColor.setStroke()
            let pad: CGFloat = stackCount > 1 ? 8 : 4
            let p = NSBezierPath(roundedRect: CGRect(x: r.minX - 4, y: r.minY - pad - 4, width: r.width + pad + 8, height: r.height + pad + 8),
                                 xRadius: 5, yRadius: 5)
            p.lineWidth = 3; p.stroke()
        }

        if let g = group {
            let c = groupColors[g % groupColors.count]
            pill(L("Document %d", g + 1), at: CGPoint(x: r.minX + 6, y: r.minY + 6), fill: c, text: .white, left: true)
            if stackCount > 1 {
                let s = L("%d pages", stackCount)
                let w = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 12
                pill(s, at: CGPoint(x: r.maxX - w - 6, y: r.maxY - 24), fill: NSColor.black.withAlphaComponent(0.65), text: .white, left: true)
            }
        }

        let numY = area.maxY - labelH + 5
        if selected {
            pill(caption, at: CGPoint(x: area.midX, y: numY), fill: .controlAccentColor, text: .white, left: false)
        } else {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let str = NSAttributedString(string: caption, attributes: a)
            str.draw(at: CGPoint(x: area.midX - str.size().width / 2, y: numY + 1))
        }
    }

    /// A round checkbox centred at `c`: filled with a tick when on, an empty ring when off.
    private func checkbox(_ on: Bool, at c: CGPoint) {
        let d: CGFloat = 24
        let circle = NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.set()
        (on ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.9)).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        circle.lineWidth = 1.5
        (on ? NSColor.white : NSColor.secondaryLabelColor).setStroke()
        circle.stroke()
        if on {
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: c.x - 5.5, y: c.y + 0.5))
            tick.line(to: CGPoint(x: c.x - 1.5, y: c.y + 4.5))
            tick.line(to: CGPoint(x: c.x + 6, y: c.y - 4.5))
            tick.lineWidth = 2.2
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        }
    }

    private func pill(_ s: String, at p: CGPoint, fill: NSColor, text: NSColor, left: Bool) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: text]
        let str = NSAttributedString(string: s, attributes: a)
        let sz = str.size()
        let w = sz.width + 12, h = sz.height + 4
        let rect = CGRect(x: left ? p.x : p.x - w / 2, y: p.y, width: w, height: h)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
        str.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 2))
    }
}

final class PageItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PageItem")
    let cell = PageCell()
    override func loadView() { view = cell }
    override var isSelected: Bool { didSet { cell.selected = isSelected } }
}

/// The collection view: double-click opens a page (or opens / closes a document stack),
/// Delete deletes, Return marks a document, right-click acts on the item under the mouse.
final class GridCollectionView: NSCollectionView {
    weak var owner: DocWindowController?
    weak var grid: PageGrid?
    /// The item a Shift-click selects from: the last one clicked (or selected by the program).
    var anchor: Int?

    override func mouseDown(with event: NSEvent) {
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if grid?.choosing == true {
            if let ip { grid?.toggleChoice(ip.item) }
            return
        }
        // Shift-click: everything from the anchor to here (with ⌘ added to what is already selected)
        if event.modifierFlags.contains(.shift), let ip, let a = anchor, event.clickCount == 1 {
            let run = Set((min(a, ip.item)...max(a, ip.item)).map { IndexPath(item: $0, section: 0) })
            let all = event.modifierFlags.contains(.command) ? selectionIndexPaths.union(run) : run
            selectionIndexPaths = all
            delegate?.collectionView?(self, didSelectItemsAt: all)
            return
        }
        super.mouseDown(with: event)
        if let ip { anchor = ip.item }
        if event.clickCount == 2, let ip {
            grid?.activate(ip.item)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: owner?.escape()                         // esc
        case 51, 117: owner?.deletePages(nil)          // delete, forward delete
        case 36, 76: owner?.markDocument(nil)          // return, enter
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)), !selectionIndexPaths.contains(ip) {
            selectionIndexPaths = [ip]
            delegate?.collectionView?(self, didSelectItemsAt: [ip])
        }
        return super.menu(for: event)
    }
}

/// Grid of all pages. In split mode marked documents collapse into stacks.
final class PageGrid: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    /// A grid item: one page, or a collapsed document (its pages, in order).
    enum Entry { case page(Int), stack(group: Int, pages: [Int]) }

    let collection = GridCollectionView()
    let scroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    weak var owner: DocWindowController?
    var doc: PDFDoc? { owner?.pdfDoc }

    var splitMode = false
    /// Choosing pages to clean ("Apply" in "Clean Margins"): every page with a round checkbox.
    private(set) var choosing = false
    /// Chosen pages (0-based); pages `canChoose` refuses are never chosen.
    private(set) var chosen = Set<Int>()
    var canChoose: (Int) -> Bool = { _ in true }
    var choiceChanged: (() -> Void)?

    func startChoosing(_ pages: Set<Int>) {
        choosing = true
        collection.isSelectable = false
        setChosen(pages)
    }

    func stopChoosing() {
        choosing = false
        collection.isSelectable = true
        chosen = []
    }

    func setChosen(_ pages: Set<Int>) {
        chosen = pages.filter(canChoose)
        refreshChoices()
        choiceChanged?()
    }

    func toggleChoice(_ item: Int) {
        guard item < entries.count, case .page(let i) = entries[item], canChoose(i) else { return }
        if chosen.contains(i) { chosen.remove(i) } else { chosen.insert(i) }
        refreshChoices()
        choiceChanged?()
    }

    private func refreshChoices() {
        for item in collection.visibleItems() {
            guard let ip = collection.indexPath(for: item), ip.item < entries.count, let cell = (item as? PageItem)?.cell,
                  case .page(let i) = entries[ip.item] else { continue }
            cell.checked = choosing ? chosen.contains(i) : nil
            cell.disabled = choosing && !canChoose(i)
        }
    }
    var itemWidth: CGFloat = 170 { didSet { applySize() } }
    private(set) var entries: [Entry] = []
    private var expanded = Set<ObjectIdentifier>()   // documents opened by double-click (keyed by their first page)
    private var cache: [ObjectIdentifier: (rotation: Int, width: CGFloat, image: NSImage)] = [:]
    private var pending = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "papiro.thumbs", qos: .userInitiated)
    private var groupOf: [Int: Int] = [:]

    override init() {
        super.init()
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 16
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.grid = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [NSColor.underPageBackgroundColor]
        collection.register(PageItem.self, forItemWithIdentifier: PageItem.id)
        collection.registerForDraggedTypes([.pageIndex, .fileURL])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        applySize()
    }

    private func applySize() {
        layout.itemSize = NSSize(width: itemWidth, height: (itemWidth - 12) * 1.414 + 38)
        layout.invalidateLayout()
    }

    // MARK: entries

    private func buildEntries() {
        let n = doc?.pdf.pageCount ?? 0
        groupOf = splitMode ? (doc?.groupNumbers() ?? [:]) : [:]
        guard splitMode, let doc else { entries = (0..<n).map { .page($0) }; return }
        let groups = doc.orderedGroups()
        var startOf: [Int: Int] = [:]          // first page -> group
        var hidden = Set<Int>()
        for (g, pages) in groups.enumerated() {
            guard let first = doc.pdf.page(at: pages[0]), !expanded.contains(ObjectIdentifier(first)) else { continue }
            startOf[pages[0]] = g
            pages.dropFirst().forEach { hidden.insert($0) }
        }
        entries = (0..<n).compactMap { i in
            if let g = startOf[i] { return .stack(group: g, pages: groups[g]) }
            return hidden.contains(i) ? nil : .page(i)
        }
    }

    func pages(of e: Entry) -> [Int] {
        switch e { case .page(let i): return [i]; case .stack(_, let p): return p }
    }

    func entryIndex(ofPage p: Int) -> Int? { entries.firstIndex { pages(of: $0).contains(p) } }

    /// Pages of the selected items, in page order.
    var selected: [Int] {
        collection.selectionIndexPaths.flatMap { $0.item < entries.count ? pages(of: entries[$0.item]) : [] }.sorted()
    }

    func reload(select: [Int]? = nil) {
        let keep = select ?? selected
        buildEntries()
        collection.reloadData()
        collection.selectionIndexPaths = Set(Set(keep.compactMap(entryIndex)).map { IndexPath(item: $0, section: 0) })
    }

    func select(_ pageIdx: [Int], scrollTo: Int? = nil) {
        let items = Set(pageIdx.compactMap(entryIndex))
        collection.selectionIndexPaths = Set(items.map { IndexPath(item: $0, section: 0) })
        collection.anchor = items.min()
        if let s = scrollTo.flatMap(entryIndex) ?? items.min() {
            collection.scrollToItems(at: [IndexPath(item: s, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
        owner?.selectionChanged()
    }

    /// Double-click: a stack opens to show its pages (or closes again); a page opens in page view.
    func activate(_ item: Int) {
        guard item < entries.count, let doc else { return }
        switch entries[item] {
        case .stack(_, let p):
            if let first = doc.pdf.page(at: p[0]) { expanded.insert(ObjectIdentifier(first)) }
            reload(select: p)
        case .page(let i):
            if splitMode, let g = groupOf[i], let first = doc.orderedGroups()[g].first.flatMap({ doc.pdf.page(at: $0) }),
               expanded.contains(ObjectIdentifier(first)) {
                expanded.remove(ObjectIdentifier(first))
                collapse(doc.orderedGroups()[g])
            } else {
                owner?.openPage(i)
            }
        }
        owner?.selectionChanged()
    }

    // MARK: collapse animation

    /// Rebuild the grid so `pages` show as one stack; the page images fly together into it.
    func collapse(_ pages: [Int], thenSelect next: [Int] = []) {
        let pageSet = Set(pages)
        // where the pages are now
        var flying: [(CGRect, NSImage?)] = []
        for item in collection.visibleItems() {
            guard let ip = collection.indexPath(for: item), ip.item < entries.count,
                  !pageSet.isDisjoint(with: self.pages(of: entries[ip.item])), let cell = (item as? PageItem)?.cell else { continue }
            flying.append((cell.convert(cell.pageRect, to: collection), cell.image))
        }
        if let first = pages.first, let p = doc?.pdf.page(at: first) { expanded.remove(ObjectIdentifier(p)) }
        reload(select: next)
        collection.layoutSubtreeIfNeeded()
        guard let first = pages.first, let target = entryIndex(ofPage: first),
              let item = collection.item(at: IndexPath(item: target, section: 0)) as? PageItem, flying.count > 1 else { return }
        let cell = item.cell
        let dest = cell.convert(cell.pageRect, to: collection)
        cell.alphaValue = 0

        let views: [NSImageView] = flying.reversed().map { frame, img in
            let v = NSImageView(frame: frame)
            v.image = img
            v.imageScaling = .scaleAxesIndependently
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.cgColor
            v.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            v.layer?.borderWidth = 1
            v.layer?.shadowOpacity = 0.35
            v.layer?.shadowRadius = 4
            collection.addSubview(v)
            return v
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (k, v) in views.enumerated() {
                let off = CGFloat(min(views.count - 1 - k, 3)) * 4
                v.animator().frame = dest.offsetBy(dx: off, dy: -off)
            }
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                cell.animator().alphaValue = 1
                views.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { views.forEach { $0.removeFromSuperview() } })
        })
    }

    // MARK: data source

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: PageItem.id, for: ip) as! PageItem
        let cell = item.cell
        cell.alphaValue = 1
        let e = entries[ip.item]
        let ps = pages(of: e)
        switch e {
        case .page(let i):
            cell.caption = "\(i + 1)"; cell.stackCount = 0; cell.group = groupOf[i]
        case .stack(let g, let p):
            cell.caption = p.count > 1 ? "\(p[0] + 1)–\(p[p.count - 1] + 1)" : "\(p[0] + 1)"
            cell.stackCount = p.count; cell.group = g
        }
        cell.selected = cv.selectionIndexPaths.contains(ip)
        cell.checked = choosing ? chosen.contains(ps[0]) : nil
        cell.disabled = choosing && !canChoose(ps[0])
        if let page = doc?.pdf.page(at: ps[0]) {
            var b = page.bounds(for: .cropBox).size
            if page.rotation % 180 != 0 { b = CGSize(width: b.height, height: b.width) }
            cell.pageSize = b
            cell.image = thumbnail(for: page)
        }
        return item
    }

    private func thumbnail(for page: PDFPage) -> NSImage? {
        let key = ObjectIdentifier(page)
        let scale = collection.window?.backingScaleFactor ?? 2
        let want = itemWidth * scale
        if let c = cache[key], c.rotation == page.rotation, c.width >= want * 0.9 { return c.image }
        if !pending.contains(key) {
            pending.insert(key)
            let rotation = page.rotation
            queue.async { [weak self] in
                let img = page.thumbnail(of: NSSize(width: want, height: want * 1.5), for: .cropBox)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(key)
                    self.cache[key] = (rotation, want, img)
                    guard let i = self.doc?.pdf.index(for: page), i != NSNotFound, let e = self.entryIndex(ofPage: i),
                          self.pages(of: self.entries[e]).first == i,
                          let item = self.collection.item(at: IndexPath(item: e, section: 0)) as? PageItem else { return }
                    item.cell.image = page.rotation == rotation ? img : self.thumbnail(for: page)
                }
            }
        }
        return cache[key]?.image   // an older size or rotation while the new one renders
    }

    /// Forget cached images of these pages (after their content changed).
    func invalidate(_ pages: [PDFPage]) { pages.forEach { cache.removeValue(forKey: ObjectIdentifier($0)) } }

    // MARK: selection

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { owner?.selectionChanged() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { owner?.selectionChanged() }

    // MARK: drag and drop (reorder; PDF files from Finder are inserted). Off in split mode.

    func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool { !splitMode }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        guard ip.item < entries.count, case .page(let i) = entries[ip.item] else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(i), forType: .pageIndex)
        return item
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if splitMode { return [] }
        if op.pointee == .on { op.pointee = .before }
        if (info.draggingSource as? NSCollectionView) === cv { return .move }
        return pdfURLs(info).isEmpty ? [] : .copy
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        guard let doc, !splitMode else { return false }
        if (info.draggingSource as? NSCollectionView) === cv {
            let idx = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .pageIndex).flatMap(Int.init) }
            guard !idx.isEmpty else { return false }
            reload(select: doc.move(idx, to: ip.item))
            return true
        }
        let pages = pdfURLs(info).flatMap { url -> [PDFPage] in
            guard let d = PDFDocument(url: url) else { return [] }
            return (0..<d.pageCount).compactMap { d.page(at: $0)?.copy() as? PDFPage }
        }
        guard !pages.isEmpty else { return false }
        reload(select: doc.insert(pages, at: ip.item))
        return true
    }

    private func pdfURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }
}
