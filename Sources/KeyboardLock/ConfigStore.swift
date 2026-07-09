import Foundation

struct AppConfig: Codable {
    var launchAtLogin: Bool

    static let `default` = AppConfig(launchAtLogin: false)
}

enum ConfigStore {
    private static let directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyboardLock", isDirectory: true)
    }()

    private static let fileURL: URL = directoryURL.appendingPathComponent("config.json")

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .default
        }
        return config
    }

    static func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KeyboardLock: failed to save config: \(error)")
        }
    }
}
