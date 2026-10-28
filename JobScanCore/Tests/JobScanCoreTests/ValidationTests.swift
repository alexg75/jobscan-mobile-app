import Foundation
import XCTest
@testable import JobScanCore

final class ValidationTests: XCTestCase {
    func messages(_ c: ScanConfig) -> [String] { c.normalized().validate().map(\.message) }

    func testDefaultsAreValid() {
        XCTAssertEqual(ScanConfig.builtInDefault.validate(), [])
        XCTAssertEqual(try ScanConfig(toml: ConfigTests.bundledConfig).validate(), [])
    }

    func testNormalizedTrimsAndDropsBlanks() {
        var c = ScanConfig.builtInDefault
        c.query = "  java architect "
        c.keywords = ["java", " ", " lead "]
        c.includeLanguages = [""]
        c.extraParams = [QueryParam(name: " sort ", value: "date"), QueryParam(name: "", value: " ")]
        c.searches[0].site = "https://englishjobsearch.nl/ "
        let n = c.normalized()
        XCTAssertEqual(n.query, "java architect")
        XCTAssertEqual(n.keywords, ["java", "lead"])
        XCTAssertEqual(n.includeLanguages, [])
        XCTAssertEqual(n.extraParams, [QueryParam(name: "sort", value: "date")])
        XCTAssertEqual(n.searches[0].site, "https://englishjobsearch.nl")
        XCTAssertEqual(n.searches[0].id, c.searches[0].id)
    }

    func testRequiredFields() {
        var c = ScanConfig.builtInDefault
        c.query = " "
        c.keywords = [""]
        c.searches = []
        c.reportFormats = []
        XCTAssertEqual(messages(c), ["Enter the text to search for.", "Add at least one title keyword.",
                                     "Choose at least one report format.", "Add at least one city."])
    }

    func testRanges() {
        var c = ScanConfig.builtInDefault
        c.maxAgeDays = -1
        c.maxPages = 0
        c.requestDelaySeconds = 0.5
        c.keepReportsDays = 0
        let fields = c.validate().map(\.field)
        XCTAssertEqual(fields, [.maxAgeDays, .maxPages, .requestDelay, .keepReportsDays])
    }

    func testCityProblemsPointAtTheCity() {
        var c = ScanConfig.builtInDefault
        let bad = SearchTarget(name: "amsterdam (nl)", site: "http://example.com/x", location: "new york")
        c.searches.append(bad)
        let issues = c.normalized().validate()
        XCTAssertEqual(issues.map(\.field), [.search(bad.id), .search(bad.id), .search(bad.id)])
        XCTAssertEqual(issues.map(\.message), [
            "Another city is already called \"amsterdam (nl)\".",
            "The site must be a web address starting with https://",
            "The location can't contain spaces, /, ? or #.",
        ])
    }

    func testExtraParams() {
        var c = ScanConfig.builtInDefault
        c.extraParams = [QueryParam(name: "page", value: "2"), QueryParam(name: "sort", value: "date"),
                         QueryParam(name: "Sort", value: "x"), QueryParam(name: "", value: "y")]
        XCTAssertEqual(messages(c), ["\"page\" is set by the app and can't be an extra parameter.",
                                     "\"Sort\" is listed twice.", "Every extra parameter needs a name."])
    }

    func testSiteCheck() {
        XCTAssertTrue(SearchTarget.isValidSite("https://englishjobs.no"))
        XCTAssertTrue(SearchTarget.isValidSite("https://englishjobs.no/"))
        XCTAssertFalse(SearchTarget.isValidSite("englishjobs.no"))
        XCTAssertFalse(SearchTarget.isValidSite("https://englishjobs.no/in/oslo"))
        XCTAssertFalse(SearchTarget.isValidSite("https://localhost"))
    }

    func testCityEqualityIgnoresID() {
        let a = SearchTarget(name: "Oslo", site: "https://englishjobs.no", location: "oslo")
        let b = SearchTarget(name: "Oslo", site: "https://englishjobs.no", location: "oslo")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }

    func testSavedSettingsWithoutIDsStillLoad() throws {
        let json = #"{"name":"Oslo","site":"https://englishjobs.no","location":"oslo"}"#
        let city = try JSONDecoder().decode(SearchTarget.self, from: Data(json.utf8))
        XCTAssertEqual(city.location, "oslo")

        let roundTrip = try JSONDecoder().decode(SearchTarget.self, from: JSONEncoder().encode(city))
        XCTAssertEqual(roundTrip.id, city.id)
    }

    func testProbeFetchesOnlyTheFirstPage() async throws {
        let client = FakeClient { _, _ in HTTPResponse(statusCode: 200, body: ParserTests.sample) }
        let today = Day(year: 2026, month: 10, day: 27)!
        let result = try await SiteScanner(client: client, sleep: noSleep)
            .probe(config: .builtInDefault, search: ScanConfig.builtInDefault.searches[3], today: today)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(result, ProbeResult(found: 4, matching: 2))
    }
}
