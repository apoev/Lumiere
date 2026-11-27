import AppKit
import SwiftUI

struct PlayerScreen: View {
    @StateObject private var model = PlayerModel()
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTargeted = false
    @State private var scrub = 0.0
    @State private var draggingTimeline = false

    var body: some View {
        HStack(spacing: 0) {
            if model.showPlaylist {
                playlist
                    .frame(width: PlayerModel.playlistColumnWidth)
                Rectangle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
                    .frame(width: 1)
            }
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 360, minHeight: 220)
        .background(colorScheme == .dark ? Color.lumiereBg : Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.theme.colorScheme)
        .tint(Color.lumiereAccent)
        .animation(.easeInOut(duration: 0.18), value: model.showPlaylist)
        .onAppear {
            settings.applyAppearance()
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
                    if !model.hasVideo, !model.awaitingPicture, model.duration > 0 {
                        audioState
                    }
                    StageClicks(
                        onSingle: {
                            model.flashCue(model.isPlaying ? .pause : .play)
                            model.togglePlay(announce: false)
                        },
                        onDouble: {
                            // Первый щелчок уже переключил воспроизведение.
                            model.dismissCue()
                            model.togglePlay(announce: false)
                            model.toggleFullscreen()
                        }
                    )
                    .padding(.top, 28)
                    .padding(.bottom, 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let cue = model.playbackCue, !model.pictureInPicture {
                PlaybackCueOverlay(cue: cue)
                    .id(cue.token)
            }
            CornerReadoutBadge(model: model)
                .padding(.top, 12)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            if case .active = phase {
                model.pokeControls()
            }
        }
        .environment(\.colorScheme, .dark)
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
                        get: { draggingTimeline ? scrub : fraction },
                        set: { newValue in
                            scrub = newValue
                            model.preview(fraction: newValue)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        draggingTimeline = editing
                        if editing {
                            scrub = fraction
                            model.beginScrub()
                        } else {
                            model.preview(fraction: scrub)
                            model.endScrub()
                            model.pokeControls()
                        }
                    }
                )
                .disabled(model.duration <= 0)
                Text(remainingTime)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 72, alignment: .trailing)
            }
            GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                IconButton(system: "backward.end.fill", help: "Предыдущий", enabled: model.canPlayPrevious) {
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
                IconButton(system: "forward.end.fill", help: "Следующий", enabled: model.canPlayNext) {
                    model.next()
                }
                QuickRateButtons(model: model)
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
            .frame(minWidth: geo.size.width, alignment: .center)
            }
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var playlist: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(model.playlist.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(playlistSecondary)
                Spacer(minLength: 4)
                Button {
                    model.sortPlaylist(ascending: true)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(model.playlist.count < 2)
                .help("По возрастанию")
                Button {
                    model.sortPlaylist(ascending: false)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(model.playlist.count < 2)
                .help("По убыванию")
                Button {
                    model.openFiles(replacing: false)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Добавить файлы")
                Button {
                    model.openFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Добавить папку")
                Button {
                    model.removeMissing()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .disabled(model.missingPaths.isEmpty)
                .help("Удалить отсутствующие")
                Button {
                    model.clearPlaylist()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(model.playlist.isEmpty)
                .help("Очистить")
                Button {
                    model.togglePlaylist()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("Свернуть плейлист")
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .foregroundStyle(playlistPrimary)
            .onAppear { model.refreshMissing() }

            if model.playlist.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.lumiereAccent.opacity(0.8))
                    Text("Пока пусто")
                        .font(.system(size: 13, weight: .medium))
                    Text("Добавьте файлы кнопкой сверху или перетащите их в окно.")
                        .font(.system(size: 12))
                        .foregroundStyle(playlistSecondary)
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
        .background(colorScheme == .dark ? Color.lumiereBg.opacity(0.96) : Color(nsColor: .windowBackgroundColor))
    }

    private var playlistPrimary: Color {
        colorScheme == .dark ? .white : Color(red: 0.12, green: 0.11, blue: 0.16)
    }

    private var playlistSecondary: Color {
        playlistPrimary.opacity(0.5)
    }

    private func playlistRow(index: Int, item: MediaItem) -> some View {
        PlaylistRow(
            title: item.title,
            path: item.url.path,
            isCurrent: index == model.currentIndex,
            isPlaying: index == model.currentIndex && model.isPlaying,
            fraction: model.watchedFraction(for: item.url),
            missing: model.missingPaths.contains(item.url.path)
        ) {
            model.play(index: index)
        } onReveal: {
            model.revealInFinder(item.url)
        } onRemove: {
            model.remove(at: index)
        } onDrag: {
            model.beginDrag(item.id)
        } onDrop: {
            model.dropDraggedItem(before: item.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            bundleIcon
                .frame(width: 92, height: 92)
                .shadow(color: Color.lumiereAccent.opacity(0.45), radius: 24)
            Text("Перетащите видео сюда")
                .font(.system(size: 20, weight: .semibold))
            Text("Двойной щелчок — на весь экран. Свайп вправо — перемотка, вверх — громче. Пробел — пауза, стрелки — 10 секунд.")
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

    private var remainingTime: String {
        guard model.duration > 0 else { return "0:00" }
        return "-" + formatTime(max(0, model.duration - model.currentTime))
    }
}

struct PiPOverlay: View {
    @ObservedObject var model: PlayerModel
    @State private var scrub = 0.0
    @State private var draggingTimeline = false
    @State private var pointerInside = false

    private var showChrome: Bool {
        pointerInside || draggingTimeline
    }

    var body: some View {
        ZStack {
            Color.black
            VideoHost(model: model)
            PiPDragSurface { inside in
                pointerInside = inside
            }
            if !model.hasVideo, !model.awaitingPicture, model.currentIndex != nil {
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.lumiereAccent)
            }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        model.setPictureInPicture(false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help("Закрыть")
                }
                .padding(10)
                Spacer(minLength: 0)
                controls
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .opacity(showChrome ? 1 : 0)
            .allowsHitTesting(showChrome)
            .animation(.easeInOut(duration: 0.16), value: showChrome)
            if let cue = model.playbackCue {
                PlaybackCueOverlay(cue: cue)
                    .id(cue.token)
            }
            CornerReadoutBadge(model: model)
                .padding(.top, 12)
                .padding(.trailing, 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { draggingTimeline ? scrub : fraction },
                    set: { newValue in
                        scrub = newValue
                        model.preview(fraction: newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    draggingTimeline = editing
                    if editing {
                        scrub = fraction
                        model.beginScrub()
                    } else {
                        model.preview(fraction: scrub)
                        model.endScrub()
                    }
                }
            )
            .disabled(model.duration <= 0)
            .tint(Color.lumiereAccent)
            HStack(spacing: 4) {
                Button {
                    model.playAdjacent(-1)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(!model.canPlayPrevious)
                .help("Предыдущее видео")
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                Button {
                    model.playAdjacent(1)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(!model.canPlayNext)
                .help("Следующее видео")
                Button {
                    model.seek(by: -PlayerModel.skipSeconds)
                } label: {
                    Image(systemName: "gobackward.10")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("Назад на 10 секунд")
                Button {
                    model.seek(by: PlayerModel.skipSeconds)
                } label: {
                    Image(systemName: "goforward.10")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("Вперёд на 10 секунд")
                QuickRateButtons(model: model)
                Text(formatTime(model.currentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Button {
                    model.setPictureInPicture(false)
                } label: {
                    Image(systemName: "pip.exit")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("Вернуть в окно")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var fraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }
}

private struct CornerReadoutBadge: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Group {
            if let readout = model.cornerReadout {
                Text(label(readout))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Color.black.opacity(0.62)))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.cornerReadout)
    }

    private func label(_ readout: CornerReadout) -> String {
        switch readout {
        case .time:
            return formatTime(model.currentTime)
        case .volume:
            return model.muted || model.volume == 0 ? "0%" : "\(model.volume)%"
        }
    }
}

private struct PlaybackCueOverlay: View {
    var cue: PlaybackCue
    @State private var expand = false
    @State private var fade = false

    var body: some View {
        Image(systemName: cue.symbol)
            .font(.system(size: 45, weight: .semibold))
            .foregroundStyle(.white)
            .offset(x: cue.kind == .play ? 3 : 0)
            .frame(width: 111, height: 111)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .scaleEffect(expand ? 1.55 : 0.82)
            .opacity(fade ? 0 : 1)
            .onAppear {
                withAnimation(.linear(duration: 0.32)) {
                    expand = true
                }
                withAnimation(.easeIn(duration: 0.2).delay(0.08)) {
                    fade = true
                }
            }
            .allowsHitTesting(false)
    }
}

/// Щелчок обрабатывается сразу: жест SwiftUI ждёт, не будет ли это двойной клик.
private struct StageClicks: NSViewRepresentable {
    var onSingle: () -> Void
    var onDouble: () -> Void

    func makeNSView(context: Context) -> StageClickView {
        let view = StageClickView()
        view.onSingle = onSingle
        view.onDouble = onDouble
        return view
    }

    func updateNSView(_ view: StageClickView, context: Context) {
        view.onSingle = onSingle
        view.onDouble = onDouble
    }
}

final class StageClickView: NSView {
    var onSingle: (() -> Void)?
    var onDouble: (() -> Void)?
    private static var lastSingle = 0.0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDouble?()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Повторная доставка того же щелчка не должна переключать воспроизведение несколько раз.
        if now - Self.lastSingle < 0.28 { return }
        Self.lastSingle = now
        onSingle?()
    }
}

private struct PlaylistRow: View {
    var title: String
    var path: String
    var isCurrent: Bool
    var isPlaying: Bool
    var fraction: Double
    var missing: Bool
    var onPlay: () -> Void
    var onReveal: () -> Void
    var onRemove: () -> Void
    var onDrag: () -> Void
    var onDrop: () -> Void
    @State private var hover = false
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(primary.opacity(hover ? 0.55 : 0.28))
                    .frame(width: 12)
                Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "pause.fill") : "film")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.lumiereAccent : primary.opacity(0.4))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(primary.opacity(isCurrent ? 1 : 0.82))
                Spacer(minLength: 4)
                if missing {
                    BrokenFolderMark()
                        .foregroundStyle(primary)
                        .help("Файла нет на диске")
                } else {
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .opacity(hover ? 0.9 : 0.45)
                    .help("Показать в Finder")
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .opacity(hover ? 0.8 : 0)
                .help("Убрать из плейлиста")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(primary.opacity(0.12))
                    Capsule()
                        .fill(fraction >= 0.97 ? Color.lumiereAccent : Color.lumiereAccent.opacity(0.85))
                        .frame(width: max(0, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 3)
            .padding(.leading, 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.lumiereAccent.opacity(dropTargeted ? 0.8 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hover = $0 }
        .onDrag {
            onDrag()
            return NSItemProvider(object: path as NSString)
        }
        .onDrop(of: [.plainText, .fileURL], isTargeted: $dropTargeted) { _ in
            onDrop()
            return true
        }
        .opacity(missing ? 0.4 : 1)
        .help(missing ? "Файла нет на диске" : path)
    }

    private var primary: Color {
        colorScheme == .dark ? .white : Color(red: 0.12, green: 0.11, blue: 0.16)
    }

    private var rowFill: Color {
        if isCurrent { return Color.lumiereAccent.opacity(colorScheme == .dark ? 0.22 : 0.16) }
        if hover || dropTargeted { return primary.opacity(0.06) }
        return .clear
    }
}

private struct QuickRateButtons: View {
    @ObservedObject var model: PlayerModel

    private var showsCustomRate: Bool {
        !PlayerModel.quickRates.contains { abs(model.rate - $0) < 0.01 }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlayerModel.quickRates, id: \.self) { rate in
                let selected = abs(model.rate - rate) < 0.01
                Button {
                    model.setRate(rate)
                } label: {
                    Text(formatRate(rate))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.black.opacity(0.88) : .white)
                        .padding(.horizontal, 7)
                        .frame(height: 26)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? Color.lumiereAccent : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .help(formatRate(rate))
            }
            UpwardSpeedMenu(rate: model.rate, showsRate: showsCustomRate) { rate in
                model.setRate(rate)
            }
            .frame(width: showsCustomRate ? 52 : 26, height: 26)
            .help("Все скорости")
        }
    }
}

/// Меню скорости открывается вверх: панель стоит у нижнего края, вниз оно наезжает на кадр.
private struct UpwardSpeedMenu: NSViewRepresentable {
    var rate: Float
    var showsRate: Bool
    var onPick: (Float) -> Void

    func makeNSView(context: Context) -> SpeedMenuButton {
        let button = SpeedMenuButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        button.onPick = onPick
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: SpeedMenuButton, context: Context) {
        button.onPick = onPick
        button.rate = rate
        button.showsRate = showsRate
        button.needsDisplay = true
    }
}

final class SpeedMenuButton: NSView {
    var rate: Float = 1 {
        didSet { needsDisplay = true }
    }
    var showsRate = true {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var onPick: ((Float) -> Void)?

    override var isFlipped: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: showsRate ? 52 : 26, height: 26)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for value in PlayerModel.rates {
            let item = NSMenuItem(title: formatRate(value), action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.state = abs(value - rate) < 0.01 ? .on : .off
            item.representedObject = NSNumber(value: value)
            menu.addItem(item)
        }
        guard let bottom = menu.items.last else { return }
        menu.popUp(positioning: bottom, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.12).setFill()
        capsule.fill()

        let quick = PlayerModel.quickRates.contains { abs(rate - $0) < 0.01 }
        if showsRate || !quick {
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 12) ?? font
            let text = formatRate(rate) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: rounded,
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(
                in: NSRect(
                    x: (bounds.width - size.width) / 2,
                    y: (bounds.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                ),
                withAttributes: attrs
            )
            return
        }

        let chevron = NSBezierPath()
        let midX = bounds.midX
        let midY = bounds.midY - 0.5
        chevron.move(to: NSPoint(x: midX - 4.5, y: midY - 1.5))
        chevron.line(to: NSPoint(x: midX, y: midY + 2.5))
        chevron.line(to: NSPoint(x: midX + 4.5, y: midY - 1.5))
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.white.setStroke()
        chevron.stroke()
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onPick?(number.floatValue)
    }
}

private struct BrokenFolderMark: View {
    var body: some View {
        ZStack {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .semibold))
                .overlay {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: geo.size.width * 0.66, height: geo.size.height * 0.12)
                            .position(x: geo.size.width * 0.5, y: geo.size.height * 0.395)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            Image(systemName: "xmark")
                .font(.system(size: 6.5, weight: .bold))
                .offset(x: 0.5)
        }
        .frame(width: 20, height: 20)
    }
}

private struct IconButton: View {
    var system: String
    var help: String
    var size: CGFloat = 14
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
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
