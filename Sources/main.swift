import AppKit
import PDFKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMenu()
        // "iPhone’dan İçe Aktar" (Continuity Camera): macOS offers it only to apps that say they take pictures / PDFs
        NSApp.registerServicesMenuSendTypes([], returnTypes: DeviceImport.types)
        MarkStore.removeOld()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // opened without a file: the start window ("Open" and the files opened last). Opened to show a file
        // (double-click in Finder, Papiro the default PDF app) it does not come: a large file takes a moment to
        // open, and the start window would flash before it.
        if !openingFiles {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WelcomeController.showIfIdle() }
        }
        // a newer version on GitHub? (at most once a day, a few seconds after opening)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Updater.shared.checkAutomatically() }
    }

    /// Papiro → Yeniləmələri yoxla
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkNow(sender) }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Files given by Finder (double-click, "Open With", dropped on the Dock icon): opened as macOS would, and
    /// noted, so the start window stays away. If none opens, the start window comes after all.
    private var openingFiles = false
    func application(_ application: NSApplication, open urls: [URL]) {
        openingFiles = true
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                guard let error else { return }
                NSApp.presentError(error)
                WelcomeController.showIfIdle()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeController.showIfIdle() }
        return false
    }

    /// Fayl → Faylları birləşdir: the chosen PDFs (in name order) become one new, unsaved document.
    @objc func mergeFiles(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = true
        p.message = L("Choose the PDF files to merge (they are joined in name order)")
        p.prompt = L("Merge")
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let urls = p.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for url in urls {
            guard let src = PDFDocument(url: url) else { continue }
            for i in 0..<src.pageCount { if let pg = src.page(at: i)?.copy() as? PDFPage { merged.insert(pg, at: merged.pageCount) } }
        }
        let doc = PDFDoc()
        doc.pdf = merged
        doc.fileType = UTType.pdf.identifier
        doc.displayName = L("Merged")
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.updateChangeCount(.changeDone)
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
            return m
        }
        func it(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let sep = { NSMenuItem.separator() }

        _ = sub("Papiro", [
            it(L("About Papiro"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            it(L("Check for Updates"), #selector(AppDelegate.checkForUpdates(_:))), sep(),
            it(L("Hide Papiro"), #selector(NSApplication.hide(_:)), "h"),
            it(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            it(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))), sep(),
            it(L("Quit Papiro"), #selector(NSApplication.terminate(_:)), "q"),
        ])

        // Open Recent, Duplicate, Rename, Move To and Revert To are put in by macOS itself (in the app's language)
        let file = sub(L("File"), [
            it(L("Open"), #selector(NSDocumentController.openDocument(_:)), "o"), sep(),
            it(L("Merge Files"), #selector(mergeFiles(_:))), DeviceImport.holder(), sep(),
            it(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
            it(L("Save"), #selector(NSDocument.save(_:)), "s"),
            it(L("Save As"), #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            it(L("Revert to Saved"), #selector(NSDocument.revertToSaved(_:))), sep(),
            it(L("Show in Finder"), #selector(showInFinder(_:))), sep(),
            it(L("Print"), #selector(NSDocument.printDocument(_:)), "p"),
        ])
        file.items.first { $0.action == #selector(mergeFiles(_:)) }?.target = self

        _ = sub(L("Edit"), [
            it(L("Undo"), Selector(("undo:")), "z"),
            it(L("Redo"), Selector(("redo:")), "z", [.command, .shift]), sep(),
            it(L("Cut"), #selector(NSText.cut(_:)), "x"),
            it(L("Copy"), #selector(NSText.copy(_:)), "c"),
            it(L("Paste"), #selector(NSText.paste(_:)), "v"),
            it(L("Select All"), #selector(NSText.selectAll(_:)), "a"), sep(),
            it(L("Find"), #selector(DocWindowController.focusSearch(_:)), "f"),
        ])

        _ = sub(L("View"), [
            it(L("Page"), #selector(DocWindowController.showPageMode(_:)), "1"),
            it(L("Grid"), #selector(DocWindowController.showGridMode(_:)), "2"), sep(),
            it(L("Single Page"), #selector(DocWindowController.singlePage(_:))),
            it(L("Two Pages"), #selector(DocWindowController.twoPages(_:))), sep(),
            it(L("Hide Sidebar"), #selector(DocWindowController.toggleSidebarPanel(_:)), "s", [.command, .option]), sep(),
            it(L("Zoom In"), #selector(DocWindowController.zoomInAction(_:)), "+"),
            it(L("Zoom Out"), #selector(DocWindowController.zoomOutAction(_:)), "-"),
            it(L("Zoom to Fit"), #selector(DocWindowController.zoomToFit(_:)), "9"),
            it(L("Actual Size"), #selector(DocWindowController.actualSize(_:)), "0"), sep(),
            it(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        _ = sub(L("Pages"), [
            it(L("Rotate Left"), #selector(DocWindowController.rotateLeft(_:)), "l"),
            it(L("Rotate Right"), #selector(DocWindowController.rotateRight(_:)), "r"), sep(),
            it(L("Export"), #selector(DocWindowController.extractPages(_:)), "e", [.command, .option]),
            it(L("Add File"), #selector(DocWindowController.appendFile(_:)), "a", [.command, .option]),
            it(L("Add Blank Page"), #selector(DocWindowController.insertBlankPage(_:)), "n", [.command, .option]), sep(),
            it(L("Delete"), #selector(DocWindowController.deletePages(_:)), "\u{8}"), sep(),
            it(L("Clean Margins"), #selector(DocWindowController.beginMargins(_:)), "k"),
            it(L("White Out"), #selector(DocWindowController.beginWhiteout(_:)), "w", [.command, .option]), sep(),
            it(L("Split into Documents"), #selector(DocWindowController.splitVolume(_:)), "b"),
            it(L("Make Document"), #selector(DocWindowController.markDocument(_:)), "\r"),
            it(L("Separate"), #selector(DocWindowController.unmarkPages(_:))),
            it(L("Separate All"), #selector(DocWindowController.unmarkAll(_:))),
        ])

        _ = sub(L("Go"), [
            // plain arrows stay with the page view / grid; the menu uses ⌥⌘ and ⌘
            it(L("Previous Page"), #selector(DocWindowController.previousPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            it(L("Next Page"), #selector(DocWindowController.nextPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            it(L("First Page"), #selector(DocWindowController.firstPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            it(L("Last Page"), #selector(DocWindowController.lastPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!)), sep(),
            it(L("Go to Page"), #selector(DocWindowController.goToPage(_:)), "g", [.command, .option]),
        ])

        let window = sub(L("Window"), [
            it(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            it(L("Zoom"), #selector(NSWindow.performZoom(_:))), sep(),
            it(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        let help = sub(L("Help"), [])
        NSApp.helpMenu = help
        return main
    }

    @objc func showInFinder(_ sender: Any?) {
        if let url = NSDocumentController.shared.currentDocument?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
