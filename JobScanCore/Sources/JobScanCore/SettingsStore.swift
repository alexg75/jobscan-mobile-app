import Foundation

/// Where the app keeps its settings. The app uses `SettingsDatabase` (SwiftData);
/// `ConfigFileSettingsStore` (config.toml) is the fallback if the database can't be opened.
@MainActor
public protocol SettingsStore: AnyObject {
    /// The settings to use, plus a problem description if something needs attention.
    /// Never fails.
    func load() -> (config: ScanConfig, problem: String?)
    /// The default settings (the config.toml bundled with the app).
    func loadDefaults() -> (config: ScanConfig, problem: String?)
    func save(_ config: ScanConfig) throws
    /// Removes everything stored.
    func reset() throws
    /// True when nothing is stored.
    var isEmpty: Bool { get }
}

/// The config.toml file store, usable wherever a `SettingsStore` is expected.
public final class ConfigFileSettingsStore: SettingsStore {
    public let file: ConfigStore

    public init(file: ConfigStore) {
        self.file = file
    }

    public func load() -> (config: ScanConfig, problem: String?) { file.load() }
    public func loadDefaults() -> (config: ScanConfig, problem: String?) { file.loadDefaults() }
    public func save(_ config: ScanConfig) throws { try file.save(config) }
    public func reset() throws { try file.reset() }
    public var isEmpty: Bool { !FileManager.default.fileExists(atPath: file.fileURL.path) }
}
