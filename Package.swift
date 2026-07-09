// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyboardLock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeyboardLock",
            path: "Sources/KeyboardLock"
        )
    ]
)
