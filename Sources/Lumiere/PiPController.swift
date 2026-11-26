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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        panel.title = "Lumiere"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
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

        let host = NSHostingView(rootView: PiPOverlay(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
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
