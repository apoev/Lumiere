// swift-tools-version: 5.9
import PackageDescription

// Рабочая сборка — ./Scripts/build.sh (swiftc + libvlc из VLC.app).
// Xcode.app на этой машине нет, как и у Mimir. project.yml оставлен для xcodegen.
let package = Package(
    name: "Lumiere",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lumiere", targets: ["Lumiere"])
    ],
    targets: [
        .executableTarget(
            name: "Lumiere",
            path: "Sources/Lumiere"
        )
    ]
)
