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

/// Collects progress updates (they arrive on the main actor).
@MainActor
final class ProgressUpdates {
    var all: [ScanProgress] = []
}

/// Records the waits instead of sleeping.
final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: [Double] = []
    var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return _seconds }
    var sleeper: Sleeper {
        { [self] s in lock.lock(); _seconds.append(s); lock.unlock() }
    }
}

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

    func testBusyServerIsRetriedAfter1And2Seconds() async throws {
        let waits = Waits()
        let client = FakeClient { n, _ in HTTPResponse(statusCode: n < 3 ? 503 : 200, body: "ok") }
        let response = try await RetryingHTTPClient(base: client, sleep: waits.sleeper)
            .get(URL(string: "https://example.com")!, timeout: 1)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(waits.seconds, [1, 2])
    }

    func testGivesUpAfterRetryingAfter1And2And3Seconds() async throws {
        let waits = Waits()
        let client = FakeClient { _, _ in HTTPResponse(statusCode: 503, body: "busy") }
        let response = try await RetryingHTTPClient(base: client, sleep: waits.sleeper)
            .get(URL(string: "https://example.com")!, timeout: 1)
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(client.calls.count, 4)  // the request plus 3 retries
        XCTAssertEqual(waits.seconds, [1, 2, 3])
    }

    func testNetworkErrorsAreRetriedButBadRequestsAreNot() async throws {
        let lost = FakeClient { n, _ in
            if n == 1 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 200, body: "ok")
        }
        _ = try await RetryingHTTPClient(base: lost, sleep: noSleep).get(URL(string: "https://example.com")!, timeout: 1)
        XCTAssertEqual(lost.calls.count, 2)

        let rejected = FakeClient { _, _ in HTTPResponse(statusCode: 400, body: "") }
        let response = try await RetryingHTTPClient(base: rejected, sleep: noSleep).get(URL(string: "https://example.com")!, timeout: 1)
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(rejected.calls.count, 1)
    }

    func testIfPage1FailsAllRetriesPages2And3AreNotRequested() async throws {
        let site = FakeClient { _, _ in HTTPResponse(statusCode: 503, body: "busy") }
        let cfg = config()
        do {
            _ = try await SiteScanner(client: RetryingHTTPClient(base: site, sleep: noSleep), sleep: noSleep)
                .scanSearch(config: cfg, search: cfg.searches[1], today: today)
            XCTFail("expected an error")
        } catch let error as HTTPStatusError {
            XCTAssertEqual(errorLabel(for: error), "SERVICE UNAVAILABLE")
        }
        XCTAssertEqual(site.calls.count, 4)
        XCTAssertFalse(site.calls.contains { $0.absoluteString.contains("page=") })  // only page 1 was tried
    }

    func testIfPage2FailsAllRetriesPage3IsNotRequested() async throws {
        // Page 1 is fine and says there's a next page; every later request is refused.
        let site = FakeClient { n, _ in
            n == 1 ? HTTPResponse(statusCode: 200, body: ParserTests.sample) : HTTPResponse(statusCode: 503, body: "busy")
        }
        let cfg = config { $0.resultsSortedByDate = false }
        do {
            _ = try await SiteScanner(client: RetryingHTTPClient(base: site, sleep: noSleep), sleep: noSleep)
                .scanSearch(config: cfg, search: cfg.searches[1], today: today)
            XCTFail("expected an error")
        } catch is HTTPStatusError {}
        XCTAssertEqual(site.calls.count, 1 + 4)
        XCTAssertFalse(site.calls.contains { $0.absoluteString.contains("page=3") })
    }

    func testAnUnreachableSiteSkipsItsOtherCities() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // englishjobsearch.nl (The Hague and Amsterdam) times out; the other sites answer.
        let client = FakeClient { _, url in
            if url.host == "englishjobsearch.nl" { throw URLError(.timedOut) }
            return HTTPResponse(statusCode: 200, body: "no jobs today")
        }
        let cfg = config()
        let outcome = try await ScanRunner(config: cfg, client: client, store: ReportStore(directory: dir), sleep: noSleep,
                                           calendar: utcCalendar(), now: { date(2026, 10, 27, 7, 13) }).run()

        XCTAssertEqual(outcome.results.map(\.name), cfg.searches.map(\.name))
        XCTAssertEqual(outcome.results[0].errorLabel, "TIMED OUT")   // The Hague: tried once
        XCTAssertEqual(outcome.results[1].errorLabel, "TIMED OUT")   // Amsterdam: skipped
        XCTAssertTrue(outcome.results[1].error?.hasPrefix("Not searched: englishjobsearch.nl") ?? false)
        XCTAssertNil(outcome.results[2].error)                        // Stockholm still searched
        XCTAssertEqual(client.calls.filter { $0.host == "englishjobsearch.nl" }.count, 1)
        XCTAssertFalse(outcome.allFailed)
    }

    func testAPageErrorDoesNotSkipTheSitesOtherCities() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The Hague's address is rejected, but the site itself is up.
        let client = FakeClient { _, url in
            url.path.contains("s-gravenhage") ? HTTPResponse(statusCode: 400, body: "")
                                              : HTTPResponse(statusCode: 200, body: "no jobs today")
        }
        let outcome = try await ScanRunner(config: config(), client: client, store: ReportStore(directory: dir), sleep: noSleep,
                                           calendar: utcCalendar(), now: { date(2026, 10, 27, 7, 13) }).run()
        XCTAssertEqual(outcome.results[0].errorLabel, "BAD REQUEST")
        XCTAssertNil(outcome.results[1].error)  // Amsterdam was still searched
    }

    func testRequestsHaveTimeLimits() {
        let configuration = URLSessionHTTPClient.defaultSession.configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
    }

    func testReportMentionsErrorsAndEmpty() {
        let cfg = config { $0.query = "q"; $0.keywords = ["java"]; $0.includeLanguages = ["italian"] }
        let text = ReportRenderer.text(results: [CityResult(name: "Oslo", jobs: []),
                                                 CityResult(name: "Stockholm", jobs: [], error: "timeout")],
                                       config: cfg, now: date(2026, 10, 27, 7, 0), cutoff: today.adding(days: -1),
                                       calendar: utcCalendar())
        XCTAssertTrue(text.contains("No matching jobs."))
        XCTAssertTrue(text.contains("ERROR: timeout"))
        XCTAssertTrue(text.contains("== Stockholm - ERROR =="))
        XCTAssertTrue(text.contains("== Oslo - 0 matches =="))
        XCTAssertTrue(text.contains("Extra languages: italian"))
        XCTAssertTrue(text.hasPrefix("Anglo Job Radar - 2026-10-27 07:00\n"))
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
        XCTAssertTrue(md.hasPrefix("# Anglo Job Radar - 2026-10-27 15:00"))
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
        XCTAssertTrue(txt.contains("== Oslo (NO) - INTERNAL SERVER ERROR ==\n   ERROR: 500 Server Error"))
        let html = try String(contentsOf: store.fileURL(day: today, format: .html), encoding: .utf8)
        XCTAssertTrue(html.contains("Oslo (NO) <span class=\"count error\">INTERNAL SERVER ERROR</span>"))
    }

    func testAnErrorStopsThatCitysSearchAndIsShownInsteadOfTheCount() async throws {
        // Page 1 is fine and says there's a next page; page 2 is rejected.
        let client = FakeClient { n, _ in
            n == 1 ? HTTPResponse(statusCode: 200, body: ParserTests.sample)
                   : HTTPResponse(statusCode: 400, body: "bad request")
        }
        let cfg = config()
        do {
            _ = try await SiteScanner(client: client, sleep: noSleep)
                .scanSearch(config: cfg, search: cfg.searches[0], today: today)
            XCTFail("expected an error")
        } catch let error as HTTPStatusError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(errorLabel(for: error), "BAD REQUEST")
            // The message names the exact address requested, parameters included.
            XCTAssertTrue(error.url.hasSuffix("?format=markdown&include=italian&sort=date&page=2"), error.url)
        }
        XCTAssertEqual(client.calls.count, 2)  // nothing after the failing page

        let city = CityResult(name: "Luxembourg City (LU)", jobs: [], error: "400 Client Error", errorLabel: "BAD REQUEST")
        let page = ReportRenderer.html(results: [city], config: cfg, now: date(2026, 11, 2, 15, 0),
                                       cutoff: today, calendar: utcCalendar())
        XCTAssertTrue(page.contains("<span class=\"count error\">BAD REQUEST</span>"))
        XCTAssertFalse(page.contains("0 matches"))
        let md = ReportRenderer.markdown(results: [city], config: cfg, now: date(2026, 11, 2, 15, 0),
                                         cutoff: today, calendar: utcCalendar())
        XCTAssertTrue(md.contains("## Luxembourg City (LU) - BAD REQUEST\n"))
    }

    func testErrorLabels() {
        XCTAssertEqual(errorLabel(for: HTTPStatusError(statusCode: 404, url: "x")), "NOT FOUND")
        XCTAssertEqual(errorLabel(for: URLError(.networkConnectionLost)), "CONNECTION LOST")
        XCTAssertEqual(errorLabel(for: URLError(.timedOut)), "TIMED OUT")
        XCTAssertEqual(errorLabel(for: CancellationError()), "ERROR")
    }

    func testLogShowsTheExactAddressRequested() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ScanLog(fileURL: dir.appendingPathComponent("anglo-job-scan.log"))
        let client = FakeClient { _, _ in HTTPResponse(statusCode: 200, body: "no jobs") }
        let cfg = config()
        _ = try await SiteScanner(client: client, sleep: noSleep, log: log)
            .scanSearch(config: cfg, search: cfg.searches[4], today: today)
        XCTAssertTrue(log.tail().contains(
            "INFO GET https://englishjobs.lu/in/luxembourg/java_solution_architect?format=markdown&include=italian&sort=date"))
    }

    @MainActor
    func testProgressNamesEachCityAndCountsThemOff() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Oslo fails; it still counts as done.
        let client = FakeClient { _, url in
            url.host == "englishjobs.no" ? HTTPResponse(statusCode: 404, body: "")
                                         : HTTPResponse(statusCode: 200, body: "no jobs today")
        }
        let updates = ProgressUpdates()
        let runner = ScanRunner(config: config(), client: client, store: ReportStore(directory: dir), sleep: noSleep,
                                calendar: utcCalendar(), now: { date(2026, 10, 27, 7, 13) },
                                onProgress: { updates.all.append($0) })
        _ = try await runner.run()

        XCTAssertEqual(updates.all, [
            ScanProgress(currentCity: "S Gravenhage (NL)", completed: 0, total: 5),
            ScanProgress(currentCity: "Amsterdam (NL)", completed: 1, total: 5),
            ScanProgress(currentCity: "Stockholm (SE)", completed: 2, total: 5),
            ScanProgress(currentCity: "Oslo (NO)", completed: 3, total: 5),
            ScanProgress(currentCity: "Luxembourg (LU)", completed: 4, total: 5),
            ScanProgress(currentCity: nil, completed: 5, total: 5),
        ])
    }

    func testStoppingKeepsWhatWasFoundAndMarksTheRest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Amsterdam's page 1 has jobs; Stop is pressed while page 2 is loading.
        let client = FakeClient { _, url in
            let address = url.absoluteString
            if address.contains("/amsterdam/") {
                if address.contains("page=2") { throw CancellationError() }
                return HTTPResponse(statusCode: 200, body: ParserTests.sample)
            }
            return HTTPResponse(statusCode: 200, body: "no jobs today")
        }
        let cfg = config { $0.resultsSortedByDate = false; $0.reportFormats = [.txt] }
        let store = ReportStore(directory: dir)
        let outcome = try await ScanRunner(config: cfg, client: client, store: store, sleep: noSleep,
                                           calendar: utcCalendar(), now: { date(2026, 10, 27, 7, 13) }).run()

        XCTAssertTrue(outcome.stopped)
        XCTAssertEqual(outcome.results.map(\.errorLabel),
                       [nil, "STOPPED", "NOT SEARCHED", "NOT SEARCHED", "NOT SEARCHED"])
        XCTAssertEqual(outcome.results[1].jobs.map(\.title), ["Senior Java Solution Architect", "Tech Lead - Payments"])
        XCTAssertEqual(outcome.finishedCities, 1)
        XCTAssertTrue(outcome.failures.isEmpty)   // stopping isn't a failure
        XCTAssertFalse(outcome.allFailed)
        XCTAssertFalse(client.calls.contains { ["englishjobsearch.se", "englishjobs.no", "englishjobs.lu"].contains($0.host ?? "") })

        let txt = try String(contentsOf: store.fileURL(day: today, format: .txt), encoding: .utf8)
        XCTAssertTrue(txt.contains("== Amsterdam (NL) - STOPPED =="))
        XCTAssertTrue(txt.contains("* Senior Java Solution Architect"))
        XCTAssertTrue(txt.contains("== Stockholm (SE) - NOT SEARCHED ==\n   Not searched: the search was stopped."))
        XCTAssertFalse(txt.contains("ERROR: Not searched"))
    }

    func testCancellingTheScanStopsAHangingRequestAndStillWritesTheReport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        struct HangingClient: HTTPClient {
            func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return HTTPResponse(statusCode: 200, body: "")
            }
        }
        let runner = ScanRunner(config: config(), client: HangingClient(), store: ReportStore(directory: dir), sleep: noSleep,
                                calendar: utcCalendar(), now: { date(2026, 10, 27, 7, 13) })
        let task = Task { try await runner.run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()  // what the Stop button does
        let outcome = try await task.value

        XCTAssertTrue(outcome.stopped)
        XCTAssertEqual(outcome.results[0].errorLabel, "STOPPED")
        XCTAssertEqual(outcome.results.dropFirst().map(\.errorLabel), [String?](repeating: "NOT SEARCHED", count: 4))
        XCTAssertEqual(outcome.reportFiles.map(\.lastPathComponent), ["jobs-2026-10-27.html"])
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
