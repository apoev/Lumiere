import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyAppearance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AppUpdate.shared.check(interactive: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerModel.current?.saveSession()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model = PlayerModel.current {
            model.acceptExternal(urls)
        } else {
            AppDelegate.pending.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LumiereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Одно окно: WindowGroup открывал новое на каждый файл из Finder.
        Window("Lumiere", id: "main") {
            PlayerScreen()
        }
        .defaultSize(width: 1180, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть файлы…") {
                    PlayerModel.current?.openFiles(replacing: true)
                }
                .keyboardShortcut("o")
                Button("Открыть папку…") {
                    PlayerModel.current?.openFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Добавить в плейлист…") {
                    PlayerModel.current?.openFiles(replacing: false)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") {
                    AppUpdate.shared.check(interactive: true)
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Плейлист") {
                    PlayerModel.current?.togglePlaylist()
                }
                .keyboardShortcut("l")
            }
            CommandMenu("Воспроизведение") {
                Button("Пауза / воспроизведение") {
                    PlayerModel.current?.togglePlay()
                }
                Button("Назад на 10 секунд") {
                    PlayerModel.current?.seek(by: -PlayerModel.skipSeconds)
                }
                Button("Вперёд на 10 секунд") {
                    PlayerModel.current?.seek(by: PlayerModel.skipSeconds)
                }
                Button("Следующий") {
                    PlayerModel.current?.next()
                }
                Divider()
                Button("Картинка в картинке") {
                    guard let model = PlayerModel.current else { return }
                    model.setPictureInPicture(!model.pictureInPicture)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
