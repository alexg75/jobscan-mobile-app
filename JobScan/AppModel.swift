import Foundation
import Observation
import UIKit
import JobScanCore

/// App state: the "RUN A SEARCH" button, its status/result message and
/// the report list. Scans run only when you press the button.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// How the last scan ended.
    struct LastRun {
        let ok: Bool
        let message: String
        let finishedAt: Date
        let report: ReportEntry?
        let totalMatches: Int
    }

    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var lastRun: LastRun?
    private(set) var reports: [ReportEntry] = []
    /// The report produced by the last scan, marked "new" in the list.
    private(set) var newReportDay: Day?
    private(set) var config: ScanConfig
    private(set) var configProblem: String?
    /// True when config.toml differs from the one that came with the app.
    private(set) var isCustomConfig = false

    let store: ReportStore
    let log: ScanLog
    let configStore: ConfigStore

    private init() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configStore = ConfigStore(fileURL: documents.appendingPathComponent("config.toml"),
                                      bundledTOML: Bundle.main.url(forResource: "config", withExtension: "toml"),
                                      legacyJSON: support.appendingPathComponent("config.json"))
        let loaded = configStore.load()
        self.store = ReportStore(directory: documents)
        self.log = ScanLog(fileURL: documents.appendingPathComponent("jobscan.log"))
        self.configStore = configStore
        self.config = loaded.config
        self.configProblem = loaded.problem
        self.isCustomConfig = loaded.problem == nil && loaded.config != configStore.loadDefaults().config
        reloadReports()
    }

    // MARK: Header text

    /// "Java Solution Architect roles · The Hague, Amsterdam, Stockholm, Oslo, Luxembourg City"
    var subtitle: String {
        let what = config.query.split(separator: " ").map { word -> String in
            word.prefix(1).uppercased() + String(word.dropFirst())
        }.joined(separator: " ")
        let cities = config.searches.map { search -> String in
            guard let paren = search.name.range(of: " (", options: .backwards) else { return search.name }
            return String(search.name[..<paren.lowerBound])
        }
        return "\(what) roles · \(cities.joined(separator: ", "))"
    }

    // MARK: Settings

    /// Re-reads config.toml (it may have been edited or replaced in the Files app).
    func reloadConfig() {
        guard !isRunning else { return }
        let loaded = configStore.load()
        config = loaded.config
        configProblem = loaded.problem
        isCustomConfig = loaded.problem == nil && loaded.config != configStore.loadDefaults().config
    }

    /// Checks the edited settings and writes them to config.toml; the next scan uses them.
    func updateConfig(_ edited: ScanConfig) throws {
        let clean = edited.normalized()
        let issues = clean.validate()
        guard issues.isEmpty else { throw ConfigValidationError(issues: issues) }
        try configStore.save(clean)
        config = clean
        configProblem = nil
        isCustomConfig = clean != configStore.loadDefaults().config
        log.info("Settings saved to config.toml")
    }

    /// Puts back the config.toml that came with the app.
    func resetConfig() throws {
        try configStore.reset()
        let loaded = configStore.load()
        config = loaded.config
        configProblem = loaded.problem
        isCustomConfig = false
        log.info("config.toml reset to the default settings")
    }

    // MARK: Reports

    func reloadReports() {
        reports = store.reports(limit: 10)
    }

    func deleteReports(at offsets: IndexSet) {
        for index in offsets where reports.indices.contains(index) {
            try? store.delete(reports[index])
        }
        reloadReports()
    }

    // MARK: Running a scan

    /// Runs one scan. Returns false if a scan was already running
    /// or every city failed.
    @discardableResult
    func runScan() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        startedAt = Date()

        // Ask iOS for extra time so the scan finishes if the app goes to the background.
        let backgroundTask = BackgroundTime()
        defer { backgroundTask.end() }

        let runner = ScanRunner(config: config, store: store, log: log)
        let result: LastRun
        do {
            let outcome = try await runner.run()
            let report = store.report(for: outcome.day)
            if outcome.allFailed {
                let first = outcome.failures.first?.error ?? "unknown error"
                result = LastRun(ok: false, message: "every search failed (\(first))",
                                 finishedAt: outcome.finishedAt, report: report, totalMatches: 0)
            } else {
                var message = "\(outcome.totalMatches) matching job\(outcome.totalMatches == 1 ? "" : "s")"
                if !outcome.failures.isEmpty {
                    message += "; could not search \(outcome.failures.map(\.name).joined(separator: ", "))"
                }
                result = LastRun(ok: true, message: message, finishedAt: outcome.finishedAt,
                                 report: report, totalMatches: outcome.totalMatches)
            }
        } catch is CancellationError {
            log.error("Scan stopped before it finished")
            result = LastRun(ok: false, message: "the search was stopped before it finished",
                             finishedAt: Date(), report: nil, totalMatches: 0)
        } catch {
            log.error("Scan failed: \(error.localizedDescription)")
            result = LastRun(ok: false, message: error.localizedDescription,
                             finishedAt: Date(), report: nil, totalMatches: 0)
        }

        lastRun = result
        newReportDay = result.report?.day
        isRunning = false
        reloadReports()
        return result.ok
    }
}

/// Keeps the app running for up to ~30 s after it leaves the screen.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Job scan") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
