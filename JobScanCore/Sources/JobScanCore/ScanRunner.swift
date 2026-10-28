import Foundation

public struct ScanOutcome: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let day: Day
    public let cutoff: Day
    public let results: [CityResult]
    public let reportFiles: [URL]

    public var totalMatches: Int { results.reduce(0) { $0 + $1.jobs.count } }
    public var failures: [CityResult] { results.filter { $0.error != nil } }
    /// The scan counts as failed only when every search failed.
    public var allFailed: Bool { failures.count == results.count }
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

    public init(config: ScanConfig,
                client: HTTPClient = RetryingHTTPClient(base: URLSessionHTTPClient()),
                store: ReportStore,
                log: ScanLog? = nil,
                sleep: @escaping Sleeper = taskSleep,
                calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.client = client
        self.store = store
        self.log = log
        self.sleep = sleep
        self.calendar = calendar
        self.now = now
    }

    /// Errors for single cities are recorded in the outcome; this only throws when
    /// the scan is cancelled or the report can't be written.
    public func run() async throws -> ScanOutcome {
        let started = now()
        let today = Day(started, calendar: calendar)
        let cutoff = today.adding(days: -config.maxAgeDays)
        let matcher = KeywordMatcher(keywords: config.keywords)
        let scanner = SiteScanner(client: client, sleep: sleep, log: log)
        try store.ensureDirectory()

        var results: [CityResult] = []
        for (index, search) in config.searches.enumerated() {
            try Task.checkCancellation()
            do {
                let found = try await scanner.scanSearch(config: config, search: search, today: today)
                let kept = ResultsParser.select(found, matcher: matcher, cutoff: cutoff)
                log?.info("\(search.name): \(found.count) scanned, \(kept.count) kept")
                results.append(CityResult(name: search.name, jobs: kept, scanned: found.count))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let message = Self.describe(error)
                log?.error("\(search.name) failed: \(message)")  // keep going with the other cities
                results.append(CityResult(name: search.name, jobs: [], error: message))
            }
            if index < config.searches.count - 1 {
                try await sleep(config.requestDelaySeconds)
            }
        }

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
                           results: results, reportFiles: files)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        return error.localizedDescription
    }
}
