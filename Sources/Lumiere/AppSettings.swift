import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AssociationKind: Identifiable, Equatable {
    let id: String
    let title: String
    var isDefault: Bool
    var handlerName: String
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var theme: ThemeChoice {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
            applyAppearance()
        }
    }

    /// Выключено: жест вправо перематывает вперёд. Включено — наоборот.
    @Published var invertScroll: Bool {
        didSet { UserDefaults.standard.set(invertScroll, forKey: Keys.invertScroll) }
    }

    @Published var associations: [AssociationKind] = []
    @Published var associationStatus: String?

    static let catalog: [(title: String, extensions: [String])] = [
        ("MP4", ["mp4", "m4v"]),
        ("MOV", ["mov"]),
        ("MKV", ["mkv"]),
        ("AVI", ["avi"]),
        ("WebM", ["webm"]),
        ("WMV", ["wmv", "asf"]),
        ("MPEG", ["mpg", "mpeg"]),
        ("FLV", ["flv"]),
        ("TS", ["ts", "m2ts", "mts"]),
        ("3GP", ["3gp"])
    ]

    private enum Keys {
        static let theme = "lumiere.theme"
        static let invertScroll = "lumiere.invertScroll"
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.theme) ?? ThemeChoice.system.rawValue
        theme = ThemeChoice(rawValue: raw) ?? .system
        invertScroll = UserDefaults.standard.bool(forKey: Keys.invertScroll)
    }

    func applyAppearance() {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func refreshAssociations() {
        var rows: [AssociationKind] = []
        var seen = Set<String>()
        for item in Self.catalog {
            guard let type = item.extensions.compactMap({ UTType(filenameExtension: $0) }).first else { continue }
            if !seen.insert(type.identifier).inserted { continue }
            let handler = NSWorkspace.shared.urlForApplication(toOpen: type)
            rows.append(AssociationKind(
                id: item.title,
                title: item.title,
                isDefault: Self.isLumiere(handler),
                handlerName: handler.map { FileManager.default.displayName(atPath: $0.path) } ?? "не задано"
            ))
        }
        associations = rows
    }

    func claimAssociations() {
        let app = Bundle.main.bundleURL
        var seen = Set<String>()
        let sharedTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        for type in sharedTypes where seen.insert(type.identifier).inserted {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        }
        for item in Self.catalog {
            for ext in item.extensions {
                guard let type = UTType(filenameExtension: ext), seen.insert(type.identifier).inserted else { continue }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            }
        }
        refreshAssociations()
        if associations.allSatisfy(\.isDefault) {
            associationStatus = "Готово. Двойной щелчок по этим видео открывает Lumiere."
        } else if associations.contains(where: \.isDefault) {
            let missing = associations.filter { !$0.isDefault }.map(\.title).joined(separator: ", ")
            associationStatus = "Часть форматов система не отдала: \(missing)."
        } else {
            associationStatus = "Система не сменила программу по умолчанию. Lumiere должен лежать в «Программах»."
        }
    }

    private static func isLumiere(_ url: URL?) -> Bool {
        guard let url else { return false }
        if Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return true
        }
        return url.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Тема")
                    .font(.headline)
                Picker("Тема", selection: $settings.theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Прокрутка")
                    .font(.headline)
                Toggle("Инвертировать направление", isOn: $settings.invertScroll)
                Text("Выключено: скролл вправо перематывает вперёд.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Открывать видео двойным щелчком")
                    .font(.headline)
                Text("Назначает Lumiere программой по умолчанию для этих форматов.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(settings.associations) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isDefault ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDefault ? Color.lumiereAccent : Color.secondary)
                            .frame(width: 16)
                        Text(item.title)
                            .frame(width: 64, alignment: .leading)
                        Text(item.handlerName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                Button("Назначить Lumiere") {
                    settings.claimAssociations()
                }
                if let associationStatus = settings.associationStatus {
                    Text(associationStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 440, alignment: .topLeading)
        .onAppear {
            settings.refreshAssociations()
        }
    }
}
