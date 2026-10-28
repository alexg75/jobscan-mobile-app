import Foundation

/// A day's report, in one or more formats (jobs-2026-10-28.html, .md, .txt).
public struct ReportEntry: Identifiable, Hashable, Sendable {
    public var id: Day { day }
    public let day: Day
    public let files: [ReportFormat: URL]
    /// When the main file was last written.
    public let updated: Date

    public init(day: Day, files: [ReportFormat: URL], updated: Date) {
        self.day = day
        self.files = files
        self.updated = updated
    }

    /// "jobs 2026-10-28"
    public var label: String { "jobs \(day)" }

    /// The file to show: HTML if there is one, else Markdown, else text.
    public var primaryFormat: ReportFormat {
        for f in [ReportFormat.html, .md, .txt] where files[f] != nil { return f }
        return .html
    }

    public var primaryURL: URL? { files[primaryFormat] }

    /// All files, in html/md/txt order (for sharing).
    public var allFiles: [(format: ReportFormat, url: URL)] {
        ReportFormat.allCases.compactMap { f -> (format: ReportFormat, url: URL)? in
            guard let url = files[f] else { return nil }
            return (f, url)
        }
    }
}

/// The reports folder: the app's Documents
/// folder, which the Files app shows under On My iPhone › Job Scan.
public final class ReportStore: @unchecked Sendable {
    public let directory: URL
    static let fileName = Rx(#"^jobs-(\d{4}-\d{2}-\d{2})\.(html|md|txt)$"#)

    public init(directory: URL) {
        self.directory = directory
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(day: Day, format: ReportFormat) -> URL {
        directory.appendingPathComponent("jobs-\(day).\(format.fileExtension)")
    }

    @discardableResult
    public func write(_ text: String, day: Day, format: ReportFormat) throws -> URL {
        try ensureDirectory()
        let url = fileURL(day: day, format: format)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Report files in the folder as (day, format, url).
    func reportFiles() -> [(day: Day, format: ReportFormat, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> (day: Day, format: ReportFormat, url: URL)? in
            guard let m = Self.fileName.match(url.lastPathComponent),
                  let dayText = m[1], let day = Day(iso: dayText),
                  let ext = m[2], let format = ReportFormat(rawValue: ext) else { return nil }
            return (day, format, url)
        }
    }

    /// Newest first, at most `limit` days (the home screen shows the last 10).
    public func reports(limit: Int = 10) -> [ReportEntry] {
        var byDay: [Day: [ReportFormat: URL]] = [:]
        for file in reportFiles() {
            byDay[file.day, default: [:]][file.format] = file.url
        }
        return byDay.keys.sorted(by: >).prefix(limit).map { day -> ReportEntry in
            let files = byDay[day] ?? [:]
            var updated = Date.distantPast
            if let url = ReportEntry(day: day, files: files, updated: updated).primaryURL,
               let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date {
                updated = modified
            }
            return ReportEntry(day: day, files: files, updated: updated)
        }
    }

    public func report(for day: Day) -> ReportEntry? {
        reports(limit: Int.max).first { $0.day == day }
    }

    /// Deletes reports more than `keepDays` days old. Returns the removed file names.
    @discardableResult
    public func prune(keepDays: Int, today: Day, log: ScanLog? = nil) -> [String] {
        var removed: [String] = []
        for file in reportFiles() where today.days(since: file.day) > keepDays {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                removed.append(file.url.lastPathComponent)
                log?.info("Removed old report \(file.url.lastPathComponent)")
            }
        }
        return removed.sorted()
    }

    public func delete(_ entry: ReportEntry) throws {
        for url in entry.files.values where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
