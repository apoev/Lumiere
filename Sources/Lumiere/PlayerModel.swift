import AppKit
import Foundation
import UniformTypeIdentifiers

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL

    init(url: URL) {
        id = UUID()
        self.url = url.standardizedFileURL
    }

    var title: String {
        url.lastPathComponent
    }
}

enum AddMode {
    case replace
    case append
}

final class PlayerModel: ObservableObject {
    static weak var current: PlayerModel?
    static let skipSeconds: Double = 10
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    @Published var playlist: [MediaItem] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float
    @Published var volume: Int
    @Published var muted = false
    @Published var hasVideo = false
    @Published var pictureInPicture = false
    @Published var showPlaylist = true
    @Published var controlsVisible = true
    @Published var isScrubbing = false
    @Published var status: String?
    @Published var vlcMissing = false

    let engine: VLCEngine?
    private var keyMonitor: Any?
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var playGeneration = 0
    private var startedAt = Date.distantPast
    private var didConsumePending = false
    private var aspectLocked = false
    private var jobs: [(urls: [URL], mode: AddMode)] = []
    private var draining = false
    private var externalURLs: [URL] = []
    private var externalScheduled = false

    private enum Keys {
        static let rate = "lumiere.rate"
        static let volume = "lumiere.volume"
    }

    init() {
        let storedRate = UserDefaults.standard.object(forKey: Keys.rate) as? Float ?? 1
        let storedVolume = UserDefaults.standard.object(forKey: Keys.volume) as? Int ?? 100
        rate = PlayerModel.rates.contains(storedRate) ? storedRate : 1
        volume = min(100, max(0, storedVolume))
        if let plugins = VLCLocator.pluginPath() {
            engine = VLCEngine(pluginPath: plugins)
        } else {
            engine = nil
        }
        vlcMissing = engine == nil
        engine?.onEvent = { [weak self] event in
            self?.handle(event)
        }
        PlayerModel.current = self
        startTimer()
    }

    var currentTitle: String? {
        guard let currentIndex, playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex].title
    }

    func consumeLaunch() {
        installKeys()
        guard !didConsumePending else { return }
        didConsumePending = true
        let queued = AppDelegate.pending
        AppDelegate.pending = []
        var urls = queued
        for argument in CommandLine.arguments.dropFirst() {
            let path = (argument as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        if !urls.isEmpty {
            add(urls: urls, mode: .replace)
        }
    }

    func acceptExternal(_ urls: [URL]) {
        // Finder может прислать файлы несколькими событиями, пока список ещё пуст.
        externalURLs.append(contentsOf: urls)
        guard !externalScheduled else { return }
        externalScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushExternal()
        }
    }

    func openFiles(replacing: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = replacing ? "Открыть" : "Добавить"
        panel.message = "Любые видео и аудио. Редкие форматы читает движок VLC."
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls, mode: replacing ? .replace : .append)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Открыть папку"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls, mode: .replace)
    }

    func takeDrop(_ providers: [NSItemProvider]) {
        let replacing = playlist.isEmpty
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = Self.url(from: item) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(urls: urls, mode: replacing ? .replace : .append)
        }
    }

    func add(urls: [URL], mode: AddMode) {
        jobs.append((urls, mode))
        drainJobs()
    }

    private func flushExternal() {
        externalScheduled = false
        let batch = externalURLs
        externalURLs = []
        guard !batch.isEmpty else { return }
        let mode: AddMode = (playlist.isEmpty && jobs.isEmpty && !draining) ? .replace : .append
        add(urls: batch, mode: mode)
    }

    private func drainJobs() {
        guard !draining, !jobs.isEmpty else { return }
        draining = true
        let job = jobs.removeFirst()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let expanded = PlayerModel.expand(job.urls)
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(expanded, mode: job.mode)
                self.draining = false
                self.drainJobs()
            }
        }
    }

    func play(index: Int) {
        guard let engine, playlist.indices.contains(index) else { return }
        playGeneration += 1
        let generation = playGeneration
        startedAt = Date()
        currentIndex = index
        aspectLocked = false
        status = nil
        hasVideo = false
        currentTime = 0
        duration = 0
        engine.play(url: playlist[index].url)
        applyPreferences()
        isPlaying = true
        pokeControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.playGeneration == generation else { return }
            self.applyPreferences()
        }
    }

    func togglePlay() {
        guard engine != nil else { return }
        if currentIndex == nil, let first = playlist.indices.first {
            play(index: first)
            return
        }
        engine?.togglePause()
        pokeControls()
    }

    func next() {
        guard let currentIndex else { return }
        let next = currentIndex + 1
        guard playlist.indices.contains(next) else { return }
        play(index: next)
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let currentIndex, currentIndex > 0 else {
            seek(to: 0)
            return
        }
        play(index: currentIndex - 1)
    }

    func remove(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let wasCurrent = index == currentIndex
        playlist.remove(at: index)
        if playlist.isEmpty {
            clearPlayback()
            return
        }
        if wasCurrent {
            play(index: min(index, playlist.count - 1))
        } else if let currentIndex, index < currentIndex {
            self.currentIndex = currentIndex - 1
        }
    }

    func clearPlaylist() {
        playlist = []
        clearPlayback()
    }

    func seek(by seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, currentTime + seconds), max(0, duration - 0.15))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        engine?.setTime(seconds)
        pokeControls()
    }

    func preview(fraction: Double) {
        isScrubbing = true
        guard duration > 0 else { return }
        let target = min(max(0, fraction), 1) * duration
        currentTime = target
        engine?.setTime(target)
    }

    func setRate(_ value: Float) {
        rate = value
        engine?.setRate(value)
        UserDefaults.standard.set(value, forKey: Keys.rate)
        pokeControls()
    }

    func stepRate(_ direction: Int) {
        guard let index = PlayerModel.rates.firstIndex(of: rate) else {
            setRate(1)
            return
        }
        let next = min(PlayerModel.rates.count - 1, max(0, index + direction))
        setRate(PlayerModel.rates[next])
    }

    func setVolume(_ value: Int) {
        let clamped = min(100, max(0, value))
        volume = clamped
        if clamped > 0, muted {
            muted = false
            engine?.setMuted(false)
        }
        engine?.setVolume(clamped)
        UserDefaults.standard.set(clamped, forKey: Keys.volume)
        pokeControls()
    }

    func toggleMute() {
        muted.toggle()
        engine?.setMuted(muted)
        pokeControls()
    }

    func setPictureInPicture(_ enabled: Bool) {
        guard enabled != pictureInPicture else { return }
        guard currentIndex != nil || !enabled else { return }
        pictureInPicture = enabled
        if enabled {
            PiPController.shared.show(model: self)
        } else {
            PiPController.shared.close()
        }
        pokeControls()
    }

    func notePictureInPictureClosed() {
        pictureInPicture = false
    }

    func togglePlaylist() {
        showPlaylist.toggle()
    }

    func toggleFullscreen() {
        let window = NSApp.mainWindow ?? NSApp.windows.first { $0.identifier?.rawValue != PiPController.windowID }
        guard let window else { return }
        window.toggleFullScreen(nil)
    }

    func pokeControls() {
        controlsVisible = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying, !self.isScrubbing else { return }
            self.controlsVisible = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        // Коды клавиш, а не буквы: при русской раскладке символ другой, а место клавиши то же.
        switch event.keyCode {
        case 49: // пробел
            if event.isARepeat { return true }
            togglePlay()
            return true
        case 123: // влево
            seek(by: -PlayerModel.skipSeconds)
            return true
        case 124: // вправо
            seek(by: PlayerModel.skipSeconds)
            return true
        case 126: // вверх
            setVolume(volume + 5)
            return true
        case 125: // вниз
            setVolume(volume - 5)
            return true
        case 53: // esc
            if pictureInPicture {
                setPictureInPicture(false)
                return true
            }
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                return true
            }
            return false
        case 3: // f
            toggleFullscreen()
            return true
        case 35: // p
            setPictureInPicture(!pictureInPicture)
            return true
        case 46: // m
            toggleMute()
            return true
        case 45: // n
            next()
            return true
        case 33: // [
            stepRate(-1)
            return true
        case 30: // ]
            stepRate(1)
            return true
        default:
            return false
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ended:
            // Смена файла тоже шлёт EndReached. Короткое окно после старта — это ещё прошлый ролик.
            guard Date().timeIntervalSince(startedAt) > 0.6 else { return }
            startedAt = Date()
            isPlaying = false
            if let currentIndex, playlist.indices.contains(currentIndex + 1) {
                play(index: currentIndex + 1)
            } else {
                pokeControls()
            }
        case .failed:
            isPlaying = false
            status = "Не удалось воспроизвести \(currentTitle ?? "файл")"
            pokeControls()
        case .playing:
            isPlaying = true
            applyPreferences()
            updateActivity()
        case .paused, .stopped:
            isPlaying = false
            updateActivity()
            pokeControls()
        }
    }

    private func apply(_ urls: [URL], mode: AddMode) {
        guard !urls.isEmpty else {
            status = "Нет файлов, которые можно воспроизвести"
            return
        }
        status = nil
        let items = urls.map { MediaItem(url: $0) }
        switch mode {
        case .replace:
            playlist = items
            play(index: 0)
        case .append:
            let existing = Set(playlist.map(\.url.path))
            let fresh = items.filter { !existing.contains($0.url.path) }
            let start = playlist.count
            playlist.append(contentsOf: fresh)
            if currentIndex == nil, playlist.indices.contains(start) {
                play(index: start)
            } else if currentIndex == nil, let first = playlist.indices.first {
                play(index: first)
            }
        }
    }

    private func clearPlayback() {
        currentIndex = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        hasVideo = false
        status = nil
        engine?.pause()
        updateActivity()
        pokeControls()
    }

    private func applyPreferences() {
        engine?.setRate(rate)
        engine?.setVolume(volume)
        engine?.setMuted(muted)
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let engine, currentIndex != nil else { return }
        if !isScrubbing {
            let time = engine.time()
            if abs(time - currentTime) > 0.05 {
                currentTime = time
            }
        }
        let length = engine.length()
        if length > 0, abs(length - duration) > 0.2 {
            duration = length
        }
        let playing = engine.isPlaying()
        if playing != isPlaying {
            isPlaying = playing
            updateActivity()
        }
        let video = engine.hasVideo()
        if video != hasVideo {
            hasVideo = video
        }
        if pictureInPicture, !aspectLocked, let size = engine.videoSize() {
            PiPController.shared.setAspect(size)
            aspectLocked = true
        }
    }

    private func updateActivity() {
        if isPlaying {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleDisplaySleepDisabled],
                    reason: "Воспроизведение Lumiere"
                )
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        return nil
    }

    private static let folderExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "asf", "flv", "webm",
        "mpg", "mpeg", "mpe", "mpv", "m2v", "m2ts", "mts", "ts", "vob",
        "ogv", "ogm", "ogg", "3gp", "3g2", "divx", "rm", "rmvb", "f4v",
        "qt", "dv", "nut", "y4m", "hevc", "h264", "h265", "av1", "m4p",
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "opus",
        "wma", "ac3", "eac3", "dts", "mka", "caf", "amr", "ape", "wv"
    ]

    private static func expand(_ urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = manager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let item as URL in enumerator {
                    let ext = item.pathExtension.lowercased()
                    guard folderExtensions.contains(ext) else { continue }
                    files.append(item.standardizedFileURL)
                }
            } else {
                files.append(url.standardizedFileURL)
            }
        }
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.path).inserted }
        return unique.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
