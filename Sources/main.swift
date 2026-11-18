import AppKit
import PDFKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMenu()
        MarkStore.removeOld()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // opened without a file: the start window ("Fayl seç" and the files opened last)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WelcomeController.showIfIdle() }
        // a newer version on GitHub? (at most once a day, a few seconds after opening)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Updater.shared.checkAutomatically() }
    }

    /// Papiro → Yeniləmələri yoxla…
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkNow(sender) }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeController.showIfIdle() }
        return false
    }

    /// Fayl → Faylları birləşdir…: the chosen PDFs (in name order) become one new, unsaved document.
    @objc func mergeFiles(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = true
        p.message = "Birləşdiriləcək PDF fayllarını seçin (ad sırası ilə birləşəcək)"
        p.prompt = "Birləşdir"
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
        doc.displayName = "Birləşdirilmiş"
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
            it("Papiro haqqında", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            it("Yeniləmələri yoxla…", #selector(AppDelegate.checkForUpdates(_:))), sep(),
            it("Papiro-nu gizlət", #selector(NSApplication.hide(_:)), "h"),
            it("Digərlərini gizlət", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            it("Hamısını göstər", #selector(NSApplication.unhideAllApplications(_:))), sep(),
            it("Papiro-dan çıx", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = it("Son açılanlar", nil)
        let recentMenu = NSMenu(title: "Son açılanlar")
        recentMenu.addItem(it("Siyahını təmizlə", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        let file = sub("Fayl", [
            it("Aç…", #selector(NSDocumentController.openDocument(_:)), "o"), recent, sep(),
            it("Faylları birləşdir…", #selector(mergeFiles(_:))), sep(),
            it("Bağla", #selector(NSWindow.performClose(_:)), "w"),
            it("Saxla", #selector(NSDocument.save(_:)), "s"),
            it("Fərqli saxla…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            it("Son saxlanana qaytar", #selector(NSDocument.revertToSaved(_:))), sep(),
            it("Finder-də göstər", #selector(showInFinder(_:))), sep(),
            it("Çap et…", #selector(NSDocument.printDocument(_:)), "p"),
        ])
        file.items.first { $0.title == "Faylları birləşdir…" }?.target = self
        // macOS fills the "Son açılanlar" menu itself when it finds the clear item inside it

        _ = sub("Düzəliş", [
            it("Geri al", Selector(("undo:")), "z"),
            it("Təkrarla", Selector(("redo:")), "z", [.command, .shift]), sep(),
            it("Kəs", #selector(NSText.cut(_:)), "x"),
            it("Kopyala", #selector(NSText.copy(_:)), "c"),
            it("Yapışdır", #selector(NSText.paste(_:)), "v"),
            it("Hamısını seç", #selector(NSText.selectAll(_:)), "a"), sep(),
            it("Tap…", #selector(DocWindowController.focusSearch(_:)), "f"),
        ])

        _ = sub("Görünüş", [
            it("Səhifə", #selector(DocWindowController.showPageMode(_:)), "1"),
            it("Səhifələr (şəbəkə)", #selector(DocWindowController.showGridMode(_:)), "2"), sep(),
            it("Tək səhifə", #selector(DocWindowController.singlePage(_:))),
            it("İki səhifə", #selector(DocWindowController.twoPages(_:))), sep(),
            it("Sol paneli gizlət", #selector(DocWindowController.toggleSidebarPanel(_:)), "s", [.command, .option]), sep(),
            it("Böyüt", #selector(DocWindowController.zoomInAction(_:)), "+"),
            it("Kiçilt", #selector(DocWindowController.zoomOutAction(_:)), "-"),
            it("Pəncərəyə sığdır", #selector(DocWindowController.zoomToFit(_:)), "9"),
            it("Həqiqi ölçü", #selector(DocWindowController.actualSize(_:)), "0"), sep(),
            it("Tam ekran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        _ = sub("Səhifələr", [
            it("Sola döndər", #selector(DocWindowController.rotateLeft(_:)), "l"),
            it("Sağa döndər", #selector(DocWindowController.rotateRight(_:)), "r"), sep(),
            it("Çıxar…", #selector(DocWindowController.extractPages(_:)), "e", [.command, .option]),
            it("Fayl əlavə et…", #selector(DocWindowController.appendFile(_:)), "a", [.command, .option]),
            it("Boş səhifə əlavə et", #selector(DocWindowController.insertBlankPage(_:)), "n", [.command, .option]), sep(),
            it("Sil", #selector(DocWindowController.deletePages(_:)), "\u{8}"), sep(),
            it("Kənarları təmizlə…", #selector(DocWindowController.beginMargins(_:)), "k"),
            it("Ağart…", #selector(DocWindowController.beginWhiteout(_:)), "w", [.command, .option]), sep(),
            it("Sənədlərə parçala", #selector(DocWindowController.splitVolume(_:)), "b"),
            it("Sənəd et", #selector(DocWindowController.markDocument(_:)), "\r"),
            it("Ayır", #selector(DocWindowController.unmarkPages(_:))),
            it("Hamısını ayır", #selector(DocWindowController.unmarkAll(_:))),
        ])

        _ = sub("Keç", [
            // plain arrows stay with the page view / grid; the menu uses ⌥⌘ and ⌘
            it("Əvvəlki səhifə", #selector(DocWindowController.previousPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            it("Növbəti səhifə", #selector(DocWindowController.nextPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            it("İlk səhifə", #selector(DocWindowController.firstPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            it("Son səhifə", #selector(DocWindowController.lastPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!)), sep(),
            it("Səhifəyə keç…", #selector(DocWindowController.goToPage(_:)), "g", [.command, .option]),
        ])

        let window = sub("Pəncərə", [
            it("Kiçilt", #selector(NSWindow.performMiniaturize(_:)), "m"),
            it("Böyüt", #selector(NSWindow.performZoom(_:))), sep(),
            it("Hamısını önə gətir", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        let help = sub("Kömək", [])
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
