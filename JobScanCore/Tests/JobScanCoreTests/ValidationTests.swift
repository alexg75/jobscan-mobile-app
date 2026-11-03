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
        let bad = SearchTarget(name: "", site: "http://example.com/x", location: "new york")
        let noLocation = SearchTarget(name: "Typed name", site: "https://englishjobs.no", location: " ")
        c.searches += [bad, noLocation]
        let issues = c.normalized().validate()
        XCTAssertEqual(issues.map(\.field), [.search(bad.id), .search(bad.id), .search(noLocation.id)])
        XCTAssertEqual(issues.map(\.message), [
            "The site must be a web address starting with https://",
            "The location can't contain spaces, /, ? or #.",
            "Enter the location, e.g. amsterdam.",
        ])
    }

    func testCityNameIsMadeFromLocationAndSite() {
        XCTAssertEqual(SearchTarget.cityName(site: "https://englishjobsearch.nl", location: "amsterdam"), "Amsterdam (NL)")
        XCTAssertEqual(SearchTarget.cityName(site: "https://englishjobsearch.nl/", location: " s-gravenhage "), "S Gravenhage (NL)")
        XCTAssertEqual(SearchTarget.cityName(site: "https://englishjobs.lu", location: "luxembourg"), "Luxembourg (LU)")
        XCTAssertEqual(SearchTarget.cityName(site: "", location: "oslo"), "Oslo")
        XCTAssertEqual(SearchTarget.cityName(site: "https://englishjobs.no", location: ""), "")

        // Whatever name was typed or imported, normalizing replaces it.
        let city = SearchTarget(name: "My favourite", site: "https://englishjobsearch.se", location: "stockholm")
        XCTAssertEqual(city.normalized().name, "Stockholm (SE)")
        XCTAssertEqual(ScanConfig.builtInDefault.normalized(), ScanConfig.builtInDefault)
    }

    func testACityWithTheSameNameReplacesTheEarlierOne() {
        var c = ScanConfig.builtInDefault
        let first = c.searches[1]  // Amsterdam (NL) on englishjobsearch.nl, second in the list
        let again = SearchTarget(name: "", site: "https://englishjobsearch.nl/", location: "Amsterdam")
        c.searches.append(again)
        let n = c.normalized()
        XCTAssertEqual(n.searches.count, 5)
        XCTAssertEqual(n.searches[1].id, first.id)           // keeps its place in the list
        XCTAssertEqual(n.searches[1].location, "Amsterdam")  // with the later city's details
        XCTAssertEqual(n.searches[1].name, "Amsterdam (NL)")
        XCTAssertEqual(n.validate(), [])
    }

    func testExtraParams() {
        var c = ScanConfig.builtInDefault
        c.extraParams = [QueryParam(name: "page", value: "2"), QueryParam(name: "sort", value: "date"),
                         QueryParam(name: "Sort", value: "x"), QueryParam(name: "", value: "y")]
        XCTAssertEqual(messages(c), ["\"page\" is set by the app and can't be an extra parameter.",
                                     "\"Sort\" is listed twice.", "Every extra parameter needs a name."])
    }

    func testCityCanBeTestedBeforeTheSearchTextIsEntered() async throws {
        XCTAssertEqual(SiteScanner.searchURL(site: "https://englishjobsearch.nl/", location: "amsterdam", query: " "),
                       "https://englishjobsearch.nl/in/amsterdam")
        XCTAssertEqual(SiteScanner.searchURL(site: "https://englishjobsearch.nl", location: "amsterdam", query: "java architect"),
                       "https://englishjobsearch.nl/in/amsterdam/java_architect")

        let client = FakeClient { _, _ in HTTPResponse(statusCode: 200, body: ParserTests.sample) }
        let today = Day(year: 2026, month: 10, day: 27)!
        let result = try await SiteScanner(client: client, sleep: noSleep)
            .probe(config: .empty, search: ScanConfig.builtInDefault.searches[1], today: today)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(result.found, 4)
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
