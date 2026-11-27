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
    /// Файл из Finder: добавить к сохранённому списку и включить его.
    case open
}

struct WatchProgress: Codable, Equatable {
    var position: Double
    var duration: Double
    var finished: Bool
}

enum CornerReadout: Equatable {
    case time
    case volume
}

struct PlaybackCue: Equatable {
    enum Kind: Equatable {
        case play
        case pause
    }

    var kind: Kind
    var token: UUID

    var symbol: String {
        switch kind {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        }
    }
}

final class PlayerModel: ObservableObject {
    static weak var current: PlayerModel?
    static let skipSeconds: Double = 10
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let quickRates: [Float] = [1, 1.5, 2]
    static let playlistColumnWidth: CGFloat = 280

    @Published var playlist: [MediaItem] = []
    @Published var progress: [String: WatchProgress] = [:]
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float
    @Published var volume: Int
    @Published var muted = false
    @Published var hasVideo = false
    /// Пока новый ролик не нарисовал свой кадр, прошлый не показываем.
    @Published var awaitingPicture = false
    @Published private(set) var missingPaths: Set<String> = []
    @Published var pictureInPicture = false
    @Published var showPlaylist = true
    @Published var controlsVisible = true
    @Published var isScrubbing = false
    /// Время или громкость, пока пользователь перематывает или меняет звук.
    @Published var cornerReadout: CornerReadout?
    @Published var status: String?
    @Published var vlcMissing = false
    @Published var playbackCue: PlaybackCue?

    let engine: VLCEngine?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var volumeScrollRemainder: CGFloat = 0
    private var suppressStopUntil = Date.distantPast
    private var reachedEnd = false
    private var brokenSkip: DispatchWorkItem?
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
    private var mediaStarted = false
    private var resume: (generation: Int, time: Double)?
    private var saveWork: DispatchWorkItem?
    private var draggedID: UUID?
    private var lastStoredPosition: Double = -1
    private var frameBeforePlay: NSRect?
    private var scrubIdle: DispatchWorkItem?
    private var scrubHoldUntil = Date.distantPast
    private var lastSeekSentAt = Date.distantPast
    private var lastSeekSent = -1.0
    private var cueClear: DispatchWorkItem?
    private var readoutClear: DispatchWorkItem?
    private var trustPlayingUntil = Date.distantPast

    private enum Keys {
        static let rate = "lumiere.rate"
        static let volume = "lumiere.volume"
        static let showPlaylist = "lumiere.showPlaylist"
    }

    init() {
        let storedRate = UserDefaults.standard.object(forKey: Keys.rate) as? Float ?? 1
        let storedVolume = UserDefaults.standard.object(forKey: Keys.volume) as? Int ?? 100
        rate = PlayerModel.rates.contains(storedRate) ? storedRate : 1
        volume = min(100, max(0, storedVolume))
        if UserDefaults.standard.object(forKey: Keys.showPlaylist) != nil {
            showPlaylist = UserDefaults.standard.bool(forKey: Keys.showPlaylist)
        }
        if let plugins = VLCLocator.pluginPath() {
            engine = VLCEngine(pluginPath: plugins)
        } else {
            engine = nil
        }
        vlcMissing = engine == nil
        loadLibrary()
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
        // m3u — это готовый список, его нужно поставить вместо текущего.
        // Обычные файлы из Finder по-прежнему добавляются к тому, что уже открыто.
        let mode: AddMode = batch.contains(where: Self.isPlaylistFile) ? .replace : .open
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

    func play(index: Int, resumeAt: Double? = nil) {
        guard let engine, playlist.indices.contains(index) else { return }
        storeProgress(force: true)
        frameBeforePlay = NSApp.mainWindow?.frame
        playGeneration += 1
        let generation = playGeneration
        startedAt = Date()
        currentIndex = index
        aspectLocked = false
        status = nil
        hasVideo = false
        mediaStarted = true
        reachedEnd = false
        brokenSkip?.cancel()
        let path = playlist[index].url.path
        if let resumeAt {
            if resumeAt > 0.35 {
                resume = (generation, resumeAt)
                currentTime = resumeAt
            } else {
                resume = nil
                currentTime = 0
            }
        } else if let mark = progress[path], !mark.finished, mark.position > 3 {
            resume = (generation, mark.position)
            currentTime = mark.position
        } else {
            resume = nil
            currentTime = 0
        }
        duration = progress[path]?.duration ?? 0
        suppressStopUntil = Date().addingTimeInterval(0.8)
        if !FileManager.default.fileExists(atPath: path) {
            engine.clearPicture()
            isPlaying = false
            hasVideo = false
            awaitingPicture = false
            currentTime = 0
            duration = 0
            status = "Файл не найден"
            refreshMissing()
            pokeControls()
            scheduleSave()
            scheduleSkipBroken(generation: generation, from: index)
            return
        }
        awaitingPicture = true
        engine.play(url: playlist[index].url)
        applyPreferences()
        isPlaying = true
        pokeControls()
        scheduleSave()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.playGeneration == generation else { return }
            self.applyPreferences()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.playGeneration == generation, self.awaitingPicture, !self.hasVideo else { return }
            self.awaitingPicture = false
        }
    }

    func togglePlay(announce: Bool = true) {
        guard engine != nil else { return }
        if reachedEnd, let currentIndex {
            let time = (duration > 1 && currentTime >= duration - 1.2) ? 0 : currentTime
            play(index: currentIndex, resumeAt: time)
            if announce { flashCue(.play) }
            return
        }
        if let currentIndex, !mediaStarted {
            play(index: currentIndex)
            if announce { flashCue(.play) }
            return
        }
        if currentIndex == nil, let first = playlist.indices.first {
            play(index: first)
            if announce { flashCue(.play) }
            return
        }
        let willPlay = !isPlaying
        isPlaying = willPlay
        trustPlayingUntil = Date().addingTimeInterval(0.35)
        engine?.togglePause()
        if announce { flashCue(willPlay ? .play : .pause) }
        pokeControls()
    }

    var canPlayNext: Bool {
        guard let currentIndex else { return false }
        return nextLiving(after: currentIndex, step: 1) != nil
    }

    var canPlayPrevious: Bool {
        guard let currentIndex else { return false }
        if currentTime > 3, !isMissing(currentIndex) { return true }
        return nextLiving(after: currentIndex, step: -1) != nil
    }

    func playAdjacent(_ delta: Int) {
        guard let currentIndex, let target = nextLiving(after: currentIndex, step: delta) else { return }
        play(index: target)
    }

    func next() {
        playAdjacent(1)
    }

    func previous() {
        if currentTime > 3, let currentIndex, !isMissing(currentIndex) {
            seek(to: 0)
            return
        }
        playAdjacent(-1)
    }

    private func isMissing(_ index: Int) -> Bool {
        guard playlist.indices.contains(index) else { return true }
        return !FileManager.default.fileExists(atPath: playlist[index].url.path)
    }

    private func nextLiving(after index: Int, step: Int) -> Int? {
        guard step != 0 else { return nil }
        var cursor = index + step
        while playlist.indices.contains(cursor) {
            if !isMissing(cursor) { return cursor }
            cursor += step
        }
        return nil
    }

    private func scheduleSkipBroken(generation: Int, from index: Int) {
        brokenSkip?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.playGeneration == generation, self.currentIndex == index else { return }
            guard let next = self.nextLiving(after: index, step: 1) else { return }
            self.play(index: next)
        }
        brokenSkip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
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
        scheduleSave()
    }

    func clearPlaylist() {
        storeProgress(force: true)
        playlist = []
        missingPaths = []
        clearPlayback()
        scheduleSave()
    }

    func refreshMissing() {
        let missing = Set(playlist.map(\.url.path).filter { !FileManager.default.fileExists(atPath: $0) })
        if missing != missingPaths {
            missingPaths = missing
        }
    }

    func removeMissing() {
        let current = currentPath
        let currentMissing = current.map { !FileManager.default.fileExists(atPath: $0) } ?? false
        playlist.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        missingPaths = []
        if playlist.isEmpty {
            clearPlayback()
        } else if currentMissing {
            play(index: 0)
        } else if let current {
            currentIndex = playlist.firstIndex { $0.url.path == current }
        }
        scheduleSave()
    }

    func sortPlaylist(ascending: Bool) {
        let path = currentPath
        playlist.sort { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        rebindCurrent(path: path)
        scheduleSave()
    }

    func beginDrag(_ id: UUID) {
        draggedID = id
    }

    func dropDraggedItem(before id: UUID) {
        guard let draggedID, draggedID != id,
              let from = playlist.firstIndex(where: { $0.id == draggedID }) else { return }
        let path = currentPath
        let moving = playlist.remove(at: from)
        if let to = playlist.firstIndex(where: { $0.id == id }) {
            playlist.insert(moving, at: to)
        } else {
            playlist.append(moving)
        }
        self.draggedID = nil
        rebindCurrent(path: path)
        scheduleSave()
    }

    func seek(by seconds: Double) {
        guard duration > 0 else { return }
        seek(to: clampedTime(currentTime + seconds))
    }

    func seek(to seconds: Double) {
        let target = clampedTime(seconds)
        resume = nil
        currentTime = target
        deliverSeek(target)
        showCornerReadout(.time)
        pokeControls()
    }

    func beginScrub() {
        isScrubbing = true
    }

    func scrub(byScroll delta: CGFloat) {
        guard duration > 0 else { return }
        trackScrub(to: currentTime + Double(delta) * 0.12)
    }

    func preview(fraction: Double) {
        guard duration > 0 else { return }
        trackScrub(to: min(max(0, fraction), 1) * duration)
    }

    func endScrub() {
        scrubIdle?.cancel()
        isScrubbing = true
        deliverSeek(currentTime)
        releaseScrubHold()
    }

    private func clampedTime(_ seconds: Double) -> Double {
        min(max(0, seconds), max(0, duration - 0.15))
    }

    /// Ползунок двигается сразу, а libvlc получает позицию не чаще десяти раз в секунду.
    private func trackScrub(to seconds: Double) {
        let target = clampedTime(seconds)
        resume = nil
        if !isScrubbing { pokeControls() }
        currentTime = target
        isScrubbing = true
        showCornerReadout(.time)
        if Date().timeIntervalSince(lastSeekSentAt) >= 0.1 {
            deliverSeek(target)
        }
        scrubIdle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deliverSeek(self.currentTime)
            self.releaseScrubHold()
        }
        scrubIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func deliverSeek(_ seconds: Double) {
        let target = clampedTime(seconds)
        guard abs(target - lastSeekSent) > 0.04 || Date().timeIntervalSince(lastSeekSentAt) > 0.25 else { return }
        lastSeekSent = target
        lastSeekSentAt = Date()
        engine?.setTime(target)
        scrubHoldUntil = Date().addingTimeInterval(0.45)
    }

    private func releaseScrubHold() {
        scrubHoldUntil = Date().addingTimeInterval(0.35)
        let work = DispatchWorkItem { [weak self] in
            guard let self, Date() >= self.scrubHoldUntil else { return }
            self.isScrubbing = false
        }
        scrubIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
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
        showCornerReadout(.volume)
        pokeControls()
    }

    /// Свайп вверх увеличивает громкость. Инверсия в настройках переворачивает направление.
    func changeVolume(byScroll delta: CGFloat) {
        volumeScrollRemainder += delta / 4
        let steps = Int(volumeScrollRemainder.rounded(.towardZero))
        guard steps != 0 else { return }
        volumeScrollRemainder -= CGFloat(steps)
        setVolume(volume + steps)
    }

    func revealInFinder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "Файл не найден"
            return
        }
        status = nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleMute() {
        muted.toggle()
        engine?.setMuted(muted)
        showCornerReadout(.volume)
        pokeControls()
    }

    private func showCornerReadout(_ kind: CornerReadout) {
        readoutClear?.cancel()
        cornerReadout = kind
        let work = DispatchWorkItem { [weak self] in
            guard self?.cornerReadout == kind else { return }
            self?.cornerReadout = nil
        }
        readoutClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func setPictureInPicture(_ enabled: Bool) {
        guard enabled != pictureInPicture else { return }
        guard currentIndex != nil || !enabled else { return }
        if enabled {
            PiPController.shared.enter(model: self) { [weak self] in
                self?.pictureInPicture = true
                self?.pokeControls()
            }
        } else {
            PiPController.shared.leave { [weak self] in
                self?.pictureInPicture = false
                self?.pokeControls()
            }
        }
    }

    func flashCue(_ kind: PlaybackCue.Kind) {
        cueClear?.cancel()
        let cue = PlaybackCue(kind: kind, token: UUID())
        playbackCue = cue
        let work = DispatchWorkItem { [weak self] in
            guard self?.playbackCue?.token == cue.token else { return }
            self?.playbackCue = nil
        }
        cueClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }

    func dismissCue() {
        cueClear?.cancel()
        playbackCue = nil
    }

    func notePictureInPictureClosed() {
        pictureInPicture = false
    }

    func togglePlaylist() {
        showPlaylist.toggle()
        UserDefaults.standard.set(showPlaylist, forKey: Keys.showPlaylist)
    }

    func watchedFraction(for url: URL) -> Double {
        if mediaStarted, url.path == currentPath, duration > 0 {
            return min(1, max(0, currentTime / duration))
        }
        guard let mark = progress[url.path] else { return 0 }
        if mark.finished { return 1 }
        guard mark.duration > 1 else { return 0 }
        return min(1, max(0, mark.position / mark.duration))
    }

    func saveSession() {
        storeProgress(force: true)
        writeLibrary()
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
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event) ? nil : event
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

    private func handleScroll(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil { return false }
        guard let window = event.window, mediaStarted, duration > 0, currentIndex != nil else { return false }
        let point = event.locationInWindow
        let isPip = window.identifier?.rawValue == PiPController.windowID
        if !isPip, showPlaylist, point.x < PlayerModel.playlistColumnWidth {
            return false
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
        let dx = (event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX) * scale
        let dy = (event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY) * scale
        let overTimeline = point.y < 140
        let horizontal = abs(dx) >= abs(dy) && abs(dx) >= 0.4
        let direction: CGFloat = AppSettings.shared.invertScroll ? -1 : 1
        if horizontal {
            guard mediaStarted, duration > 0 else { return false }
            // Жест вправо — вперёд, независимо от «естественной» прокрутки системы.
            let fingerRight = event.isDirectionInvertedFromDevice ? dx : -dx
            scrub(byScroll: fingerRight * direction)
            return true
        }
        guard abs(dy) >= 0.4 else { return false }
        // У таймлайна основного окна вертикаль по-прежнему перематывает.
        // В мини-плеере вверх-вниз — громкость, как на большом экране.
        if overTimeline, !isPip, mediaStarted, duration > 0 {
            scrub(byScroll: dy * direction)
            return true
        }
        // deltaY: 1 — свайп вверх, пока система не перевернула жест. Инверсия настройки меняет это.
        let fingerUp = event.isDirectionInvertedFromDevice ? -dy : dy
        changeVolume(byScroll: fingerUp * direction)
        return true
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ended:
            if Date() < suppressStopUntil { return }
            // Смена файла тоже шлёт EndReached. Короткое окно после старта — это ещё прошлый ролик.
            guard Date().timeIntervalSince(startedAt) > 0.6 else { return }
            startedAt = Date()
            markCurrentFinished()
            isPlaying = false
            if let currentIndex, let next = nextLiving(after: currentIndex, step: 1) {
                play(index: next)
            } else {
                reachedEnd = true
                pokeControls()
                scheduleSave()
            }
        case .failed:
            suppressStopUntil = Date().addingTimeInterval(0.8)
            engine?.clearPicture()
            awaitingPicture = false
            hasVideo = false
            isPlaying = false
            status = "Не удалось воспроизвести \(currentTitle ?? "файл")"
            pokeControls()
            if let currentIndex {
                scheduleSkipBroken(generation: playGeneration, from: currentIndex)
            }
        case .playing:
            reachedEnd = false
            isPlaying = true
            applyPreferences()
            applyResume()
            keepWindowFromVideoSize()
            updateActivity()
        case .paused:
            if Date() < suppressStopUntil { return }
            isPlaying = false
            updateActivity()
            pokeControls()
        case .stopped:
            if Date() < suppressStopUntil { return }
            isPlaying = false
            if duration > 1, currentTime >= duration - 1.2 {
                reachedEnd = true
            }
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
            storeProgress(force: true)
            currentIndex = nil
            mediaStarted = false
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
        case .open:
            var firstIndex: Int?
            for url in urls {
                if let index = playlist.firstIndex(where: { $0.url.path == url.path }) {
                    if firstIndex == nil { firstIndex = index }
                } else {
                    playlist.append(MediaItem(url: url))
                    if firstIndex == nil { firstIndex = playlist.count - 1 }
                }
            }
            if let firstIndex {
                play(index: firstIndex)
            }
        }
        refreshMissing()
        scheduleSave()
    }

    private func clearPlayback() {
        mediaStarted = false
        resume = nil
        currentIndex = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        hasVideo = false
        awaitingPicture = false
        reachedEnd = false
        brokenSkip?.cancel()
        status = nil
        suppressStopUntil = Date().addingTimeInterval(0.8)
        engine?.clearPicture()
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
        progressTick &+= 1
        if showPlaylist, progressTick % 8 == 0 {
            refreshMissing()
        }
        guard let engine, currentIndex != nil, mediaStarted else { return }
        let time = engine.time()
        let holding = isScrubbing || Date() < scrubHoldUntil
        if !holding, !reachedEnd {
            if abs(time - currentTime) > 0.05 {
                currentTime = time
            }
        } else if !isScrubbing, abs(time - currentTime) < 0.25 {
            scrubHoldUntil = .distantPast
        }
        let length = engine.length()
        if length > 0, abs(length - duration) > 0.2 {
            duration = length
        }
        if Date() >= trustPlayingUntil {
            let playing = engine.isPlaying()
            if playing != isPlaying {
                isPlaying = playing
                updateActivity()
            }
        }
        let video = engine.hasVideo()
        if video != hasVideo {
            hasVideo = video
        }
        if video, awaitingPicture {
            awaitingPicture = false
        }
        if pictureInPicture, !aspectLocked, let size = engine.videoSize() {
            PiPController.shared.setAspect(size)
            aspectLocked = true
        }
        if progressTick % 4 == 0 {
            storeProgress(force: false)
        }
    }

    private var progressTick: UInt = 0

    var currentPath: String? {
        guard let currentIndex, playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex].url.path
    }

    private func rebindCurrent(path: String?) {
        guard let path else { return }
        currentIndex = playlist.firstIndex { $0.url.path == path }
    }

    private func markCurrentFinished() {
        guard let path = currentPath else { return }
        var mark = progress[path] ?? WatchProgress(position: currentTime, duration: duration, finished: true)
        mark.finished = true
        if duration > 0 {
            mark.duration = duration
            mark.position = duration
        }
        progress[path] = mark
    }

    private func keepWindowFromVideoSize() {
        guard let saved = frameBeforePlay, let window = NSApp.mainWindow else { return }
        let grown = window.frame.width > saved.width + 24 || window.frame.height > saved.height + 24
        if grown {
            window.setFrame(saved, display: true, animate: false)
        }
        let token = saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.frameBeforePlay == token, let window = NSApp.mainWindow else { return }
            let stillGrown = window.frame.width > token.width + 24 || window.frame.height > token.height + 24
            if stillGrown {
                window.setFrame(token, display: true, animate: false)
            }
            self.frameBeforePlay = nil
        }
    }

    private func applyResume() {
        guard let resume, resume.generation == playGeneration else { return }
        engine?.setTime(resume.time)
        currentTime = resume.time
        let token = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, let still = self.resume, still.generation == token.generation else { return }
            self.engine?.setTime(still.time)
            self.currentTime = still.time
            self.resume = nil
        }
    }

    private func storeProgress(force: Bool) {
        guard mediaStarted, let path = currentPath else { return }
        var mark = progress[path] ?? WatchProgress(position: 0, duration: 0, finished: false)
        if duration > 0 { mark.duration = duration }
        mark.position = currentTime
        if mark.finished, duration > 0, currentTime < duration - 8 {
            mark.finished = false
        }
        let changed = progress[path] != mark
        if changed {
            progress[path] = mark
        }
        if force || (changed && abs(mark.position - lastStoredPosition) > 1) {
            lastStoredPosition = mark.position
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeLibrary()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var libraryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Lumiere", isDirectory: true).appendingPathComponent("library.json")
    }

    private struct LibrarySnapshot: Codable {
        var paths: [String]
        var currentPath: String?
        var progress: [String: WatchProgress]
    }

    private func loadLibrary() {
        let url = libraryURL
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else { return }
        progress = snapshot.progress
        playlist = snapshot.paths.map { MediaItem(url: URL(fileURLWithPath: $0)) }
        if let current = snapshot.currentPath,
           let index = playlist.firstIndex(where: { $0.url.path == current }) {
            currentIndex = index
            if let mark = progress[current] {
                currentTime = mark.finished ? 0 : mark.position
                duration = mark.duration
            }
        }
    }

    private func writeLibrary() {
        let snapshot = LibrarySnapshot(
            paths: playlist.map(\.url.path),
            currentPath: currentPath,
            progress: progress
        )
        let url = libraryURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Список останется в памяти до следующей попытки.
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

    private static func isPlaylistFile(_ url: URL) -> Bool {
        ["m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    /// Строки m3u — абсолютные или относительные пути к файлам. Комментарии и ссылки пропускаются.
    private static func readPlaylist(_ url: URL) -> [URL] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let base = url.deletingLastPathComponent()
        var files: [URL] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("http://") || line.hasPrefix("https://") { continue }
            if line.hasPrefix("file://"), let remote = URL(string: line), remote.isFileURL {
                files.append(remote)
            } else if line.hasPrefix("/") {
                files.append(URL(fileURLWithPath: line))
            } else {
                files.append(base.appendingPathComponent(line))
            }
        }
        return files
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
        var preserveOrder = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if Self.isPlaylistFile(url) {
                preserveOrder = true
                files.append(contentsOf: Self.readPlaylist(url).filter {
                    manager.fileExists(atPath: $0.path)
                })
                continue
            }
            if isDirectory.boolValue {
                files.append(contentsOf: filesInFolder(url))
            } else {
                files.append(url.standardizedFileURL)
            }
        }
        var seen = Set<String>()
        let unique = files.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        if preserveOrder { return unique }
        return unique.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func filesInFolder(_ url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let item as URL in enumerator {
            guard folderExtensions.contains(item.pathExtension.lowercased()) else { continue }
            files.append(item.standardizedFileURL)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
