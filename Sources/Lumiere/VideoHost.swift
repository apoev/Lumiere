import SwiftUI

struct VideoHost: NSViewRepresentable {
    @ObservedObject var model: PlayerModel

    func makeNSView(context: Context) -> HostView {
        HostView()
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        model.engine?.embedCanvas(in: nsView)
    }
}
