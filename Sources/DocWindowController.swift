import AppKit
import PDFKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("sidebar"), mode = Self("mode"), zoom = Self("zoom"), search = Self("search")
    static let tools = Self("tools"), share = Self("share"), print = Self("print")
    static let rotateLeft = Self("rotateLeft"), rotateRight = Self("rotateRight"), undo = Self("undo"), redo = Self("redo")
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
        owner?.selectionFinished()      // PDFView follows the drag inside mouseDown: the selection is complete here
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        owner?.selectionFinished()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.markupMenu(for: event) ?? super.menu(for: event)
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
        fixCursor(event.locationInWindow)
    }
    /// Keep the view where it was (or fitted) when its size changes: see `pageViewResized`.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { super.setFrameSize(newSize); return }
        let y = owner?.scrollBeforeResize()
        super.setFrameSize(newSize)
        owner?.pageViewResized(scrolledTo: y)
    }

    override func cursorUpdate(with event: NSEvent) {
        if owner?.nearPanelEdge(event) == true { return }
        super.cursorUpdate(with: event)
        fixCursor(event.locationInWindow)
    }

    /// PDFKit shows a pointing hand over pictures, so on a scanned page (one picture) it is a hand everywhere.
    /// Pointers as in Preview instead: an I-beam over text, a hand only over links, an arrow elsewhere; the open
    /// tool (margins, whitening, text) decides over the pages.
    override func setCursorFor(_ area: PDFAreaOfInterest) {
        guard let w = window, let c = owner?.cursor(at: w.mouseLocationOutsideOfEventStream, area: area) else {
            super.setCursorFor(area)
            return
        }
        c.set()
    }

    private func fixCursor(_ windowPoint: NSPoint) {
        let area = areaOfInterest(for: convert(windowPoint, from: nil))
        owner?.cursor(at: windowPoint, area: area)?.set()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, owner?.escape() == true { return }
        if event.keyCode == 51 || event.keyCode == 117, owner?.deleteSelectedSignature() == true { return }
        super.keyDown(with: event)
    }
}

/// The glass bubble in the bottom-right corner: the page number ("3 / 120"), or in the grid what is selected or
/// marked, in numbers and symbols. Clicks go through it to the page below.
final class PageBubble: NSGlassEffectView {
    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        contentView = row
        cornerRadius = 13
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Parts in a row: a symbol, a text, or both (a symbol before its text).
    func show(_ parts: [(symbol: String?, text: String)]) {
        isHidden = parts.isEmpty
        var views: [NSView] = []
        for (k, part) in parts.enumerated() {
            if k > 0 { views.append(label("·", secondary: true)) }
            if let name = part.symbol, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let v = NSImageView(image: img)
                v.symbolConfiguration = .init(pointSize: 11, weight: .medium)
                v.contentTintColor = .secondaryLabelColor
                views.append(v)
            }
            if !part.text.isEmpty { views.append(label(part.text, secondary: false)) }
        }
        row.setViews(views, in: .leading)
    }

    private func label(_ s: String, secondary: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.textColor = secondary ? .secondaryLabelColor : .labelColor
        return l
    }
}

/// One document window (tab).
/// - page: one page at a time, thumbnails panel on the left;
/// - grid: all pages, for organising (rotate, delete, move, extract) — "Split" is here;
/// - split: entered with "Split" — pages are marked as documents, which collapse into stacks; then files are written;
/// - margins: "Clean Margins" — a frame decides what stays; everything outside is removed (scanned pages only);
/// - marginsApply: its "Apply" — all pages in the grid with checkboxes, to choose which pages to clean;
/// - whiteout: "White Out" — rectangles drawn by hand are removed (scanned pages only);
/// - text: "Text" — text boxes typed on the pages.
/// The signature panel ("Signature") opens on the right in the page view; signatures are dragged onto pages.
final class DocWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                 NSToolbarItemValidation, NSSearchFieldDelegate, NSSharingServicePickerToolbarItemDelegate, NSServicesMenuRequestor {
    enum Mode { case page, grid, split, margins, marginsApply, whiteout, text, highlight }

    let pdfView = PageView()
    let side = PageSidebar()
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
    private let bubble = PageBubble()
    private var modeGroup: NSToolbarItemGroup?
    /// Rotate, undo / redo and zoom: segmented controls (as "Səhifə / Şəbəkə"), so they react to a click like the
    /// other toolbar buttons and show dividers between their parts.
    private var zoomGroup: NSToolbarItemGroup?
    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    /// The toolbar's search field (the system one, as in Preview).
    private var searchItem: NSSearchToolbarItem?
    /// The "Alətlər" button: shows or hides the tool bar under the toolbar.
    private var toolsGroup: NSToolbarItemGroup?
    /// The tool bar (under the toolbar), and whether the user wants it shown (tools that need it show it anyway).
    private var stripBar: NSSplitViewItemAccessoryViewController!
    private var toolsWanted: Bool {
        get { UserDefaults.standard.object(forKey: "toolsShown") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "toolsShown") }
    }
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
    /// "Clean Margins" and "White Out" need at least one scanned page.
    private var hasScans: Bool { pdfDoc?.pages.contains(where: isScan) ?? false }
    private var inGrid: Bool { mode == .grid || mode == .split || mode == .marginsApply }

    /// The pointer over the page view (nil: PDFKit's own, e.g. the hand over a link).
    func cursor(at windowPoint: NSPoint, area: PDFAreaOfInterest) -> NSCursor? {
        switch mode {
        case .margins: return overlay.cursor(at: windowPoint)
        case .whiteout: return whiteOverlay.cursor(at: windowPoint)
        case .text: return textOverlay.cursor(at: windowPoint)
        default: break
        }
        if !area.isDisjoint(with: [.linkArea, .controlArea, .textFieldArea, .popupArea]) { return nil }
        if area.contains(.textArea) { return .iBeam }
        return .arrow
    }

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
        case .whiteout, .text, .highlight: setMode(.page)
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
            side.reload(select: [0])
            grid.reload()
            updatePageLabel()
            updateStrip()
            // the split view restores its last state (possibly folded in the grid): show the panel as the mode wants
            DispatchQueue.main.async {
                self.sidebarReady = true; self.applySidebar(); self.sidebarResized()
                // open showing the whole first page, centred: the window (tool bar included) is laid out first,
                // otherwise the page was fitted to a view that then changed size
                self.window?.layoutIfNeeded()
                self.fitPage(nil)
            }
            NotificationCenter.default.removeObserver(self, name: .pagesChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(docChanged), name: .pagesChanged, object: d)
            for n in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.removeObserver(self, name: n, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(updateToolbarStates), name: n, object: d.undoManager)
            }
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
        side.owner = self
        side.show = { [weak self] i in
            guard let self, let p = self.pdfDoc?.pdf.page(at: i), p !== self.pdfView.currentPage else { return }
            self.showPage(p)
        }
        side.selectionChanged = { [weak self] in self?.selectionChanged() }
        side.collection.menu = sideMenu()
        signaturePanel.willOfferImport = { [weak self] in self?.importTarget = .signature }
        pin(side.scroll, in: sidebar, safeTop: true)
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
        stripBar = bar

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
        textOverlay.moved = { [weak self] a, from, page in self?.pdfDoc?.movedAnnotation(a, from: from, on: page, name: L("Move Text")) }
        textOverlay.showStyle = { [weak self] s in self?.showTextStyle(s) }
        textOverlay.onEscape = { [weak self] in self?.setMode(.page) }
        content.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bubble.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
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
        w.toolbarStyle = .unified
        updateStrip()
        updateStripVisibility()
    }

    // MARK: tool strip

    private lazy var bExtract = tool("", "arrow.up.doc", #selector(extractPages(_:)), tip: L("Export"))
    private lazy var bAdd = tool("", "plus", #selector(showAddMenu(_:)), tip: L("Add"))
    private lazy var bDelete = tool("", "trash", #selector(deletePages(_:)), tip: L("Delete"))
    private lazy var bMargins = tool(L("Clean Margins"), "crop", #selector(beginMargins(_:)), tip: L("Clean Margins"), toggle: true)
    private lazy var bText = tool("", "character.textbox", #selector(beginText(_:)), tip: L("Add Text"), toggle: true)
    private lazy var bSign = tool("", "signature", #selector(toggleSignatures(_:)), tip: L("Add Signature"), toggle: true)
    private lazy var bBold = tool("", "bold", #selector(textStyleChanged(_:)), tip: L("Bold"), toggle: true)
    private lazy var bItalic = tool("", "italic", #selector(textStyleChanged(_:)), tip: L("Italic"), toggle: true)
    private lazy var fontPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        p.target = self
        p.action = #selector(textStyleChanged(_:))
        p.toolTip = L("Font")
        p.controlSize = .large
        p.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return p
    }()
    private lazy var sizePopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: TextStyle.sizes.map { "\(Int($0))" })
        p.target = self
        p.action = #selector(textStyleChanged(_:))
        p.toolTip = L("Size")
        p.controlSize = .large
        return p
    }()
    private lazy var colorWell: NSColorWell = {
        let w = NSColorWell(style: .minimal)
        w.target = self
        w.action = #selector(textStyleChanged(_:))
        w.toolTip = L("Color")
        return w
    }()
    /// "Vurgula" as in Preview: one liquid-glass capsule (interactive, as glass holding controls should be) with the
    /// highlighter, a divider and the arrow for the styles. Turned on, the highlighter sits on a glass circle of its
    /// own and the divider goes; with the styles open, the arrow does.
    private lazy var bHighlight = capsulePart(HighlightStyle.saved.symbol, L("Highlight"), #selector(beginHighlight(_:)))
    private lazy var bHighlightStyle = capsulePart("chevron.down", L("Highlight Style"), #selector(showHighlightMenu(_:)))
    private let highlightDivider: NSBox = {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }()
    private lazy var highlightCapsule: NSGlassEffectView = {
        let row = NSStackView(views: [bHighlight.superview!, highlightDivider, bHighlightStyle.superview!])
        // 3.25 + 29 + 4.25 + 1 + 4.25 + 29 + 3.25 = 74 pt: the glass shows 72.5 pt, as Preview's capsule; both circles the same size
        row.spacing = 4.25
        row.edgeInsets = NSEdgeInsets(top: 0, left: 3.25, bottom: 0, right: 3.25)
        row.detachesHiddenViews = false
        let g = NSGlassEffectView()
        // not interactive glass: that squeezes the whole capsule on a click; each part answers on its own (as in Preview)
        g.cornerRadius = Self.buttonSize / 2
        g.contentView = row
        g.translatesAutoresizingMaskIntoConstraints = false
        g.heightAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
        g.widthAnchor.constraint(equalToConstant: 74).isActive = true      // never changes (hover, press, on)
        return g
    }()

    /// A button inside the glass capsule, on a part of its own that shows a glass circle while the pointer is over
    /// it, brightens it while pressed and keeps it while "on" (as the parts of Preview's toolbar capsules).
    private func capsulePart(_ symbol: String, _ name: String, _ action: Selector) -> NSButton {
        let b = CapsulePartButton(image: Self.symbol(symbol, name), target: self, action: action)
        b.isBordered = false
        b.toolTip = name
        let part = CapsulePart(button: b, size: 29)
        part.changed = { [weak self] in self?.updateDivider() }
        return b
    }

    /// A part of the capsule shown "on" (its glass circle stays).
    private func showOn(_ b: NSButton, _ on: Bool) {
        (b.superview as? CapsulePart)?.isOn = on
        updateDivider()
    }

    /// The divider goes while either part shows its circle (hovered or on), as in Preview.
    private func updateDivider() {
        let parts = [bHighlight, bHighlightStyle].compactMap { $0.superview as? CapsulePart }
        // faded rather than hidden, so nothing in the capsule moves
        highlightDivider.alphaValue = parts.contains { $0.showsCircle } ? 0 : 1
    }

    /// A tool symbol, the size of the other tool buttons' symbols.
    private static func symbol(_ name: String, _ label: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)!
        return img.withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) ?? img
    }
    private lazy var bWhite = tool("", "eraser", #selector(beginWhiteout(_:)), tip: L("White Out"), toggle: true)
    private lazy var bSplit = tool(L("Split into Documents"), "scissors", #selector(splitVolume(_:)), tip: L("Split into Documents"))
    private lazy var bAuto = tool("", "wand.and.stars", #selector(marginsAuto(_:)), tip: L("Detect Automatically"))
    private lazy var bMark = tool(L("Make Document"), "rectangle.stack.badge.plus", #selector(markDocument(_:)), tip: L("Make Document"))
    private lazy var bUnmark = tool(L("Separate"), "rectangle.stack.badge.minus", #selector(unmarkPages(_:)), tip: L("Separate"))
    private lazy var bUnmarkAll = tool(L("Separate All"), "square.grid.3x3", #selector(unmarkAll(_:)), tip: L("Separate All"))
    private lazy var bFinish = tool(L("Cancel"), "xmark", #selector(finishSplit(_:)), tip: L("Cancel"))
    private lazy var bWrite = tool(L("Write Files"), "square.and.arrow.down.on.square", #selector(writeFiles(_:)),
                                          tip: L("Write Files"), prominent: true)
    private lazy var bPrev = tool("", "chevron.left", #selector(previousPage(_:)), tip: L("Previous Page"))
    private lazy var bNext = tool("", "chevron.right", #selector(nextPage(_:)), tip: L("Next Page"))
    private lazy var bFull = tool("", "rectangle.dashed", #selector(marginsFull(_:)), tip: L("Whole Page"))
    private lazy var bCancel = tool(L("Cancel"), "xmark", #selector(cancelMargins(_:)), tip: L("Cancel"))
    private lazy var bApplyOne = tool(L("This Page"), "doc", #selector(marginsApplyOne(_:)), tip: L("This Page"))
    private lazy var bApply = tool(L("Apply"), "doc.on.doc", #selector(marginsApply(_:)),
                                   tip: L("Apply"), prominent: true)
    private lazy var bBack = tool(L("Back"), "chevron.left", #selector(marginsBack(_:)), tip: L("Back"))
    /// "Apply": the first and last page to clean (1-based).
    private lazy var firstField = pageField(L("First Page"))
    private lazy var lastField = pageField(L("Last Page"))
    private lazy var rangeBox: NSView = {
        let label = NSTextField(labelWithString: L("Pages:"))
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
    private var pageTools: [NSView] { [bAdd, bExtract, bDelete, bWhite, bText, bSign, highlightCapsule] }

    /// "Clean Margins" and "Split into Documents" show their names; only a window too narrow for them makes
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
        sizeSlider.toolTip = L("Thumbnail Size")

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

    /// Strip arrangements. "White Out" keeps the page arrangement: the bar does not move, only its button shows "on".
    private enum StripLayout { case page, margins, marginsApply, grid, split, text }
    private var stripLayout: StripLayout?
    /// The usual tools sit in the middle; with "Clean Margins" open they slide to the left and its buttons fade in
    /// on the right, next to the "Clean Margins" button, which always stays at the right end.
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
                // "Clean Margins" makes way for its own tools; leaving is "İmtina" (Esc)
                left = pageTools
                right = [group([bPrev, bNext]), group([bAuto, bFull]), bCancel, bApplyOne, bApply]
            case .marginsApply:
                // the frame tools make way for the pages to clean: first – last, and the checkboxes in the grid
                left = [hint]
                right = [bBack, rangeBox, bApply]
            case .text:
                // "Text": the font, size, colour and bold / italic of the text boxes
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
        showOn(bHighlight, mode == .highlight)
        bHighlight.isEnabled = can(#selector(beginHighlight(_:)))
        bHighlightStyle.isEnabled = bHighlight.isEnabled
        showHighlightStyle()
        bText.state = mode == .text ? .on : .off
        bSign.state = inspectorItem.isCollapsed ? .off : .on
        switch mode {
        case .split: hint.stringValue = L("Click the start → Shift-click the end → ⏎ · Double-click: open / close a document")
        case .margins:
            hint.stringValue = ""
        case .marginsApply: hint.stringValue = L("Unticked pages are left as they are")
        default: hint.stringValue = ""
        }
        for b in [bAdd, bExtract, bDelete, bMargins, bWhite, bSplit, bMark, bUnmark, bUnmarkAll, bFinish, bWrite,
                  bPrev, bNext, bAuto, bFull, bCancel, bApplyOne, bApply, bBack, bText, bSign] {
            b.target = self
            b.isEnabled = can(b.action)
        }
        updateToolbarStates()
    }

    /// "+": a small menu — pages of another PDF, or a blank page.
    /// "+": pages of another PDF, a blank page, or pages from the iPhone ("iPhone’dan İçe Aktar").
    @objc func showAddMenu(_ sender: NSButton) {
        let m = NSMenu()
        let file = m.addItem(withTitle: L("Add File"), action: #selector(appendFile(_:)), keyEquivalent: "")
        file.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        let blank = m.addItem(withTitle: L("Add Blank Page"), action: #selector(insertBlankPage(_:)), keyEquivalent: "")
        blank.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        m.items.forEach { $0.target = self }
        importTarget = .pages
        DeviceImport.popUp(m, under: sender)
    }

    // MARK: iPhone (Continuity Camera)

    /// Where a picture or scan from the iPhone goes: set by the menu that offered it ("+" or the signatures' "+").
    var importTarget: DeviceImport = .pages

    /// macOS asks who can take a picture or a PDF (to offer "iPhone’dan İçe Aktar"): this window can.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let r = returnType, DeviceImport.types.contains(r), pdfDoc != nil,
           importTarget == .signature || can(#selector(insertBlankPage(_:))) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// What the iPhone sent: pages after the current page (one undoable step), or a new signature.
    func readSelection(from pb: NSPasteboard) -> Bool {
        switch importTarget {
        case .signature:
            return signaturePanel.addFromDevice(pb)
        case .pages:
            guard let d = pdfDoc else { return false }
            let pages = DeviceImport.pages(from: pb)
            guard !pages.isEmpty else { return false }
            let new = d.insert(pages, at: (targetPages.last ?? -1) + 1)
            if inGrid { grid.select(new) } else if let p = d.pdf.page(at: new[0]) { showPage(p) }
            return true
        }
    }

    /// Right-click in the left panel: the selected pages.
    private func sideMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ symbol: String, _ a: Selector) {
            let item = m.addItem(withTitle: t, action: a, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.keepImageVisible()
            item.target = self
        }
        add(L("Rotate Left"), "rotate.left", #selector(rotateLeft(_:)))
        add(L("Rotate Right"), "rotate.right", #selector(rotateRight(_:)))
        m.addItem(.separator())
        add(L("Export"), "arrow.up.doc", #selector(extractPages(_:)))
        add(L("Delete"), "trash", #selector(deletePages(_:)))
        return m
    }

    private func gridMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector) { m.addItem(withTitle: t, action: a, keyEquivalent: "") }
        add(L("Make Document"), #selector(markDocument(_:)))
        add(L("Separate"), #selector(unmarkPages(_:)))
        m.addItem(.separator())
        add(L("Open"), #selector(openSelectedPage(_:)))
        add(L("Rotate Left"), #selector(rotateLeft(_:)))
        add(L("Rotate Right"), #selector(rotateRight(_:)))
        add(L("Export"), #selector(extractPages(_:)))
        add(L("Add Blank Page"), #selector(insertBlankPage(_:)))
        m.addItem(.separator())
        add(L("Delete"), #selector(deletePages(_:)))
        m.autoenablesItems = true
        return m
    }

    // MARK: toolbar

    // Preview's arrangement. From the right: search; share; zoom out / scale / zoom in; page view / grid;
    // undo / redo; rotate left / right; "Alətlər" (the tool bar below). Groups share one glass capsule.
    // The flexible space before the panel button keeps it at the panel's right edge, following its width.
    private static let items: [NSToolbarItem.Identifier] =
        [.flexibleSpace, .sidebar, .sidebarTrackingSeparator, .flexibleSpace, .tools,
         .rotateLeft, .rotateRight, .space, .undo, .redo, .zoom, .mode, .print, .share, .search]
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    private func updateToolbar() {
        modeGroup?.selectedIndex = inGrid ? 1 : 0
    }

    /// One toolbar button (also used inside groups).
    @objc func undoClicked(_ sender: Any?) { history(undo: true) }
    @objc func redoClicked(_ sender: Any?) { history(undo: false) }

    private func barItem(_ id: String, _ label: String, _ symbol: String, _ action: Selector, tip: String, toResponders: Bool = false) -> NSToolbarItem {
        let i = NSToolbarItem(itemIdentifier: .init(id))
        i.label = label
        i.toolTip = tip
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        i.action = action
        i.target = toResponders ? nil : self      // nil: through the responder chain (undo / redo)
        i.isBordered = true
        return i
    }

    /// A momentary segmented control in one capsule (one part per symbol), with a tooltip for each part.
    private func segments(_ id: NSToolbarItem.Identifier, _ label: String, _ symbols: [String], _ labels: [String],
                          _ tips: [String], _ action: Selector) -> NSToolbarItemGroup {
        let images = zip(symbols, labels).map { NSImage(systemSymbolName: $0, accessibilityDescription: $1)! }
        let g = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .momentary, labels: labels, target: self, action: action)
        g.label = label
        g.controlRepresentation = .expanded
        for (i, t) in tips.enumerated() where i < g.subitems.count { g.subitems[i].toolTip = t }
        return g
    }


    /// Through the responder chain: the text being typed undoes its typing, otherwise the document its last step.
    private func history(undo: Bool) {
        if !NSApp.sendAction(undo ? Selector(("undo:")) : Selector(("redo:")), to: nil, from: self) {
            if undo { pdfDoc?.undoManager?.undo() } else { pdfDoc?.undoManager?.redo() }
        }
        updateToolbarStates()
    }

    /// The parts of the segmented controls are not validated by AppKit: enable them here (after every change,
    /// undo, redo, mode or selection change).
    @objc func updateToolbarStates() {
        window?.toolbar?.validateVisibleItems()          // undo / redo follow the undo manager at once
        if let g = zoomGroup, g.subitems.count == 3 { g.subitems[1].isEnabled = !inGrid }
    }

    @objc func zoomClicked(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: zoomOutAction(sender)
        case 2: zoomInAction(sender)
        default: showZoomMenu()
        }
    }

    /// The scale on the middle part of the zoom control ("112%"; in the grid the thumbnail width).
    private func updateZoomLabel() {
        guard panelsMoving == 0, let g = zoomGroup, g.subitems.count == 3 else { return }   // not percent by percent
        g.subitems[1].title = inGrid ? "\(Int(grid.itemWidth)) px" : "\(Int((pdfView.scaleFactor * 100).rounded()))%"
        fixZoomWidth()
    }

    /// The scale's part keeps one width whatever it shows ("83%", "1000%", "420 px"), so the toolbar does not grow
    /// and shrink as the scale changes. (The toolbar draws the group as a segmented control: set that part's width.)
    private func fixZoomWidth() {
        if zoomControl?.window == nil, let frame = window?.contentView?.superview {
            zoomControl = Self.segmentedControl(in: frame) { c in
                c.segmentCount == 3 && c.image(forSegment: 0)?.accessibilityDescription == L("Zoom Out")
            }
        }
        guard let c = zoomControl else { return }
        let font = c.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let widest = ["1000%", "420 px"].map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 40
        let w = (widest + 18).rounded()
        if abs(c.width(forSegment: 1) - w) > 0.5 { c.setWidth(w, forSegment: 1) }
    }
    private weak var zoomControl: NSSegmentedControl?

    private static func segmentedControl(in v: NSView, where test: (NSSegmentedControl) -> Bool) -> NSSegmentedControl? {
        if let c = v as? NSSegmentedControl, test(c) { return c }
        for sub in v.subviews { if let c = segmentedControl(in: sub, where: test) { return c } }
        return nil
    }

    private func showZoomMenu() {
        guard !inGrid else { return }
        let m = NSMenu()
        for t in [L("Fit Page"), L("Fit Width")] { m.addItem(withTitle: t, action: #selector(zoomPicked(_:)), keyEquivalent: "") }
        m.addItem(.separator())
        let now = Int((pdfView.scaleFactor * 100).rounded())
        for s in Self.zoomSteps {
            let item = m.addItem(withTitle: "\(Int(s * 100))%", action: #selector(zoomPicked(_:)), keyEquivalent: "")
            item.state = Int(s * 100) == now ? .on : .off
        }
        m.items.forEach { $0.target = self }
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func zoomPicked(_ sender: NSMenuItem) {
        let t = sender.title
        if t == L("Fit Page") { fitPage(nil) }
        else if t == L("Fit Width") { fitWidth(nil) }
        else if let v = Int(t.dropLast()) { setScale(CGFloat(v) / 100) }
        updateZoomLabel()
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar f: Bool) -> NSToolbarItem? {
        switch id {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitVC.splitView, dividerIndex: 0)
        case .sidebar:
            return barItem("sidebar", L("Show Sidebar"), "sidebar.left", #selector(toggleSidebarPanel(_:)), tip: L("Show Sidebar"))
        // plain buttons side by side share one glass capsule with no line between them (as in Preview); a space
        // keeps rotate and undo / redo in capsules of their own
        case .rotateLeft:
            return barItem("rotateLeft", L("Rotate Left"), "rotate.left", #selector(rotateLeft(_:)), tip: L("Rotate Left"))
        case .rotateRight:
            return barItem("rotateRight", L("Rotate Right"), "rotate.right", #selector(rotateRight(_:)), tip: L("Rotate Right"))
        case .undo:
            return barItem("undo", L("Undo"), "arrow.uturn.backward", #selector(undoClicked(_:)), tip: L("Undo"))
        case .redo:
            return barItem("redo", L("Redo"), "arrow.uturn.forward", #selector(redoClicked(_:)), tip: L("Redo"))
        case .tools:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: L("Tool Bar"))!],
                                       selectionMode: .selectAny, labels: [L("Tool Bar")], target: self, action: #selector(toolsClicked(_:)))
            g.label = L("Tool Bar")
            g.toolTip = L("Tool Bar")
            g.subitems.first?.toolTip = L("Tool Bar")
            toolsGroup = g
            updateStripVisibility()
            return g
        case .print:
            // two plain items side by side share one glass capsule, with no line between them (as in Preview)
            return barItem("print", L("Print"), "printer", #selector(printDocument(_:)), tip: L("Print"))
        case .share:
            let i = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            i.label = L("Share")
            i.toolTip = L("Share")
            i.delegate = self
            return i
        case .mode:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "doc.text", accessibilityDescription: L("Page View"))!,
                                                NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: L("Grid View"))!],
                                       selectionMode: .selectOne, labels: [L("Page View"), L("Grid View")],
                                       target: self, action: #selector(modeClicked(_:)))
            g.label = L("View")
            for (i, t) in [L("Page View"), L("Grid View")].enumerated() where i < g.subitems.count { g.subitems[i].toolTip = t }
            g.controlRepresentation = .expanded
            g.selectedIndex = inGrid ? 1 : 0
            modeGroup = g
            return g
        case .zoom:
            // the middle part shows the scale ("112%"); a click on it opens the list of scales
            let g = segments(id, L("Scale"), ["minus.magnifyingglass", "magnifyingglass", "plus.magnifyingglass"], [L("Zoom Out"), L("Scale"), L("Zoom In")],
                             [L("Zoom Out"), L("Scale"), L("Zoom In")], #selector(zoomClicked(_:)))
            g.subitems[1].image = nil
            zoomGroup = g
            updateZoomLabel()
            return g
        case .search:
            let i = NSSearchToolbarItem(itemIdentifier: id)
            i.label = L("Search Text")
            i.toolTip = L("Search Text")
            i.searchField.placeholderString = L("Search")
            i.searchField.sendsWholeSearchString = true
            i.searchField.target = self
            i.searchField.action = #selector(searchAction(_:))
            i.preferredWidthForSearchField = 200
            searchItem = i
            return i
        default: return nil
        }
    }

    /// "Share": the document's file (saved first, so the shared copy has every change).
    private func shareItems() -> [Any] {
        guard let d = pdfDoc, let url = d.fileURL else { return [] }
        if d.isDocumentEdited { d.save(to: url, ofType: d.fileType ?? "com.adobe.pdf", for: .saveOperation) { _ in } }
        return [url]
    }

    @objc func printDocument(_ sender: Any?) { pdfDoc?.printDocument(sender) }

    /// "Paylaş": the document's file.
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { shareItems() }

    /// "Alətlər": show or hide the tool bar (it stays while a tool that needs it is open).
    @objc func toolsClicked(_ sender: NSToolbarItemGroup) {
        toolsWanted = sender.isSelected(at: 0)
        updateStripVisibility()
    }

    /// The tool bar shows when the user wants it, and always for the tools that work from it.
    private func updateStripVisibility() {
        guard stripBar != nil else { return }
        let needed: Set<Mode> = [.split, .margins, .marginsApply, .text, .whiteout, .highlight]
        let show = toolsWanted || needed.contains(mode)
        if stripBar.isHidden == show {
            animatePanels(duration: 0.2) { self.stripBar.animator().isHidden = !show }
        }
        toolsGroup?.setSelected(show, at: 0)
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
        // the signature panel closes in the grid, and for the other tools (one tool at a time)
        if [.grid, .split, .marginsApply, .margins, .whiteout, .text, .highlight].contains(m), !inspectorItem.isCollapsed {
            animatePanels { self.inspectorItem.animator().isCollapsed = true }
        }
        let wasInGrid = inGrid
        mode = m
        pdfView.isHidden = inGrid
        grid.scroll.isHidden = !inGrid
        applySidebar(relayout: wasInGrid && !inGrid)
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
            let wasPageView = old == .page || old == .margins || old == .whiteout || old == .text || old == .highlight
            if old == .marginsApply {
                if let p = pdfDoc?.pdf.page(at: applyReturnPage) { showPage(p) }
            } else if !wasPageView, let p = pdfDoc?.pdf.page(at: current) { showPage(p) }
            window?.makeFirstResponder(pdfView)
            if m == .margins { if old == .marginsApply { overlay.isHidden = false } else { startMargins() } }
            if m == .whiteout { startWhiteout() }
            if m == .highlight { markSelection() }       // text selected before the tool was turned on
            if m == .text { startText() }
        }
        updateToolbar()
        updatePageLabel()
        updateZoomLabel()
        updateStrip()
        updateStripVisibility()
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
        guard sidebar.bounds.width > 60 else { return }
        side.resized()
    }

    /// The panel shows with a single page (also while cleaning margins or whitening); it leaves no trace when hidden.
    /// `relayout`: the page view was hidden (the grid was shown) and must lay its pages out again.
    private func applySidebar(relayout: Bool = false) {
        let show = !inGrid && sidebarWanted
        let changes = sidebarItem.isCollapsed == show
        if changes {
            sidebarAnimating = true
            animatePanels({ self.sidebarItem.animator().isCollapsed = !show }, then: { [weak self] in self?.sidebarAnimating = false })
        }
        if show { DispatchQueue.main.async { self.sidebarResized() } }
        // laying the pages out again moves the view to the top: only when something changed (switching tools in
        // the page view did it every time, and the page jumped up and back)
        if !inGrid && (changes || relayout) { pdfView.layoutDocumentView() }
    }

    @objc func toggleSidebarPanel(_ sender: Any?) {
        if inGrid { sidebarWanted = true; setMode(.page) } else { sidebarWanted.toggle(); applySidebar() }
    }

    private var currentPageIndex: Int {
        guard let d = pdfDoc?.pdf, let p = pdfView.currentPage else { return 0 }
        let i = d.index(for: p)
        return i == NSNotFound ? 0 : i
    }

    /// Pages an action works on: the selection in the grid, or in the left panel when it shows; the page on
    /// screen otherwise.
    private var targetPages: [Int] {
        guard (pdfDoc?.pdf.pageCount ?? 0) > 0 else { return [] }
        if inGrid { return grid.selected }
        if !sidebarItem.isCollapsed, !side.selected.isEmpty { return side.selected }
        return [currentPageIndex]
    }

    /// Where the page view was before the pages changed; put back afterwards (undo re-inserts every page,
    /// which would otherwise leave the view at the last page).
    private var spotBeforeChange: (Int, CGPoint, Int)?

    /// The pages selected in the left panel before the pages changed: selected again afterwards, where they still are.
    private var sideBeforeChange: [PDFPage]?

    /// The page in the middle of the view before the pages changed, and how it was turned: if it is turned now,
    /// it is the page to keep in view (the saved spot belongs to the page at the top of the view, maybe another).
    private var focusBeforeChange: (page: PDFPage, rotation: Int)?

    @objc func docWillChange() {
        if !inGrid && spotBeforeChange == nil { spotBeforeChange = viewSpot() }
        if !inGrid && focusBeforeChange == nil, let p = pdfDoc?.pdf.page(at: shownPage) { focusBeforeChange = (p, p.rotation) }
        if sideBeforeChange == nil { sideBeforeChange = side.selected.compactMap { pdfDoc?.pdf.page(at: $0) } }
    }

    @objc func docChanged() {
        if inGrid { grid.reload() }
        // laid out again in one step, with no implicit animation: PDFKit's page layers otherwise slid to their new
        // size, and after a turn a strip of the page as it was showed for a moment (Preview turns at once too)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pdfView.layoutDocumentView()
        if !inGrid {
            if let f = focusBeforeChange, f.page.rotation != f.rotation, pdfDoc?.pdf.index(for: f.page) != NSNotFound {
                showPage(f.page)           // the page just turned: shown (centred at "Sayfayı Sığdır"), same scale
            } else if let spot = spotBeforeChange {
                restore(spot)
            }
        }
        focusBeforeChange = nil
        CATransaction.commit()
        spotBeforeChange = nil
        if let d = pdfDoc?.pdf {
            let keep = (sideBeforeChange ?? side.selected.compactMap { d.page(at: $0) })
                .map { d.index(for: $0) }.filter { $0 != NSNotFound }
            side.reload(select: keep.isEmpty ? [currentPageIndex] : keep)
        }
        sideBeforeChange = nil
        overlay.needsDisplay = true
        whiteOverlay.needsDisplay = true
        updatePageLabel()
        updateStrip()
    }

    func selectionChanged() { updatePageLabel(); updateStrip() }

    @objc func pageChanged() {
        pdfView.sharpenAnnotations()
        if !inGrid { side.follow(shownPage) }
        updatePageLabel()
        if !inGrid { updateStrip() }
        overlay.needsDisplay = true
        whiteOverlay.needsDisplay = true
    }

    @objc func viewScrolled() {
        // PDFKit tells about a new page only once the scrolling stops: the list and the page number follow the
        // page in the middle of the view at every step instead
        if !inGrid {
            let p = shownPage
            if p != lastShownPage {
                lastShownPage = p
                side.follow(p)
                updatePageLabel()
            }
        }
        pdfView.sharpenAnnotations()
        if mode == .margins { overlay.needsDisplay = true }
        if mode == .whiteout { whiteOverlay.needsDisplay = true }
        if mode == .text { textOverlay.layoutEditor() }
        selectionOverlay.needsDisplay = true
    }

    /// The page in the middle of the visible part of the page view: the page the user is on (it changes while
    /// scrolling, unlike PDFKit's current page, which waits for the scrolling to stop).
    var shownPage: Int {
        guard let d = pdfDoc?.pdf, d.pageCount > 0 else { return 0 }
        let free = visiblePageArea()
        guard let page = pdfView.page(for: NSPoint(x: free.midX, y: free.midY), nearest: true) else { return currentPageIndex }
        let i = d.index(for: page)
        return i == NSNotFound ? currentPageIndex : i
    }
    private var lastShownPage = -1

    @objc func scaleChanged() {
        updateGapInset()
        if !settingScale { fit = nil }        // pinched or set by PDFKit: no longer fitting
        updateZoomLabel()
        overlay.needsDisplay = true; whiteOverlay.needsDisplay = true
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
        side.redraw([page])
        if let s = selectionOverlay.selected, !s.page.annotations.contains(where: { $0 === s.a }) { selectionOverlay.selected = nil }
        selectionOverlay.needsDisplay = true
    }

    /// The bubble in the bottom-right corner (the title has no subtitle):
    /// - page view: "3 / 120";
    /// - grid: "120", one page selected "3 / 120", several "✓ 5 / 120";
    /// - Sənədlərə parçala: "❐ 12 · 📄 5" (documents, pages not in a document; ✓ when every page is in one);
    /// - Tətbiq et: "✓ 80 / 120" (pages to clean).
    func updatePageLabel() {
        window?.subtitle = ""
        let n = pdfDoc?.pdf.pageCount ?? 0
        guard n > 0 else { bubble.show([]); return }
        switch mode {
        case .page, .margins, .whiteout, .text, .highlight:
            bubble.show([(nil, "\(shownPage + 1) / \(n)")])
        case .grid:
            let s = grid.selected
            bubble.show(s.count == 0 ? [(nil, "\(n)")]
                        : s.count == 1 ? [(nil, "\(s[0] + 1) / \(n)")]
                        : [("checkmark.circle.fill", "\(s.count) / \(n)")])
        case .split:
            let groups = pdfDoc?.orderedGroups() ?? []
            let loose = n - groups.reduce(0) { $0 + $1.count }
            bubble.show([("doc.on.doc", "\(groups.count)"), loose > 0 ? ("doc", "\(loose)") : ("checkmark", "")])
        case .marginsApply:
            bubble.show([("checkmark.circle.fill", "\(grid.chosen.count) / \(n)")])
        }
    }

    // MARK: zoom & navigation

    @objc func sizeChanged(_ sender: NSSlider) { grid.itemWidth = CGFloat(sender.doubleValue); updateZoomLabel() }

    @objc func zoomInAction(_ sender: Any?) {
        if inGrid { grid.itemWidth = min(grid.itemWidth + 40, 420); sizeSlider.doubleValue = Double(grid.itemWidth) }
        else { stepZoom(up: true) }
        updateZoomLabel()
    }
    @objc func zoomOutAction(_ sender: Any?) {
        if inGrid { grid.itemWidth = max(grid.itemWidth - 40, 90); sizeSlider.doubleValue = Double(grid.itemWidth) }
        else { stepZoom(up: false) }
        updateZoomLabel()
    }
    /// Zoom in or out to the next whole ten percent: 100 → 110 → 120; from a scale set by hand, e.g. 83%,
    /// in goes to 90% and out to 80%.
    func stepZoom(up: Bool) {
        let now = (pdfView.scaleFactor * 10_000).rounded() / 100            // percent, to 0.01 (99.9999… is 100)
        let tens = up ? (now / 10).rounded(.down) + 1 : (now / 10).rounded(.up) - 1
        let lowest = max(10, pdfView.minScaleFactor * 100), highest = min(1000, pdfView.maxScaleFactor * 100)
        let target = min(max(tens * 10, lowest), highest)
        setScale(target / 100)
    }

    /// How the page view keeps fitting when the window or the panels change size ("Səhifəni sığdır",
    /// "Eninə sığdır"); nil once the scale is set by hand.
    private enum Fit { case page, width }
    private var fit: Fit?
    /// On while the scale is set here, so `scaleChanged` can tell it from a pinch.
    private var settingScale = false

    private func setScale(_ s: CGFloat, fit f: Fit? = nil) {
        settingScale = true
        pdfView.autoScales = false
        pdfView.scaleFactor = s
        settingScale = false
        fit = f
        updateGapInset()
    }

    /// Room above the first page and below the last one, as wide as the gap between two pages. Without it the first
    /// (or last) page could not be centred like the others: "Sayfayı Sığdır" scrolled past the document's edge, and
    /// AppKit pulled the view back at its next layout, so the page stuck to the top and the next one peeked in.
    private var gapInset: CGFloat = 0
    private func updateGapInset() {
        guard let sv = pdfView.documentView?.enclosingScrollView else { return }
        let m = ((pdfView.pageBreakMargins.top + pdfView.pageBreakMargins.bottom) / 2 * pdfView.scaleFactor).rounded()
        guard abs(m - gapInset) > 0.5 || sv.automaticallyAdjustsContentInsets else { return }
        var i = sv.contentInsets
        i.top += m - gapInset; i.bottom += m - gapInset
        gapInset = m
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = i
    }

    /// Go to a page. At the "Sayfayı Sığdır" scale the page is centred with its gaps, exactly as that command does
    /// (PDFKit's `go(to:)` puts its top at the top, so the next page peeks in at the bottom); otherwise its top is
    /// shown at the top.
    func showPage(_ p: PDFPage) {
        pdfView.go(to: p)
        guard fit == .page, !inGrid else { return }
        pdfView.layoutDocumentView()
        centre(p)
    }

    /// Where the page view is scrolled, just before its size changes.
    func scrollBeforeResize() -> CGFloat? {
        guard !inGrid, pdfDoc != nil else { return nil }
        return pdfView.documentView?.enclosingScrollView?.contentView.bounds.origin.y
    }

    /// The page view changed size (window, left panel, signature panel). PDFKit scrolls it to the top as it lays
    /// the pages out again: in the same step, before anything is drawn, fit again as asked last, or go back to
    /// where it was. (Done later, the page jumped up and back down while a panel opened or closed.)
    func pageViewResized(scrolledTo y: CGFloat?) {
        guard !inGrid, pdfDoc != nil, !fitting else { return }
        fitting = true
        defer { fitting = false }
        // while a panel slides in or out the page is fitted at every step, so it grows or shrinks smoothly with
        // the panel; only the percentage waits for the end (`animatePanels`, `updateZoomLabel`)
        switch fit {
        case .page: fitPage(nil)
        case .width: fitWidth(nil)
        case nil:
            guard let y, let clip = pdfView.documentView?.enclosingScrollView?.contentView, clip.bounds.origin.y != y else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
    private var fitting = false

    /// Panels (tool bar, left panel, signature panel) sliding in or out. Meanwhile the page follows them smoothly but
    /// the percentage in the toolbar stays; when the last one stops it shows the new scale, in one step.
    private var panelsMoving = 0

    private func animatePanels(duration: TimeInterval? = nil, _ changes: @escaping () -> Void, then: (() -> Void)? = nil) {
        panelsMoving += 1
        NSAnimationContext.runAnimationGroup({ ctx in
            if let duration { ctx.duration = duration }
            changes()
        }, completionHandler: { [weak self] in
            guard let self else { return }
            then?()
            self.panelsMoving -= 1
            if self.panelsMoving == 0 {
                self.pageViewResized(scrolledTo: nil)
                self.updateZoomLabel()
            }
        })
    }

    @objc func zoomToFit(_ sender: Any?) {
        if inGrid { grid.itemWidth = 170; sizeSlider.doubleValue = 170 } else { fitPage(nil) }
        updateZoomLabel()
    }

    /// "Sayfayı Sığdır": the whole current page fits, with a gap above and below it half as wide as the gap between
    /// two pages (so the next page does not show); the page is centred in the part of the view the bars leave free.
    @objc func fitPage(_ sender: Any?) {
        guard let p = pdfView.currentPage ?? pdfDoc?.pdf.page(at: 0) else { return }
        var size = p.bounds(for: pdfView.displayBox).size
        if p.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let free = visiblePageArea()
        let gap = (pdfView.pageBreakMargins.top + pdfView.pageBreakMargins.bottom) / 2   // half the gap between two pages (12 pt)
        guard size.width > 0, size.height > 0, free.width > 0, free.height > 0 else { return }
        setScale(min(free.width / (size.width + 2 * gap), free.height / (size.height + 2 * gap)), fit: .page)
        pdfView.layoutDocumentView()
        centre(p)
        updateZoomLabel()
    }

    /// "Eninə sığdır": the page fills the width the bars and panels leave free (with the usual gap at its sides);
    /// the view stays where it was on the page.
    @objc func fitWidth(_ sender: Any?) {
        guard let p = pdfView.currentPage ?? pdfDoc?.pdf.page(at: 0) else { return }
        var size = p.bounds(for: pdfView.displayBox).size
        if p.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        var free = visiblePageArea().width
        if let sv = pdfView.documentView?.enclosingScrollView, sv.scrollerStyle == .legacy, sv.hasVerticalScroller {
            free -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        let across: CGFloat = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous ? 2 : 1
        let side = pdfView.pageBreakMargins.left + pdfView.pageBreakMargins.right
        guard size.width > 0, free > 0 else { return }
        let spot = pdfView.currentDestination
        setScale(free / (across * (size.width + side)) * 0.998, fit: .width)
        pdfView.layoutDocumentView()
        if let spot, spot.page != nil { pdfView.go(to: spot) }
        centre(p, vertically: false)
        updateZoomLabel()
    }

    /// The part of the page view not covered by the bars floating over it (in page-view coordinates).
    private func visiblePageArea() -> CGRect {
        var insets = pdfView.documentView?.enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
        insets.top -= gapInset; insets.bottom -= gapInset        // our own room above and below is free space
        let b = pdfView.bounds
        let y = pdfView.isFlipped ? b.minY + insets.top : b.minY + insets.bottom
        return CGRect(x: b.minX + insets.left, y: y,
                      width: b.width - insets.left - insets.right, height: b.height - insets.top - insets.bottom)
    }

    /// Scroll so the page's middle is in the middle of the free part of the view (across always; up and down
    /// unless `vertically` is false).
    private func centre(_ p: PDFPage, vertically: Bool = true) {
        guard let clip = pdfView.documentView?.enclosingScrollView?.contentView, let sv = clip.enclosingScrollView else { return }
        let page = clip.convert(pdfView.convert(p.bounds(for: pdfView.displayBox), from: p), from: pdfView)
        let free = clip.convert(visiblePageArea(), from: pdfView)
        let dx = clip.documentRect.width > clip.bounds.width + 1 ? page.midX - free.midX : 0
        var to = clip.bounds
        to.origin.x += dx
        to.origin.y += vertically ? page.midY - free.midY : 0
        // never past the document's edges (and the room kept above and below them): AppKit would pull such a
        // position back at its next layout and the page would jump — the first or last page then rests at the edge
        clip.scroll(to: clip.constrainBoundsRect(to).origin)
        sv.reflectScrolledClipView(clip)
    }
    @objc func actualSize(_ sender: Any?) { setMode(.page); setScale(1) }
    @objc func singlePage(_ sender: Any?) { setMode(.page); pdfView.displayMode = .singlePageContinuous }
    @objc func twoPages(_ sender: Any?) { setMode(.page); pdfView.displayMode = .twoUpContinuous }

    @objc func nextPage(_ sender: Any?) { go(currentPageIndex + 1) }
    @objc func previousPage(_ sender: Any?) { go(currentPageIndex - 1) }
    @objc func firstPage(_ sender: Any?) { go(0) }
    @objc func lastPage(_ sender: Any?) { go((pdfDoc?.pdf.pageCount ?? 1) - 1) }

    private func go(_ i: Int) {
        guard let d = pdfDoc?.pdf, d.pageCount > 0 else { return }
        let k = max(0, min(i, d.pageCount - 1))
        if inGrid { grid.select([k]) } else if let p = d.page(at: k) { showPage(p) }
    }

    @objc func goToPage(_ sender: Any?) {
        guard let w = window, let n = pdfDoc?.pdf.pageCount, n > 0 else { return }
        let a = NSAlert()
        a.messageText = L("Go to Page")
        a.informativeText = L("Page number (1–%d):", n)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: L("Go")); a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn, let k = Int(f.stringValue.trimmingCharacters(in: .whitespaces)) { self.go(k - 1) }
        }
    }

    // MARK: search

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
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
        guard let d = pdfDoc, !idx.isEmpty, can(#selector(deletePages(_:))) else { return }
        d.delete(idx)      // no question: ⌘Z brings the pages back
        if inGrid { grid.select([min(idx[0], d.pdf.pageCount - 1)]) }
    }

    @objc func insertBlankPage(_ sender: Any?) {
        guard let d = pdfDoc, can(#selector(insertBlankPage(_:))) else { return }
        let at = (targetPages.last ?? -1) + 1
        d.insertBlank(at: at)
        if inGrid { grid.select([at]) } else if let p = d.pdf.page(at: at) { showPage(p) }
    }

    @objc func appendFile(_ sender: Any?) {
        guard let w = window, let d = pdfDoc, can(#selector(appendFile(_:))) else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = true
        p.message = L("Choose the PDF files to add")
        p.prompt = L("Add")
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
            if self.inGrid { self.grid.select(new) } else if let pg = d.pdf.page(at: new[0]) { self.showPage(pg) }
        }
    }

    @objc func extractPages(_ sender: Any?) {
        let idx = targetPages
        guard let w = window, let d = pdfDoc, !idx.isEmpty else { return }
        let base = d.displayName.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive, .anchored, .backwards])
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.canCreateDirectories = true
        p.nameFieldStringValue = L("%@ page %@.pdf", base, rangeText(idx))
        if let dir = UserDefaults.standard.url(forKey: "extractFolder") { p.directoryURL = dir }

        let one = NSButton(radioButtonWithTitle: L("All in one file"), target: nil, action: nil)
        let each = NSButton(radioButtonWithTitle: L("Each page in its own file"), target: nil, action: nil)
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
            if !ok { self.alert(L("The file could not be written."), L("Check that the folder can be written to.")) }
        }
    }

    private func rangeText(_ idx: [Int]) -> String {
        let s = idx.sorted()
        if s.count == 1 { return "\(s[0] + 1)" }
        let contiguous = s.last! - s.first! == s.count - 1
        return contiguous ? "\(s.first! + 1)–\(s.last! + 1)" : "\(s.first! + 1)–\(s.last! + 1) (\(s.count))"
    }

    // MARK: split (Böl)

    /// "Split into Documents" (page view or grid): enter split mode; in split mode ⌘B writes the files.
    @objc func splitVolume(_ sender: Any?) {
        switch mode {
        case .split: writeFiles(sender)
        default:
            splitReturn = (inGrid ? .grid : .page, inGrid ? nil : currentPageIndex)
            setMode(.split)
        }
    }

    /// The view "Split into Documents" was started from, and the page shown there.
    private var splitReturn: (mode: Mode, page: Int?) = (.grid, nil)

    /// "Cancel": back to that view (the marks stay).
    @objc func finishSplit(_ sender: Any?) {
        let back = splitReturn
        setMode(back.mode)
        if let i = back.page, let p = pdfDoc?.pdf.page(at: i) { showPage(p) }
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
        a.messageText = L("Remove all document marks?")
        a.informativeText = L("The pages themselves are not changed.")
        a.addButton(withTitle: L("Delete")); a.addButton(withTitle: "Ləğv et")
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            d.unmarkAll(); self.grid.reload(); self.selectionChanged()
        }
    }

    @objc func writeFiles(_ sender: Any?) {
        guard mode == .split, let w = window, let d = pdfDoc else { return }
        let groups = d.orderedGroups()
        if groups.isEmpty {
            alert(L("No documents are marked yet."),
                  L("Click the first page of a document, Shift-click its last page and press ⏎ (or “Make Document”). Repeat for each document."))
            return
        }
        let inGroup = Set(groups.flatMap { $0 })
        let loose = (0..<d.pdf.pageCount).filter { !inGroup.contains($0) }
        SplitPanel(window: w, doc: d, groups: groups, loose: loose).run { written, dir, skipped in
            if skipped == 0 { d.forgetStoredMarks() }   // every document written: nothing left to recover
            let a = NSAlert()
            a.messageText = skipped > 0
                ? L("Files created: %d, not written: %d (stopped)", written.count, skipped)
                : L("Files created: %d", written.count)
            a.informativeText = written.isEmpty ? "" : written.count == 1 ? written[0] : "\(written.first!) … \(written.last!)"
            a.addButton(withTitle: L("Show in Finder")); a.addButton(withTitle: L("Close"))
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

    /// "Detect Automatically": find the frame of the page on screen again (undoes hand edits of that page only).
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
        if let p = pdfDoc?.pdf.page(at: i) { showPage(p) }
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

    /// "Apply", first press: the frame tools give way to "first – last" (1 – N) and the grid shows every page
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
        if let p = d.pdf.page(at: at) { showPage(p) }
    }

    /// "Back" (or Esc) while choosing pages: back to the frames, nothing cleaned.
    @objc func marginsBack(_ sender: Any?) { if mode == .marginsApply { setMode(.margins) } }

    /// The page shown before "Apply", to come back to.
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

    // MARK: highlight (Vurgula)

    /// The button toggles the tool; turned on with text selected, it marks that text at once.
    @objc func beginHighlight(_ sender: Any?) {
        guard (pdfDoc?.pdf.pageCount ?? 0) > 0 else { return }
        setMode(mode == .highlight ? .page : .highlight)
    }

    /// The colours, then underline and strikethrough. Choosing one turns the tool on (and marks a selection).
    @objc func showHighlightMenu(_ sender: NSView) {
        let m = NSMenu()
        let now = HighlightStyle.saved
        for s in HighlightStyle.allCases {
            if s == .underline { m.addItem(.separator()) }
            let item = m.addItem(withTitle: s.title, action: #selector(highlightStylePicked(_:)), keyEquivalent: "")
            item.tag = s.rawValue
            item.image = s.swatch
            item.keepImageVisible()
            item.state = s == now ? .on : .off
            item.target = self
        }
        // under the arrow, which shows "on" while the menu is open
        showOn(bHighlightStyle, true)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 8), in: sender)
        showOn(bHighlightStyle, false)
    }

    @objc func highlightStylePicked(_ sender: NSMenuItem) {
        guard let s = HighlightStyle(rawValue: sender.tag) else { return }
        HighlightStyle.saved = s
        showHighlightStyle()
        if mode == .highlight { markSelection() } else { setMode(.highlight) }
    }

    /// The tool button shows the chosen style: a highlighter, or the underline / strikethrough sign.
    private func showHighlightStyle() {
        bHighlight.image = Self.symbol(HighlightStyle.saved.symbol, L("Highlight"))
    }

    /// A text selection was finished (mouse released): with the tool on, mark it.
    func selectionFinished() {
        guard mode == .highlight else { return }
        markSelection()
    }

    private func markSelection() {
        guard let d = pdfDoc, let sel = pdfView.currentSelection,
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        d.mark(sel, HighlightStyle.saved)
        pdfView.clearSelection()
    }

    /// Right-click on a mark (highlight, underline, strikethrough): "Remove Highlight".
    func markupMenu(for event: NSEvent) -> NSMenu? {
        let at = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: at, nearest: false) else { return nil }
        let pt = pdfView.convert(at, to: page)
        guard let a = page.annotations.last(where: { markupTypes.contains($0.type ?? "") && $0.bounds.contains(pt) }) else { return nil }
        let m = NSMenu()
        let item = m.addItem(withTitle: L("Remove Highlight"), action: #selector(removeMarkup(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
        item.representedObject = (a, page)
        item.target = self
        return m
    }

    @objc func removeMarkup(_ sender: NSMenuItem) {
        guard let (a, page) = sender.representedObject as? (PDFAnnotation, PDFPage) else { return }
        pdfDoc?.swapAnnotation(a, nil, on: page, name: L("Remove Highlight"))
    }

    // MARK: signatures (İmza)

    /// "Signature": the panel of signatures on the right (in the page view).
    @objc func toggleSignatures(_ sender: Any?) {
        let open = inspectorItem.isCollapsed
        // one tool at a time: "Text", "White Out" or "Clean Margins" closes when the signatures open
        if open && mode != .page { setMode(.page) }
        animatePanels { self.inspectorItem.animator().isCollapsed = !open }
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
        d.swapAnnotation(nil, a, on: page, name: L("Signature"))
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
        if changed { d.movedAnnotation(a, from: from, on: page, name: corner == nil ? L("Move Signature") : L("Resize Signature")) }
        return true
    }

    /// Delete (⌫) with a signature selected removes it.
    func deleteSelectedSignature() -> Bool {
        guard let s = selectionOverlay.selected, let d = pdfDoc else { return false }
        selectionOverlay.selected = nil
        d.swapAnnotation(s.a, nil, on: s.page, name: L("Delete Signature"))
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
        if p.rotation == rotation { pdfView.go(to: PDFDestination(page: p, at: pt)) } else { showPage(p) }
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
            return mode == .whiteout && d.undoManager?.undoActionName == L("White Out")
        case #selector(marginsApply(_:)):
            return mode == .margins || (mode == .marginsApply && !grid.chosen.isEmpty)
        case #selector(marginsBack(_:)):
            return mode == .marginsApply
        case #selector(beginText(_:)), #selector(toggleSignatures(_:)), #selector(beginHighlight(_:)), #selector(showHighlightMenu(_:)):
            return mode != .split && mode != .marginsApply && n > 0
        case #selector(undoClicked(_:)):
            return (window?.firstResponder?.undoManager ?? d.undoManager)?.canUndo ?? false
        case #selector(redoClicked(_:)):
            return (window?.firstResponder?.undoManager ?? d.undoManager)?.canRedo ?? false
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
        case #selector(toggleSidebarPanel(_:)): item.title = (!inGrid && sidebarWanted) ? L("Hide Sidebar") : L("Show Sidebar")
        case #selector(splitVolume(_:)): item.title = mode == .split ? L("Write Files") : L("Split into Documents")
        default: break
        }
        return can(item.action)
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // the last document closed: Papiro quits (it does not go back to the start window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty { NSApp.terminate(nil) }
        }
    }
}

/// Keeps two radio buttons in an accessory view exclusive.
final class RadioGroup: NSObject {
    static let shared = RadioGroup()
    var buttons: [NSButton] = []
    @objc func pick(_ sender: NSButton) { for b in buttons { b.state = b === sender ? .on : .off } }
}

/// A part of a glass capsule ("Vurgula"): a button over a glass circle that fades in while the pointer is over the
/// part, brightens while the button is pressed and stays while the part is "on".
final class CapsulePart: NSView {
    let button: CapsulePartButton
    private let circle = NSGlassEffectView()
    var changed: (() -> Void)?
    var isOn = false { didSet { update() } }
    private var hovered = false { didSet { if oldValue != hovered { update() } } }
    var showsCircle: Bool { isOn || hovered }

    init(button: CapsulePartButton, size: CGFloat) {
        self.button = button
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        circle.cornerRadius = size / 2
        circle.alphaValue = 0
        for v in [circle, button] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                                         v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        button.pressed = { [weak self] down in
            self?.circle.tintColor = down ? NSColor.white.withAlphaComponent(0.18) : nil
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if button.isEnabled { hovered = true } }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func update() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            circle.animator().alphaValue = showsCircle ? 1 : 0
        }
        changed?()
    }
}

/// The button of a capsule part: tells its part when it is pressed and let go.
final class CapsulePartButton: NSButton {
    var pressed: ((Bool) -> Void)?
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed?(flag)
    }
}
