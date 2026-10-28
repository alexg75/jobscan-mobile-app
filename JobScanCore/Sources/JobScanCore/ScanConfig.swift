import Foundation

/// One city to search (a `[[searches]]` block in config.toml).
public struct SearchTarget: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity for lists in the UI. Not part of config.toml, and ignored
    /// when comparing two cities (two cities are equal when their settings are).
    public var id: UUID
    public var name: String
    /// e.g. "https://englishjobsearch.nl"
    public var site: String
    /// The slug in the site's city link, e.g. "s-gravenhage"
    public var location: String

    public init(id: UUID = UUID(), name: String, site: String, location: String) {
        self.id = id
        self.name = name
        self.site = site
        self.location = location
    }

    enum CodingKeys: String, CodingKey { case id, name, site, location }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()  // older saved settings have no id
        name = try c.decode(String.self, forKey: .name)
        site = try c.decode(String.self, forKey: .site)
        location = try c.decode(String.self, forKey: .location)
    }

    public static func == (lhs: SearchTarget, rhs: SearchTarget) -> Bool {
        lhs.name == rhs.name && lhs.site == rhs.site && lhs.location == rhs.location
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(site)
        hasher.combine(location)
    }

    /// The englishjobs.* sites the app knows about (offered in the city editor).
    public static let knownSites: [KnownSite] = [
        KnownSite(url: "https://englishjobsearch.nl", country: "Netherlands"),
        KnownSite(url: "https://englishjobsearch.se", country: "Sweden"),
        KnownSite(url: "https://englishjobs.no", country: "Norway"),
        KnownSite(url: "https://englishjobs.lu", country: "Luxembourg"),
    ]
}

public struct KnownSite: Hashable, Sendable, Identifiable {
    public var id: String { url }
    public let url: String
    public let country: String

    /// "englishjobsearch.nl"
    public var host: String { URL(string: url)?.host ?? url }
}

public struct QueryParam: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum ReportFormat: String, Codable, CaseIterable, Sendable {
    case html, md, txt

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .html: return "Web page (HTML)"
        case .md: return "Markdown"
        case .txt: return "Plain text"
        }
    }
}

/// Everything config.toml controls. Reports
/// always go to the app's Documents folder (visible in the Files app).
public struct ScanConfig: Codable, Hashable, Sendable {
    /// Search text sent to every site (becomes /in/{location}/{query}).
    public var query: String
    /// Keep jobs whose title has a word starting with one of these (case-insensitive).
    public var keywords: [String]
    /// Keep jobs posted today or within the last N days.
    public var maxAgeDays: Int
    /// Also include jobs that need English plus one of these languages.
    public var includeLanguages: [String]
    public var maxPages: Int
    public var requestDelaySeconds: Double
    /// Stop paging at the first page where every job is older than `maxAgeDays`.
    public var resultsSortedByDate: Bool
    public var extraParams: [QueryParam]
    public var reportFormats: [ReportFormat]
    public var keepReportsDays: Int
    public var searches: [SearchTarget]

    public init(query: String,
                keywords: [String],
                maxAgeDays: Int,
                includeLanguages: [String] = [],
                maxPages: Int,
                requestDelaySeconds: Double,
                resultsSortedByDate: Bool = false,
                extraParams: [QueryParam] = [],
                reportFormats: [ReportFormat] = [.html],
                keepReportsDays: Int = 30,
                searches: [SearchTarget]) {
        self.query = query
        self.keywords = keywords
        self.maxAgeDays = maxAgeDays
        self.includeLanguages = includeLanguages
        self.maxPages = maxPages
        self.requestDelaySeconds = requestDelaySeconds
        self.resultsSortedByDate = resultsSortedByDate
        self.extraParams = extraParams
        self.reportFormats = reportFormats
        self.keepReportsDays = keepReportsDays
        self.searches = searches
    }

    /// The same settings as the bundled config.toml; used if that file can't be read.
    public static let builtInDefault = ScanConfig(
        query: "java solution architect",
        keywords: ["architect", "java", "tech", "lead"],
        maxAgeDays: 1,
        includeLanguages: ["italian"],
        maxPages: 5,
        requestDelaySeconds: 3,
        resultsSortedByDate: true,
        extraParams: [QueryParam(name: "sort", value: "date")],
        reportFormats: [.html],
        keepReportsDays: 30,
        searches: [
            SearchTarget(name: "The Hague (NL)", site: "https://englishjobsearch.nl", location: "s-gravenhage"),
            SearchTarget(name: "Amsterdam (NL)", site: "https://englishjobsearch.nl", location: "amsterdam"),
            SearchTarget(name: "Stockholm (SE)", site: "https://englishjobsearch.se", location: "stockholm"),
            SearchTarget(name: "Oslo (NO)", site: "https://englishjobs.no", location: "oslo"),
            SearchTarget(name: "Luxembourg City (LU)", site: "https://englishjobs.lu", location: "luxembourg"),
        ]
    )
}

// MARK: - Reading config.toml

public struct ConfigError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { "config.toml: \(message)" }
}

extension ScanConfig {
    /// Reads config.toml. Optional keys get their defaults; keys the app doesn't know are ignored.
    public init(toml text: String) throws {
        let root = try TOML.parse(text)

        let searchItems = try Self.requiredValue("searches", in: root, as: "array of [[searches]] tables") { v -> [TOMLValue]? in
            if case .array(let items) = v { return items }
            return nil
        }
        var searches: [SearchTarget] = []
        for (index, item) in searchItems.enumerated() {
            guard case .table(let t) = item else { throw ConfigError(message: "searches #\(index + 1) is not a table") }
            func field(_ key: String) throws -> String {
                guard let v = t[key] else { throw ConfigError(message: "searches #\(index + 1) is missing '\(key)'") }
                guard case .string(let s) = v else { throw ConfigError(message: "searches #\(index + 1): '\(key)' must be a string") }
                return s
            }
            searches.append(SearchTarget(name: try field("name"), site: try field("site"), location: try field("location")))
        }

        var extraParams: [QueryParam] = []
        if let v = root["extra_params"] {
            guard case .table(let t) = v else { throw ConfigError(message: "'extra_params' must be a table, e.g. { sort = \"date\" }") }
            for (key, value) in t.entries {
                guard let text = Self.scalarText(value) else {
                    throw ConfigError(message: "extra_params.\(key) must be a string or number")
                }
                extraParams.append(QueryParam(name: key, value: text))
            }
        }

        let formatNames = try Self.optionalValue("report_formats", in: root, as: "array of strings", Self.stringArray) ?? ["html"]
        var formats: [ReportFormat] = []
        for name in formatNames {
            guard let f = ReportFormat(rawValue: name) else {
                throw ConfigError(message: "unknown report format '\(name)' (use html, md or txt)")
            }
            formats.append(f)
        }

        self.init(
            query: try Self.requiredValue("query", in: root, as: "string", Self.string),
            keywords: try Self.requiredValue("keywords", in: root, as: "array of strings", Self.stringArray),
            maxAgeDays: try Self.requiredValue("max_age_days", in: root, as: "integer", Self.int),
            includeLanguages: try Self.optionalValue("include_languages", in: root, as: "array of strings", Self.stringArray) ?? [],
            maxPages: try Self.requiredValue("max_pages", in: root, as: "integer", Self.int),
            requestDelaySeconds: try Self.requiredValue("request_delay_seconds", in: root, as: "number", Self.number),
            resultsSortedByDate: try Self.optionalValue("results_sorted_by_date", in: root, as: "boolean", Self.bool) ?? false,
            extraParams: extraParams,
            reportFormats: formats,
            keepReportsDays: try Self.optionalValue("keep_reports_days", in: root, as: "integer", Self.int) ?? 30,
            searches: searches
        )
    }

    private static func requiredValue<T>(_ key: String, in root: TOMLTable, as type: String,
                                    _ convert: (TOMLValue) -> T?) throws -> T {
        guard let v = root[key] else { throw ConfigError(message: "missing '\(key)'") }
        guard let out = convert(v) else { throw ConfigError(message: "'\(key)' must be a \(type), found \(v.typeName)") }
        return out
    }

    private static func optionalValue<T>(_ key: String, in root: TOMLTable, as type: String,
                                    _ convert: (TOMLValue) -> T?) throws -> T? {
        guard root[key] != nil else { return nil }
        return try requiredValue(key, in: root, as: type, convert)
    }

    private static func string(_ v: TOMLValue) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    private static func int(_ v: TOMLValue) -> Int? {
        if case .integer(let n) = v { return n }
        return nil
    }

    private static func number(_ v: TOMLValue) -> Double? {
        switch v {
        case .integer(let n): return Double(n)
        case .float(let d): return d
        default: return nil
        }
    }

    private static func bool(_ v: TOMLValue) -> Bool? {
        if case .bool(let b) = v { return b }
        return nil
    }

    private static func stringArray(_ v: TOMLValue) -> [String]? {
        guard case .array(let items) = v else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }

    /// Query-string text for a scalar (true -> "True").
    private static func scalarText(_ v: TOMLValue) -> String? {
        switch v {
        case .string(let s): return s
        case .integer(let n): return String(n)
        case .float(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        default: return nil
        }
    }
}

// MARK: - Storage

/// The settings file: `config.toml` in the app's Documents folder (visible in the
/// Files app). The editor rewrites it; it can also be edited by hand or shared.
/// The copy bundled in the app is the factory default.
public struct ConfigStore: Sendable {
    /// Documents/config.toml
    public let fileURL: URL
    /// The read-only config.toml inside the app.
    public let bundledTOML: URL?
    /// Settings saved as JSON by the previous version of the app; moved into config.toml once.
    public let legacyJSON: URL?

    public init(fileURL: URL, bundledTOML: URL?, legacyJSON: URL? = nil) {
        self.fileURL = fileURL
        self.bundledTOML = bundledTOML
        self.legacyJSON = legacyJSON
    }

    /// The settings to use, plus a problem description when config.toml can't be used
    /// (then the defaults are used, and the file is left alone so it can be fixed).
    public func load() -> (config: ScanConfig, problem: String?) {
        migrateLegacyJSON()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? installDefaults()
        }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let config = try ScanConfig(toml: text)
            if let issue = config.validate().first {
                return (loadDefaults().config, "config.toml: \(issue.message) The default settings are in use until it's fixed.")
            }
            return (config, nil)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (loadDefaults().config, "\(reason). The default settings are in use until it's fixed.")
        }
    }

    /// The bundled config.toml (or the built-in copy of it if that can't be used).
    public func loadDefaults() -> (config: ScanConfig, problem: String?) {
        guard let url = bundledTOML else {
            return (.builtInDefault, nil)
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let config = try ScanConfig(toml: text)
            if let issue = config.validate().first {
                return (.builtInDefault, "config.toml: \(issue.message) Using the built-in defaults.")
            }
            return (config, nil)
        } catch {
            return (.builtInDefault, "Using the default settings: \(error.localizedDescription)")
        }
    }

    /// Rewrites config.toml with these settings.
    public func save(_ config: ScanConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(config.tomlString().utf8).write(to: fileURL, options: .atomic)
    }

    /// Puts the bundled config.toml back.
    public func reset() throws {
        try installDefaults()
    }

    /// Copies the bundled file as-is (keeping its comments), or writes the built-in defaults.
    func installDefaults() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        if let url = bundledTOML, let bundled = try? Data(contentsOf: url) {
            data = bundled
        } else {
            data = Data(ScanConfig.builtInDefault.tomlString().utf8)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    /// Settings edited in the previous version (config.json) become config.toml.
    func migrateLegacyJSON() {
        guard let json = legacyJSON, FileManager.default.fileExists(atPath: json.path) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: json),
           let saved = try? JSONDecoder().decode(ScanConfig.self, from: data),
           saved.validate().isEmpty {
            try? save(saved)
        }
        try? FileManager.default.removeItem(at: json)
    }
}
