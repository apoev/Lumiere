import AppKit
import Clibvlc
import Foundation

enum VLCLocator {
    static func pluginPath() -> String? {
        for bundle in candidateBundles() {
            let plugins = bundle.appendingPathComponent("Contents/MacOS/plugins").path
            let library = bundle.appendingPathComponent("Contents/MacOS/lib/libvlc.dylib").path
            if FileManager.default.fileExists(atPath: plugins),
               FileManager.default.fileExists(atPath: library) {
                return plugins
            }
        }
        return nil
    }

    private static func candidateBundles() -> [URL] {
        var urls: [URL] = []
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") {
            urls.append(installed)
        }
        urls.append(URL(fileURLWithPath: "/Applications/VLC.app"))
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/VLC.app"))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}

enum EngineEvent {
    case ended
    case failed
    case playing
    case paused
    case stopped
}

/// Видео живёт в одном NSView и переезжает между основным окном и картинкой в картинке.
final class VideoCanvas: NSView {
    var onAttach: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        autoresizesSubviews = true
        relax(self)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        relax(subview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relaxMainWindow()
        if window != nil {
            onAttach?()
        }
    }

    override func layout() {
        super.layout()
        for subview in subviews {
            relax(subview)
            subview.frame = bounds
        }
        relaxMainWindow()
    }

    // Клики забирает SwiftUI поверх видео, а окно картинки в картинке можно тащить за фон.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// VLC подгоняет окно под размер кадра. Сбрасываем это, чтобы окно сжималось меньше видео.
    private func relaxMainWindow() {
        guard let window, window.identifier?.rawValue != PiPController.windowID else { return }
        if window.contentAspectRatio != .zero {
            window.contentAspectRatio = .zero
        }
        let cap = NSSize(width: 520, height: 360)
        if window.contentMinSize.width > cap.width || window.contentMinSize.height > cap.height {
            window.contentMinSize = NSSize(width: 360, height: 220)
        }
    }

    private func relax(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
}

final class HostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// Тонкая обёртка libvlc. Плагины остаются в VLC.app — приложение их не копирует.
final class VLCEngine {
    let canvas = VideoCanvas()
    private let instance: OpaquePointer
    private let player: OpaquePointer
    private var callbackToken: UnsafeMutableRawPointer?
    var onEvent: ((EngineEvent) -> Void)?

    init?(pluginPath: String) {
        signal(SIGPIPE, SIG_IGN)
        // В этой сборке VLC ключ --plugin-path удалён и роняет libvlc_new.
        setenv("VLC_PLUGIN_PATH", pluginPath, 1)
        let args = ["--quiet", "--ignore-config", "--no-video-title-show", "--vout=macosx"]
        let cargs = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        let pointers = cargs.map { UnsafePointer($0) }
        guard let instance = pointers.withUnsafeBufferPointer({ buffer in
            libvlc_new(Int32(buffer.count), buffer.baseAddress)
        }) else {
            return nil
        }
        guard let player = libvlc_media_player_new(instance) else {
            libvlc_release(instance)
            return nil
        }
        self.instance = instance
        self.player = player
        canvas.onAttach = { [weak self] in
            self?.attachDrawable()
        }
        let token = Unmanaged.passUnretained(self).toOpaque()
        callbackToken = token
        if let manager = libvlc_media_player_event_manager(player) {
            let types: [libvlc_event_type_t] = [
                eventCode(libvlc_MediaPlayerEndReached),
                eventCode(libvlc_MediaPlayerEncounteredError),
                eventCode(libvlc_MediaPlayerPlaying),
                eventCode(libvlc_MediaPlayerPaused),
                eventCode(libvlc_MediaPlayerStopped)
            ]
            for type in types {
                libvlc_event_attach(manager, type, vlcEventCallback, token)
            }
        }
    }

    func embedCanvas(in host: NSView) {
        host.autoresizesSubviews = true
        if canvas.superview !== host {
            canvas.removeFromSuperview()
            canvas.frame = host.bounds
            canvas.autoresizingMask = [.width, .height]
            host.addSubview(canvas)
            attachDrawable()
        } else if canvas.frame != host.bounds {
            canvas.frame = host.bounds
        }
    }

    func attachDrawable() {
        guard canvas.window != nil else { return }
        libvlc_media_player_set_nsobject(player, Unmanaged.passUnretained(canvas).toOpaque())
    }

    /// Убирает последний кадр. Иначе при смене ролика или битом файле на экране остаётся прошлая картинка.
    func clearPicture() {
        libvlc_media_player_set_nsobject(player, nil)
        libvlc_media_player_stop(player)
        for subview in canvas.subviews {
            subview.removeFromSuperview()
        }
    }

    func play(url: URL) {
        clearPicture()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        attachDrawable()
        url.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return }
            guard let media = libvlc_media_new_path(instance, representation) else { return }
            libvlc_media_player_set_media(player, media)
            libvlc_media_release(media)
            libvlc_media_player_play(player)
        }
    }

    func togglePause() {
        libvlc_media_player_pause(player)
    }

    func pause() {
        libvlc_media_player_set_pause(player, 1)
    }

    func setRate(_ rate: Float) {
        libvlc_media_player_set_rate(player, rate)
    }

    func setVolume(_ volume: Int) {
        libvlc_audio_set_volume(player, Int32(volume))
    }

    func setMuted(_ muted: Bool) {
        libvlc_audio_set_mute(player, muted ? 1 : 0)
    }

    func setTime(_ seconds: Double) {
        let milliseconds = libvlc_time_t(max(0, seconds) * 1000)
        libvlc_media_player_set_time(player, milliseconds)
    }

    func time() -> Double {
        let value = libvlc_media_player_get_time(player)
        guard value >= 0 else { return 0 }
        return Double(value) / 1000
    }

    func length() -> Double {
        let value = libvlc_media_player_get_length(player)
        guard value > 0 else { return 0 }
        return Double(value) / 1000
    }

    func isPlaying() -> Bool {
        libvlc_media_player_is_playing(player) == 1
    }

    func hasVideo() -> Bool {
        libvlc_media_player_has_vout(player) > 0
    }

    func videoSize() -> NSSize? {
        var width: UInt32 = 0
        var height: UInt32 = 0
        guard libvlc_video_get_size(player, 0, &width, &height) == 0, width > 0, height > 0 else {
            return nil
        }
        return NSSize(width: CGFloat(width), height: CGFloat(height))
    }

    func handle(eventType: Int32) {
        let event: EngineEvent?
        switch eventType {
        case eventCode(libvlc_MediaPlayerEndReached):
            event = .ended
        case eventCode(libvlc_MediaPlayerEncounteredError):
            event = .failed
        case eventCode(libvlc_MediaPlayerPlaying):
            event = .playing
        case eventCode(libvlc_MediaPlayerPaused):
            event = .paused
        case eventCode(libvlc_MediaPlayerStopped):
            event = .stopped
        default:
            event = nil
        }
        guard let event else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}

private func eventCode(_ type: libvlc_event_e) -> libvlc_event_type_t {
    libvlc_event_type_t(type.rawValue)
}

private let vlcEventCallback: libvlc_callback_t = { event, data in
    guard let event, let data else { return }
    let engine = Unmanaged<VLCEngine>.fromOpaque(data).takeUnretainedValue()
    engine.handle(eventType: event.pointee.type)
}
