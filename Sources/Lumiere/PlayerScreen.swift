import AppKit
import SwiftUI

struct PlayerScreen: View {
    @StateObject private var model = PlayerModel()
    @State private var dropTargeted = false
    @State private var scrub = 0.0

    var body: some View {
        HStack(spacing: 0) {
            if model.showPlaylist {
                playlist
                    .frame(width: 300)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }
            stage
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Color.lumiereBg)
        .preferredColorScheme(.dark)
        .tint(Color.lumiereAccent)
        .onAppear {
            model.consumeLaunch()
        }
        .background(WindowTitle(title: model.currentTitle ?? "Lumiere"))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            model.takeDrop(providers)
            return true
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            if model.vlcMissing {
                missingVLC
            } else if model.pictureInPicture {
                pipPlaceholder
            } else {
                VideoHost(model: model)
                if model.currentIndex == nil {
                    emptyState
                } else {
                    if !model.hasVideo && model.duration > 0 {
                        audioState
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.togglePlay() }
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.lumiereAccent, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.lumiereAccent.opacity(0.12))
                    )
                    .padding(14)
                    .allowsHitTesting(false)
            }
            if !model.vlcMissing && !model.pictureInPicture {
                overlayChrome
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                model.pokeControls()
            }
        }
    }

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(model.controlsVisible || model.currentIndex == nil ? 1 : 0)
                .allowsHitTesting(model.controlsVisible || model.currentIndex == nil)
            Spacer(minLength: 0)
                .allowsHitTesting(false)
            if model.currentIndex != nil {
                transport
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .opacity(model.controlsVisible ? 1 : 0)
                    .allowsHitTesting(model.controlsVisible)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.controlsVisible)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentTitle ?? "Lumiere")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = model.status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.lumiereAccent)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 78)
            Spacer()
            Button {
                model.openFiles(replacing: true)
            } label: {
                Label("Открыть", systemImage: "folder")
            }
            .buttonStyle(ChromeButtonStyle())
            Button {
                model.openFolder()
            } label: {
                Label("Папка", systemImage: "folder.badge.plus")
            }
            .buttonStyle(ChromeButtonStyle())
        }
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(formatTime(model.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 64, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { model.isScrubbing ? scrub : fraction },
                        set: { newValue in
                            scrub = newValue
                            model.preview(fraction: newValue)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            scrub = fraction
                            model.isScrubbing = true
                        } else {
                            model.preview(fraction: scrub)
                            model.isScrubbing = false
                            model.pokeControls()
                        }
                    }
                )
                .disabled(model.duration <= 0)
                Text(formatTime(model.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 64, alignment: .trailing)
            }
            HStack(spacing: 6) {
                IconButton(system: "backward.end.fill", help: "Предыдущий") {
                    model.previous()
                }
                IconButton(system: "gobackward.10", help: "Назад на 10 секунд", size: 20) {
                    model.seek(by: -PlayerModel.skipSeconds)
                }
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.lumiereAccent))
                        .foregroundStyle(Color.black.opacity(0.88))
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "Пауза" : "Воспроизвести")
                IconButton(system: "goforward.10", help: "Вперёд на 10 секунд", size: 20) {
                    model.seek(by: PlayerModel.skipSeconds)
                }
                IconButton(system: "forward.end.fill", help: "Следующий") {
                    model.next()
                }
                Spacer(minLength: 8)
                speedMenu
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Звук")
                Slider(
                    value: Binding(
                        get: { Double(model.volume) },
                        set: { model.setVolume(Int($0.rounded())) }
                    ),
                    in: 0...100
                )
                .frame(width: 88)
                .controlSize(.small)
                IconButton(
                    system: model.pictureInPicture ? "pip.exit" : "pip.enter",
                    help: "Картинка в картинке"
                ) {
                    model.setPictureInPicture(!model.pictureInPicture)
                }
                IconButton(system: "arrow.up.left.and.arrow.down.right", help: "На весь экран") {
                    model.toggleFullscreen()
                }
                IconButton(system: "list.bullet", help: "Плейлист") {
                    model.togglePlaylist()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlayerModel.rates, id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    if abs(model.rate - rate) < 0.01 {
                        Label(formatRate(rate), systemImage: "checkmark")
                    } else {
                        Text(formatRate(rate))
                    }
                }
            }
        } label: {
            Text(formatRate(model.rate))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(minWidth: 52)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 72)
        .help("Скорость")
    }

    private var playlist: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Плейлист")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(model.playlist.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    model.openFiles(replacing: false)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Добавить файлы")
                Button {
                    model.clearPlaylist()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(model.playlist.isEmpty)
                .help("Очистить")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .foregroundStyle(.white.opacity(0.9))

            if model.playlist.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.lumiereAccent.opacity(0.8))
                    Text("Пока пусто")
                        .font(.system(size: 13, weight: .medium))
                    Text("Откройте файлы или перетащите их в окно.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.playlist.enumerated()), id: \.element.id) { index, item in
                                playlistRow(index: index, item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: model.currentIndex) { _, index in
                        guard let index, model.playlist.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(model.playlist[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color.lumiereBg.opacity(0.96))
    }

    private func playlistRow(index: Int, item: MediaItem) -> some View {
        PlaylistRow(
            title: item.title,
            path: item.url.path,
            isCurrent: index == model.currentIndex,
            isPlaying: index == model.currentIndex && model.isPlaying
        ) {
            model.play(index: index)
        } onRemove: {
            model.remove(at: index)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            bundleIcon
                .frame(width: 92, height: 92)
                .shadow(color: Color.lumiereAccent.opacity(0.45), radius: 24)
            Text("Перетащите видео сюда")
                .font(.system(size: 20, weight: .semibold))
            Text("Пробел — пауза, стрелки — 10 секунд, P — картинка в картинке, [ ] — скорость.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Открыть файлы") { model.openFiles(replacing: true) }
                    .buttonStyle(AccentButtonStyle())
                Button("Открыть папку") { model.openFolder() }
                    .buttonStyle(ChromeButtonStyle())
            }
        }
        .padding(32)
        .allowsHitTesting(true)
    }

    private var audioState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.lumiereAccent)
            Text(model.currentTitle ?? "")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .allowsHitTesting(false)
    }

    private var pipPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.lumiereAccent)
            Text("Смотрите в окне «Картинка в картинке»")
                .font(.system(size: 16, weight: .semibold))
            Text(model.currentTitle ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Button("Вернуть в окно") {
                model.setPictureInPicture(false)
            }
            .buttonStyle(AccentButtonStyle())
        }
    }

    private var missingVLC: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Color.lumiereAccent)
            Text("Нужен установленный VLC")
                .font(.system(size: 18, weight: .semibold))
            Text("Lumiere не копирует кодеки: воспроизведение идёт через libvlc из VLC.app.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    @ViewBuilder
    private var bundleIcon: some View {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.lumiereAccent)
        }
    }

    private var fraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }
}

struct PiPOverlay: View {
    @ObservedObject var model: PlayerModel
    @State private var scrub = 0.0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            VideoHost(model: model)
            if !model.hasVideo, model.currentIndex != nil {
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.lumiereAccent)
                    .padding(.bottom, 64)
            }
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { model.isScrubbing ? scrub : fraction },
                        set: { newValue in
                            scrub = newValue
                            model.preview(fraction: newValue)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            scrub = fraction
                            model.isScrubbing = true
                        } else {
                            model.preview(fraction: scrub)
                            model.isScrubbing = false
                        }
                    }
                )
                .disabled(model.duration <= 0)
                HStack(spacing: 4) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.seek(by: -PlayerModel.skipSeconds)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Назад на 10 секунд")
                    Button {
                        model.seek(by: PlayerModel.skipSeconds)
                    } label: {
                        Image(systemName: "goforward.10")
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Вперёд на 10 секунд")
                    Menu {
                        ForEach(PlayerModel.rates, id: \.self) { rate in
                            Button(formatRate(rate)) { model.setRate(rate) }
                        }
                    } label: {
                        Text(formatRate(model.rate))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(minWidth: 44)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 64)
                    .help("Скорость")
                    Text(formatTime(model.currentTime))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 4)
                    Button {
                        model.setPictureInPicture(false)
                    } label: {
                        Image(systemName: "pip.exit")
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Вернуть в окно")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Color.black.opacity(0.62))
        }
        .padding(.top, 18)
    }

    private var fraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }
}

private struct PlaylistRow: View {
    var title: String
    var path: String
    var isCurrent: Bool
    var isPlaying: Bool
    var onPlay: () -> Void
    var onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "pause.fill") : "film")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? Color.lumiereAccent : Color.white.opacity(0.35))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.82))
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 0.8 : 0)
            .help("Убрать из плейлиста")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.lumiereAccent.opacity(0.2) : Color.white.opacity(hover ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hover = $0 }
        .help(path)
    }
}

private struct IconButton: View {
    var system: String
    var help: String
    var size: CGFloat = 14
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1))
            )
            .foregroundStyle(.white)
    }
}

private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.lumiereAccent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .foregroundStyle(Color.black.opacity(0.88))
    }
}

private struct WindowTitle: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = title
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let secs = total % 60
    let mins = (total / 60) % 60
    let hours = total / 3600
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, mins, secs)
    }
    return String(format: "%d:%02d", mins, secs)
}

func formatRate(_ rate: Float) -> String {
    let scaled = Int((rate * 100).rounded())
    let whole = scaled / 100
    let frac = scaled % 100
    if frac == 0 { return "\(whole)×" }
    if frac % 10 == 0 { return "\(whole),\(frac / 10)×" }
    return String(format: "%d,%02d×", whole, frac)
}

extension Color {
    static let lumiereBg = Color(red: 0.035, green: 0.027, blue: 0.075)
    static let lumiereAccent = Color(red: 0.74, green: 0.58, blue: 1.0)
}
