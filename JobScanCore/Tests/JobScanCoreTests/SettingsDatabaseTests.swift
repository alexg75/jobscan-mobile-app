#if canImport(SwiftData)
import Foundation
import SwiftData
import XCTest
@testable import JobScanCore

final class SettingsDatabaseTests: XCTestCase {

    /// Everything one test needs: a database, a temporary folder (bundled and old
    /// config.toml) and its own first-launch marker store.
    struct Setup {
        let container: ModelContainer
        let legacy: ConfigStore
        let markers: UserDefaults
        let dir: URL

        @MainActor
        func database() -> SettingsDatabase {
            SettingsDatabase(container: container, legacy: legacy, markers: markers)
        }
    }

    @MainActor
    func makeSetup(legacyTOML: String? = nil, inMemory: Bool = true) throws -> Setup {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "jobscan-tests-\(UUID().uuidString)"
        let markers = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }

        let bundled = dir.appendingPathComponent("bundled-config.toml")
        try Data(ConfigTests.bundledConfig.utf8).write(to: bundled)
        let documentsFile = dir.appendingPathComponent("config.toml")
        if let legacyTOML {
            try Data(legacyTOML.utf8).write(to: documentsFile)
        }
        let container = inMemory
            ? try SettingsDatabase.makeContainer(inMemory: true)
            : try SettingsDatabase.makeContainer(url: dir.appendingPathComponent("Settings.store"))
        return Setup(container: container, legacy: ConfigStore(fileURL: documentsFile, bundledTOML: bundled),
                     markers: markers, dir: dir)
    }

    @MainActor
    func makeDatabase(legacyTOML: String? = nil) throws -> (db: SettingsDatabase, dir: URL) {
        let setup = try makeSetup(legacyTOML: legacyTOML)
        return (setup.database(), setup.dir)
    }

    func customConfig() -> ScanConfig {
        var c = ScanConfig.builtInDefault
        c.query = "kotlin architect"
        c.keywords = ["kotlin", "lead"]
        c.extraParams = [QueryParam(name: "sort", value: "date"), QueryParam(name: "radius", value: "10")]
        c.reportFormats = [.html, .txt]
        c.searches = [
            SearchTarget(name: "Oslo (NO)", site: "https://englishjobs.no", location: "oslo"),
            SearchTarget(name: "Amsterdam (NL)", site: "https://englishjobsearch.nl", location: "amsterdam"),
        ]
        return c
    }

    @MainActor
    func testFirstLaunchStartsFromTheBundledConfigToml() throws {
        let (db, _) = try makeDatabase()
        let loaded = db.load()
        XCTAssertEqual(loaded.config, .builtInDefault)
        XCTAssertNil(loaded.problem)
        XCTAssertFalse(db.isEmpty)  // the defaults are now in the database
        XCTAssertEqual(db.recordCount().settings, 1)
    }

    @MainActor
    func testSaveAndLoadKeepsEverythingInOrder() throws {
        let (db, _) = try makeDatabase()
        let config = customConfig()
        try db.save(config)

        let loaded = db.load()
        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.config, config)
        XCTAssertEqual(loaded.config.searches.map(\.id), config.searches.map(\.id))
        XCTAssertEqual(loaded.config.extraParams.map(\.name), ["sort", "radius"])
    }

    @MainActor
    func testSavingAgainReplacesCitiesAndParameters() throws {
        let (db, _) = try makeDatabase()
        try db.save(customConfig())
        var smaller = customConfig()
        smaller.searches.removeLast()
        smaller.extraParams = []
        try db.save(smaller)

        XCTAssertEqual(db.load().config, smaller)
        let counts = db.recordCount()
        XCTAssertEqual(counts.settings, 1)
        XCTAssertEqual(counts.cities, 1)
        XCTAssertEqual(counts.params, 0)
    }

    @MainActor
    func testErasingLeavesEmptySettingsNotTheDefaults() throws {
        let (db, _) = try makeDatabase()
        _ = db.load()  // first launch: defaults copied in
        try db.save(customConfig())
        XCTAssertFalse(db.isEmpty)

        try db.reset()
        XCTAssertTrue(db.isEmpty)
        let counts = db.recordCount()
        XCTAssertEqual(counts.settings, 0)
        XCTAssertEqual(counts.cities, 0)
        XCTAssertEqual(counts.params, 0)

        let loaded = db.load()
        XCTAssertEqual(loaded.config, .empty)
        XCTAssertNil(loaded.problem)
        XCTAssertTrue(loaded.config.query.isEmpty)
        XCTAssertTrue(loaded.config.keywords.isEmpty)
        XCTAssertTrue(loaded.config.includeLanguages.isEmpty)
        XCTAssertTrue(loaded.config.searches.isEmpty)
        XCTAssertTrue(db.isEmpty)  // loading doesn't refill it

        try db.reset()  // erasing an empty database is fine too
        try db.save(customConfig())  // and it can be used again
        XCTAssertEqual(db.load().config, customConfig())
    }

    @MainActor
    func testAnErasedDatabaseStaysEmptyAfterTheAppRestarts() throws {
        let setup = try makeSetup(inMemory: false)
        do {
            let db = setup.database()
            _ = db.load()
            try db.reset()
        }
        let restarted = SettingsDatabase(container: try SettingsDatabase.makeContainer(url: setup.dir.appendingPathComponent("Settings.store")),
                                         legacy: setup.legacy, markers: setup.markers)
        XCTAssertEqual(restarted.load().config, .empty)
    }

    @MainActor
    func testTheOldConfigTomlIsImportedOnce() throws {
        let edited = ConfigTests.bundledConfig.replacingOccurrences(of: "max_age_days = 1", with: "max_age_days = 3")
        let (db, dir) = try makeDatabase(legacyTOML: edited)

        let loaded = db.load()
        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.config.maxAgeDays, 3)
        XCTAssertEqual(db.recordCount().settings, 1)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("config.toml").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("config.imported.toml").path))

        // Later changes in the database win; the file isn't imported again.
        var changed = loaded.config
        changed.maxAgeDays = 5
        try db.save(changed)
        XCTAssertEqual(db.load().config.maxAgeDays, 5)
    }

    @MainActor
    func testABrokenOldConfigTomlIsLeftAloneAndTheDefaultsAreUsed() throws {
        let broken = "query = \"java\"\nkeywords = [\"java\"\n"
        let (db, dir) = try makeDatabase(legacyTOML: broken)

        let loaded = db.load()
        XCTAssertEqual(loaded.config, .builtInDefault)
        XCTAssertTrue(loaded.problem?.hasPrefix("config.toml couldn't be imported") ?? false, loaded.problem ?? "no problem reported")
        XCTAssertEqual(db.recordCount().settings, 1)
        let file = dir.appendingPathComponent("config.toml")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    }

    @MainActor
    func testIncompleteSavedSettingsAreShownWithAProblem() throws {
        let (db, _) = try makeDatabase()
        var incomplete = customConfig()
        incomplete.searches = []
        try db.save(incomplete)  // the app checks before saving; the store itself doesn't

        let loaded = db.load()
        XCTAssertEqual(loaded.config, incomplete)  // not replaced by the defaults
        XCTAssertEqual(loaded.problem, "The saved settings need attention: Add at least one city.")
    }

    @MainActor
    func testDatabaseFileSurvivesReopening() throws {
        let setup = try makeSetup(inMemory: false)
        do {
            try setup.database().save(customConfig())
        }
        let reopened = SettingsDatabase(container: try SettingsDatabase.makeContainer(url: setup.dir.appendingPathComponent("Settings.store")),
                                        legacy: setup.legacy, markers: setup.markers)
        XCTAssertEqual(reopened.load().config, customConfig())
    }
}
#endif
