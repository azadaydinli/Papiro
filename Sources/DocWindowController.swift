import AppKit
import PDFKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("sidebar"), mode = Self("mode"), zoom = Self("zoom"), split = Self("split"), search = Self("search")
    static let searchField = Self("searchField")
    static let undo = Self("undo"), redo = Self("redo")
}

/// Search in the toolbar. Closed it is an ordinary toolbar button (`.search`), so the system draws it as the same
/// glass circle as the other icon buttons; a click puts a search field item (`.searchField`) in its place, which
/// gives way to the button again when it is left empty, or with Esc. (A toolbar item that once had a view may not
/// lose it again — AppKit stops — so the two are separate items, swapped in the toolbar.)
private final class ToolbarSearch: NSObject, NSSearchFieldDelegate {
    let field = NSSearchField()
    weak var toolbar: NSToolbar?
    private(set) var expanded = false

    init(target: AnyObject, action: Selector) {
        super.init()
        field.placeholderString = "Mətndə axtar"
        field.sendsWholeSearchString = true
        field.target = target
        field.action = action
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }

    func buttonItem() -> NSToolbarItem {
        let i = NSToolbarItem(itemIdentifier: .search)
        i.label = "Axtar"
        i.toolTip = "Mətndə axtar (⌘F)"
        i.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Axtar")
        i.isBordered = true
        i.target = self
        i.action = #selector(open)
        return i
    }

    func fieldItem() -> NSToolbarItem {
        let i = NSToolbarItem(itemIdentifier: .searchField)
        i.label = "Axtar"
        i.view = field
        return i
    }

    /// Put `to` in the toolbar where `from` is.
    private func swapItem(_ from: NSToolbarItem.Identifier, _ to: NSToolbarItem.Identifier) {
        guard let tb = toolbar, let k = tb.items.firstIndex(where: { $0.itemIdentifier == from }) else { return }
        tb.removeItem(at: k)
        tb.insertItem(withItemIdentifier: to, at: k)
    }

    @objc func open() {
        if !expanded {
            expanded = true
            swapItem(.search, .searchField)
        }
        focusField(tries: 10)
    }

    /// The field is in the window only after the toolbar has laid out its new item: try again shortly until it is.
    private func focusField(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            if let w = self.field.window { w.makeFirstResponder(self.field) }
            else if tries > 1 { self.focusField(tries: tries - 1) }
        }
    }

    func close() {
        guard expanded else { return }
        expanded = false
        // after the key press or the end of editing has been handled: the field is still busy until then
        DispatchQueue.main.async { if !self.expanded { self.swapItem(.searchField, .search) } }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if field.stringValue.isEmpty { close() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = ""
            field.sendAction(field.action, to: field.target)   // clears the highlights
            field.window?.makeFirstResponder(nil)              // ends editing; the button comes back afterwards
            close()
            return true
        }
        return false
    }
}

/// The page view. Near the left panel's edge it leaves the mouse pointer to the split view (otherwise it would
/// turn the resize pointer back to an arrow at once); Esc leaves the tool that is open.
final class PageView: PDFView {
    weak var owner: DocWindowController? { didSet { registerForDraggedTypes([.papiroSignature]) } }

    // a signature dragged from the panel lands where it is dropped
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.papiroSignature]) != nil { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.papiroSignature]) != nil { return .copy }
        return super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let path = sender.draggingPasteboard.string(forType: .papiroSignature) {
            return owner?.placeSignature(URL(fileURLWithPath: path), at: sender.draggingLocation) ?? false
        }
        return super.performDragOperation(sender)
    }
    override func mouseDown(with event: NSEvent) {
        if owner?.signatureMouseDown(event) == true { return }
        super.mouseDown(with: event)
    }

    /// PDFKit draws annotations (text boxes, signatures) in layers of their own at 1 pixel per point, while the
    /// page itself is drawn at the zoom × Retina scale: zoomed in, the annotations look blurred. Give those layers
    /// the page's scale and let them redraw. (Only layers PDFKit names "…AnnotationEffect" are touched; if a later
    /// macOS draws differently, nothing happens.)
    func sharpenAnnotations() {
        guard let doc = documentView, let w = window else { return }
        let scale = min(max(scaleFactor * w.backingScaleFactor, 1), 8)
        func visit(_ l: CALayer) {
            if NSStringFromClass(type(of: l)).contains("AnnotationEffect") {
                if abs(l.contentsScale - scale) > 0.01 {
                    l.contentsScale = scale
                    l.setNeedsDisplay()
                }
                return
            }
            l.sublayers?.forEach(visit)
        }
        doc.layer.map(visit)
        doc.subviews.compactMap(\.layer).forEach(visit)
    }
    override func mouseMoved(with event: NSEvent) {
        if owner?.nearPanelEdge(event) == true { return }
        super.mouseMoved(with: event)
    }
    override func cursorUpdate(with event: NSEvent) {
        if owner?.nearPanelEdge(event) == true { return }
        super.cursorUpdate(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, owner?.escape() == true { return }
        if event.keyCode == 51 || event.keyCode == 117, owner?.deleteSelectedSignature() == true { return }
        super.keyDown(with: event)
    }
}

/// One document window (tab).
/// - page: one page at a time, thumbnails panel on the left;
/// - grid: all pages, for organising (rotate, delete, move, extract) — "Böl" is here;
/// - split: entered with "Böl" — pages are marked as documents, which collapse into stacks; then files are written;
/// - margins: "Kənarları təmizlə" — a frame decides what stays; everything outside is removed (scanned pages only);
/// - marginsApply: its "Tətbiq et" — all pages in the grid with checkboxes, to choose which pages to clean;
/// - whiteout: "Ağart" — rectangles drawn by hand are removed (scanned pages only);
/// - text: "Mətn" — text boxes typed on the pages.
/// The signature panel ("İmza") opens on the right in the page view; signatures are dragged onto pages.
final class DocWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                 NSToolbarItemValidation, NSSearchFieldDelegate {
    enum Mode { case page, grid, split, margins, marginsApply, whiteout, text }

    let pdfView = PageView()
    let thumbs = PDFThumbnailView()
    let grid = PageGrid()
    private let strip = NSView()
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var labels: [ObjectIdentifier: String] = [:]
    private let leftStack = NSStackView()
    private let centerStack = NSStackView()
    private let rightStack = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 170, minValue: 90, maxValue: 420, target: nil, action: nil)
    private lazy var sizeBox = makeSizeBox()
    private let sidebar = NSView()
    /// The left panel can be narrowed a little (from its original 176 px) and widened up to 400 px.
    private static let sidebarRange: ClosedRange<CGFloat> = 150...400
    private let content = NSView()
    private let pageButton = NSButton(title: "", target: nil, action: nil)
    /// The current scale ("112%"); a click opens the list of scales. A plain button, so the number is drawn bright.
    private let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    private var modeGroup: NSToolbarItemGroup?
    private lazy var searchBox = ToolbarSearch(target: self, action: #selector(searchAction(_:)))
    private(set) var mode: Mode = .page
    /// Whether the left panel should show with a single page. Follows the user: the panel button, or dragging
    /// the panel's edge until it closes (or out again).
    private var sidebarWanted = true
    /// The panel is opening or closing because of `applySidebar`: the sizes it passes through say nothing about
    /// what the user wants.
    private var sidebarAnimating = false
    /// Off until the window has shown the panel for its mode: the split view first restores its last saved
    /// state (folded, if the window was last closed in the grid), and that is not the user's choice either.
    private var sidebarReady = false
    private var found: [PDFSelection] = []
    private var foundAt = 0
    private var lastQuery = ""
    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    // text and signatures
    private let textOverlay = TextOverlay()
    private let selectionOverlay = SelectionOverlay()
    private let signaturePanel = SignaturePanel()
    private var inspectorItem: NSSplitViewItem!

    // margins mode
    private let overlay = MarginOverlay()
    private let whiteOverlay = WhiteoutOverlay()
    /// Each page's own frame (fractions of its crop box), found when the tool opens; edits change only that page.
    private var frames: [ObjectIdentifier: CGRect] = [:]
    private var detectRun = 0          // bumps to cancel a detection still running in the background
    private var detected = 0, detectTotal = 0
    private let detectQueue = DispatchQueue(label: "papiro.margins", qos: .userInitiated)

    var pdfDoc: PDFDoc? { document as? PDFDoc }

    /// Whether each page is a scan (pages are replaced by new ones when edited, so the cache follows them).
    private var scanned: [ObjectIdentifier: Bool] = [:]
    func isScan(_ p: PDFPage) -> Bool {
        if let s = scanned[ObjectIdentifier(p)] { return s }
        let s = Scan.isScanned(p)
        scanned[ObjectIdentifier(p)] = s
        return s
    }
    /// "Kənarları təmizlə" and "Ağart" need at least one scanned page.
    private var hasScans: Bool { pdfDoc?.pages.contains(where: isScan) ?? false }
    private var inGrid: Bool { mode == .grid || mode == .split || mode == .marginsApply }

    /// Within a few points of the left panel's edge (where the split view shows its resize pointer).
    func nearPanelEdge(_ event: NSEvent) -> Bool {
        guard !sidebarItem.isCollapsed, sidebar.window != nil else { return false }
        let edge = sidebar.convert(sidebar.bounds, to: nil).maxX
        return abs(event.locationInWindow.x - edge) < 8
    }

    /// Esc: leave the tool that is open. Returns false when there is nothing to leave.
    @discardableResult
    func escape() -> Bool {
        if selectionOverlay.selected != nil { selectionOverlay.selected = nil; return true }
        switch mode {
        case .margins: cancelMargins(nil)
        case .marginsApply: marginsBack(nil)
        case .whiteout, .text: setMode(.page)
        default: return false
        }
        return true
    }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "Papiro.document"
        w.minSize = NSSize(width: 900, height: 520)
        super.init(window: w)
        w.delegate = self
        shouldCascadeWindows = true
        build()
        w.setContentSize(NSSize(width: 1280, height: 860))
        w.center()
        w.setFrameAutosaveName("Papiro.window")
        if w.frame.height < 480 { w.setContentSize(NSSize(width: max(w.frame.width, 1280), height: 860)); w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet {
            guard let d = pdfDoc else { return }
            WelcomeController.hide()
            pdfView.document = d.pdf
            grid.reload()
            updatePageLabel()
            updateZoomTitle()
            updateStrip()
            // the split view restores its last state (possibly folded in the grid): show the panel as the mode wants
            DispatchQueue.main.async { self.sidebarReady = true; self.applySidebar(); self.sidebarResized(); self.fitPage(nil) }   // open showing the whole first page
            NotificationCenter.default.removeObserver(self, name: .pagesChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(docChanged), name: .pagesChanged, object: d)
            NotificationCenter.default.removeObserver(self, name: .annotationsChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(annotationsChanged(_:)), name: .annotationsChanged, object: d)
            NotificationCenter.default.removeObserver(self, name: .pagesWillChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(docWillChange), name: .pagesWillChange, object: d)
        }
    }

    // MARK: layout

    /// `safeTop`: start below the toolbar and the tool bar (the window's content runs under them).
    private func pin(_ v: NSView, in p: NSView, safeTop: Bool = false) {
        v.translatesAutoresizingMaskIntoConstraints = false
        p.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: safeTop ? p.safeAreaLayoutGuide.topAnchor : p.topAnchor), v.bottomAnchor.constraint(equalTo: p.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor), v.trailingAnchor.constraint(equalTo: p.trailingAnchor),
        ])
    }

    /// Native macOS 26 layout: a split view with a floating glass sidebar, the tool bar as the content's top
    /// accessory (it gets the system glass), the toolbar on top. Nothing here draws its own chrome.
    private func build() {
        guard let w = window else { return }
        buildStrip()

        let sideVC = NSViewController()
        sideVC.view = sidebar
        thumbs.pdfView = pdfView
        thumbs.backgroundColor = .clear
        thumbs.allowsMultipleSelection = true      // ⌘/⇧-click: pages for "Tətbiq et → Aşağıdakı səhifələrə"
        pin(thumbs, in: sidebar, safeTop: true)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sideVC)
        sidebarItem.minimumThickness = Self.sidebarRange.lowerBound
        sidebarItem.maximumThickness = Self.sidebarRange.upperBound
        sidebarItem.canCollapse = true

        let mainVC = NSViewController()
        mainVC.view = content
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        let mainItem = NSSplitViewItem(viewController: mainVC)
        let bar = NSSplitViewItemAccessoryViewController()
        bar.view = strip
        mainItem.addTopAlignedAccessoryViewController(bar)

        inspectorItem = NSSplitViewItem(inspectorWithViewController: signaturePanel)
        inspectorItem.minimumThickness = 200
        inspectorItem.maximumThickness = 320
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(mainItem)
        splitVC.addSplitViewItem(inspectorItem)
        splitVC.splitView.autosaveName = "Papiro.split"
        w.contentViewController = splitVC
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarResized), name: NSSplitView.didResizeSubviewsNotification,
                                               object: splitVC.splitView)
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Papiro.split") == nil {
            DispatchQueue.main.async { self.splitVC.splitView.setPosition(176, ofDividerAt: 0) }
        }

        pdfView.owner = self
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.backgroundColor = .underPageBackgroundColor
        grid.owner = self
        grid.collection.owner = self
        grid.canChoose = { [weak self] i in
            guard let self, let p = self.pdfDoc?.pdf.page(at: i) else { return false }
            return self.isScan(p)
        }
        grid.choiceChanged = { [weak self] in self?.updatePageLabel(); self?.updateStrip() }
        grid.collection.menu = gridMenu()
        pin(pdfView, in: content, safeTop: true)
        pin(grid.scroll, in: content, safeTop: true)
        grid.scroll.isHidden = true
        overlay.pdfView = pdfView
        overlay.cover = strip
        pin(overlay, in: content, safeTop: true)
        overlay.isHidden = true
        whiteOverlay.pdfView = pdfView
        whiteOverlay.cover = strip
        pin(whiteOverlay, in: content, safeTop: true)
        whiteOverlay.isHidden = true
        selectionOverlay.pdfView = pdfView
        selectionOverlay.cover = strip
        pin(selectionOverlay, in: content, safeTop: true)
        textOverlay.pdfView = pdfView
        textOverlay.cover = strip
        pin(textOverlay, in: content, safeTop: true)
        textOverlay.isHidden = true
        textOverlay.swap = { [weak self] old, new, page, name in self?.pdfDoc?.swapAnnotation(old, new, on: page, name: name) }
        textOverlay.moved = { [weak self] a, from, page in self?.pdfDoc?.movedAnnotation(a, from: from, on: page, name: "Mətni yerini dəyiş") }
        textOverlay.showStyle = { [weak self] s in self?.showTextStyle(s) }
        textOverlay.onEscape = { [weak self] in self?.setMode(.page) }

        // "3 / 250" in the bottom-right corner; click it to go to a page
        pageButton.bezelStyle = .glass
        pageButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageButton.target = self
        pageButton.action = #selector(goToPage(_:))
        pageButton.toolTip = "Səhifəyə keç (⌥⌘G)"
        pageButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pageButton)
        NSLayoutConstraint.activate([
            pageButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            pageButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            pageButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        DispatchQueue.main.async {
            if let clip = self.pdfView.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(self.viewScrolled),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)

        // its own identifier: toolbars sharing one keep the same items, so a search opened in one window
        // would open in every other window as well
        let tb = NSToolbar(identifier: "Papiro.toolbar.\(UUID().uuidString)")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        searchBox.toolbar = tb
        w.toolbarStyle = .unified
        updateStrip()
    }

    // MARK: tool strip

    private lazy var bRotL = tool("", "rotate.left", #selector(rotateLeft(_:)), tip: "Sola döndər (⌘L)")
    private lazy var bRotR = tool("", "rotate.right", #selector(rotateRight(_:)), tip: "Sağa döndər (⌘R)")
    private lazy var bExtract = tool("", "arrow.up.doc", #selector(extractPages(_:)), tip: "Çıxar: seçilmiş səhifələri ayrıca fayl kimi saxla (⌥⌘E)")
    private lazy var bAdd = tool("", "plus", #selector(showAddMenu(_:)), tip: "Əlavə et: başqa PDF-in səhifələri və ya boş səhifə")
    private lazy var bDelete = tool("", "trash", #selector(deletePages(_:)), tip: "Sil: seçilmiş səhifələri sil (⌘⌫)")
    private lazy var bMargins = tool("Kənarları təmizlə", "crop", #selector(beginMargins(_:)), tip: "Deşik izlərini və kənar ləkələri ağ et (⌘K)", toggle: true)
    private lazy var bText = tool("", "character.textbox", #selector(beginText(_:)), tip: "Mətn əlavə et: səhifədə qutu çəkib yazın", toggle: true)
    private lazy var bSign = tool("", "signature", #selector(toggleSignatures(_:)), tip: "İmza: sağda imzalar paneli, imzanı səhifəyə sürükləyin", toggle: true)
    private lazy var bBold = tool("", "bold", #selector(textStyleChanged(_:)), tip: "Qalın", toggle: true)
    private lazy var bItalic = tool("", "italic", #selector(textStyleChanged(_:)), tip: "Kursiv", toggle: true)
    private lazy var fontPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        p.target = self
        p.action = #selector(textStyleChanged(_:))
        p.toolTip = "Şrift"
        p.controlSize = .large
        p.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return p
    }()
    private lazy var sizePopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: TextStyle.sizes.map { "\(Int($0))" })
        p.target = self
        p.action = #selector(textStyleChanged(_:))
        p.toolTip = "Ölçü (pt)"
        p.controlSize = .large
        return p
    }()
    private lazy var colorWell: NSColorWell = {
        let w = NSColorWell(style: .minimal)
        w.target = self
        w.action = #selector(textStyleChanged(_:))
        w.toolTip = "Rəng"
        return w
    }()
    private lazy var bWhite = tool("", "eraser", #selector(beginWhiteout(_:)), tip: "Ağart: mətndə lazımsız hissələri əl ilə ağart (⌥⌘W)", toggle: true)
    private lazy var bSplit = tool("Sənədlərə parçala", "scissors", #selector(splitVolume(_:)), tip: "Cildi sənədlərə parçala (⌘B)")
    private lazy var bAuto = tool("", "wand.and.stars", #selector(marginsAuto(_:)), tip: "Avtomatik tap: ekrandakı səhifənin çərçivəsini yenidən tap")
    private lazy var bMark = tool("Sənəd et", "rectangle.stack.badge.plus", #selector(markDocument(_:)), tip: "Seçilmiş səhifələri bir sənəd kimi yığ (⏎)")
    private lazy var bUnmark = tool("Ayır", "rectangle.stack.badge.minus", #selector(unmarkPages(_:)), tip: "Seçilmiş sənədi yenidən ayrı səhifələrə aç")
    private lazy var bUnmarkAll = tool("Hamısını ayır", "square.grid.3x3", #selector(unmarkAll(_:)), tip: "Bütün sənəd işarələrini sil")
    private lazy var bFinish = tool("İmtina et", "xmark", #selector(finishSplit(_:)), tip: "Parçalama ekranından çıx, əvvəlki görünüşə qayıt (işarələr yadda qalır)")
    private lazy var bWrite = tool("Faylları yaz…", "square.and.arrow.down.on.square", #selector(writeFiles(_:)),
                                          tip: "Hər sənədi ayrıca PDF kimi qovluğa yaz (⌘B)", prominent: true)
    private lazy var bPrev = tool("", "chevron.left", #selector(previousPage(_:)), tip: "Əvvəlki səhifə")
    private lazy var bNext = tool("", "chevron.right", #selector(nextPage(_:)), tip: "Növbəti səhifə")
    private lazy var bFull = tool("", "rectangle.dashed", #selector(marginsFull(_:)), tip: "Bu səhifəyə toxunma: çərçivəni bütün səhifəyə aç")
    private lazy var bCancel = tool("İmtina et", "xmark", #selector(cancelMargins(_:)), tip: "Heç nəyi dəyişmədən çıx (Esc)")
    private lazy var bApplyOne = tool("Bu səhifəyə", "doc", #selector(marginsApplyOne(_:)), tip: "Yalnız bu səhifənin kənarlarını təmizlə")
    private lazy var bApply = tool("Tətbiq et", "doc.on.doc", #selector(marginsApply(_:)),
                                   tip: "Səhifələri seç və çərçivələri onlara tətbiq et", prominent: true)
    private lazy var bBack = tool("Geri", "chevron.left", #selector(marginsBack(_:)), tip: "Çərçivələrə qayıt (Esc)")
    /// "Tətbiq et": the first and last page to clean (1-based).
    private lazy var firstField = pageField("İlk səhifə")
    private lazy var lastField = pageField("Son səhifə")
    private lazy var rangeBox: NSView = {
        let label = NSTextField(labelWithString: "Səhifələr:")
        label.textColor = .secondaryLabelColor
        let dash = NSTextField(labelWithString: "–")
        let box = NSStackView(views: [label, firstField, dash, lastField])
        box.spacing = 6
        return box
    }()

    private func pageField(_ tip: String) -> NSTextField {
        let f = NSTextField(string: "")
        f.alignment = .center
        f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        f.bezelStyle = .roundedBezel
        f.controlSize = .large
        f.placeholderString = tip
        f.toolTip = tip
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return f
    }

    /// A native glass button. `prominent` = the tinted main action; `toggle` = shows the system "on" state.
    private func tool(_ title: String, _ symbol: String, _ action: Selector, tip: String,
                      prominent: Bool = false, toggle: Bool = false) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? tip : title)!
        let b = NSButton(title: title, image: img, target: self, action: action)
        b.bezelStyle = .glass
        b.controlSize = .extraLarge
        b.font = .systemFont(ofSize: 13, weight: .medium)
        b.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        // icon buttons are full circles; buttons with a label are capsules of the same height
        b.borderShape = title.isEmpty ? .circle : .capsule
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
        let square = b.widthAnchor.constraint(equalToConstant: Self.buttonSize)
        square.isActive = title.isEmpty
        squares[ObjectIdentifier(b)] = square
        b.toolTip = tip
        if prominent { b.tintProminence = .primary }
        if toggle { b.setButtonType(.pushOnPushOff) }
        labels[ObjectIdentifier(b)] = title
        return b
    }

    /// Icon only (a circle, to make room) or icon + label (a capsule).
    private func setCompact(_ b: NSButton, _ on: Bool) {
        b.title = on ? "" : (labels[ObjectIdentifier(b)] ?? "")
        let iconOnly = b.title.isEmpty
        b.imagePosition = iconOnly ? .imageOnly : .imageLeading
        b.borderShape = iconOnly ? .circle : .capsule
        squares[ObjectIdentifier(b)]?.isActive = iconOnly
    }

    private var squares: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var pageTools: [NSButton] { [bRotL, bRotR, bAdd, bExtract, bDelete, bWhite, bText, bSign] }

    /// "Kənarları təmizlə" and "Sənədlərə parçala" show their names; only a window too narrow for them makes
    /// them icons as well.
    private func fitStrip() {
        let named: [NSButton] = [bMargins, bSplit]
        named.forEach { setCompact($0, false) }
        let need = leftStack.fittingSize.width + centerStack.fittingSize.width + rightStack.fittingSize.width + 16 + 16 + 16
        named.forEach { setCompact($0, need > strip.bounds.width) }
    }

    private func setLabel(_ b: NSButton, _ t: String) {
        labels[ObjectIdentifier(b)] = t
        if b.imagePosition != .imageOnly { b.title = t }
    }

    private static let buttonSize: CGFloat = 38

    private func group(_ views: [NSView]) -> NSStackView {
        let g = NSStackView(views: views)
        g.spacing = 6
        return g
    }

    private func buildStrip() {
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.heightAnchor.constraint(equalToConstant: 56).isActive = true
        strip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stripResized), name: NSView.frameDidChangeNotification, object: strip)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.controlSize = .small
        sizeSlider.toolTip = "Səhifə şəkillərinin ölçüsü"

        for s in [leftStack, centerStack, rightStack] {
            s.spacing = 8                 // every button the same distance from the next
            s.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(s)
        }
        rightStack.spacing = 10
        NSLayoutConstraint.activate([
            // the page tools from the left edge, the named tools from the right edge (only split mode has a centre)
            leftStack.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 16),
            leftStack.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -16),
            rightStack.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            { let c = centerStack.centerXAnchor.constraint(equalTo: strip.centerXAnchor); c.priority = .defaultHigh; return c }(),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: strip.leadingAnchor, constant: 12),
            centerStack.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            // never required: a full bar must not push the window wider
            { let c = rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 16); c.priority = .defaultHigh; return c }(),
        ])
        for v in [leftStack, centerStack, rightStack] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.setHuggingPriority(.defaultLow, for: .horizontal)
            // a full bar may be cut, never hold the window wide: `fitStrip` makes room by dropping the names
            v.setClippingResistancePriority(.defaultLow, for: .horizontal)
        }
        strip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func stripResized() { fitStrip() }

    private func makeSizeBox() -> NSView {
        let small = NSImageView(image: NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: nil)!)
        let big = NSImageView(image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!)
        [small, big].forEach { $0.contentTintColor = .secondaryLabelColor; $0.symbolConfiguration = .init(pointSize: 11, weight: .regular) }
        sizeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let box = NSStackView(views: [small, sizeSlider, big])
        box.spacing = 6
        return box
    }

    private func sep() -> NSView {
        let b = NSView(); b.wantsLayer = true; b.layer?.backgroundColor = NSColor.separatorColor.cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }

    /// Strip arrangements. "Ağart" keeps the page arrangement: the bar does not move, only its button shows "on".
    private enum StripLayout { case page, margins, marginsApply, grid, split, text }
    private var stripLayout: StripLayout?
    /// The usual tools sit in the middle; with "Kənarları təmizlə" open they slide to the left and its buttons fade in
    /// on the right, next to the "Kənarları təmizlə" button, which always stays at the right end.
    /// Split mode has tools in the centre too: the side groups keep clear of them.
    private lazy var centerGaps: [NSLayoutConstraint] = [
        { let c = leftStack.trailingAnchor.constraint(lessThanOrEqualTo: centerStack.leadingAnchor, constant: -12); c.priority = .defaultLow; return c }(),
        { let c = rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: centerStack.trailingAnchor, constant: 12); c.priority = .defaultHigh; return c }(),
    ]

    /// Put the tools of the current mode into the strip and enable them for the selection.
    private func updateStrip() {
        let layout: StripLayout = mode == .margins ? .margins : mode == .marginsApply ? .marginsApply
            : mode == .grid ? .grid : mode == .split ? .split : mode == .text ? .text : .page
        if stripLayout != layout {
            let old = stripLayout
            stripLayout = layout
            var left: [NSView] = [], center: [NSView] = [], right: [NSView] = []
            switch layout {
            case .page, .grid:
                // the same bar in the page view and the grid; the grid adds its thumbnail size
                left = pageTools
                right = (layout == .grid ? [sizeBox] : []) + [bMargins, bSplit]
            case .margins:
                // "Kənarları təmizlə" makes way for its own tools; leaving is "İmtina" (Esc)
                left = pageTools
                right = [group([bPrev, bNext]), group([bAuto, bFull]), bCancel, bApplyOne, bApply]
            case .marginsApply:
                // the frame tools make way for the pages to clean: first – last, and the checkboxes in the grid
                left = [hint]
                right = [bBack, rangeBox, bApply]
            case .text:
                // "Mətn": the font, size, colour and bold / italic of the text boxes
                left = pageTools
                right = [fontPopup, sizePopup, colorWell, group([bBold, bItalic])]
            case .split:
                left = [hint]
                center = [bMark, bUnmark, bUnmarkAll]
                right = [group([bFinish]), bWrite]
            }
            leftStack.setViews(left, in: .leading)
            centerStack.setViews(center, in: .center)
            rightStack.setViews(right, in: .trailing)
            centerGaps.forEach { $0.isActive = layout == .split }
            fitStrip()
            // every button is laid out in its place at once (animating the layout would fly new buttons in from a
            // corner); the right group cross-fades when a tool opens or closes. Only the picture fades: the buttons
            // themselves are never made transparent, so they cannot be left invisible.
            strip.layoutSubtreeIfNeeded()
            let tool: Set<StripLayout> = [.margins, .marginsApply, .text]
            if strip.window != nil, let old, tool.contains(old) || tool.contains(layout) {
                rightStack.wantsLayer = true
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.25
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                rightStack.layer?.add(fade, forKey: "fade")
            }
        }
        bMargins.state = mode == .margins ? .on : .off
        bWhite.state = mode == .whiteout ? .on : .off
        bText.state = mode == .text ? .on : .off
        bSign.state = inspectorItem.isCollapsed ? .off : .on
        switch mode {
        case .split: hint.stringValue = "Başlanğıca klik → Shift ilə sona klik → ⏎ · İki klik: sənədi aç / yığ"
        case .margins:
            hint.stringValue = ""
        case .marginsApply: hint.stringValue = "İşarəsi götürülən səhifələrə toxunulmayacaq"
        default: hint.stringValue = ""
        }
        let scans = hasScans
        bMargins.toolTip = scans ? "Deşik izlərini və kənar ləkələri sil (⌘K)" : "Yalnız skan edilmiş səhifələrdə işləyir: bu sənəddə skan yoxdur"
        bWhite.toolTip = scans ? "Ağart: lazımsız hissələri əl ilə sil (⌥⌘W)" : "Ağart yalnız skan edilmiş səhifələrdə işləyir: bu sənəddə skan yoxdur"
        for b in [bRotL, bRotR, bAdd, bExtract, bDelete, bMargins, bWhite, bSplit, bMark, bUnmark, bUnmarkAll, bFinish, bWrite,
                  bPrev, bNext, bAuto, bFull, bCancel, bApplyOne, bApply, bBack, bText, bSign] {
            b.target = self
            b.isEnabled = can(b.action)
        }
    }

    /// "+": a small menu — pages of another PDF, or a blank page.
    @objc func showAddMenu(_ sender: NSButton) {
        let m = NSMenu()
        let file = m.addItem(withTitle: "Fayl əlavə et…", action: #selector(appendFile(_:)), keyEquivalent: "")
        file.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        let blank = m.addItem(withTitle: "Boş səhifə əlavə et", action: #selector(insertBlankPage(_:)), keyEquivalent: "")
        blank.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        m.items.forEach { $0.target = self }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func gridMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector) { m.addItem(withTitle: t, action: a, keyEquivalent: "") }
        add("Sənəd et", #selector(markDocument(_:)))
        add("Ayır", #selector(unmarkPages(_:)))
        m.addItem(.separator())
        add("Aç", #selector(openSelectedPage(_:)))
        add("Sola döndər", #selector(rotateLeft(_:)))
        add("Sağa döndər", #selector(rotateRight(_:)))
        add("Çıxar…", #selector(extractPages(_:)))
        add("Boş səhifə əlavə et", #selector(insertBlankPage(_:)))
        m.addItem(.separator())
        add("Sil", #selector(deletePages(_:)))
        m.autoenablesItems = true
        return m
    }

    // MARK: toolbar

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        // the flexible space before the panel button keeps it at the panel's right edge, following its width
        [.flexibleSpace, .sidebar, .sidebarTrackingSeparator, .undo, .redo, .flexibleSpace, .mode, .zoom, .space, .search]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .sidebar, .sidebarTrackingSeparator, .undo, .redo, .flexibleSpace, .mode, .zoom, .space, .search, .searchField]
    }

    private func updateToolbar() {
        modeGroup?.selectedIndex = inGrid ? 1 : 0
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar f: Bool) -> NSToolbarItem? {
        switch id {
        case .undo, .redo:
            // through the responder chain to the document's undo manager; AppKit enables them when there is something to undo
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = id == .undo ? "Geri" : "İrəli"
            i.toolTip = id == .undo ? "Son əməliyyatı geri qaytar (⌘Z)" : "Geri qaytarılanı təkrarla (⇧⌘Z)"
            i.image = NSImage(systemSymbolName: id == .undo ? "arrow.uturn.backward" : "arrow.uturn.forward", accessibilityDescription: i.label)
            i.action = id == .undo ? Selector(("undo:")) : Selector(("redo:"))
            i.isBordered = true
            return i
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitVC.splitView, dividerIndex: 0)
        case .sidebar:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Panel"
            i.toolTip = "Sol paneli göstər / gizlət (⌥⌘S)"
            i.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Panel")
            i.target = self
            i.action = #selector(toggleSidebarPanel(_:))
            i.isBordered = true
            return i
        case .mode:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Səhifə")!,
                                                NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Səhifələr")!],
                                       selectionMode: .selectOne, labels: ["Səhifə", "Səhifələr"],
                                       target: self, action: #selector(modeClicked(_:)))
            g.label = "Görünüş"
            g.toolTip = "Səhifə (⌘1) / Bütün səhifələr (⌘2)"
            g.controlRepresentation = .expanded
            g.selectedIndex = inGrid ? 1 : 0
            modeGroup = g
            return g
        case .zoom:
            let minus = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Kiçilt")!, target: self, action: #selector(zoomOutAction(_:)))
            let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Böyüt")!, target: self, action: #selector(zoomInAction(_:)))
            for b in [minus, plus] { b.bezelStyle = .texturedRounded; b.widthAnchor.constraint(equalToConstant: 30).isActive = true }
            minus.toolTip = "Kiçilt (⌘−)"; plus.toolTip = "Böyüt (⌘+)"
            zoomButton.bezelStyle = .texturedRounded
            zoomButton.target = self
            zoomButton.action = #selector(showZoomMenu(_:))
            zoomButton.toolTip = "Miqyas"
            zoomButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let box = NSStackView(views: [minus, zoomButton, plus])
            box.spacing = 4
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Miqyas"
            i.view = box
            return i
        case .split:
            let b = NSButton(title: "Böl", image: NSImage(systemSymbolName: "scissors", accessibilityDescription: "Böl")!,
                             target: self, action: #selector(splitVolume(_:)))
            b.imagePosition = .imageLeading
            b.bezelStyle = .texturedRounded
            b.toolTip = "Cildi sənədlərə böl (⌘B)"
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Böl"
            i.view = b
            return i
        case .search:
            return searchBox.buttonItem()
        case .searchField:
            return searchBox.fieldItem()
        default: return nil
        }
    }

    // MARK: modes

    @objc func modeClicked(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 1 { if !inGrid { setMode(.grid) } } else { setMode(.page) }
    }
    @objc func showPageMode(_ sender: Any?) { setMode(.page) }
    @objc func showGridMode(_ sender: Any?) { if !inGrid { setMode(.grid) } }

    func setMode(_ m: Mode) {
        guard m != mode else { updateToolbar(); return }
        let current = inGrid ? (grid.selected.first ?? 0) : currentPageIndex
        let old = mode
        let marginsTool: Set<Mode> = [.margins, .marginsApply]
        if marginsTool.contains(old) && !marginsTool.contains(m) { endMargins() }
        if old == .whiteout { endWhiteout() }
        if old == .marginsApply { grid.stopChoosing() }
        if old == .text { textOverlay.finishEditing(); textOverlay.isHidden = true }
        selectionOverlay.selected = nil
        if [.grid, .split, .marginsApply].contains(m), !inspectorItem.isCollapsed { inspectorItem.animator().isCollapsed = true }
        mode = m
        pdfView.isHidden = inGrid
        grid.scroll.isHidden = !inGrid
        applySidebar()
        if inGrid {
            let wasGrid = old == .grid || old == .split
            let keep = wasGrid ? grid.selected : [current]
            grid.splitMode = m == .split
            if m == .marginsApply {
                overlay.isHidden = true
                grid.reload(select: [])
                grid.startChoosing(Set(0..<(pdfDoc?.pdf.pageCount ?? 0)))
            } else {
                grid.reload(select: keep)
                grid.select(keep.isEmpty ? [current] : keep)
            }
            window?.makeFirstResponder(grid.collection)
        } else {
            let wasPageView = old == .page || old == .margins || old == .whiteout || old == .text
            if old == .marginsApply {
                if let p = pdfDoc?.pdf.page(at: applyReturnPage) { pdfView.go(to: p) }
            } else if !wasPageView, let p = pdfDoc?.pdf.page(at: current) { pdfView.go(to: p) }
            window?.makeFirstResponder(pdfView)
            if m == .margins { if old == .marginsApply { overlay.isHidden = false } else { startMargins() } }
            if m == .whiteout { startWhiteout() }
            if m == .text { startText() }
        }
        updateToolbar()
        updatePageLabel()
        updateZoomTitle()
        updateStrip()
    }

    func openPage(_ i: Int) {
        grid.select([i])
        setMode(.page)
    }

    @objc func openSelectedPage(_ sender: Any?) { if let i = grid.selected.first { openPage(i) } }

    /// Thumbnails follow the panel's width (the split view keeps it within 150–400 px and remembers it).
    /// A panel closed or opened by dragging its edge is remembered, so the panel button then works with one click.
    @objc private func sidebarResized() {
        if sidebarReady && !inGrid && !sidebarAnimating { sidebarWanted = !sidebarItem.isCollapsed }
        let w = sidebar.bounds.width
        guard w > 60 else { return }
        let tw = (w - 48).rounded()
        if thumbs.thumbnailSize.width != tw { thumbs.thumbnailSize = NSSize(width: tw, height: (tw * 1.33).rounded()) }
    }

    /// The panel shows with a single page (also while cleaning margins or whitening); it leaves no trace when hidden.
    private func applySidebar() {
        let show = !inGrid && sidebarWanted
        if sidebarItem.isCollapsed == show {
            sidebarAnimating = true
            NSAnimationContext.runAnimationGroup({ _ in self.sidebarItem.animator().isCollapsed = !show },
                                                 completionHandler: { [weak self] in self?.sidebarAnimating = false })
        }
        if show { DispatchQueue.main.async { self.sidebarResized() } }
        if !inGrid { pdfView.layoutDocumentView() }
    }

    @objc func toggleSidebarPanel(_ sender: Any?) {
        if inGrid { sidebarWanted = true; setMode(.page) } else { sidebarWanted.toggle(); applySidebar() }
    }

    private var currentPageIndex: Int {
        guard let d = pdfDoc?.pdf, let p = pdfView.currentPage else { return 0 }
        let i = d.index(for: p)
        return i == NSNotFound ? 0 : i
    }

    /// Pages an action works on: the selection in the grid, the current page otherwise.
    private var targetPages: [Int] {
        guard (pdfDoc?.pdf.pageCount ?? 0) > 0 else { return [] }
        return inGrid ? grid.selected : [currentPageIndex]
    }

    /// Where the page view was before the pages changed; put back afterwards (undo re-inserts every page,
    /// which would otherwise leave the view at the last page).
    private var spotBeforeChange: (Int, CGPoint, Int)?

    @objc func docWillChange() { if !inGrid && spotBeforeChange == nil { spotBeforeChange = viewSpot() } }

    @objc func docChanged() {
        if inGrid { grid.reload() }
        pdfView.layoutDocumentView()
        if !inGrid, let spot = spotBeforeChange { restore(spot) }
        spotBeforeChange = nil
        overlay.needsDisplay = true
        whiteOverlay.needsDisplay = true
        updatePageLabel()
        updateStrip()
    }

    func selectionChanged() { updatePageLabel(); updateStrip() }

    @objc func pageChanged() {
        pdfView.sharpenAnnotations()
        updatePageLabel()
        if !inGrid { updateStrip() }
        overlay.needsDisplay = true
        whiteOverlay.needsDisplay = true
    }

    @objc func viewScrolled() {
        pdfView.sharpenAnnotations()
        if mode == .margins { overlay.needsDisplay = true }
        if mode == .whiteout { whiteOverlay.needsDisplay = true }
        if mode == .text { textOverlay.layoutEditor() }
        selectionOverlay.needsDisplay = true
    }

    @objc func scaleChanged() {
        updateZoomTitle(); overlay.needsDisplay = true; whiteOverlay.needsDisplay = true
        DispatchQueue.main.async { self.pdfView.sharpenAnnotations() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.pdfView.sharpenAnnotations() }   // layers made late
        if mode == .text { textOverlay.layoutEditor() }
        selectionOverlay.needsDisplay = true
    }

    /// A text box or signature was added, removed or moved (also by undo): redraw it, forget a stale selection.
    @objc func annotationsChanged(_ n: Notification) {
        guard let page = n.userInfo?["page"] as? PDFPage else { return }
        pdfView.annotationsChanged(on: page)
        DispatchQueue.main.async { self.pdfView.sharpenAnnotations() }   // a new annotation gets a new layer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.pdfView.sharpenAnnotations() }
        grid.invalidate([page])
        if let s = selectionOverlay.selected, !s.page.annotations.contains(where: { $0 === s.a }) { selectionOverlay.selected = nil }
        selectionOverlay.needsDisplay = true
    }

    func updatePageLabel() {
        let n = pdfDoc?.pdf.pageCount ?? 0
        let g = pdfDoc?.orderedGroups().count ?? 0
        switch mode {
        case .grid:
            let s = grid.selected.count
            pageButton.title = "\(n) səhifə" + (s > 0 ? " · seçilib \(s)" : "")
        case .split:
            let loose = n - (pdfDoc?.orderedGroups().reduce(0) { $0 + $1.count } ?? 0)
            pageButton.title = "\(g) sənəd" + (loose > 0 ? " · işarəsiz \(loose) səhifə" : " · hamısı işarələnib")
        case .page, .margins, .whiteout, .text:
            pageButton.title = n > 0 ? "\(currentPageIndex + 1) / \(n)" : ""
        case .marginsApply:
            pageButton.title = "\(grid.chosen.count) / \(n) səhifə təmizlənəcək"
        }
    }

    // MARK: zoom & navigation

    func updateZoomTitle() {
        let t = inGrid ? "\(Int(grid.itemWidth))px" : "\(Int((pdfView.scaleFactor * 100).rounded()))%"
        zoomButton.isEnabled = !inGrid      // the page view, also while cleaning margins or whitening
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        zoomButton.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: zoomButton.isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            .paragraphStyle: centred])
    }

    @objc func showZoomMenu(_ sender: NSButton) {
        let m = NSMenu()
        for t in ["Səhifəni sığdır", "Eninə sığdır"] { m.addItem(withTitle: t, action: #selector(zoomPicked(_:)), keyEquivalent: "") }
        m.addItem(.separator())
        for s in Self.zoomSteps { m.addItem(withTitle: "\(Int(s * 100))%", action: #selector(zoomPicked(_:)), keyEquivalent: "") }
        m.items.forEach { $0.target = self }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func zoomPicked(_ sender: NSMenuItem) {
        let t = sender.title
        if t == "Səhifəni sığdır" { fitPage(nil) }
        else if t == "Eninə sığdır" { pdfView.autoScales = true }
        else if let v = Int(t.dropLast()) { pdfView.autoScales = false; pdfView.scaleFactor = CGFloat(v) / 100 }
        updateZoomTitle()
    }

    @objc func sizeChanged(_ sender: NSSlider) { grid.itemWidth = CGFloat(sender.doubleValue); updateZoomTitle() }

    @objc func zoomInAction(_ sender: Any?) {
        if inGrid { grid.itemWidth = min(grid.itemWidth + 40, 420); sizeSlider.doubleValue = Double(grid.itemWidth) }
        else { pdfView.zoomIn(sender) }
        updateZoomTitle()
    }
    @objc func zoomOutAction(_ sender: Any?) {
        if inGrid { grid.itemWidth = max(grid.itemWidth - 40, 90); sizeSlider.doubleValue = Double(grid.itemWidth) }
        else { pdfView.zoomOut(sender) }
        updateZoomTitle()
    }
    @objc func zoomToFit(_ sender: Any?) {
        if inGrid { grid.itemWidth = 170; sizeSlider.doubleValue = 170 } else { fitPage(nil) }
        updateZoomTitle()
    }

    /// Scale so the whole current page is visible.
    @objc func fitPage(_ sender: Any?) {
        guard let p = pdfView.currentPage ?? pdfDoc?.pdf.page(at: 0) else { return }
        var size = p.bounds(for: pdfView.displayBox).size
        if p.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let avail = pdfView.bounds.insetBy(dx: 30, dy: 30).size
        guard size.width > 0, size.height > 0, avail.width > 0, avail.height > 0 else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(avail.width / size.width, avail.height / size.height)
        pdfView.go(to: p)
        updateZoomTitle()
    }
    @objc func actualSize(_ sender: Any?) { setMode(.page); pdfView.autoScales = false; pdfView.scaleFactor = 1; updateZoomTitle() }
    @objc func singlePage(_ sender: Any?) { setMode(.page); pdfView.displayMode = .singlePageContinuous }
    @objc func twoPages(_ sender: Any?) { setMode(.page); pdfView.displayMode = .twoUpContinuous }

    @objc func nextPage(_ sender: Any?) { go(currentPageIndex + 1) }
    @objc func previousPage(_ sender: Any?) { go(currentPageIndex - 1) }
    @objc func firstPage(_ sender: Any?) { go(0) }
    @objc func lastPage(_ sender: Any?) { go((pdfDoc?.pdf.pageCount ?? 1) - 1) }

    private func go(_ i: Int) {
        guard let d = pdfDoc?.pdf, d.pageCount > 0 else { return }
        let k = max(0, min(i, d.pageCount - 1))
        if inGrid { grid.select([k]) } else if let p = d.page(at: k) { pdfView.go(to: p) }
    }

    @objc func goToPage(_ sender: Any?) {
        guard let w = window, let n = pdfDoc?.pdf.pageCount, n > 0 else { return }
        let a = NSAlert()
        a.messageText = "Səhifəyə keç"
        a.informativeText = "Səhifə nömrəsi (1–\(n)):"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Keç"); a.addButton(withTitle: "Ləğv et")
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn, let k = Int(f.stringValue.trimmingCharacters(in: .whitespaces)) { self.go(k - 1) }
        }
    }

    // MARK: search

    @objc func focusSearch(_ sender: Any?) {
        searchBox.open()
    }

    @objc func searchAction(_ sender: NSSearchField) {
        guard let d = pdfDoc?.pdf else { return }
        let q = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { found = []; lastQuery = ""; pdfView.highlightedSelections = nil; return }
        if q != lastQuery {
            found = d.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            found.forEach { $0.color = .systemYellow }
            foundAt = 0
            lastQuery = q
        } else if !found.isEmpty {
            foundAt = (foundAt + 1) % found.count
        }
        guard !found.isEmpty else { NSSound.beep(); return }
        setMode(.page)
        pdfView.highlightedSelections = found
        pdfView.setCurrentSelection(found[foundAt], animate: true)
        pdfView.go(to: found[foundAt])
    }

    // MARK: page actions

    @objc func rotateLeft(_ sender: Any?) { rotate(-90) }
    @objc func rotateRight(_ sender: Any?) { rotate(90) }
    private func rotate(_ deg: Int) {
        let idx = targetPages
        guard let d = pdfDoc, !idx.isEmpty, can(#selector(rotateLeft(_:))) else { return }
        d.rotate(idx, by: deg)
        if inGrid { grid.select(idx) }
    }

    @objc func deletePages(_ sender: Any?) {
        let idx = targetPages
        guard let d = pdfDoc, let w = window, !idx.isEmpty, can(#selector(deletePages(_:))) else { return }
        let a = NSAlert()
        a.messageText = idx.count == 1 ? "Səhifə \(idx[0] + 1) silinsin?" : "\(idx.count) səhifə silinsin?"
        a.informativeText = "Geri qaytarmaq üçün ⌘Z basın."
        a.addButton(withTitle: "Sil"); a.addButton(withTitle: "Ləğv et")
        a.buttons[0].hasDestructiveAction = true
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            d.delete(idx)
            if self.inGrid { self.grid.select([min(idx[0], d.pdf.pageCount - 1)]) }
        }
    }

    @objc func insertBlankPage(_ sender: Any?) {
        guard let d = pdfDoc, can(#selector(insertBlankPage(_:))) else { return }
        let at = (targetPages.last ?? -1) + 1
        d.insertBlank(at: at)
        if inGrid { grid.select([at]) } else if let p = d.pdf.page(at: at) { pdfView.go(to: p) }
    }

    @objc func appendFile(_ sender: Any?) {
        guard let w = window, let d = pdfDoc, can(#selector(appendFile(_:))) else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = true
        p.message = "Əlavə ediləcək PDF fayllarını seçin"
        p.prompt = "Əlavə et"
        p.beginSheetModal(for: w) { r in
            guard r == .OK else { return }
            let urls = p.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let pages = urls.flatMap { url -> [PDFPage] in
                guard let src = PDFDocument(url: url) else { return [] }
                return (0..<src.pageCount).compactMap { src.page(at: $0)?.copy() as? PDFPage }
            }
            guard !pages.isEmpty else { return }
            let at = self.inGrid ? (self.grid.selected.last.map { $0 + 1 } ?? d.pdf.pageCount) : d.pdf.pageCount
            let new = d.insert(pages, at: at)
            if self.inGrid { self.grid.select(new) } else if let pg = d.pdf.page(at: new[0]) { self.pdfView.go(to: pg) }
        }
    }

    @objc func extractPages(_ sender: Any?) {
        let idx = targetPages
        guard let w = window, let d = pdfDoc, !idx.isEmpty else { return }
        let base = d.displayName.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive, .anchored, .backwards])
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.canCreateDirectories = true
        p.nameFieldStringValue = "\(base) səhifə \(rangeText(idx)).pdf"
        if let dir = UserDefaults.standard.url(forKey: "extractFolder") { p.directoryURL = dir }

        let one = NSButton(radioButtonWithTitle: "Hamısı bir faylda", target: nil, action: nil)
        let each = NSButton(radioButtonWithTitle: "Hər səhifə ayrı faylda", target: nil, action: nil)
        one.state = .on
        let box = NSStackView(views: [one, each])
        box.orientation = .vertical; box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        p.accessoryView = box
        one.target = RadioGroup.shared; one.action = #selector(RadioGroup.pick(_:))
        each.target = RadioGroup.shared; each.action = #selector(RadioGroup.pick(_:))
        RadioGroup.shared.buttons = [one, each]

        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "extractFolder")
            let pages = idx.compactMap { d.pdf.page(at: $0) }
            var ok = true
            if each.state == .on {
                let dir = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
                for (k, pg) in pages.enumerated() {
                    ok = makePDF([pg]).write(to: dir.appendingPathComponent("\(stem) - \(idx[k] + 1).pdf")) && ok
                }
            } else {
                ok = makePDF(pages).write(to: url)
            }
            if !ok { self.alert("Fayl yazıla bilmədi.", "Qovluğa yazmaq icazəsini yoxlayın.") }
        }
    }

    private func rangeText(_ idx: [Int]) -> String {
        let s = idx.sorted()
        if s.count == 1 { return "\(s[0] + 1)" }
        let contiguous = s.last! - s.first! == s.count - 1
        return contiguous ? "\(s.first! + 1)–\(s.last! + 1)" : "\(s.first! + 1)–\(s.last! + 1) (\(s.count))"
    }

    // MARK: split (Böl)

    /// "Sənədlərə parçala" (page view or grid): enter split mode; in split mode ⌘B writes the files.
    @objc func splitVolume(_ sender: Any?) {
        switch mode {
        case .split: writeFiles(sender)
        default:
            splitReturn = (inGrid ? .grid : .page, inGrid ? nil : currentPageIndex)
            setMode(.split)
        }
    }

    /// The view "Sənədlərə parçala" was started from, and the page shown there.
    private var splitReturn: (mode: Mode, page: Int?) = (.grid, nil)

    /// "İmtina et": back to that view (the marks stay).
    @objc func finishSplit(_ sender: Any?) {
        let back = splitReturn
        setMode(back.mode)
        if let i = back.page, let p = pdfDoc?.pdf.page(at: i) { pdfView.go(to: p) }
    }

    @objc func markDocument(_ sender: Any?) {
        guard mode == .split, let d = pdfDoc else { return }
        let s = grid.selected
        guard let a = s.first, let b = s.last else { return }
        d.markGroup(a...b)
        // the next document usually starts right after this one: select it, so the next mark is one Shift-click
        let next = b + 1 < d.pdf.pageCount ? [b + 1] : []
        grid.collapse(Array(a...b), thenSelect: next)
        grid.select(next, scrollTo: next.first ?? b)
        updatePageLabel()
    }

    @objc func unmarkPages(_ sender: Any?) {
        guard mode == .split, let d = pdfDoc else { return }
        let s = grid.selected
        d.unmark(s)
        grid.reload(select: s)
        selectionChanged()
    }

    @objc func unmarkAll(_ sender: Any?) {
        guard let d = pdfDoc, let w = window, !d.orderedGroups().isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Bütün sənəd işarələri silinsin?"
        a.informativeText = "Səhifələrin özünə toxunulmur."
        a.addButton(withTitle: "Sil"); a.addButton(withTitle: "Ləğv et")
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            d.unmarkAll(); self.grid.reload(); self.selectionChanged()
        }
    }

    @objc func writeFiles(_ sender: Any?) {
        guard mode == .split, let w = window, let d = pdfDoc else { return }
        let groups = d.orderedGroups()
        if groups.isEmpty {
            alert("Hələ sənəd işarələnməyib.",
                  "Sənədin birinci səhifəsinə klik edin, Shift ilə sonuncu səhifəsinə klik edin və ⏎ (və ya “Sənəd et”) basın. Hər sənəd üçün təkrarlayın.")
            return
        }
        let inGroup = Set(groups.flatMap { $0 })
        let loose = (0..<d.pdf.pageCount).filter { !inGroup.contains($0) }
        SplitPanel(window: w, doc: d, groups: groups, loose: loose).run { written, dir, skipped in
            if skipped == 0 { d.forgetStoredMarks() }   // every document written: nothing left to recover
            let a = NSAlert()
            a.messageText = skipped > 0
                ? "\(written.count) fayl yaradıldı, \(skipped) fayl yazılmadı (dayandırıldı)"
                : "\(written.count) fayl yaradıldı"
            a.informativeText = written.isEmpty ? "" : written.count == 1 ? written[0] : "\(written.first!) … \(written.last!)"
            a.addButton(withTitle: "Finder-də göstər"); a.addButton(withTitle: "Bağla")
            a.beginSheetModal(for: w) { r in
                if r == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting(written.map { dir.appendingPathComponent($0) })
                }
            }
        }
    }

    // MARK: margins (Kənarları təmizlə)

    /// The button toggles: a second click closes the tool and leaves the page view as it was.
    @objc func beginMargins(_ sender: Any?) {
        guard (pdfDoc?.pdf.pageCount ?? 0) > 0 else { return }
        setMode(mode == .margins ? .page : .margins)
    }

    private func startMargins() {
        frames = [:]
        overlay.frameOf = { [weak self] p in self?.frame(of: p) ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
        overlay.setFrame = { [weak self] p, f in self?.frames[ObjectIdentifier(p)] = f }
        overlay.editable = { [weak self] p in self?.isScan(p) ?? false }
        overlay.isHidden = false
        window?.invalidateCursorRects(for: overlay)

        // every page gets its own frame, found in the background
        detectRun += 1
        let run = detectRun
        let pages = (pdfDoc?.pages ?? []).filter(isScan)      // other pages are left as they are
        detected = 0; detectTotal = pages.count
        detectQueue.async { [weak self] in
            for p in pages {
                let f = Margins.detect(p)
                DispatchQueue.main.async {
                    guard let self, self.detectRun == run else { return }
                    let key = ObjectIdentifier(p)
                    if self.frames[key] == nil {                        // never overwrite a frame the user moved
                        self.frames[key] = f
                        if self.pdfView.visiblePages.contains(p) { self.overlay.needsDisplay = true }
                    }
                    self.detected += 1
                }
            }
        }
    }

    /// A page's frame, found now if the background has not reached that page yet.
    private func frame(of p: PDFPage) -> CGRect {
        let key = ObjectIdentifier(p)
        if let f = frames[key] { return f }
        let f = isScan(p) ? Margins.detect(p) : CGRect(x: 0, y: 0, width: 1, height: 1)
        frames[key] = f
        return f
    }

    private func endMargins() {
        detectRun += 1
        frames = [:]
        overlay.frameOf = nil
        overlay.setFrame = nil
        overlay.isHidden = true
    }

    /// "Avtomatik tap": find the frame of the page on screen again (undoes hand edits of that page only).
    @objc func marginsAuto(_ sender: Any?) {
        guard let p = pdfView.currentPage else { return }
        frames[ObjectIdentifier(p)] = Margins.detect(p)
        overlay.needsDisplay = true
    }

    @objc func marginsFull(_ sender: Any?) {
        if let p = pdfView.currentPage { frames[ObjectIdentifier(p)] = CGRect(x: 0, y: 0, width: 1, height: 1) }
        overlay.needsDisplay = true
    }
    @objc func cancelMargins(_ sender: Any?) { setMode(.page) }

    @objc func marginsApplyOne(_ sender: Any?) {
        guard pdfView.currentPage != nil else { return }
        let i = currentPageIndex
        applyMargins(to: [i])
        if let p = pdfDoc?.pdf.page(at: i) { pdfView.go(to: p) }
    }

    /// Clean the given pages with their frames and stay in the tool (their frames now cover the whole page).
    private func applyMargins(to idx: [Int]) {
        guard let d = pdfDoc else { return }
        var frac: [Int: CGRect] = [:]
        for i in idx { if let p = d.pdf.page(at: i) { frac[i] = frame(of: p) } }
        d.clearMargins(idx) { frac[$0] ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
        for i in idx {
            if let p = d.pdf.page(at: i) { frames[ObjectIdentifier(p)] = CGRect(x: 0, y: 0, width: 1, height: 1) }   // already clean
        }
        overlay.needsDisplay = true
    }

    /// "Tətbiq et", first press: the frame tools give way to "first – last" (1 – N) and the grid shows every page
    /// with a checkbox, all ticked. Second press: the ticked pages are cleaned. Changing the numbers ticks just
    /// the pages in between; any page can still be ticked or unticked by hand. Pages that are not scans are faded.
    @objc func marginsApply(_ sender: Any?) {
        guard let d = pdfDoc else { return }
        if mode == .margins {
            applyReturnPage = currentPageIndex
            firstField.stringValue = "1"
            lastField.stringValue = "\(d.pdf.pageCount)"
            for field in [firstField, lastField] { field.textColor = .labelColor }
            setMode(.marginsApply)
            return
        }
        guard mode == .marginsApply else { return }
        let pages = grid.chosen.sorted()
        guard !pages.isEmpty else { return }
        applyMargins(to: pages)
        let at = applyReturnPage
        setMode(.page)
        if let p = d.pdf.page(at: at) { pdfView.go(to: p) }
    }

    /// "Geri" (or Esc) while choosing pages: back to the frames, nothing cleaned.
    @objc func marginsBack(_ sender: Any?) { if mode == .marginsApply { setMode(.margins) } }

    /// The page shown before "Tətbiq et", to come back to.
    private var applyReturnPage = 0

    /// A valid "first – last" ticks exactly the pages in between.
    func controlTextDidChange(_ obj: Notification) {
        guard mode == .marginsApply, let f = obj.object as? NSTextField, f === firstField || f === lastField,
              let n = pdfDoc?.pdf.pageCount else { return }
        let a = Int(firstField.stringValue.trimmingCharacters(in: .whitespaces))
        let b = Int(lastField.stringValue.trimmingCharacters(in: .whitespaces))
        let ok = a != nil && b != nil && a! >= 1 && b! <= n && a! <= b!
        for field in [firstField, lastField] { field.textColor = ok ? .labelColor : .systemRed }
        if ok, let a, let b { grid.setChosen(Set((a - 1)...(b - 1))) }
    }

    // MARK: text (Mətn)

    @objc func beginText(_ sender: Any?) {
        guard (pdfDoc?.pdf.pageCount ?? 0) > 0 else { return }
        setMode(mode == .text ? .page : .text)
    }

    private func startText() {
        showTextStyle(TextStyle.saved)
        textOverlay.style = TextStyle.saved
        textOverlay.isHidden = false
        window?.invalidateCursorRects(for: textOverlay)
        window?.makeFirstResponder(textOverlay)
    }

    /// The tool bar shows a style (the last one used, or that of the box being edited).
    private func showTextStyle(_ s: TextStyle) {
        if fontPopup.item(withTitle: s.family) == nil { fontPopup.addItem(withTitle: s.family) }
        fontPopup.selectItem(withTitle: s.family)
        let size = "\(Int(s.size.rounded()))"
        if sizePopup.item(withTitle: size) == nil { sizePopup.addItem(withTitle: size) }
        sizePopup.selectItem(withTitle: size)
        colorWell.color = s.color
        bBold.state = s.bold ? .on : .off
        bItalic.state = s.italic ? .on : .off
    }

    @objc func textStyleChanged(_ sender: Any?) {
        var s = TextStyle()
        s.family = fontPopup.titleOfSelectedItem ?? s.family
        s.size = CGFloat(Double(sizePopup.titleOfSelectedItem ?? "") ?? Double(s.size))
        s.color = colorWell.color
        s.bold = bBold.state == .on
        s.italic = bItalic.state == .on
        TextStyle.saved = s
        textOverlay.styleChanged(s)
    }

    // MARK: signatures (İmza)

    /// "İmza": the panel of signatures on the right (in the page view).
    @objc func toggleSignatures(_ sender: Any?) {
        let open = inspectorItem.isCollapsed
        if open && inGrid { setMode(.page) }
        inspectorItem.animator().isCollapsed = !open
        if open { signaturePanel.reload() }
        updateStrip()
    }

    /// A signature dropped on a page: 160 pt wide (or less if the picture is tall), centred where it was dropped.
    func placeSignature(_ url: URL, at windowPoint: NSPoint) -> Bool {
        guard let d = pdfDoc, let image = SignatureStore.image(url),
              let page = pdfView.page(for: pdfView.convert(windowPoint, from: nil), nearest: true) else { return false }
        if mode == .text { textOverlay.finishEditing() }
        let pt = pdfView.convert(pdfView.convert(windowPoint, from: nil), to: page)
        let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        var w: CGFloat = 160, h = w * aspect
        if h > 90 { h = 90; w = h / aspect }
        let box = page.bounds(for: .cropBox)
        var r = CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h)
        r.origin.x = min(max(r.minX, box.minX), box.maxX - w)
        r.origin.y = min(max(r.minY, box.minY), box.maxY - h)
        let a = ImageAnnotation.make(image, bounds: r)
        d.swapAnnotation(nil, a, on: page, name: "İmza")
        selectionOverlay.selected = (a, page)
        window?.makeFirstResponder(pdfView)
        return true
    }

    /// A click on a signature in the page view selects it; dragging moves it, dragging a corner resizes it
    /// (keeping its shape). Returns false when the click is not for a signature (the page view handles it).
    func signatureMouseDown(_ event: NSEvent) -> Bool {
        guard mode == .page, let d = pdfDoc, let w = window,
              let page = pdfView.page(for: pdfView.convert(event.locationInWindow, from: nil), nearest: false) else {
            selectionOverlay.selected = nil
            return false
        }
        let pt = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
        var corner: CGPoint?                      // the opposite corner stays put while resizing
        var target: PDFAnnotation?
        if let s = selectionOverlay.selected, s.page === page {
            let b = s.a.bounds
            let reach = SelectionOverlay.handle / max(pdfView.scaleFactor, 0.1)
            for (c, opposite) in [(CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)), (CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY)),
                                  (CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.minY)), (CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.minY))]
            where hypot(c.x - pt.x, c.y - pt.y) <= reach { corner = opposite; target = s.a; break }
        }
        if target == nil, let a = page.annotation(at: pt), a.type == "Stamp" { target = a }
        guard let a = target else { selectionOverlay.selected = nil; return false }
        selectionOverlay.selected = (a, page)
        w.makeFirstResponder(pdfView)

        let from = a.bounds
        let aspect = from.height / max(from.width, 1)
        var changed = false
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = pdfView.convert(pdfView.convert(e.locationInWindow, from: nil), to: page)
            if let fixed = corner {
                let width = max(abs(p.x - fixed.x), 24)
                let height = width * aspect
                let x = p.x < fixed.x ? fixed.x - width : fixed.x
                let y = p.y < fixed.y ? fixed.y - height : fixed.y
                a.bounds = CGRect(x: x, y: y, width: width, height: height)
            } else {
                a.bounds = from.offsetBy(dx: p.x - pt.x, dy: p.y - pt.y)
            }
            changed = changed || a.bounds != from
            pdfView.annotationsChanged(on: page)
            selectionOverlay.needsDisplay = true
            if e.type == .leftMouseUp { break }
        }
        if changed { d.movedAnnotation(a, from: from, on: page, name: corner == nil ? "İmzanın yerini dəyiş" : "İmzanın ölçüsünü dəyiş") }
        return true
    }

    /// Delete (⌫) with a signature selected removes it.
    func deleteSelectedSignature() -> Bool {
        guard let s = selectionOverlay.selected, let d = pdfDoc else { return false }
        selectionOverlay.selected = nil
        d.swapAnnotation(s.a, nil, on: s.page, name: "İmzanı sil")
        return true
    }

    // MARK: whiteout (Ağart)

    /// Where the view is (page index + point), so it can stay put while a page is swapped for an edited copy.
    private func viewSpot() -> (Int, CGPoint, Int)? {
        guard let dest = pdfView.currentDestination, let p = dest.page, let d = pdfDoc?.pdf else { return nil }
        let i = d.index(for: p)
        return i == NSNotFound ? nil : (i, dest.point, p.rotation)
    }

    /// Back to the same spot; if that page was turned meanwhile, to the top of it (the old point no longer fits).
    private func restore(_ spot: (Int, CGPoint, Int)?) {
        guard let (i, pt, rotation) = spot, let p = pdfDoc?.pdf.page(at: i) else { return }
        if p.rotation == rotation { pdfView.go(to: PDFDestination(page: p, at: pt)) } else { pdfView.go(to: p) }
    }

    @objc func beginWhiteout(_ sender: Any?) {
        guard (pdfDoc?.pdf.pageCount ?? 0) > 0 else { return }
        setMode(mode == .whiteout ? .page : .whiteout)
    }

    private func startWhiteout() {
        whiteOverlay.onDraw = { [weak self] page, rect in
            guard let self, let d = self.pdfDoc else { return }
            let i = d.pdf.index(for: page)
            guard i != NSNotFound else { return }
            d.whiteout([(index: i, rects: [rect])])
            self.updateStrip()
        }
        whiteOverlay.editable = { [weak self] p in self?.isScan(p) ?? false }
        whiteOverlay.isHidden = false
        window?.invalidateCursorRects(for: whiteOverlay)
    }

    private func endWhiteout() {
        whiteOverlay.isHidden = true
        whiteOverlay.onDraw = nil
    }

    @objc func whiteoutUndoLast(_ sender: Any?) {
        guard let um = pdfDoc?.undoManager, um.canUndo else { return }
        um.undo()
        updateStrip()
    }

    func alert(_ title: String, _ text: String) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.beginSheetModal(for: w)
    }

    // MARK: validation

    private func can(_ action: Selector?) -> Bool {
        guard let action, let d = pdfDoc else { return false }
        let n = d.pdf.pageCount
        let organise = mode != .split && mode != .marginsApply
        switch action {
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(extractPages(_:)):
            return organise && !targetPages.isEmpty
        case #selector(deletePages(_:)):
            return organise && !targetPages.isEmpty && targetPages.count < n
        case #selector(insertBlankPage(_:)), #selector(appendFile(_:)), #selector(showAddMenu(_:)):
            return organise
        case #selector(markDocument(_:)), #selector(unmarkPages(_:)):
            return mode == .split && !grid.selected.isEmpty
        case #selector(unmarkAll(_:)), #selector(writeFiles(_:)):
            return mode == .split && !d.orderedGroups().isEmpty
        case #selector(splitVolume(_:)):
            return n > 0
        case #selector(marginsAuto(_:)):
            return mode == .margins && pdfView.currentPage != nil
        case #selector(beginMargins(_:)), #selector(beginWhiteout(_:)):
            // only scanned pages can be cleaned; from the grid they open the selected page
            return mode != .split && mode != .marginsApply && n > 0 && hasScans
        case #selector(whiteoutUndoLast(_:)):
            return mode == .whiteout && d.undoManager?.undoActionName == "Ağart"
        case #selector(marginsApply(_:)):
            return mode == .margins || (mode == .marginsApply && !grid.chosen.isEmpty)
        case #selector(marginsBack(_:)):
            return mode == .marginsApply
        case #selector(beginText(_:)), #selector(toggleSignatures(_:)):
            return mode != .split && mode != .marginsApply && n > 0
        case #selector(previousPage(_:)):
            return !inGrid && currentPageIndex > 0
        case #selector(nextPage(_:)):
            return !inGrid && currentPageIndex < n - 1
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { can(item.action) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showPageMode(_:)): item.state = mode == .page ? .on : .off
        case #selector(showGridMode(_:)): item.state = inGrid ? .on : .off
        case #selector(singlePage(_:)): item.state = mode == .page && pdfView.displayMode == .singlePageContinuous ? .on : .off
        case #selector(twoPages(_:)): item.state = mode == .page && pdfView.displayMode == .twoUpContinuous ? .on : .off
        case #selector(toggleSidebarPanel(_:)): item.title = (!inGrid && sidebarWanted) ? "Sol paneli gizlət" : "Sol paneli göstər"
        case #selector(splitVolume(_:)): item.title = mode == .split ? "Faylları yaz…" : "Sənədlərə parçala"
        default: break
        }
        return can(item.action)
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // the last document closed: back to the start window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WelcomeController.showIfIdle() }
    }
}

/// Keeps two radio buttons in an accessory view exclusive.
final class RadioGroup: NSObject {
    static let shared = RadioGroup()
    var buttons: [NSButton] = []
    @objc func pick(_ sender: NSButton) { for b in buttons { b.state = b === sender ? .on : .off } }
}
