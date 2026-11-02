import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ScanOutcome: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let day: Day
    public let cutoff: Day
    public let results: [CityResult]
    public let reportFiles: [URL]
    /// True when the scan was stopped before every city was searched.
    public let stopped: Bool

    public var totalMatches: Int { results.reduce(0) { $0 + $1.jobs.count } }
    /// Cities whose search failed (not counting those cut short by stopping).
    public var failures: [CityResult] { results.filter { $0.error != nil && !$0.wasStopped } }
    /// Cities fully searched or failed before the scan was stopped.
    public var finishedCities: Int { results.filter { !$0.wasStopped }.count }
    /// The scan counts as failed only when every search failed.
    public var allFailed: Bool { !stopped && failures.count == results.count }
}

/// One complete scan:
/// scan every city, filter, write the reports, prune old ones.
public struct ScanRunner: Sendable {
    let config: ScanConfig
    let client: HTTPClient
    let store: ReportStore
    let log: ScanLog?
    let sleep: Sleeper
    let calendar: Calendar
    let now: @Sendable () -> Date
    /// Told which city is being searched and how many are done (on the main actor, for the UI).
    let onProgress: (@MainActor @Sendable (ScanProgress) -> Void)?

    public init(config: ScanConfig,
                client: HTTPClient? = nil,
                store: ReportStore,
                log: ScanLog? = nil,
                sleep: @escaping Sleeper = taskSleep,
                calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() },
                onProgress: (@MainActor @Sendable (ScanProgress) -> Void)? = nil) {
        self.config = config
        // By default: real requests, retried after 1, 2 and 3 seconds, retries logged.
        self.client = client ?? RetryingHTTPClient(base: URLSessionHTTPClient(), log: log)
        self.store = store
        self.log = log
        self.sleep = sleep
        self.calendar = calendar
        self.now = now
        self.onProgress = onProgress
    }

    private func report(_ city: String?, completed: Int) async {
        guard let onProgress else { return }
        await onProgress(ScanProgress(currentCity: city, completed: completed, total: config.searches.count))
    }

    /// Errors for single cities are recorded in the outcome. Cancelling the task stops the
    /// scan: the report is still written, with the jobs found so far, the city that was
    /// being searched marked STOPPED and the rest NOT SEARCHED. Throws only if the report
    /// can't be written.
    public func run() async throws -> ScanOutcome {
        let started = now()
        let today = Day(started, calendar: calendar)
        let cutoff = today.adding(days: -config.maxAgeDays)
        let matcher = KeywordMatcher(keywords: config.keywords)
        let scanner = SiteScanner(client: client, sleep: sleep, log: log)
        try store.ensureDirectory()

        var results: [CityResult] = []
        // Sites that couldn't be reached at all: their other cities are skipped this time.
        var unreachable: [String: (label: String, message: String)] = [:]
        var pauseFirst = false
        var stopped = false
        for (index, search) in config.searches.enumerated() {
            // Once stopped, the remaining cities are listed as not searched.
            if stopped || Task.isCancelled {
                stopped = true
                results.append(.notSearched(search.name))
                continue
            }
            await report(search.name, completed: index)
            let site = Self.siteKey(search.site)
            if let down = unreachable[site] {
                log?.info("\(search.name): skipped, \(site) couldn't be reached")
                results.append(CityResult(name: search.name, jobs: [],
                                          error: "Not searched: \(site) couldn't be reached earlier in this scan (\(down.message))",
                                          errorLabel: down.label))
                continue
            }
            if pauseFirst {
                do {
                    try await sleep(config.requestDelaySeconds)
                } catch {
                    stopped = true
                    results.append(.notSearched(search.name))
                    continue
                }
            }
            pauseFirst = true
            do {
                let found = try await scanner.scanSearch(config: config, search: search, today: today)
                let kept = ResultsParser.select(found, matcher: matcher, cutoff: cutoff)
                log?.info("\(search.name): \(found.count) scanned, \(kept.count) kept")
                results.append(CityResult(name: search.name, jobs: kept, scanned: found.count))
            } catch let partial as ScanStopped {
                stopped = true
                let kept = ResultsParser.select(partial.jobs, matcher: matcher, cutoff: cutoff)
                log?.info("\(search.name): stopped after \(partial.jobs.count) scanned, \(kept.count) kept")
                results.append(.stopped(search.name, jobs: kept, scanned: partial.jobs.count))
            } catch {
                if isCancellation(error) {
                    stopped = true
                    results.append(.stopped(search.name, jobs: [], scanned: 0))
                    continue
                }
                // A page that still fails after its retries ends this city's search; the other cities carry on.
                let message = Self.describe(error)
                let label = errorLabel(for: error)
                log?.error("\(search.name) failed: \(message)")
                results.append(CityResult(name: search.name, jobs: [], error: message, errorLabel: label))
                if Self.siteIsUnreachable(error) { unreachable[site] = (label, message) }
            }
        }

        if stopped { log?.info("Search stopped: writing the report with the results so far") }
        await report(nil, completed: config.searches.count)

        var files: [URL] = []
        for format in config.reportFormats {
            let text = ReportRenderer.render(format, results: results, config: config,
                                             now: started, cutoff: cutoff, calendar: calendar)
            let url = try store.write(text, day: today, format: format)
            log?.info("Wrote \(url.lastPathComponent)")
            files.append(url)
        }

        store.prune(keepDays: config.keepReportsDays, today: today, log: log)
        return ScanOutcome(startedAt: started, finishedAt: now(), day: today, cutoff: cutoff,
                           results: results, reportFiles: files, stopped: stopped)
    }

    /// "englishjobsearch.nl" for "https://EnglishJobSearch.nl/"
    static func siteKey(_ site: String) -> String {
        let text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        return (URL(string: text)?.host ?? text).lowercased()
    }

    /// Errors meaning the site can't be reached at all (rather than one page failing).
    static func siteIsUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        return error.localizedDescription
    }
}
