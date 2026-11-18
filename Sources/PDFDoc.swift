import AppKit
import PDFKit

extension Notification.Name {
    /// Posted by a PDFDoc after its pages changed (order, rotation, count) or its document marks changed.
    static let pagesChanged = Notification.Name("Papiro.pagesChanged")
    /// Posted just before pages change, so views can remember where they were.
    static let pagesWillChange = Notification.Name("Papiro.pagesWillChange")
}

/// One PDF file. Page edits go through `perform` so they can be undone; document marks
/// (the "Sənəd" groups used by Böl) are working state only and are not saved into the PDF.
@objc(PDFDoc)
final class PDFDoc: NSDocument {
    var pdf = PDFDocument()

    /// Pages marked as one document each, for splitting a volume. Pages are kept by identity,
    /// so marks follow pages that are moved; deleted pages simply drop out.
    private(set) var groups: [[PDFPage]] = []

    /// PDFs that own pages made by edits (e.g. cleaned margins); a page is blank once its owner is freed.
    var keepAlive: [PDFDocument] = []

    /// Each page's position in the PDF as it is on disk. Marks are stored in this order, so they stay right
    /// even when pages were moved and the document was closed without saving. Pages added since the last
    /// save have no disk position and are left out of the stored marks.
    private var diskIndex: [ObjectIdentifier: Int] = [:]
    private var diskPageCount = 0
    /// Content fingerprint of the PDF on disk: the name of its marks file (see MarkStore).
    private var fingerprint: String?

    override class var autosavesInPlace: Bool { false }   // never rewrite a scan behind the user's back

    override func makeWindowControllers() {
        addWindowController(DocWindowController())
    }

    // MARK: reading / writing

    override func read(from url: URL, ofType typeName: String) throws {
        guard let d = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        if d.isLocked && !d.unlock(withPassword: "") {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                          userInfo: [NSLocalizedDescriptionKey: "Bu PDF parolla qorunur."])
        }
        pdf = d
        rebuildDiskIndex()
        fingerprint = MarkStore.fingerprint(of: url, pageCount: d.pageCount)
        restoreMarks(url)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let d = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        pdf = d
    }

    override func write(to url: URL, ofType typeName: String) throws {
        guard pdf.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// After a successful save the file on disk has the current page order: marks move to the new
    /// fingerprint, in the new order, and the old marks file goes.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self, saveOperation == .saveOperation || saveOperation == .saveAsOperation {
                let old = self.fingerprint
                self.rebuildDiskIndex()
                self.fingerprint = MarkStore.fingerprint(of: url, pageCount: self.pdf.pageCount)
                if let old, old != self.fingerprint { MarkStore.remove(old) }
                self.saveMarks()
            }
            completionHandler(error)
        }
    }

    private func rebuildDiskIndex() {
        diskIndex = [:]
        for (i, p) in pages.enumerated() { diskIndex[ObjectIdentifier(p)] = i }
        diskPageCount = pdf.pageCount
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let d = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return d
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw CocoaError(.featureUnsupported)
        }
        return op
    }

    // MARK: pages

    var pages: [PDFPage] { (0..<pdf.pageCount).compactMap { pdf.page(at: $0) } }

    private struct Snapshot { let pages: [PDFPage]; let rotations: [Int] }
    private func snapshot() -> Snapshot { let p = pages; return Snapshot(pages: p, rotations: p.map(\.rotation)) }

    /// Replace the page list (and rotations) in one go.
    private func apply(_ s: Snapshot) {
        while pdf.pageCount > 0 { pdf.removePage(at: pdf.pageCount - 1) }
        for (i, p) in s.pages.enumerated() {
            pdf.insert(p, at: i)
            p.rotation = s.rotations[i]
        }
    }

    private func registerRestore(_ s: Snapshot, _ name: String) {
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.willChange()
            let now = doc.snapshot()
            doc.apply(s)
            doc.registerRestore(now, name)
            doc.changed()
        }
        undoManager?.setActionName(name)
    }

    /// Run a page edit as one undoable step.
    func perform(_ name: String, _ body: () -> Void) {
        willChange()
        let before = snapshot()
        body()
        registerRestore(before, name)
        changed()
    }

    func willChange() { NotificationCenter.default.post(name: .pagesWillChange, object: self) }

    /// Pages or marks changed: store the marks (cheap, written in the background) and tell the views.
    func changed() {
        saveMarks()
        NotificationCenter.default.post(name: .pagesChanged, object: self)
    }

    // MARK: stored marks (MarkStore)

    /// Marks of the PDF just opened, left by marking that was interrupted: from the marks file, or once from
    /// the old per-path UserDefaults key, which is then moved to the marks file. Read before the window opens.
    private func restoreMarks(_ url: URL) {
        guard let fp = fingerprint, groups.isEmpty else { return }
        if let rec = MarkStore.load(fp) {
            if rec.pageCount == pdf.pageCount {
                groups = rec.groups.map { $0.compactMap { pdf.page(at: $0) } }.filter { !$0.isEmpty }
            }
        } else if migrateOldMarks(url) {
            saveMarks()
        }
    }

    /// All documents of this volume have been written: its marks file is no longer needed. The marks stay
    /// on screen; marking again stores them again.
    func forgetStoredMarks() {
        if let fp = fingerprint { MarkStore.remove(fp) }
    }

    /// Returns true when marks were taken over (the caller then shows and stores them).
    private func migrateOldMarks(_ url: URL) -> Bool {
        let key = "marks:\(url.path)"
        guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        guard groups.isEmpty, saved["pages"] as? Int == pdf.pageCount, let g = saved["groups"] as? [[Int]] else { return false }
        groups = g.map { $0.compactMap { pdf.page(at: $0) } }.filter { !$0.isEmpty }
        return true
    }

    /// Store the marks in the disk page order (pages added since the last save are left out).
    private func saveMarks() {
        guard let fp = fingerprint else { return }
        let stored = groups
            .map { $0.compactMap { diskIndex[ObjectIdentifier($0)] }.sorted() }
            .filter { !$0.isEmpty }
            .sorted { $0[0] < $1[0] }
        MarkStore.save(fp, fileName: fileURL?.lastPathComponent ?? displayName, pageCount: diskPageCount, groups: stored)
    }

    func rotate(_ idx: [Int], by deg: Int) {
        perform(deg < 0 ? "Sola döndər" : "Sağa döndər") {
            for i in idx { if let p = pdf.page(at: i) { p.rotation = ((p.rotation + deg) % 360 + 360) % 360 } }
        }
    }

    func delete(_ idx: [Int]) {
        perform("Səhifələri sil") {
            for i in idx.sorted(by: >) where i < pdf.pageCount { pdf.removePage(at: i) }
        }
    }

    /// Move the pages at `idx` so they sit before the page that is now at `target`.
    /// Returns the new indexes of the moved pages.
    @discardableResult
    func move(_ idx: [Int], to target: Int) -> [Int] {
        let all = pages
        let moving = idx.sorted().map { all[$0] }
        let set = Set(moving.map(ObjectIdentifier.init))
        var rest = all.filter { !set.contains(ObjectIdentifier($0)) }
        let at = target - idx.filter { $0 < target }.count
        rest.insert(contentsOf: moving, at: max(0, min(at, rest.count)))
        perform("Yerini dəyiş") { apply(Snapshot(pages: rest, rotations: rest.map(\.rotation))) }
        let start = max(0, min(at, all.count - moving.count))
        return Array(start..<(start + moving.count))
    }

    /// Insert copies of `newPages` at `index`. Returns the new indexes.
    @discardableResult
    func insert(_ newPages: [PDFPage], at index: Int) -> [Int] {
        let at = max(0, min(index, pdf.pageCount))
        perform("Səhifə əlavə et") {
            for (k, p) in newPages.enumerated() { pdf.insert(p, at: at + k) }
        }
        return Array(at..<(at + newPages.count))
    }

    func insertBlank(at index: Int) {
        let ref = pdf.page(at: max(0, min(index, pdf.pageCount) - 1))?.bounds(for: .mediaBox)
            ?? CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: ref.size), for: .mediaBox)
        insert([page], at: index)
    }

    // MARK: document marks (Böl)

    /// Groups in page order, each with its pages in page order; pages no longer in the PDF are left out.
    func orderedGroups() -> [[Int]] {
        var index: [ObjectIdentifier: Int] = [:]
        for (i, p) in pages.enumerated() { index[ObjectIdentifier(p)] = i }
        return groups
            .map { $0.compactMap { index[ObjectIdentifier($0)] }.sorted() }
            .filter { !$0.isEmpty }
            .sorted { $0[0] < $1[0] }
    }

    /// Position (0-based, in page order) of the group a page belongs to.
    func groupNumbers() -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (g, idx) in orderedGroups().enumerated() { for i in idx { out[i] = g } }
        return out
    }

    // Mark edits are undoable, but they never make the document "edited": marks are not written into the PDF,
    // so closing after only marking must not ask "Save?". NSDocument counts changes through the undo manager;
    // `updateChangeCount` below leaves out changes whose undo action has one of these names. Page edits use
    // other names, so a mixed sequence (Sənəd et → Döndər → ⌘Z → ⌘Z) still counts only the page edit.
    private static let markActions: Set<String> = ["Sənəd et", "Ayır", "Hamısını ayır"]

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        let name: String?
        switch change {
        case .changeDone, .changeRedone: name = undoManager?.undoActionName   // the step just done / redone
        case .changeUndone: name = undoManager?.redoActionName                // the step just undone
        default: name = nil
        }
        if let name, Self.markActions.contains(name) { return }
        super.updateChangeCount(change)
    }

    /// Make a mark edit undoable: undo puts the previous groups back (and registers the redo).
    private func registerMarks(_ before: [[PDFPage]], _ name: String) {
        undoManager?.registerUndo(withTarget: self) { doc in
            let now = doc.groups
            doc.groups = before
            doc.registerMarks(now, name)
            doc.changed()
        }
        undoManager?.setActionName(name)
    }

    func markGroup(_ range: ClosedRange<Int>) {
        let before = groups
        let newPages = range.compactMap { pdf.page(at: $0) }
        removeFromGroups(Array(range))
        groups.append(newPages)
        registerMarks(before, "Sənəd et")
        changed()
    }

    func unmark(_ idx: [Int]) {
        let before = groups
        removeFromGroups(idx)
        registerMarks(before, "Ayır")
        changed()
    }

    func unmarkAll() {
        let before = groups
        groups = []
        registerMarks(before, "Hamısını ayır")
        changed()
    }

    private func removeFromGroups(_ idx: [Int]) {
        let drop = Set(idx.compactMap { pdf.page(at: $0) }.map(ObjectIdentifier.init))
        groups = groups.map { $0.filter { !drop.contains(ObjectIdentifier($0)) } }.filter { !$0.isEmpty }
    }

    /// A page was replaced by an edited copy: the copy keeps the original's document mark.
    func replaceInGroups(_ old: PDFPage, with new: PDFPage) {
        groups = groups.map { $0.map { $0 === old ? new : $0 } }
        // the edited copy stands where the original stood in the file on disk
        if let i = diskIndex[ObjectIdentifier(old)] { diskIndex[ObjectIdentifier(new)] = i }
    }
}

/// A new PDF made of copies of the given pages (signatures placed since opening are carried over: see restoreSignatures).
func makePDF(_ pages: [PDFPage]) -> PDFDocument {
    let d = PDFDocument()
    for (k, p) in pages.enumerated() {
        let c = p.copy() as! PDFPage
        d.insert(c, at: k)
        restoreSignatures(of: p, in: c)
    }
    return d
}
