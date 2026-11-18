import AppKit
import CryptoKit

/// Updates from GitHub Releases (github.com/azadaydinli/Papiro). Once a day (and from "Yeniləmələri yoxla…") Papiro
/// asks GitHub for the latest release; if it is newer, a window shows what is new, and "Yenilə" downloads
/// Papiro.zip, checks it against Papiro.zip.sha256 from the same release, puts the new app in place of this one
/// and opens it. Nothing about the user or their files is sent: only the request for the latest release.
final class Updater: NSObject {
    static let shared = Updater()
    static let repo = "azadaydinli/Papiro"

    private let lastCheckKey = "updateLastCheck"
    private let skipKey = "updateSkipVersion"
    private var busy = false

    struct Release {
        let version: String
        let notes: String
        let zip: URL
        let sha: URL?
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "1.10" is newer than "1.9"; "v" in front is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: checking

    /// At launch: at most once a day, and only for an installed copy (not the one built on the Desktop).
    func checkAutomatically() {
        guard !Bundle.main.bundlePath.contains(".noindex") else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    /// Papiro → "Yeniləmələri yoxla…".
    @objc func checkNow(_ sender: Any?) { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Papiro/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = status == 200 ? data.flatMap(Self.parse) : nil
            DispatchQueue.main.async {
                self.busy = false
                UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                guard let release else {
                    if userInitiated {
                        let why = error?.localizedDescription ?? (status == 404 ? "GitHub-da hələ buraxılış yoxdur." : "GitHub cavabı: \(status)")
                        self.alert("Yeniləmələri yoxlamaq olmadı", why)
                    }
                    return
                }
                if Self.isNewer(release.version, than: Self.currentVersion) {
                    if !userInitiated, UserDefaults.standard.string(forKey: self.skipKey) == release.version { return }
                    self.offer(release)
                } else if userInitiated {
                    self.alert("Papiro ən son versiyadır", "Sizdəki versiya: \(Self.currentVersion)")
                }
            }
        }.resume()
    }

    /// The latest release from GitHub's answer (tag "v1.2", notes, the Papiro.zip asset and its .sha256).
    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func url(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }.flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let zip = url("Papiro.zip") else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return Release(version: version, notes: json["body"] as? String ?? "", zip: zip, sha: url("Papiro.zip.sha256"))
    }

    // MARK: offering

    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Papiro \(r.version) hazırdır"
        a.informativeText = "Sizdəki versiya: \(Self.currentVersion). Yeniləmə yüklənəcək, Papiro bağlanıb yeni versiya ilə açılacaq."
        if !r.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
            text.string = r.notes
            text.isEditable = false
            text.drawsBackground = false
            text.font = .systemFont(ofSize: 12)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            a.accessoryView = scroll
        }
        a.addButton(withTitle: "Yenilə")
        a.addButton(withTitle: "Sonra")
        a.addButton(withTitle: "Bu versiyanı ötür")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: skipKey)
        default: break
        }
    }

    // MARK: installing

    private var progress: NSWindow?

    private func install(_ r: Release) {
        if NSDocumentController.shared.hasEditedDocuments {
            alert("Əvvəlcə sənədləri saxlayın", "Açıq sənədlərdə saxlanmamış dəyişikliklər var. Onları saxlayıb (⌘S) yenidən “Yeniləmələri yoxla…” seçin.")
            return
        }
        guard let sha = r.sha else {
            alert("Yeniləmə quraşdırılmadı", "Bu buraxılışda yoxlama faylı (Papiro.zip.sha256) yoxdur.")
            return
        }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            alert("Yeniləmə quraşdırılmadı", "“\(target.deletingLastPathComponent().path)” qovluğuna yazmaq icazəsi yoxdur. Yeni versiyanı GitHub-dan endirin.")
            return
        }
        showProgress("Papiro \(r.version) yüklənir…")
        Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("papiro-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let newApp = try await Self.prepare(r, sha: sha, in: work)
                await MainActor.run {
                    self.hideProgress()
                    self.relaunch(into: target, from: newApp, cleaning: work)
                }
            } catch {
                await MainActor.run {
                    self.hideProgress()
                    self.alert("Yeniləmə quraşdırılmadı", error.localizedDescription)
                }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Download, check the checksum, unpack and check the app inside. Returns the new Papiro.app.
    static func prepare(_ r: Release, sha: URL, in work: URL) async throws -> URL {
        var shaReq = URLRequest(url: sha)
        shaReq.setValue("Papiro/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (shaData, _) = try await URLSession.shared.data(for: shaReq)
        guard let expected = String(data: shaData, encoding: .utf8)?.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init),
              expected.count == 64 else { throw UpdateError("Yoxlama faylı oxunmadı.") }

        var zipReq = URLRequest(url: r.zip)
        zipReq.setValue("Papiro/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: zipReq)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Yükləmə alınmadı.") }
        let zip = work.appendingPathComponent("Papiro.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        return try unpackChecked(zip: zip, expectedSHA: expected, version: r.version, in: work)
    }

    /// Check the zip's SHA-256, unpack it and check that it holds Papiro of that version, correctly signed.
    static func unpackChecked(zip: URL, expectedSHA: String, version: String, in work: URL) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA.lowercased() else { throw UpdateError("Yüklənən fayl yoxlamadan keçmədi (SHA-256 uyğun deyil).") }
        let out = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], "Arxiv açılmadı.")
        let app = out.appendingPathComponent("Papiro.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? "az.local.papiro",
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("Arxivdə gözlənilən Papiro \(version) yoxdur.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], "Yeni proqramın imzası pozulub.")
        return app
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String], _ failure: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(failure) }
        return p.terminationStatus
    }

    /// A small script waits for this Papiro to quit, puts the new app in its place (the old one comes back if that
    /// fails) and opens it. Papiro quits right after starting it.
    private func relaunch(into target: URL, from newApp: URL, cleaning work: URL) {
        let script = work.appendingPathComponent("install.sh")
        let text = Self.installScript
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", target.path, newApp.path, work.path]
            try p.run()
        } catch {
            alert("Yeniləmə quraşdırılmadı", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    /// $1 pid of Papiro, $2 installed app, $3 new app, $4 work folder. (PAPIRO_TEST set: do not open the app.)
    static let installScript = """
    #!/bin/sh
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
    rm -rf "$2.old"
    if mv "$2" "$2.old" && /usr/bin/ditto "$3" "$2"; then
        rm -rf "$2.old"
    else
        rm -rf "$2"; mv "$2.old" "$2"
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
    [ -n "$PAPIRO_TEST" ] || /usr/bin/open "$2"
    rm -rf "$4"
    """

    // MARK: small windows

    private func showProgress(_ text: String) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Yeniləmə"
        let label = NSTextField(labelWithString: text)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        w.contentView = stack
        w.center()
        w.makeKeyAndOrderFront(nil)
        progress = w
    }

    private func hideProgress() {
        progress?.orderOut(nil)
        progress = nil
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}
