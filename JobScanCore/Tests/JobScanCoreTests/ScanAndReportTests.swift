import Foundation
import XCTest
@testable import JobScanCore

/// Returns canned pages and records every URL requested.
final class FakeClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    let pages: @Sendable (Int, URL) throws -> HTTPResponse

    init(pages: @escaping @Sendable (Int, URL) throws -> HTTPResponse) {
        self.pages = pages
    }

    var calls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
        lock.lock()
        _calls.append(url)
        let n = _calls.count
        lock.unlock()
        return try pages(n, url)
    }
}

let noSleep: Sleeper = { _ in }

func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    utcCalendar().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func queryItems(_ url: URL) -> [String] {
    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}

func config(_ change: (inout ScanConfig) -> Void = { _ in }) -> ScanConfig {
    var c = ScanConfig.builtInDefault
    c.requestDelaySeconds = 0
    change(&c)
    return c
}

final class ScanAndReportTests: XCTestCase {
    let today = Day(year: 2026, month: 10, day: 27)!

    func testSortedScanStopsAtOldPageAndSendsSort() async throws {
        let newPage = ParserTests.sample
        let oldPage = newPage.replacingOccurrences(of: "October 26", with: "October 1")
            .replacingOccurrences(of: "yesterday", with: "October 1")
        let client = FakeClient { n, _ in HTTPResponse(statusCode: 200, body: n == 1 ? newPage : oldPage) }
        let scanner = SiteScanner(client: client, sleep: noSleep)
        let search = SearchTarget(name: "Amsterdam", site: "https://englishjobsearch.nl", location: "amsterdam")
        _ = try await scanner.scanSearch(config: config(), search: search, today: today)

        XCTAssertEqual(client.calls.count, 2)  // page 2 was all old -> stopped, no page 3
        let second = client.calls[1]
        XCTAssertEqual(second.absoluteString.components(separatedBy: "?")[0],
                       "https://englishjobsearch.nl/in/amsterdam/java_solution_architect")
        XCTAssertEqual(queryItems(second), ["format=markdown", "include=italian", "sort=date", "page=2"])
        XCTAssertEqual(queryItems(client.calls[0]), ["format=markdown", "include=italian", "sort=date"])
    }

    func testMaxPagesLimitsRequests() async throws {
        let client = FakeClient { _, _ in HTTPResponse(statusCode: 200, body: ParserTests.sample) }
        let scanner = SiteScanner(client: client, sleep: noSleep)
        let cfg = config { $0.maxPages = 3; $0.resultsSortedByDate = false }
        let jobs = try await scanner.scanSearch(config: cfg, search: cfg.searches[0], today: today)
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(jobs.count, 12)
    }

    func testRelativeLinksMadeAbsolute() async throws {
        let page = "[Java Architect](/clickout/e94?ql=ql&p=10)\n\n- ITSync\n- Amsterdam\n- October 26\n"
        let client = FakeClient { _, _ in HTTPResponse(statusCode: 200, body: page) }
        let cfg = config { $0.maxPages = 1 }
        let jobs = try await SiteScanner(client: client, sleep: noSleep).scanSearch(
            config: cfg, search: SearchTarget(name: "A", site: "https://englishjobsearch.nl", location: "amsterdam"),
            today: today)
        XCTAssertEqual(jobs[0].url, "https://englishjobsearch.nl/clickout/e94?ql=ql&p=10")
    }

    func testHTTPErrorIsReported() async {
        let client = FakeClient { _, _ in HTTPResponse(statusCode: 404, body: "nope") }
        let cfg = config()
        do {
            _ = try await SiteScanner(client: client, sleep: noSleep).scanSearch(config: cfg, search: cfg.searches[0], today: today)
            XCTFail("expected an error")
        } catch let error as HTTPStatusError {
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRetryOnBusyServer() async throws {
        let client = FakeClient { n, _ in HTTPResponse(statusCode: n < 3 ? 503 : 200, body: "ok") }
        let retrying = RetryingHTTPClient(base: client, sleep: noSleep)
        let response = try await retrying.get(URL(string: "https://example.com")!, timeout: 1)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(client.calls.count, 3)
    }

    func testReportMentionsErrorsAndEmpty() {
        let cfg = config { $0.query = "q"; $0.keywords = ["java"]; $0.includeLanguages = ["italian"] }
        let text = ReportRenderer.text(results: [CityResult(name: "Oslo", jobs: []),
                                                 CityResult(name: "Stockholm", jobs: [], error: "timeout")],
                                       config: cfg, now: date(2026, 10, 27, 7, 0), cutoff: today.adding(days: -1),
                                       calendar: utcCalendar())
        XCTAssertTrue(text.contains("No matching jobs."))
        XCTAssertTrue(text.contains("ERROR: timeout"))
        XCTAssertTrue(text.contains("Extra languages: italian"))
        XCTAssertTrue(text.hasPrefix("Job scan - 2026-10-27 07:00\n"))
    }

    func testMarkdownReportTableAndLinks() {
        let jobs = [Job(title: "Senior Java | Architect", company: "ITSync", location: "Amsterdam",
                        posted: Day(year: 2026, month: 10, day: 26)!,
                        url: "https://englishjobsearch.nl/clickout/abc?x=1&y=2")]
        let cfg = config { $0.keywords = ["java"] }
        let md = ReportRenderer.markdown(results: [CityResult(name: "The Hague (NL)", jobs: []),
                                                   CityResult(name: "Amsterdam (NL)", jobs: jobs)],
                                         config: cfg, now: date(2026, 10, 27, 15, 0),
                                         cutoff: Day(year: 2026, month: 10, day: 26)!, calendar: utcCalendar())
        XCTAssertTrue(md.hasPrefix("# Job scan - 2026-10-27 15:00"))
        XCTAssertTrue(md.contains("## The Hague (NL) - 0 matches"))
        XCTAssertTrue(md.contains("_No matching jobs._"))
        XCTAssertTrue(md.contains("## Amsterdam (NL) - 1 match\n"))
        XCTAssertTrue(md.contains("| Title | Company | Location | Posted |"))
        XCTAssertTrue(md.contains("| [Senior Java \\| Architect](<https://englishjobsearch.nl/clickout/abc?x=1&y=2>) "
                                  + "| ITSync | Amsterdam | 2026-10-26 |"))
    }

    func testHTMLReportEscapesAndLinks() {
        let jobs = [Job(title: "R&D <Java> Architect", company: "A&B", location: "Amsterdam",
                        posted: Day(year: 2026, month: 10, day: 26)!,
                        url: "https://englishjobsearch.nl/clickout/abc?x=1&y=2")]
        let cfg = config { $0.keywords = ["java"] }
        let page = ReportRenderer.html(results: [CityResult(name: "The Hague (NL)", jobs: []),
                                                 CityResult(name: "Amsterdam (NL)", jobs: jobs)],
                                       config: cfg, now: date(2026, 10, 27, 15, 0),
                                       cutoff: Day(year: 2026, month: 10, day: 26)!, calendar: utcCalendar())
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("href=\"https://englishjobsearch.nl/clickout/abc?x=1&amp;y=2\""))
        XCTAssertTrue(page.contains("R&amp;D &lt;Java&gt; Architect"))
        XCTAssertTrue(page.contains("<td>A&amp;B</td>"))
        XCTAssertTrue(page.contains("No matching jobs."))
        XCTAssertTrue(page.contains("<strong>1 match</strong>"))
    }

    func testFullRunWritesReportAndPrunes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReportStore(directory: dir)
        try store.write("old", day: Day(year: 2026, month: 9, day: 1)!, format: .html)  // > 30 days old
        try store.write("recent", day: Day(year: 2026, month: 10, day: 20)!, format: .html)

        // Oslo fails, the other cities return the sample page.
        let client = FakeClient { _, url in
            url.host == "englishjobs.no" ? HTTPResponse(statusCode: 500, body: "")
                                         : HTTPResponse(statusCode: 200, body: "no jobs today")
        }
        let cfg = config { $0.reportFormats = [.html, .md, .txt] }
        let runner = ScanRunner(config: cfg, client: client, store: store, sleep: noSleep,
                                calendar: utcCalendar(), now: { date(2026, 10, 27, 7, 13) })
        let outcome = try await runner.run()

        XCTAssertEqual(outcome.results.map(\.name), cfg.searches.map(\.name))
        XCTAssertEqual(outcome.failures.map(\.name), ["Oslo (NO)"])
        XCTAssertFalse(outcome.allFailed)
        XCTAssertEqual(outcome.reportFiles.map(\.lastPathComponent),
                       ["jobs-2026-10-27.html", "jobs-2026-10-27.md", "jobs-2026-10-27.txt"])

        let reports = store.reports()
        XCTAssertEqual(reports.map(\.label), ["jobs 2026-10-27", "jobs 2026-10-20"])
        XCTAssertEqual(reports[0].primaryFormat, .html)
        XCTAssertEqual(reports[0].files.count, 3)
        let txt = try String(contentsOf: store.fileURL(day: today, format: .txt), encoding: .utf8)
        XCTAssertTrue(txt.contains("== Oslo (NO) - 0 matches ==\n   ERROR: 500 Server Error"))
    }

    func testReportsListIsLimitedAndNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReportStore(directory: dir)
        for d in 1...12 { try store.write("x", day: Day(year: 2026, month: 10, day: d)!, format: .html) }
        try Data("ignore".utf8).write(to: dir.appendingPathComponent("jobs-latest.html"))
        let list = store.reports()
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(list.first?.day, Day(year: 2026, month: 10, day: 12))
        XCTAssertEqual(list.last?.day, Day(year: 2026, month: 10, day: 3))
    }
}
