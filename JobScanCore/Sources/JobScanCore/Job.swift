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

    public init(name: String, jobs: [Job], scanned: Int = 0, error: String? = nil) {
        self.name = name
        self.jobs = jobs
        self.scanned = scanned
        self.error = error
    }
}
