import Foundation

/// A problem with a setting, tied to the field it belongs to so the editor can
/// show it next to that field.
public struct ConfigIssue: Hashable, Sendable {
    public enum Field: Hashable, Sendable {
        case query, keywords, includeLanguages, maxAgeDays, maxPages, requestDelay
        case reportFormats, keepReportsDays, extraParams
        /// The list of cities as a whole (e.g. "add at least one city").
        case searches
        /// One city, by `SearchTarget.id`.
        case search(UUID)
    }

    public let field: Field
    public let message: String

    public init(_ field: Field, _ message: String) {
        self.field = field
        self.message = message
    }
}

/// Thrown when saving settings that don't pass `validate()`.
public struct ConfigValidationError: Error, LocalizedError, Equatable {
    public let issues: [ConfigIssue]

    public init(issues: [ConfigIssue]) {
        self.issues = issues
    }

    public var errorDescription: String? {
        issues.map(\.message).joined(separator: "\n")
    }
}

extension ScanConfig {
    public static let maxAgeDaysRange = 0...30
    public static let maxPagesRange = 1...10
    /// At least a second between requests, to stay polite to the sites.
    public static let requestDelayRange = 1.0...60.0
    public static let keepReportsDaysRange = 1...365
    /// Query parameters the scanner sets itself.
    static let reservedParams: Set<String> = ["format", "page"]

    /// Trims spaces, drops empty list entries and blank extra-parameter rows, and
    /// removes a trailing "/" from site addresses. The editor saves the normalized copy.
    public func normalized() -> ScanConfig {
        var c = self
        c.query = query.trimmed
        c.keywords = keywords.map(\.trimmed).filter { !$0.isEmpty }
        c.includeLanguages = includeLanguages.map(\.trimmed).filter { !$0.isEmpty }
        c.extraParams = extraParams
            .map { QueryParam(name: $0.name.trimmed, value: $0.value.trimmed) }
            .filter { !($0.name.isEmpty && $0.value.isEmpty) }
        // Each city's name comes from its location and site. Two cities with the same
        // name can't both be kept: the later one replaces the earlier one, in its place.
        var cities: [SearchTarget] = []
        for s in searches.map({ $0.normalized() }) {
            if !s.name.isEmpty, let i = cities.firstIndex(where: { $0.name.lowercased() == s.name.lowercased() }) {
                cities[i] = SearchTarget(id: cities[i].id, name: s.name, site: s.site, location: s.location)
            } else {
                cities.append(s)
            }
        }
        c.searches = cities
        return c
    }

    /// Every problem with these settings (empty when they're fine to use).
    /// Call it on `normalized()` settings.
    public func validate() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        if query.trimmed.isEmpty {
            issues.append(ConfigIssue(.query, "Enter the text to search for."))
        }
        if keywords.allSatisfy({ $0.trimmed.isEmpty }) {
            issues.append(ConfigIssue(.keywords, "Add at least one title keyword."))
        }
        if !Self.maxAgeDaysRange.contains(maxAgeDays) {
            issues.append(ConfigIssue(.maxAgeDays, "Posted within must be 0 to \(Self.maxAgeDaysRange.upperBound) days."))
        }
        if !Self.maxPagesRange.contains(maxPages) {
            issues.append(ConfigIssue(.maxPages, "Pages per city must be \(Self.maxPagesRange.lowerBound) to \(Self.maxPagesRange.upperBound)."))
        }
        if !Self.requestDelayRange.contains(requestDelaySeconds) {
            issues.append(ConfigIssue(.requestDelay, "The delay between requests must be 1 to 60 seconds."))
        }
        if reportFormats.isEmpty {
            issues.append(ConfigIssue(.reportFormats, "Choose at least one report format."))
        }
        if !Self.keepReportsDaysRange.contains(keepReportsDays) {
            issues.append(ConfigIssue(.keepReportsDays, "Keep reports for 1 to \(Self.keepReportsDaysRange.upperBound) days."))
        }

        var paramNames = Set<String>()
        for p in extraParams {
            let name = p.name.trimmed
            if name.isEmpty {
                issues.append(ConfigIssue(.extraParams, "Every extra parameter needs a name."))
            } else if Self.reservedParams.contains(name.lowercased()) {
                issues.append(ConfigIssue(.extraParams, "\"\(name)\" is set by the app and can't be an extra parameter."))
            } else if !paramNames.insert(name.lowercased()).inserted {
                issues.append(ConfigIssue(.extraParams, "\"\(name)\" is listed twice."))
            }
        }

        if searches.isEmpty {
            issues.append(ConfigIssue(.searches, "Add at least one city."))
        }
        for s in searches {
            if !SearchTarget.isValidSite(s.site) {
                issues.append(ConfigIssue(.search(s.id), "The site must be a web address starting with https://"))
            }
            let location = s.location.trimmed
            if location.isEmpty {
                issues.append(ConfigIssue(.search(s.id), "Enter the location, e.g. amsterdam."))
            } else if location.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "?" || $0 == "#" }) {
                issues.append(ConfigIssue(.search(s.id), "The location can't contain spaces, /, ? or #."))
            }
        }
        return issues
    }
}

extension SearchTarget {
    /// Trims the fields, removes a trailing "/" from the site and sets the name from the
    /// location and the site (see `cityName(site:location:)`).
    public func normalized() -> SearchTarget {
        var site = self.site.trimmed
        while site.hasSuffix("/") { site.removeLast() }
        let location = self.location.trimmed
        return SearchTarget(id: id, name: Self.cityName(site: site, location: location), site: site, location: location)
    }

    /// The city's name, made from the location and the site's country domain:
    /// "amsterdam" on https://englishjobsearch.nl -> "Amsterdam (NL)",
    /// "s-gravenhage" -> "S Gravenhage (NL)". Empty when there's no location.
    public static func cityName(site: String, location: String) -> String {
        let words = location.trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
        guard !words.isEmpty else { return "" }
        let place = words.joined(separator: " ")
        guard let host = URL(string: site.trimmed)?.host, host.contains("."),
              let country = host.split(separator: ".").last, !country.isEmpty else { return place }
        return "\(place) (\(country.uppercased()))"
    }

    /// The name this city gets when saved.
    public var cityName: String { Self.cityName(site: site, location: location) }

    /// "https://host" with no path, query or spaces.
    public static func isValidSite(_ text: String) -> Bool {
        let t = text.trimmed
        guard !t.contains(where: { $0.isWhitespace }),
              let url = URL(string: t), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains(".") else { return false }
        return url.query == nil && (url.path.isEmpty || url.path == "/")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
