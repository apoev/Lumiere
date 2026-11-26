import AppKit
import Foundation

// Finder показывает иконку .app из CFBundleIconFile не всегда;
// NSWorkspace.setIcon пишет «кастомную» иконку, которую Finder видит сразу.

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: set-finder-icon App.app AppIcon.icns\n", stderr)
    exit(1)
}

let appPath = args[1]
let iconPath = args[2]
guard let image = NSImage(contentsOfFile: iconPath) else {
    fputs("не открылась иконка: \(iconPath)\n", stderr)
    exit(1)
}

let ok = NSWorkspace.shared.setIcon(image, forFile: appPath, options: [])
if !ok {
    fputs("setIcon не удался для \(appPath)\n", stderr)
    exit(1)
}

// Подтолкнуть Finder
NSWorkspace.shared.noteFileSystemChanged(appPath)
print("Finder icon → \(appPath)")
