import AppKit
import PDFKit

/// One page in the left panel: the page as it is now (turned, with its text and signatures, whitened), its number
/// under it. A selected page sits on the system's selection background, as in Preview: the accent colour while the
/// panel has the keyboard focus, the muted (unemphasized) one once the focus is elsewhere or the window is inactive.
final class SideCell: NSView {
    static let pad: CGFloat = 8          // between the selection's edge and the page
    static let labelH: CGFloat = 24

    private let face = SideFace()

    var image: NSImage? { get { face.image } set { face.image = newValue } }
    var pageSize: CGSize { get { face.pageSize } set { face.pageSize = newValue } }
    var number: String { get { face.number } set { face.number = newValue } }
    var selected = false { didSet { needsDisplay = true; face.selected = selected } }
    var emphasized = true { didSet { needsDisplay = true; face.emphasized = emphasized } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        addSubview(face)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Preview's muted selection: a light veil with a touch of the accent colour, so it stays blue-grey on any
    /// background (measured from Preview on macOS 26: #4F6083 over its sidebar's #2E3143).
    private static let veil = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        if emphasized {
            NSColor.controlAccentColor.setFill()
            shape.fill()
        } else {
            Self.veil.setFill()
            shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            shape.fill()
        }
    }
}

/// What a cell draws over its selection background: the page and its number.
final class SideFace: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var pageSize = CGSize(width: 595, height: 842) { didSet { needsDisplay = true } }
    var number = "" { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var emphasized = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// Where the page is drawn.
    var pageRect: CGRect {
        let area = CGRect(x: SideCell.pad, y: SideCell.pad, width: bounds.width - 2 * SideCell.pad,
                          height: bounds.height - 2 * SideCell.pad - SideCell.labelH)
        let s = pageSize
        let scale = min(area.width / max(s.width, 1), area.height / max(s.height, 1))
        let w = (s.width * scale).rounded(), h = (s.height * scale).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: area.minY + (area.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = pageRect
        let page = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        page.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        page.addClip()
        image?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        let color: NSColor = !selected ? .secondaryLabelColor : emphasized ? .white : .labelColor
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
            .foregroundColor: color,
        ]
        let s = NSAttributedString(string: number, attributes: a)
        let size = s.size()
        s.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                           y: bounds.maxY - SideCell.pad - SideCell.labelH + (SideCell.labelH - size.height) / 2))
    }
}

final class SideItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("SideItem")
    let cell = SideCell()
    override func loadView() { view = cell }
    override var isSelected: Bool { didSet { cell.selected = isSelected } }
}

/// The left panel's list: a click shows the page; ⌘ / ⇧-click select several pages (for Sil, İxrac et, Döndər);
/// Delete deletes them; right-click offers "Export" and "Delete"; pages are dragged to a new place.
final class SideCollectionView: NSCollectionView {
    weak var side: PageSidebar?
    var anchor: Int?

    /// The selection shows in the accent colour only while the list has the keyboard focus in the key window.
    var emphasized: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        side?.updateEmphasis()
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { self.side?.updateEmphasis() }
        return ok
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: n, object: nil)
        }
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: n, object: w)
        }
    }
    @objc private func keyChanged() { side?.updateEmphasis() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift), let ip, let a = anchor, event.clickCount == 1 {
            let run = Set((min(a, ip.item)...max(a, ip.item)).map { IndexPath(item: $0, section: 0) })
            selectionIndexPaths = event.modifierFlags.contains(.command) ? selectionIndexPaths.union(run) : run
            side?.picked(ip.item)
            return
        }
        super.mouseDown(with: event)
        if let ip { anchor = ip.item }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: side?.owner?.escape()
        case 51, 117: side?.owner?.deletePages(nil)
        default: super.keyDown(with: event)
        }
    }

    /// Right-click on a page that is not selected selects just that page first.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selectionIndexPaths.contains(ip) {
            selectionIndexPaths = [ip]
            anchor = ip.item
            side?.picked(ip.item)
        }
        return super.menu(for: event)
    }
}

/// The left panel in the page view. It draws the pages itself (PDFThumbnailView did not redraw a page after it was
/// turned or edited): every change of the document redraws the pages it touched.
final class PageSidebar: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let collection = SideCollectionView()
    let scroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    weak var owner: DocWindowController?
    private var pdf: PDFDocument? { owner?.pdfDoc?.pdf }
    /// Called when the user picks a page (click, arrow keys): the page view shows it.
    var show: ((Int) -> Void)?
    var selectionChanged: (() -> Void)?

    private static let inset: CGFloat = 12
    private var cache: [ObjectIdentifier: (rotation: Int, width: CGFloat, stale: Bool, image: NSImage)] = [:]
    private var pending = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "papiro.sidebar", qos: .userInitiated)

    override init() {
        super.init()
        layout.sectionInset = NSEdgeInsets(top: 8, left: Self.inset, bottom: 12, right: Self.inset)
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.side = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(SideItem.self, forItemWithIdentifier: SideItem.id)
        collection.registerForDraggedTypes([.pageIndex, .fileURL])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
    }

    /// Selected pages, in page order.
    var selected: [Int] { collection.selectionIndexPaths.map(\.item).sorted() }

    /// Select these pages (by the program: the page view is not moved).
    func select(_ pages: [Int], scrollTo: Int? = nil) {
        let n = shownCount
        collection.selectionIndexPaths = Set(pages.filter { $0 < n }.map { IndexPath(item: $0, section: 0) })
        collection.anchor = pages.first
        if let s = scrollTo ?? pages.first, s < n { reveal(s) }
    }

    /// The page view moved to another page: select it, unless it is one of the selected pages
    /// (a page picked among several keeps the others selected).
    func follow(_ page: Int) {
        guard page >= 0, page < shownCount else { return }
        if !collection.selectionIndexPaths.contains(IndexPath(item: page, section: 0)) { select([page]) }
        else { reveal(page) }
    }

    /// The number of pages the list holds now (the document may already have more or fewer, until `reload`).
    private var shownCount: Int { collection.numberOfSections > 0 ? collection.numberOfItems(inSection: 0) : 0 }

    private func reveal(_ page: Int) {
        guard page >= 0, page < shownCount else { return }
        let ip = IndexPath(item: page, section: 0)
        guard let frame = collection.layoutAttributesForItem(at: ip)?.frame else { return }
        let visible = collection.visibleRect
        if visible.contains(frame) { return }
        collection.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
    }

    /// Pages were added, removed, moved or turned: lay the list out again (pages keep their cached pictures).
    func reload(select pages: [Int]) {
        collection.reloadData()
        select(pages)
    }

    /// The content of these pages changed (text, signatures): draw them again.
    func redraw(_ pages: [PDFPage]) {
        guard let pdf else { return }
        var ips = Set<IndexPath>()
        for p in pages {
            let key = ObjectIdentifier(p)
            cache[key]?.stale = true
            let i = pdf.index(for: p)
            if i != NSNotFound { ips.insert(IndexPath(item: i, section: 0)) }
        }
        refresh(ips)
    }

    /// The list gained or lost the keyboard focus, or the window became or stopped being the key window.
    func updateEmphasis() {
        let on = collection.emphasized
        for item in collection.visibleItems() { (item as? SideItem)?.cell.emphasized = on }
    }

    /// The panel's width changed.
    func resized() { layout.invalidateLayout() }

    private func refresh(_ ips: Set<IndexPath>) {
        guard let pdf else { return }
        for ip in ips {
            guard let item = collection.item(at: ip) as? SideItem, let page = pdf.page(at: ip.item) else { continue }
            item.cell.pageSize = shownSize(page)
            item.cell.image = picture(for: page)
        }
    }

    /// The page's size as it shows (turned).
    private func shownSize(_ p: PDFPage) -> CGSize {
        let b = p.bounds(for: .cropBox).size
        return p.rotation % 180 != 0 ? CGSize(width: b.height, height: b.width) : b
    }

    private var cellWidth: CGFloat { max(collection.bounds.width - 2 * Self.inset, 40) }

    // MARK: pictures

    /// The picture of a page, drawn in the background; meanwhile its last picture (turned, if the page was turned
    /// since) stands in.
    private func picture(for page: PDFPage) -> NSImage? {
        let key = ObjectIdentifier(page)
        let scale = collection.window?.backingScaleFactor ?? 2
        let want = (cellWidth - 2 * SideCell.pad) * scale
        if let c = cache[key], !c.stale, c.rotation == page.rotation, c.width >= want * 0.9 { return c.image }
        if !pending.contains(key) {
            pending.insert(key)
            let rotation = page.rotation
            queue.async { [weak self] in
                let img = page.thumbnail(of: NSSize(width: want, height: want * 1.6), for: .cropBox)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(key)
                    let stale = page.rotation != rotation
                    self.cache[key] = (rotation, want, stale, img)
                    guard let i = self.pdf?.index(for: page), i != NSNotFound,
                          let item = self.collection.item(at: IndexPath(item: i, section: 0)) as? SideItem else { return }
                    item.cell.pageSize = self.shownSize(page)
                    item.cell.image = stale ? self.picture(for: page) : img
                }
            }
        }
        guard let c = cache[key] else { return nil }
        return Self.turned(c.image, by: page.rotation - c.rotation)
    }

    /// An old picture turned by the page's new rotation, to show until the new picture is drawn.
    private static func turned(_ img: NSImage, by deg: Int) -> NSImage {
        let d = ((deg % 360) + 360) % 360
        guard d != 0 else { return img }
        let s = img.size
        let out = d == 180 ? s : CGSize(width: s.height, height: s.width)
        return NSImage(size: out, flipped: false) { _ in
            let t = NSAffineTransform()
            t.translateX(by: out.width / 2, yBy: out.height / 2)
            t.rotate(byDegrees: CGFloat(-d))
            t.translateX(by: -s.width / 2, yBy: -s.height / 2)
            t.concat()
            img.draw(in: CGRect(origin: .zero, size: s))
            return true
        }
    }

    // MARK: data source and layout

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pdf?.pageCount ?? 0 }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: SideItem.id, for: ip) as! SideItem
        item.cell.number = "\(ip.item + 1)"
        item.cell.selected = cv.selectionIndexPaths.contains(ip)
        item.cell.emphasized = collection.emphasized
        if let page = pdf?.page(at: ip.item) {
            item.cell.pageSize = shownSize(page)
            item.cell.image = picture(for: page)
        }
        return item
    }

    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt ip: IndexPath) -> NSSize {
        let w = cellWidth
        let pageW = w - 2 * SideCell.pad
        var aspect: CGFloat = 1.414
        if let page = pdf?.page(at: ip.item) {
            let s = shownSize(page)
            aspect = min(max(s.height / max(s.width, 1), 0.3), 1.8)
        }
        return NSSize(width: w, height: (pageW * aspect).rounded() + 2 * SideCell.pad + SideCell.labelH)
    }

    // MARK: selection

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) {
        if let i = ips.map(\.item).min() { picked(i) } else { selectionChanged?() }
    }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { selectionChanged?() }

    /// The user picked this page (it may be one of several selected).
    func picked(_ i: Int) {
        show?(i)
        selectionChanged?()
    }

    // MARK: drag and drop (reorder; PDF files from Finder are inserted)

    func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(ip.item), forType: .pageIndex)
        return item
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if op.pointee == .on { op.pointee = .before }
        if (info.draggingSource as? NSCollectionView) === cv { return .move }
        return pdfURLs(info).isEmpty ? [] : .copy
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        guard let doc = owner?.pdfDoc else { return false }
        let moved: [Int]
        if (info.draggingSource as? NSCollectionView) === cv {
            let idx = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .pageIndex).flatMap(Int.init) }
            guard !idx.isEmpty else { return false }
            moved = doc.move(idx, to: ip.item)
        } else {
            let pages = pdfURLs(info).flatMap { url -> [PDFPage] in
                guard let d = PDFDocument(url: url) else { return [] }
                return (0..<d.pageCount).compactMap { d.page(at: $0)?.copy() as? PDFPage }
            }
            guard !pages.isEmpty else { return false }
            moved = doc.insert(pages, at: ip.item)
        }
        reload(select: moved)
        if let first = moved.first { show?(first) }
        selectionChanged?()
        return true
    }

    private func pdfURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }
}
