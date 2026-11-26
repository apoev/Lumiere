import AppKit
import Foundation

/// Сверяет версию с последним релизом github.com/apoev/Lumiere и подменяет .app.
final class AppUpdate: NSObject, URLSessionDownloadDelegate, NSWindowDelegate {
    static let shared = AppUpdate()

    private let releasesURL = URL(string: "https://api.github.com/repos/apoev/Lumiere/releases/latest")!
    private var session: URLSession!
    private var busy = false
    private var interactive = false
    private var zipURL: URL?
    private var progressWindow: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var progressLabel: NSTextField?

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func check(interactive: Bool) {
        guard !busy else { return }
        busy = true
        self.interactive = interactive
        var request = URLRequest(url: releasesURL)
        request.setValue("Lumiere", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.finishCheck(data: data, response: response, error: error)
            }
        }.resume()
    }

    private func finishCheck(data: Data?, response: URLResponse?, error: Error?) {
        defer { busy = false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            if interactive { inform("Обновления ещё не опубликованы", detail: "Сейчас установлена версия \(localVersion).") }
            return
        }
        guard error == nil, let data, status == 200, let remote = parse(data) else {
            if interactive { inform("Не удалось проверить обновления", detail: "Нет связи с GitHub. Попробуйте ещё раз позже.") }
            return
        }
        guard isNewer(remote.version, than: localVersion) else {
            if interactive { inform("Установлена последняя версия", detail: "Lumiere \(localVersion).") }
            return
        }
        offer(remote)
    }

    private func offer(_ release: RemoteRelease) {
        let alert = NSAlert()
        alert.messageText = "Доступна версия \(release.version)"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? "Lumiere скачает её и откроется заново."
            : String(notes.prefix(900))
        alert.addButton(withTitle: "Обновить")
        alert.addButton(withTitle: "Не сейчас")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let destination = installDestination() else { return }
        busy = true
        showProgress()
        let task = session.downloadTask(with: release.zipURL)
        task.taskDescription = destination.path
        task.resume()
    }

    private func installDestination() -> URL? {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        if path.contains("/AppTranslocation/") {
            inform(
                "Сначала перенесите Lumiere в «Программы»",
                detail: "Программа открыта из загрузок. Перетащите Lumiere.app в папку «Программы» и запустите её оттуда — тогда обновления встанут сами."
            )
            return nil
        }
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            inform(
                "Нет прав заменить Lumiere",
                detail: "Перетащите программу в папку «Программы» и откройте её оттуда."
            )
            return nil
        }
        return bundle
    }

    private func showProgress() {
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: 340, height: 18))
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let label = NSTextField(labelWithString: "Скачивание обновления…")
        label.frame = NSRect(x: 20, y: 54, width: 340, height: 20)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        content.addSubview(label)
        content.addSubview(bar)
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Обновление Lumiere"
        window.contentView = content
        window.delegate = self
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
        progressBar = bar
        progressLabel = label
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let bar = progressBar else { return }
        bar.isIndeterminate = false
        bar.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumiere-update-\(UUID().uuidString)", isDirectory: true)
        let zip = folder.appendingPathComponent("Lumiere.zip")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: zip)
            zipURL = zip
        } catch {
            zipURL = nil
            fail("Не удалось сохранить скачанный архив.")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { busy = false }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { closeProgress(); return }
            fail("Не удалось скачать обновление.")
            return
        }
        guard let zipURL, let destination = task.taskDescription.map({ URL(fileURLWithPath: $0) }) else {
            fail("Архив обновления пуст.")
            return
        }
        progressLabel?.stringValue = "Установка…"
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        install(zip: zipURL, replacing: destination)
    }

    func windowWillClose(_ notification: Notification) {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    private func install(zip: URL, replacing destination: URL) {
        let folder = zip.deletingLastPathComponent()
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", zip.path, folder.path]
        do {
            try unpack.run()
            unpack.waitUntilExit()
        } catch {
            fail("Не удалось распаковать обновление.")
            return
        }
        guard unpack.terminationStatus == 0 else {
            fail("Архив обновления повреждён.")
            return
        }
        let app = unpackedApp(in: folder)
        guard let app else {
            fail("В архиве нет Lumiere.app.")
            return
        }
        guard launchInstaller(newApp: app, destination: destination) else {
            fail("Не удалось запустить установку.")
            return
        }
        PlayerModel.current?.saveSession()
        NSApp.terminate(nil)
    }

    private func unpackedApp(in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent("Lumiere.app")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items.first { $0.pathExtension == "app" }
    }

    private func launchInstaller(newApp: URL, destination: URL) -> Bool {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("lumiere-install-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        PID="$1"
        SRC="$2"
        DEST="$3"
        SELF="$4"
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.4
        if ! rm -rf "$DEST"; then
          osascript -e 'display alert "Lumiere" message "Не удалось заменить программу. Перетащите Lumiere.app в папку «Программы» и откройте её оттуда."'
          exit 1
        fi
        ditto "$SRC" "$DEST"
        xattr -cr "$DEST" || true
        codesign --force --sign - "$DEST" >/dev/null 2>&1 || true
        open "$DEST"
        rm -rf "$(dirname "$SRC")"
        rm -f "$SELF"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let pid = ProcessInfo.processInfo.processIdentifier
            let command = "nohup /bin/bash \(sh(script.path)) \(pid) \(sh(newApp.path)) \(sh(destination.path)) \(sh(script.path)) >/tmp/lumiere-update.log 2>&1 &"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", command]
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func parse(_ data: Data) -> RemoteRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tag = (json["tag_name"] as? String) ?? ""
        let version = tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }
        let notes = json["body"] as? String ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { asset in
            let name = (asset["name"] as? String ?? "").lowercased()
            return name.hasSuffix(".zip") && name.contains("lumiere")
        } ?? assets.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".zip") }
        guard let link = zip?["browser_download_url"] as? String, let url = URL(string: link) else { return nil }
        return RemoteRelease(version: version, notes: notes, zipURL: url)
    }

    private var localVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let left = versionParts(remote)
        let right = versionParts(local)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func versionParts(_ version: String) -> [Int] {
        version.split(separator: ".").map { piece in
            Int(piece.prefix { $0.isNumber }) ?? 0
        }
    }

    private func inform(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Хорошо")
        alert.runModal()
    }

    private func fail(_ message: String) {
        closeProgress()
        inform("Обновление не установлено", detail: message)
    }

    private func closeProgress() {
        progressWindow?.delegate = nil
        progressWindow?.close()
        progressWindow = nil
        progressBar = nil
        progressLabel = nil
    }

    private func sh(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct RemoteRelease {
    var version: String
    var notes: String
    var zipURL: URL
}
