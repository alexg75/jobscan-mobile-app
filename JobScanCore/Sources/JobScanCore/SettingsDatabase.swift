#if canImport(SwiftData)
import Foundation
import SwiftData

// MARK: - Stored types

/// The search settings: one record. Cities and extra parameters are separate records.
@Model
final class StoredSettings {
    var query: String = ""
    var keywords: [String] = []
    var maxAgeDays: Int = 1
    var includeLanguages: [String] = []
    var maxPages: Int = 5
    var requestDelaySeconds: Double = 3
    var resultsSortedByDate: Bool = false
    /// "html", "md", "txt"
    var reportFormats: [String] = []
    var keepReportsDays: Int = 30
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \StoredCity.settings)
    var cities: [StoredCity]? = []

    @Relationship(deleteRule: .cascade, inverse: \StoredParam.settings)
    var extraParams: [StoredParam]? = []

    init() {}
}

/// One city to search.
@Model
final class StoredCity {
    var cityID: UUID = UUID()
    var name: String = ""
    var site: String = ""
    var location: String = ""
    /// Order in the list (and in the reports).
    var position: Int = 0
    var settings: StoredSettings?

    init(cityID: UUID, name: String, site: String, location: String, position: Int) {
        self.cityID = cityID
        self.name = name
        self.site = site
        self.location = location
        self.position = position
    }
}

/// One extra query parameter (`extra_params` in config.toml).
@Model
final class StoredParam {
    var name: String = ""
    var value: String = ""
    var position: Int = 0
    var settings: StoredSettings?

    init(name: String, value: String, position: Int) {
        self.name = name
        self.value = value
        self.position = position
    }
}

extension StoredSettings {
    var scanConfig: ScanConfig {
        let orderedParams = (extraParams ?? []).sorted { $0.position < $1.position }
        let orderedCities = (cities ?? []).sorted { $0.position < $1.position }
        return ScanConfig(
            query: query,
            keywords: keywords,
            maxAgeDays: maxAgeDays,
            includeLanguages: includeLanguages,
            maxPages: maxPages,
            requestDelaySeconds: requestDelaySeconds,
            resultsSortedByDate: resultsSortedByDate,
            extraParams: orderedParams.map { QueryParam(name: $0.name, value: $0.value) },
            reportFormats: reportFormats.compactMap { ReportFormat(rawValue: $0) },
            keepReportsDays: keepReportsDays,
            searches: orderedCities.map {
                SearchTarget(id: $0.cityID, name: $0.name, site: $0.site, location: $0.location)
            }
        )
    }

    func update(from c: ScanConfig, in context: ModelContext) {
        query = c.query
        keywords = c.keywords
        maxAgeDays = c.maxAgeDays
        includeLanguages = c.includeLanguages
        maxPages = c.maxPages
        requestDelaySeconds = c.requestDelaySeconds
        resultsSortedByDate = c.resultsSortedByDate
        reportFormats = c.reportFormats.map(\.rawValue)
        keepReportsDays = c.keepReportsDays
        updatedAt = Date()

        // Replace the cities and parameters with the new lists.
        for city in cities ?? [] { context.delete(city) }
        for param in extraParams ?? [] { context.delete(param) }
        var newCities: [StoredCity] = []
        for (index, s) in c.searches.enumerated() {
            let city = StoredCity(cityID: s.id, name: s.name, site: s.site, location: s.location, position: index)
            context.insert(city)
            newCities.append(city)
        }
        var newParams: [StoredParam] = []
        for (index, p) in c.extraParams.enumerated() {
            let param = StoredParam(name: p.name, value: p.value, position: index)
            context.insert(param)
            newParams.append(param)
        }
        cities = newCities
        extraParams = newParams
    }
}

// MARK: - The store

/// Settings kept in a SwiftData database on the phone (no server).
///
/// - First launch only: the database is filled from the config.toml the app kept in its
///   Documents folder before (then renamed config.imported.toml), or, on a new install,
///   from the config.toml bundled with the app.
/// - After that the bundled file is never used: an empty database (e.g. after `reset()`)
///   means empty settings, `ScanConfig.empty`, until new ones are saved.
@MainActor
public final class SettingsDatabase: SettingsStore {
    public let container: ModelContainer
    /// The bundled defaults, and the config.toml file to import from.
    public let legacy: ConfigStore
    /// Remembers that the first-launch setup has been done.
    let markers: UserDefaults
    static let initialisedKey = "settingsDatabaseInitialised"

    var context: ModelContext { container.mainContext }

    public init(container: ModelContainer, legacy: ConfigStore, markers: UserDefaults = .standard) {
        self.container = container
        self.legacy = legacy
        self.markers = markers
    }

    /// The database file, or an in-memory database (for tests).
    public static func makeContainer(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([StoredSettings.self, StoredCity.self, StoredParam.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public func load() -> (config: ScanConfig, problem: String?) {
        let setupProblem = initialiseIfNeeded()
        guard let stored = fetchSettings() else {
            return (.empty, setupProblem)  // erased: nothing to search until new settings are saved
        }
        let config = stored.scanConfig
        if let issue = config.validate().first {
            return (config, setupProblem ?? "The saved settings need attention: \(issue.message)")
        }
        return (config, setupProblem)
    }

    public func loadDefaults() -> (config: ScanConfig, problem: String?) {
        legacy.loadDefaults()
    }

    public func save(_ config: ScanConfig) throws {
        let stored: StoredSettings
        if let existing = fetchSettings() {
            stored = existing
        } else {
            stored = StoredSettings()
            context.insert(stored)
        }
        stored.update(from: config, in: context)
        try context.save()
    }

    /// Deletes every record. The settings are then empty (the bundled defaults are not used).
    public func reset() throws {
        for settings in try context.fetch(FetchDescriptor<StoredSettings>()) { context.delete(settings) }
        // Normally removed with their settings record; this also clears any left over.
        for city in try context.fetch(FetchDescriptor<StoredCity>()) { context.delete(city) }
        for param in try context.fetch(FetchDescriptor<StoredParam>()) { context.delete(param) }
        try context.save()
    }

    public var isEmpty: Bool {
        let counts = recordCount()
        return counts.settings + counts.cities + counts.params == 0
    }

    /// How many records of each kind exist.
    func recordCount() -> (settings: Int, cities: Int, params: Int) {
        let settings = (try? context.fetchCount(FetchDescriptor<StoredSettings>())) ?? 0
        let cities = (try? context.fetchCount(FetchDescriptor<StoredCity>())) ?? 0
        let params = (try? context.fetchCount(FetchDescriptor<StoredParam>())) ?? 0
        return (settings, cities, params)
    }

    func fetchSettings() -> StoredSettings? {
        var descriptor = FetchDescriptor<StoredSettings>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// First launch only: fills the database from the old Documents/config.toml (or
    /// config.json) if there is one, otherwise from the bundled config.toml. Databases that
    /// already have settings are left as they are. Never runs again, so an erased database
    /// stays empty.
    func initialiseIfNeeded() -> String? {
        guard !markers.bool(forKey: Self.initialisedKey) else { return nil }
        if fetchSettings() != nil {
            markers.set(true, forKey: Self.initialisedKey)
            return nil
        }

        let fm = FileManager.default
        let hasTOML = fm.fileExists(atPath: legacy.fileURL.path)
        let hasJSON = legacy.legacyJSON.map { fm.fileExists(atPath: $0.path) } ?? false
        var problem: String?
        let seed: ScanConfig
        var importedFile = false
        if hasTOML || hasJSON {
            let loaded = legacy.load()  // the defaults if the file can't be used
            seed = loaded.config
            if let fileProblem = loaded.problem {
                problem = "config.toml couldn't be imported (\(fileProblem)), so the default settings were used. The file was left as it is."
            } else {
                importedFile = true
            }
        } else {
            seed = loadDefaults().config
        }

        do {
            try save(seed)
        } catch {
            return "The settings couldn't be saved: \(error.localizedDescription)"  // try again next time
        }
        markers.set(true, forKey: Self.initialisedKey)
        if importedFile {
            let imported = legacy.fileURL.deletingLastPathComponent().appendingPathComponent("config.imported.toml")
            try? fm.removeItem(at: imported)
            try? fm.moveItem(at: legacy.fileURL, to: imported)
        }
        return problem
    }
}
#endif
