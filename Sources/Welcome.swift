import AppKit
import QuickLookThumbnailing

/// The start window, shown when no document is open: "Open" in the middle and, under it, the files opened
/// last ("Recently Viewed"); a click opens one. A PDF dropped on the window opens too.
final class WelcomeController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = WelcomeController()

    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: L("No files opened yet"))
    private var recents: [URL] = []
    private var thumbs: [URL: NSImage] = [:]

    init() {
        let w = DropWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Papiro"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Show it (with the list brought up to date) when no document is open.
    static func showIfIdle() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        shared.reloadRecents()
        shared.showWindow(nil)
        shared.window?.center()
        shared.window?.makeKeyAndOrderFront(nil)
    }

    static func hide() { if shared.isWindowLoaded { shared.window?.orderOut(nil) } }

    // MARK: layout

    private func build() {
        guard let w = window else { return }
        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        w.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let name = NSTextField(labelWithString: "Papiro")
        name.font = .systemFont(ofSize: 28, weight: .semibold)

        // the title alone, so it is centred in the whole capsule; the folder sits on its left, apart from it
        let open = NSButton(title: L("Open"), target: self, action: #selector(chooseFile(_:)))
        open.bezelStyle = .glass
        open.controlSize = .extraLarge
        open.borderShape = .capsule
        open.tintProminence = .primary
        open.font = .systemFont(ofSize: 15, weight: .semibold)
        open.keyEquivalent = "\r"
        open.toolTip = L("Open")
        open.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let folder = ClickThroughImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
        folder.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        folder.contentTintColor = .white
        folder.translatesAutoresizingMaskIntoConstraints = false
        open.addSubview(folder)
        NSLayoutConstraint.activate([
            folder.leadingAnchor.constraint(equalTo: open.leadingAnchor, constant: 20),
            folder.centerYAnchor.constraint(equalTo: open.centerYAnchor),
        ])

        let header = NSTextField(labelWithString: L("Recently Viewed"))
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 52
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openClicked(_:))
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center

        let top = NSStackView(views: [icon, name, open])
        top.orientation = .vertical
        top.spacing = 14
        top.setCustomSpacing(26, after: name)

        for v in [top, header, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 54),
            header.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 34),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 30),
        ])
        w.initialFirstResponder = open
    }

    // MARK: actions

    @objc private func chooseFile(_ sender: Any?) { NSDocumentController.shared.openDocument(sender) }

    @objc private func openClicked(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < recents.count else { return }
        Self.open(recents[row])
    }

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { return }
            let a = NSAlert(error: error)
            a.messageText = L("The file could not be opened")
            a.informativeText = "\(url.lastPathComponent)\n\(error.localizedDescription)"
            if let w = shared.window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
            shared.reloadRecents()
        }
    }

    // MARK: recent files

    private func reloadRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        empty.isHidden = !recents.isEmpty
        table.reloadData()
        for url in recents where thumbs[url] == nil {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 34, height: 44),
                                                   scale: window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let image = rep?.nsImage else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.thumbs[url] = image
                    if let row = self.recents.firstIndex(of: url) {
                        self.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
                    }
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = recents[row]
        let image = NSImageView(image: thumbs[url] ?? NSWorkspace.shared.icon(forFile: url.path))
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: url.deletingPathExtension().lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [name, folder])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let rowView = NSStackView(views: [image, texts])
        rowView.spacing = 10
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        image.widthAnchor.constraint(equalToConstant: 34).isActive = true
        image.heightAnchor.constraint(equalToConstant: 44).isActive = true
        for t in [name, folder] { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        rowView.toolTip = url.path
        return rowView
    }
}

/// The start window takes PDF files dropped on it.
private final class DropWindow: NSWindow, NSDraggingDestination {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        registerForDraggedTypes([.fileURL])
    }
    private func pdfs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { pdfs(sender).isEmpty ? [] : .copy }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = pdfs(sender)
        urls.forEach(WelcomeController.open)
        return !urls.isEmpty
    }
}

/// An image inside a button that leaves clicks to the button.
final class ClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
