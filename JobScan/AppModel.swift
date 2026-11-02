import Foundation
import Observation
import SwiftData
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
        /// The scan was stopped with the Stop button; the report has the results so far.
        var stopped = false
    }

    private(set) var isRunning = false
    /// Which city is being searched and how many are done, while a scan runs.
    private(set) var progress: ScanProgress?
    /// Stop was pressed and the scan is winding down.
    private(set) var isStopping = false
    private var scanTask: Task<ScanOutcome, Error>?
    private(set) var startedAt: Date?
    private(set) var lastRun: LastRun?
    private(set) var reports: [ReportEntry] = []
    /// The report produced by the last scan, marked "new" in the list.
    private(set) var newReportDay: Day?
    private(set) var config: ScanConfig
    private(set) var configProblem: String?
    /// True when the saved settings differ from the defaults that came with the app.
    private(set) var isCustomConfig = false
    /// True when the settings database has anything in it.
    private(set) var hasSavedSettings = false

    let store: ReportStore
    let log: ScanLog
    /// The settings database (or the config.toml file if the database can't be opened).
    let settings: any SettingsStore

    private init() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let log = ScanLog(fileURL: documents.appendingPathComponent("jobscan.log"))
        // The defaults bundled with the app, and the config.toml file used until now
        // (imported into the database once).
        let configFile = ConfigStore(fileURL: documents.appendingPathComponent("config.toml"),
                                     bundledTOML: Bundle.main.url(forResource: "config", withExtension: "toml"),
                                     legacyJSON: support.appendingPathComponent("config.json"))
        let settings: any SettingsStore
        var startupProblem: String?
        do {
            let container = try SettingsDatabase.makeContainer(url: support.appendingPathComponent("Settings.store"))
            settings = SettingsDatabase(container: container, legacy: configFile)
        } catch {
            // Keep working: fall back to the config.toml file.
            log.error("Settings database unavailable: \(error.localizedDescription)")
            startupProblem = "The settings database couldn't be opened, so settings are kept in config.toml for now."
            settings = ConfigFileSettingsStore(file: configFile)
        }
        let loaded = settings.load()
        self.store = ReportStore(directory: documents)
        self.log = log
        self.settings = settings
        self.config = loaded.config
        self.configProblem = loaded.problem ?? startupProblem
        self.isCustomConfig = loaded.problem == nil && loaded.config != settings.loadDefaults().config
        self.hasSavedSettings = !settings.isEmpty
        reloadReports()
    }

    // MARK: Header text

    /// "Java Solution Architect roles · The Hague, Amsterdam, Stockholm, Oslo, Luxembourg City"
    var subtitle: String {
        if config.query.trimmingCharacters(in: .whitespaces).isEmpty || config.searches.isEmpty {
            return "No search set up yet"
        }
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

    /// True when the settings are complete enough to search (search text, keywords, cities…).
    var canScan: Bool { config.validate().isEmpty }

    /// Re-reads the saved settings.
    func reloadConfig() {
        guard !isRunning else { return }
        let loaded = settings.load()
        config = loaded.config
        configProblem = loaded.problem
        isCustomConfig = loaded.problem == nil && loaded.config != settings.loadDefaults().config
        hasSavedSettings = !settings.isEmpty
    }

    /// Checks the edited settings and saves them; the next scan uses them.
    func updateConfig(_ edited: ScanConfig) throws {
        let clean = edited.normalized()
        let issues = clean.validate()
        guard issues.isEmpty else { throw ConfigValidationError(issues: issues) }
        try settings.save(clean)
        config = clean
        configProblem = nil
        isCustomConfig = clean != settings.loadDefaults().config
        hasSavedSettings = !settings.isEmpty
        log.info("Settings saved")
    }

    /// Erases everything in the settings database. The settings are then empty (no search
    /// text, keywords, languages or cities) until new ones are saved; the bundled
    /// config.toml is not used.
    func eraseSettings() throws {
        try settings.reset()
        let loaded = settings.load()
        config = loaded.config
        configProblem = loaded.problem
        isCustomConfig = false
        hasSavedSettings = !settings.isEmpty
        log.info("Settings database erased; the settings are empty")
    }

    /// Reads a config.toml file (e.g. chosen in the Files app) and saves its settings.
    func importConfig(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        try updateConfig(try ScanConfig(toml: text))
        log.info("Settings imported from \(url.lastPathComponent)")
    }

    /// The current settings written as config.toml in a temporary folder, for sharing.
    func exportConfigFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config.toml")
        do {
            try Data(config.tomlString().utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
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

    /// Stops the running scan. It finishes quickly and writes a report with the
    /// results collected so far.
    func stopScan() {
        guard isRunning, !isStopping, let scanTask else { return }
        isStopping = true
        log.info("Stop pressed")
        scanTask.cancel()
    }

    /// Runs one scan. Returns false if a scan was already running
    /// or every city failed.
    @discardableResult
    func runScan() async -> Bool {
        guard !isRunning, canScan else { return false }
        isRunning = true
        startedAt = Date()
        progress = ScanProgress(currentCity: nil, completed: 0, total: config.searches.count)

        // Ask iOS for extra time so the scan finishes if the app goes to the background.
        let backgroundTask = BackgroundTime()
        defer { backgroundTask.end() }

        let runner = ScanRunner(config: config, store: store, log: log, onProgress: { [weak self] update in
            guard let self, self.isRunning else { return }
            self.progress = update
        })
        let result: LastRun
        do {
            let task = Task { try await runner.run() }
            scanTask = task
            let outcome = try await task.value
            let report = store.report(for: outcome.day)
            if outcome.stopped {
                let matches = "\(outcome.totalMatches) matching job\(outcome.totalMatches == 1 ? "" : "s") so far"
                var stoppedRun = LastRun(ok: true,
                                         message: "\(matches) (\(outcome.finishedCities) of \(outcome.results.count) cities searched)",
                                         finishedAt: outcome.finishedAt, report: report,
                                         totalMatches: outcome.totalMatches)
                stoppedRun.stopped = true
                result = stoppedRun
            } else if outcome.allFailed {
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
        progress = nil
        scanTask = nil
        isStopping = false
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
