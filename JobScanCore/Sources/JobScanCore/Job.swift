import Foundation

/// One job found on a results page.
public struct Job: Hashable, Codable, Sendable {
    public var title: String
    public var company: String
    public var location: String
    public var posted: Day
    public var url: String

    public init(title: String, company: String, location: String, posted: Day, url: String) {
        self.title = title
        self.company = company
        self.location = location
        self.posted = posted
        self.url = url
    }
}

/// How far a scan has got, for showing on screen.
public struct ScanProgress: Equatable, Sendable {
    /// The city being searched now; nil before the first city and once all are done.
    public let currentCity: String?
    /// Cities finished so far (searched, failed or skipped).
    public let completed: Int
    public let total: Int

    public init(currentCity: String?, completed: Int, total: Int) {
        self.currentCity = currentCity
        self.completed = completed
        self.total = total
    }
}

/// The outcome for one city (one `[[searches]]` block).
public struct CityResult: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Jobs kept after the keyword and age filters, newest first.
    public let jobs: [Job]
    /// How many jobs were read from the site before filtering.
    public let scanned: Int
    /// Set when the city could not be scanned; the other cities still run.
    public let error: String?
    /// A short version of the error for headings, e.g. "BAD REQUEST".
    public let errorLabel: String?
    /// True when the scan was stopped before this city finished (or started).
    public let wasStopped: Bool

    public init(name: String, jobs: [Job], scanned: Int = 0, error: String? = nil, errorLabel: String? = nil,
                wasStopped: Bool = false) {
        self.name = name
        self.jobs = jobs
        self.scanned = scanned
        self.error = error
        self.errorLabel = errorLabel
        self.wasStopped = wasStopped
    }

    /// Stopped part-way: the jobs found on the pages read so far.
    static func stopped(_ name: String, jobs: [Job], scanned: Int) -> CityResult {
        CityResult(name: name, jobs: jobs, scanned: scanned,
                   error: "The search was stopped before this city finished; these are the jobs found until then.",
                   errorLabel: "STOPPED", wasStopped: true)
    }

    /// Never searched because the scan was stopped first.
    static func notSearched(_ name: String) -> CityResult {
        CityResult(name: name, jobs: [], error: "Not searched: the search was stopped.",
                   errorLabel: "NOT SEARCHED", wasStopped: true)
    }
}
