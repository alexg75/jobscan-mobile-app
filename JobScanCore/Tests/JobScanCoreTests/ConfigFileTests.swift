import Foundation
import XCTest
@testable import JobScanCore

/// Saving settings as config.toml and reading them back.
final class ConfigFileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    var fileURL: URL { dir.appendingPathComponent("Documents/config.toml") }

    /// A bundled config.toml like the app's.
    func bundled() throws -> URL {
        let url = dir.appendingPathComponent("bundled-config.toml")
        try Data(ConfigTests.bundledConfig.utf8).write(to: url)
        return url
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: Writer

    func testWrittenFileReadsBackTheSame() throws {
        let text = ScanConfig.builtInDefault.tomlString()
        XCTAssertEqual(try ScanConfig(toml: text), .builtInDefault)
        XCTAssertTrue(text.contains("extra_params = { sort = \"date\" }\n"))
        XCTAssertTrue(text.contains("[[searches]]\nname = \"The Hague (NL)\"\nsite = \"https://englishjobsearch.nl\"\nlocation = \"s-gravenhage\"\n"))
    }

    func testWriterEscapesAndRoundTripsUnusualValues() throws {
        var c = ScanConfig.builtInDefault
        c.query = "say \"hi\" \\ tab\there"
        c.keywords = ["c#", "über"]
        c.includeLanguages = []
        c.extraParams = []
        c.requestDelaySeconds = 1.5
        c.reportFormats = [.html, .txt]
        c.searches = [SearchTarget(name: "Zürich (CH)", site: "https://example.ch", location: "zurich")]
        let text = c.tomlString()
        XCTAssertTrue(text.contains(#"query = "say \"hi\" \\ tab\there""#))
        XCTAssertTrue(text.contains("extra_params = {}\n"))
        XCTAssertTrue(text.contains("request_delay_seconds = 1.5\n"))
        XCTAssertEqual(try ScanConfig(toml: text), c)
    }

    func testOddParameterNamesAreQuoted() throws {
        var c = ScanConfig.builtInDefault
        c.extraParams = [QueryParam(name: "sort", value: "date"), QueryParam(name: "job type", value: "full-time")]
        XCTAssertTrue(c.tomlString().contains(#"extra_params = { sort = "date", "job type" = "full-time" }"#))
        XCTAssertEqual(try ScanConfig(toml: c.tomlString()).extraParams, c.extraParams)
    }

    // MARK: Store

    func testFirstLoadInstallsTheBundledFile() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled())
        let loaded = store.load()
        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.config, .builtInDefault)
        XCTAssertEqual(try read(fileURL), ConfigTests.bundledConfig)  // copied as-is, comments included
    }

    func testSaveRewritesConfigTomlAndResetRestoresIt() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled())
        var changed = store.load().config
        changed.query = "kotlin architect"
        try store.save(changed)
        XCTAssertTrue(try read(fileURL).contains("query = \"kotlin architect\""))
        XCTAssertEqual(store.load().config.query, "kotlin architect")

        try store.reset()
        XCTAssertEqual(try read(fileURL), ConfigTests.bundledConfig)
        XCTAssertEqual(store.load().config, .builtInDefault)
    }

    func testHandEditsAreRead() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled())
        _ = store.load()
        let edited = try read(fileURL).replacingOccurrences(of: "max_age_days = 1", with: "max_age_days = 3")
        try Data(edited.utf8).write(to: fileURL)
        XCTAssertEqual(store.load().config.maxAgeDays, 3)
    }

    func testUnknownSettingsAreIgnored() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled())
        _ = store.load()
        let text = ConfigTests.bundledConfig.replacingOccurrences(
            of: "keep_reports_days = 30", with: "keep_reports_days = 30\nlegacy_setting = \"anything\"")
        try Data(text.utf8).write(to: fileURL)
        let loaded = store.load()
        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.config, .builtInDefault)
    }

    func testBrokenFileFallsBackToDefaultsAndIsLeftAlone() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled())
        _ = store.load()
        let broken = "query = \"java\"\nkeywords = [\"java\"\n"
        try Data(broken.utf8).write(to: fileURL)

        let loaded = store.load()
        XCTAssertEqual(loaded.config, .builtInDefault)
        XCTAssertTrue(loaded.problem?.contains("line") ?? false, loaded.problem ?? "no problem reported")
        XCTAssertEqual(try read(fileURL), broken)  // not overwritten: it can still be fixed
    }

    func testInvalidValuesFallBackToDefaults() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled())
        _ = store.load()
        try Data(ConfigTests.bundledConfig.replacingOccurrences(of: "max_pages = 5", with: "max_pages = 0").utf8).write(to: fileURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.config, .builtInDefault)
        XCTAssertEqual(loaded.problem, "config.toml: Pages per city must be 1 to 10. The default settings are in use until it's fixed.")
    }

    func testSettingsFromThePreviousVersionAreMoved() throws {
        let json = dir.appendingPathComponent("config.json")
        var old = ScanConfig.builtInDefault
        old.query = "kotlin architect"
        try JSONEncoder().encode(old).write(to: json)

        let store = ConfigStore(fileURL: fileURL, bundledTOML: try bundled(), legacyJSON: json)
        XCTAssertEqual(store.load().config.query, "kotlin architect")
        XCTAssertTrue(try read(fileURL).contains("query = \"kotlin architect\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
    }

    func testWithoutABundledFileTheBuiltInDefaultsAreWritten() throws {
        let store = ConfigStore(fileURL: fileURL, bundledTOML: nil)
        XCTAssertEqual(store.load().config, .builtInDefault)
        XCTAssertEqual(try read(fileURL), ScanConfig.builtInDefault.tomlString())
    }
}
