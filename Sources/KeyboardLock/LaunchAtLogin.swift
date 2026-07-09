import Foundation

/// Installs/removes a per-user LaunchAgent that starts the app binary at
/// login. Using a plain LaunchAgent (rather than SMAppService) means this
/// works regardless of whether the .app lives in /Applications or was run
/// straight out of the build folder.
enum LaunchAtLogin {
    private static let label = "com.edmundtam.keyboardlock"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
            runLaunchctl(["load", plistURL.path])
        } catch {
            NSLog("KeyboardLock: failed to install launch agent: \(error)")
        }
    }

    private static func uninstall() {
        runLaunchctl(["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        try? task.run()
        task.waitUntilExit()
    }
}
