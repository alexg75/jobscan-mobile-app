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
        c.searches = searches.map { $0.normalized() }
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
        var cityNames = Set<String>()
        for s in searches {
            let name = s.name.trimmed
            if name.isEmpty {
                issues.append(ConfigIssue(.search(s.id), "Enter a name for the city."))
            } else if !cityNames.insert(name.lowercased()).inserted {
                issues.append(ConfigIssue(.search(s.id), "Another city is already called \"\(name)\"."))
            }
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
    public func normalized() -> SearchTarget {
        var site = self.site.trimmed
        while site.hasSuffix("/") { site.removeLast() }
        return SearchTarget(id: id, name: name.trimmed, site: site, location: location.trimmed)
    }

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
