import AppKit
import PDFKit

/// "Böl": choose the folder, check the first number, write one PDF per marked document
/// (Document_0059.pdf, Document_0060.pdf …). The first number continues after the highest
/// Document_NNNN already in the chosen folder, so the next volume carries on the numbering.
final class SplitPanel: NSObject, NSOpenSavePanelDelegate, NSTextFieldDelegate {
    private let window: NSWindow
    private let doc: PDFDoc
    private let groups: [[Int]]
    private let loose: [Int]
    private let panel = NSOpenPanel()
    private let prefixField = NSTextField(string: UserDefaults.standard.string(forKey: "splitPrefix") ?? "Document_")
    private let startField = NSTextField(string: "1")
    private let info = NSTextField(wrappingLabelWithString: "")
    private var folder: URL?
    private static var running: SplitPanel?   // keeps the panel alive until writing has finished
    private let writeQueue = DispatchQueue(label: "papiro.split-write")   // files go to disk one after another
    private var stopRequested = false

    init(window: NSWindow, doc: PDFDoc, groups: [[Int]], loose: [Int]) {
        self.window = window; self.doc = doc; self.groups = groups; self.loose = loose
        super.init()
    }

    /// `done`: the files written, the folder, and how many were left unwritten because "Dayandır" was pressed.
    func run(done: @escaping (_ written: [String], _ folder: URL, _ skipped: Int) -> Void) {
        SplitPanel.running = self
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Böl"
        panel.message = "Sənədlərin yazılacağı qovluğu seçin (\(groups.count) sənəd)"
        panel.delegate = self
        let start = UserDefaults.standard.url(forKey: "splitFolder") ?? doc.fileURL?.deletingLastPathComponent()
        panel.directoryURL = start
        folder = start
        panel.accessoryView = accessory()
        panel.isAccessoryViewDisclosed = true
        suggestNumber()

        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let dir = self.panel.url else { SplitPanel.running = nil; return }
            // let the folder panel finish closing before the progress sheet takes its place
            DispatchQueue.main.async { self.write(to: dir, done: done) }
        }
    }

    private func accessory() -> NSView {
        let l1 = NSTextField(labelWithString: "Fayl adı:")
        let l2 = NSTextField(labelWithString: "İlk nömrə:")
        prefixField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        startField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        prefixField.delegate = self
        startField.delegate = self
        let row = NSStackView(views: [l1, prefixField, l2, startField])
        row.spacing = 8
        info.preferredMaxLayoutWidth = 520
        info.textColor = .secondaryLabelColor
        let col = NSStackView(views: [row, info])
        col.orientation = .vertical
        col.alignment = .leading
        col.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        return col
    }

    // the user moved to another folder: continue the numbering found there
    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        folder = url
        suggestNumber()
    }

    func controlTextDidChange(_ obj: Notification) { updateInfo() }

    private var prefix: String { prefixField.stringValue }
    private var first: Int { max(1, Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1) }
    private func name(_ k: Int) -> String { prefix + String(format: "%04d", first + k) + ".pdf" }

    private func suggestNumber() {
        startField.stringValue = String(nextNumber(in: folder))
        updateInfo()
    }

    /// Highest "<prefix>NNNN.pdf" in the folder, plus one.
    private func nextNumber(in dir: URL?) -> Int {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 1 }
        let p = prefix.lowercased()
        let nums = names.compactMap { n -> Int? in
            let l = n.lowercased()
            guard l.hasPrefix(p), l.hasSuffix(".pdf") else { return nil }
            return Int(l.dropFirst(p.count).dropLast(4))
        }
        return (nums.max() ?? 0) + 1
    }

    private func updateInfo() {
        var t = "\(groups.count) fayl yaradılacaq: \(name(0))"
        if groups.count > 1 { t += " … \(name(groups.count - 1))" }
        if !loose.isEmpty {
            let list = loose.prefix(12).map { String($0 + 1) }.joined(separator: ", ") + (loose.count > 12 ? " …" : "")
            t += "\nHeç bir sənədə daxil olmayan \(loose.count) səhifə yazılmayacaq: \(list)"
        }
        info.stringValue = t
    }

    // MARK: writing

    /// Write the files without freezing the app: each document's pages are copied here (fast), the file is
    /// written on a background queue, one after another. A sheet shows the progress and can stop the run.
    /// Each file is first written as ".Document_0061.pdf.partial" and renamed when complete, so a stopped
    /// or failed run never leaves a half-written Document_*.pdf behind.
    private func write(to dir: URL, done: @escaping ([String], URL, Int) -> Void) {
        UserDefaults.standard.set(dir, forKey: "splitFolder")
        UserDefaults.standard.set(prefix, forKey: "splitPrefix")
        let names = groups.indices.map(name)
        let fm = FileManager.default
        let clash = names.filter { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if !clash.isEmpty {
            SplitPanel.running = nil
            let a = NSAlert()
            a.messageText = "Qovluqda bu adda fayllar artıq var"
            a.informativeText = clash.prefix(8).joined(separator: "\n") + (clash.count > 8 ? "\n…" : "")
                + "\n\nHeç nə yazılmadı. Başqa ilk nömrə və ya qovluq seçin."
            a.beginSheetModal(for: window)
            return
        }

        let sheet = ProgressSheet(total: names.count) { [weak self] in self?.stopRequested = true }
        window.beginSheet(sheet.window)
        stopRequested = false
        var written: [String] = []

        func finish(failed: String?) {
            window.endSheet(sheet.window)
            SplitPanel.running = nil
            if let failed {
                let a = NSAlert()
                a.messageText = "Yazma dayandı: \(failed)"
                a.informativeText = "\(written.count) fayl yazıldı. Qovluğa yazma icazəsini və boş yeri yoxlayın."
                a.beginSheetModal(for: window)
            } else {
                done(written, dir, names.count - written.count)
            }
        }

        func next(_ k: Int) {
            guard k < names.count, !stopRequested else { finish(failed: nil); return }
            sheet.show(file: names[k], index: k)
            let pdf = makePDF(groups[k].compactMap { doc.pdf.page(at: $0) })   // copies made on the main thread
            let final = dir.appendingPathComponent(names[k])
            let partial = dir.appendingPathComponent(".\(names[k]).partial")
            writeQueue.async {
                var ok = pdf.write(to: partial)
                if ok {
                    do { try FileManager.default.moveItem(at: partial, to: final) } catch { ok = false }
                }
                if !ok { try? FileManager.default.removeItem(at: partial) }
                DispatchQueue.main.async {
                    guard ok else { finish(failed: names[k]); return }
                    written.append(names[k])
                    sheet.advance(to: k + 1)
                    next(k + 1)
                }
            }
        }
        next(0)
    }
}

/// The sheet shown while files are written: "Yazılır: Document_0061.pdf (3 / 58)", a progress bar, "Dayandır".
private final class ProgressSheet: NSObject {
    let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let stopButton = NSButton(title: "Dayandır", target: nil, action: nil)
    private let total: Int
    private let onStop: () -> Void

    init(total: Int, onStop: @escaping () -> Void) {
        self.total = total
        self.onStop = onStop
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
        bar.doubleValue = 0
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.keyEquivalent = "\u{1b}"          // Esc
        let stack = NSStackView(views: [label, bar, stopButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.widthAnchor.constraint(equalToConstant: 380),
            label.widthAnchor.constraint(equalToConstant: 380),
        ])
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        window.contentView = content
    }

    func show(file: String, index: Int) { label.stringValue = "Yazılır: \(file) (\(index + 1) / \(total))" }
    func advance(to n: Int) { bar.doubleValue = Double(n) }

    @objc private func stop() {
        stopButton.isEnabled = false
        stopButton.title = "Dayandırılır…"
        onStop()
    }
}
