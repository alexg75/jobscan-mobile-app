import XCTest
@testable import JobScanCore

final class ParserTests: XCTestCase {
    let today = Day(year: 2026, month: 10, day: 27)!

    static let sample = #"""

    # 76 English-speaking jobs in Oslo

    [Include languages [+]](#)

    [Senior Java Solution Architect](https://englishjobs.no/clickout_alt/abc?p=1)

    - CUJO AI®
    - , Oslo fylke, Norway
    - October 26

    Lead the architecture of our platform.

    [report problem](#)[](#)

    [Tech Lead \- Payments](https://englishjobs.no/clickout/def?p=2)

    - Randstad AS
    - OSLO
    - yesterday
    - part-time

    Some description.

    [Head Pastry Chef](https://englishjobs.no/clickout/ghi?p=3)

    - MapleClass Education
    - , Oslo fylke, Norway
    - October 26
    - hospitality

    [Enterprise Architect](https://englishjobs.no/clickout/jkl?p=4)

    - Old Corp
    - Oslo
    - October 14

    - 1
    - [2](https://englishjobs.no/in/oslo?page=2)

    [next page](https://englishjobs.no/in/oslo?page=2)

    """#

    func testParseResultsExtractsJobs() {
        let jobs = ResultsParser.parseResults(Self.sample, today: today)
        XCTAssertEqual(jobs.map(\.title), ["Senior Java Solution Architect", "Tech Lead - Payments",
                                           "Head Pastry Chef", "Enterprise Architect"])
        XCTAssertEqual(jobs[0].company, "CUJO AI®")
        XCTAssertEqual(jobs[0].location, "Oslo fylke, Norway")
        XCTAssertEqual(jobs[0].posted, Day(year: 2026, month: 10, day: 26))
        XCTAssertEqual(jobs[0].url, "https://englishjobs.no/clickout_alt/abc?p=1")
        XCTAssertEqual(jobs[1].posted, Day(year: 2026, month: 10, day: 26))  // "yesterday"
    }

    func testWindowsLineEndings() {
        let crlf = Self.sample.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(ResultsParser.parseResults(crlf, today: today).count, 4)
    }

    func testSelectFiltersKeywordsAndAge() {
        let jobs = ResultsParser.parseResults(Self.sample, today: today)
        let kept = ResultsParser.select(jobs, matcher: KeywordMatcher(keywords: ["architect", "java", "tech", "lead"]),
                                        cutoff: today.adding(days: -1))
        XCTAssertEqual(kept.map(\.title), ["Senior Java Solution Architect", "Tech Lead - Payments"])
    }

    func testSelectRemovesDuplicates() {
        let d = today
        let a = Job(title: "Java Architect", company: "ITSync", location: "", posted: d, url: "https://x/1")
        let b = Job(title: "java architect", company: "itsync", location: "", posted: d, url: "https://x/2")
        let kept = ResultsParser.select([a, b], matcher: KeywordMatcher(keywords: ["java"]), cutoff: d)
        XCTAssertEqual(kept.map(\.url), ["https://x/1"])
    }

    func testKeywordWordStartMatching() {
        let m = KeywordMatcher(keywords: ["tech", "lead"])
        XCTAssertTrue(m.matches("Technical Leader"))
        XCTAssertFalse(m.matches("Biotechnician"))
        XCTAssertFalse(m.matches("Misleading role"))
    }

    func testParsePostedVariants() {
        let p = ResultsParser.parsePosted
        XCTAssertEqual(p("today", today), today)
        XCTAssertEqual(p("3 days ago", today), Day(year: 2026, month: 10, day: 24))
        XCTAssertEqual(p("2 weeks ago", today), Day(year: 2026, month: 10, day: 13))
        XCTAssertEqual(p("5 hours ago", today), today)
        XCTAssertEqual(p("Oct 3", today), Day(year: 2026, month: 10, day: 3))
        XCTAssertEqual(p("26 October", today), Day(year: 2026, month: 10, day: 26))
        XCTAssertEqual(p("Sept. 5, 2025", today), Day(year: 2025, month: 9, day: 5))
        // Year roll-over: "December 30" seen on 2 January belongs to last year
        XCTAssertEqual(p("December 30", Day(year: 2027, month: 1, day: 2)!), Day(year: 2026, month: 12, day: 30))
        XCTAssertNil(p("Oslo", today))
        XCTAssertNil(p("February 30", today))
    }

    func testPaginationDetection() {
        XCTAssertTrue(ResultsParser.hasNextPage(Self.sample, page: 1))
        XCTAssertFalse(ResultsParser.hasNextPage("no more pages here", page: 1))
    }

    func testSearchURLEncodesQuery() {
        XCTAssertEqual(SiteScanner.searchURL(site: "https://englishjobsearch.nl/", location: "amsterdam",
                                             query: "Java Solution Architect"),
                       "https://englishjobsearch.nl/in/amsterdam/java_solution_architect")
    }

    func testHeadingMarkersRemovedFromTitles() {
        let page = "### [### Java Solution Architect](https://x/1)\n\n- ITSync\n- Amsterdam\n- today\n\n"
            + "[Tech  Lead ###](https://x/2)\n\n- Adyen\n- Amsterdam\n- today\n"
        XCTAssertEqual(ResultsParser.parseResults(page, today: today).map(\.title),
                       ["Java Solution Architect", "Tech Lead"])
    }

    func testDayArithmetic() {
        XCTAssertEqual(Day(year: 2024, month: 3, day: 1)!.adding(days: -1), Day(year: 2024, month: 2, day: 29))
        XCTAssertEqual(Day(year: 2026, month: 12, day: 31)!.adding(days: 1), Day(year: 2027, month: 1, day: 1))
        XCTAssertEqual(Day(iso: "2026-10-27"), today)
        XCTAssertEqual(today.description, "2026-10-27")
        XCTAssertEqual(Day(ordinal: 0), Day(year: 1970, month: 1, day: 1))
    }
}
