import Foundation

struct AppConfig: Codable {
    var launchAtLogin: Bool
    var autoLockOnBurst: Bool

    static let `default` = AppConfig(launchAtLogin: false, autoLockOnBurst: false)

    init(launchAtLogin: Bool, autoLockOnBurst: Bool) {
        self.launchAtLogin = launchAtLogin
        self.autoLockOnBurst = autoLockOnBurst
    }

    // Tolerate configs written by older versions that lack newer keys —
    // otherwise adding a field would silently reset every existing setting
    // to defaults (ConfigStore.load() falls back to .default on any decode
    // failure).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoLockOnBurst = try container.decodeIfPresent(Bool.self, forKey: .autoLockOnBurst) ?? false
    }
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
