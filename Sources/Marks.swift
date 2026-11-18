import Foundation
import CryptoKit

/// Böl marks, kept so that marking interrupted by a crash, a power cut or quitting by mistake is still there when
/// the PDF is opened again: one small JSON file per PDF in the app's own folder
/// (`~/Library/Application Support/Papiro/Marks/`), on this Mac only. A file is named after the PDF's content
/// fingerprint, not its path, so renaming or moving the PDF keeps its marks. The files are temporary: a volume's
/// file goes once all its documents have been written, and files untouched for 30 days go at launch.
enum MarkStore {
    struct Record: Codable {
        var version = 1
        var fileName: String
        var pageCount: Int          // pages of the PDF on disk
        var groups: [[Int]]         // 0-based indexes in the page order of the PDF on disk
        var updated: Date
        var device: String
    }

    private static let queue = DispatchQueue(label: "papiro.marks")   // serial: writes land in order
    private static let keepDays = 30

    static var folder: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Papiro/Marks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(_ fp: String) -> URL { folder.appendingPathComponent("\(fp).json") }

    /// SHA256 of (first 1 MB + file size + page count), hex.
    static func fingerprint(of file: URL, pageCount: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 1 << 20),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber else { return nil }
        var hash = SHA256()
        hash.update(data: head)
        hash.update(data: Data("\(size.int64Value)|\(pageCount)".utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read on the calling thread: the file is small and local. Waits for writes still queued for it.
    static func load(_ fp: String) -> Record? {
        let target = url(fp)
        guard let data = queue.sync(execute: { try? Data(contentsOf: target) }) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Record.self, from: data)
    }

    /// Write (or, with no groups, delete) the marks of a PDF — atomically, off the main thread.
    static func save(_ fp: String, fileName: String, pageCount: Int, groups: [[Int]]) {
        let target = url(fp)
        guard !groups.isEmpty else { remove(fp); return }
        let rec = Record(fileName: fileName, pageCount: pageCount, groups: groups, updated: Date(),
                         device: Host.current().localizedName ?? "Mac")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rec) else { return }
        queue.async { try? data.write(to: target, options: .atomic) }
    }

    static func remove(_ fp: String) {
        let target = url(fp)
        queue.async { try? FileManager.default.removeItem(at: target) }
    }

    /// Delete marks files not changed for `keepDays` days (in the background).
    static func removeOld() {
        let dir = folder
        let limit = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        queue.async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "json" {
                if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < limit {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }
}
