import AppKit
import SwiftUI

final class PiPController: NSObject, NSWindowDelegate {
    static let shared = PiPController()
    static let windowID = "lumiere.pip"

    private var panel: NSPanel?
    private weak var model: PlayerModel?
    private weak var playerWindow: NSWindow?
    private var restoredFrame: NSRect?
    private var lastPipFrame: NSRect?
    private var fullscreenObserver: NSObjectProtocol?
    private var returnObserver: NSObjectProtocol?
    private var transitioning = false
    /// Одинаковая скорость свёртки в угол и возврата в большое окно.
    private let travelDuration: TimeInterval = 0.22

    /// Маленькое окно уезжает в угол. Большое сворачивается в Dock без анимации.
    func enter(model: PlayerModel, reveal: @escaping () -> Void) {
        guard !transitioning else { return }
        transitioning = true
        self.model = model
        guard let window = playerWindow(preferring: NSApp.mainWindow) else {
            transitioning = false
            reveal()
            present(at: defaultPipFrame(on: nil))
            return
        }
        if window.styleMask.contains(.fullScreen) {
            fullscreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.clearFullscreenObserver()
                self?.shrink(window, reveal: reveal)
            }
            window.toggleFullScreen(nil)
            return
        }
        shrink(window, reveal: reveal)
    }

    /// Маленькое окно возвращается на место большого, Dock при этом не анимируется.
    func leave(restore: @escaping () -> Void) {
        guard !transitioning else { return }
        let window = playerWindow(preferring: playerWindow)
        let destination = restoredFrame ?? window?.frame
        guard let window, let destination else {
            restore()
            dismissPanel()
            return
        }
        transitioning = true
        if let panel {
            // Кадр ещё маленький. После анимации возврата он совпадёт с большим окном, его запоминать нельзя.
            lastPipFrame = panel.frame
        }
        let finish = { [weak self] in
            guard let self else { return }
            self.revealMain(window, at: destination) {
                restore()
                self.dismissPanel()
                self.transitioning = false
            }
        }
        guard let panel else {
            finish()
            return
        }
        panel.contentAspectRatio = .zero
        animate(panel, to: destination, duration: travelDuration, timing: .easeOut, completion: finish)
    }

    func setAspect(_ size: NSSize) {
        guard size.width > 1, size.height > 1 else { return }
        panel?.contentAspectRatio = size
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model?.notePictureInPictureClosed()
    }

    private func shrink(_ window: NSWindow, reveal: @escaping () -> Void) {
        transitioning = true
        playerWindow = window
        restoredFrame = window.frame
        let target = pipTarget(for: window)
        lastPipFrame = target
        let start = window.frame
        reveal()
        DispatchQueue.main.async { [weak self] in
            window.animationBehavior = .none
            window.alphaValue = 0
            self?.present(at: start, then: target) {
                self?.miniaturizeInstantly(window)
            }
        }
    }

    /// Прозрачное окно уходит в Dock уже после сжатия панели, без жеста «джинна».
    private func miniaturizeInstantly(_ window: NSWindow) {
        guard !window.isMiniaturized else { return }
        window.animationBehavior = .none
        window.alphaValue = 0
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { _ in
            window.animationBehavior = .default
            window.alphaValue = 0
            if let token = box.token {
                NotificationCenter.default.removeObserver(token)
                box.token = nil
            }
        }
        window.miniaturize(nil)
    }

    private func revealMain(_ window: NSWindow, at frame: NSRect, done: @escaping () -> Void) {
        let show = {
            window.setFrame(frame, display: true)
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            done()
        }
        guard window.isMiniaturized else {
            show()
            return
        }
        window.animationBehavior = .none
        window.alphaValue = 0
        clearReturnObserver()
        returnObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.clearReturnObserver()
            window.animationBehavior = .default
            show()
        }
        window.deminiaturize(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard self?.returnObserver != nil else { return }
            self?.clearReturnObserver()
            window.animationBehavior = .default
            show()
        }
    }

    private func present(at frame: NSRect, then target: NSRect? = nil, done: @escaping () -> Void = {}) {
        guard let model else { return }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        panel.contentAspectRatio = .zero
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard let target, target != frame else {
            transitioning = false
            done()
            return
        }
        // Кадр старта нужно показать отдельно, иначе оба размера схлопываются в скачок.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else {
                done()
                return
            }
            self.animate(panel, to: target, duration: self.travelDuration, timing: .easeOut) {
                if let size = model.engine?.videoSize(), size.width > 40, size.height > 40 {
                    panel.contentAspectRatio = size
                }
                self.transitioning = false
                done()
            }
        }
    }

    private func animate(
        _ panel: NSPanel,
        to frame: NSRect,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        completion: @escaping () -> Void
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            completion()
        }
    }

    private func dismissPanel() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
    }

    /// Позиция картинки годится, только если это всё ещё маленькое окно, а не развёрнутое основное.
    private func pipTarget(for window: NSWindow) -> NSRect {
        let full = window.frame
        if let saved = lastPipFrame,
           saved.width < full.width * 0.92,
           saved.height < full.height * 0.92 {
            return saved
        }
        return defaultPipFrame(on: window)
    }

    private func defaultPipFrame(on window: NSWindow?) -> NSRect {
        let video = model?.engine?.videoSize()
        let aspect = (video?.width ?? 16) / max(video?.height ?? 9, 1)
        let width: CGFloat = 460
        let height = max(200, width / aspect)
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: screen.maxX - width - 28,
            y: screen.minY + 28,
            width: width,
            height: height
        )
    }

    private func playerWindow(preferring preferred: NSWindow?) -> NSWindow? {
        if let preferred, preferred.identifier?.rawValue != Self.windowID {
            return preferred
        }
        if let playerWindow, playerWindow.identifier?.rawValue != Self.windowID {
            return playerWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == "main"
        } ?? NSApp.windows.first {
            $0.identifier?.rawValue != Self.windowID && !($0 is NSPanel)
        }
    }

    private func clearFullscreenObserver() {
        if let fullscreenObserver {
            NotificationCenter.default.removeObserver(fullscreenObserver)
            self.fullscreenObserver = nil
        }
    }

    private func clearReturnObserver() {
        if let returnObserver {
            NotificationCenter.default.removeObserver(returnObserver)
            self.returnObserver = nil
        }
    }

    private func makePanel(model: PlayerModel) -> NSPanel {
        let size = NSSize(width: 480, height: 300)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        panel.title = "Lumiere"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 320, height: 200)
        panel.delegate = self

        let host = PiPHostingView(rootView: PiPOverlay(model: model))
        host.roundCorners()
        panel.contentView = host

        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(
                NSRect(
                    x: screen.maxX - size.width - 28,
                    y: screen.minY + 28,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
        }
        return panel
    }
}

private final class ObserverBox {
    var token: NSObjectProtocol?
}

/// Без заголовка системные кнопки не рисуются, поэтому окно тащим за само видео.
final class PiPDragView: NSView {
    var onHover: ((Bool) -> Void)?
    private var inside = false

    override func layout() {
        super.layout()
        syncHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // activeAlways: панель не становится ключевым окном, а панель всё равно должна реагировать на курсор.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        syncHover()
    }

    override func mouseEntered(with event: NSEvent) {
        setInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setInside(false)
    }

    private func syncHover() {
        guard let window else { return }
        setInside(bounds.contains(window.mouseLocationOutsideOfEventStream))
    }

    private func setInside(_ now: Bool) {
        guard now != inside else { return }
        inside = now
        onHover?(now)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct PiPDragSurface: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PiPDragView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PiPDragView)?.onHover = onHover
    }
}

final class PiPHostingView: NSHostingView<PiPOverlay> {
    func roundCorners() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func layout() {
        super.layout()
        roundCorners()
        window?.invalidateShadow()
    }
}
