import XCTest
@testable import JobScanCore

final class ConfigTests: XCTestCase {
    /// A copy of the config.toml bundled with the app.
    static let bundledConfig = #"""
    # Search text sent to every site (becomes /in/{location}/{query})
    query = "java solution architect"

    # Keep jobs whose TITLE has a word starting with one of these (case-insensitive).
    # "lead" also matches "Leader"/"Leading", "tech" matches "Technical"/"Technology".
    keywords = ["architect", "java", "tech", "lead"]

    # Keep jobs posted today or within the last N days.
    max_age_days = 1

    # Also include jobs that need English plus one of these languages.
    include_languages = ["italian"]

    # Pagination and politeness
    max_pages = 5
    request_delay_seconds = 3

    # Results are sorted newest-first (sort=date, the site's "newest" link), so the
    # scan stops at the first page where every job is older than max_age_days.
    results_sorted_by_date = true
    extra_params = { sort = "date" }

    # Report files to write each run: "html", "md" (Markdown), "txt" (plain text) - any mix,
    # and how many days to keep them.
    report_formats = ["html"]
    keep_reports_days = 30

    [[searches]]
    name = "The Hague (NL)"
    site = "https://englishjobsearch.nl"
    location = "s-gravenhage"

    [[searches]]
    name = "Amsterdam (NL)"
    site = "https://englishjobsearch.nl"
    location = "amsterdam"

    [[searches]]
    name = "Stockholm (SE)"
    site = "https://englishjobsearch.se"
    location = "stockholm"

    [[searches]]
    name = "Oslo (NO)"
    site = "https://englishjobs.no"
    location = "oslo"

    [[searches]]
    name = "Luxembourg City (LU)"
    site = "https://englishjobs.lu"
    location = "luxembourg"
    """#

    func testBundledConfigMatchesBuiltInDefault() throws {
        XCTAssertEqual(try ScanConfig(toml: Self.bundledConfig), ScanConfig.builtInDefault)
    }

    func testOptionalKeysUseDefaults() throws {
        let cfg = try ScanConfig(toml: """
        query = "java"
        keywords = [
            "java",   # trailing comma and comments are fine
        ]
        max_age_days = 2
        max_pages = 1
        request_delay_seconds = 0.5

        [[searches]]
        name = 'Oslo'
        site = "https://englishjobs.no"
        location = "oslo"
        """)
        XCTAssertEqual(cfg.includeLanguages, [])
        XCTAssertEqual(cfg.extraParams, [])
        XCTAssertEqual(cfg.reportFormats, [.html])
        XCTAssertEqual(cfg.keepReportsDays, 30)
        XCTAssertFalse(cfg.resultsSortedByDate)
        XCTAssertEqual(cfg.requestDelaySeconds, 0.5)
        XCTAssertEqual(cfg.searches, [SearchTarget(name: "Oslo", site: "https://englishjobs.no", location: "oslo")])
    }

    func testErrorsAreReadable() {
        XCTAssertThrowsError(try ScanConfig(toml: "query = \"x\"\n")) { error in
            XCTAssertEqual(error as? ConfigError, ConfigError(message: "missing 'searches'"))
        }
        XCTAssertThrowsError(try ScanConfig(toml: "query = \"x\" oops\n")) { error in
            XCTAssertEqual((error as? TOMLError)?.line, 1)
        }
    }

}
