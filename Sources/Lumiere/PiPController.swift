import AppKit
import SwiftUI

final class PiPController: NSObject, NSWindowDelegate {
    static let shared = PiPController()
    static let windowID = "lumiere.pip"

    private var panel: NSPanel?
    private weak var model: PlayerModel?

    func show(model: PlayerModel) {
        self.model = model
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        if let size = model.engine?.videoSize(), size.height > 40 {
            panel.contentAspectRatio = size
        }
        panel.orderFrontRegardless()
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
    }

    func setAspect(_ size: NSSize) {
        guard size.width > 1, size.height > 1 else { return }
        panel?.contentAspectRatio = size
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model?.notePictureInPictureClosed()
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

/// Без заголовка системные кнопки не рисуются, поэтому окно тащим за само видео.
final class PiPDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct PiPDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PiPDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
