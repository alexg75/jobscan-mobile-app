import Foundation

/// Fetches the result pages for one city. Port of `search_url` and `scan_search`.
public struct SiteScanner: Sendable {
    let client: HTTPClient
    let sleep: Sleeper
    let log: ScanLog?

    public init(client: HTTPClient, sleep: @escaping Sleeper = taskSleep, log: ScanLog? = nil) {
        self.client = client
        self.sleep = sleep
        self.log = log
    }

    static let pathSafe: CharacterSet = {
        // Letters, digits, "_.-~" and "/" are left as they are.
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/")
    }()

    static func trimSlashes(_ site: String) -> String {
        var s = site
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The site's own search box writes spaces as underscores: /in/amsterdam/java_solution_architect
    public static func searchURL(site: String, location: String, query: String) -> String {
        let slug = query.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: pathSafe) ?? slug
        return "\(trimSlashes(site))/in/\(location)/\(encoded)"
    }

    /// Query parameters in this order: format, include, extra params, page.
    static func baseParams(_ config: ScanConfig) -> [QueryParam] {
        var params = [QueryParam(name: "format", value: "markdown")]
        if !config.includeLanguages.isEmpty {
            params.append(QueryParam(name: "include", value: config.includeLanguages.joined(separator: ".")))
        }
        for p in config.extraParams { upsert(&params, p) }
        return params
    }

    /// Replaces the parameter in place if it exists, else appends it.
    static func upsert(_ params: inout [QueryParam], _ p: QueryParam) {
        if let index = params.firstIndex(where: { $0.name == p.name }) {
            params[index] = p
        } else {
            params.append(p)
        }
    }

    static func makeURL(_ base: String, _ params: [QueryParam]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw URLError(.badURL) }
        components.queryItems = params.map { URLQueryItem(name: $0.name, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    /// `{'format': 'markdown', 'page': '2'}` for the log.
    static func describe(_ params: [QueryParam]) -> String {
        "{" + params.map { "'\($0.name)': '\($0.value)'" }.joined(separator: ", ") + "}"
    }

    /// All jobs on up to `maxPages` result pages for one city (unfiltered).
    public func scanSearch(config: ScanConfig, search: SearchTarget, today: Day) async throws -> [Job] {
        let base = Self.searchURL(site: search.site, location: search.location, query: config.query)
        let params = Self.baseParams(config)
        let cutoff = today.adding(days: -config.maxAgeDays)
        let siteRoot = URL(string: Self.trimSlashes(search.site) + "/")

        var jobs: [Job] = []
        var page = 1
        while page <= config.maxPages {
            var pageParams = params
            if page > 1 { Self.upsert(&pageParams, QueryParam(name: "page", value: String(page))) }
            log?.info("GET \(base) \(Self.describe(pageParams))")

            let response = try await client.get(try Self.makeURL(base, pageParams), timeout: 30)
            guard response.statusCode < 400 else {
                throw HTTPStatusError(statusCode: response.statusCode, url: base)
            }

            // Links can come back relative ("/clickout/..."): make them absolute so they open anywhere.
            let pageJobs = ResultsParser.parseResults(response.body, today: today).map { job -> Job in
                var j = job
                if let root = siteRoot, let absolute = URL(string: j.url, relativeTo: root) {
                    j.url = absolute.absoluteString
                }
                return j
            }
            log?.info("  page \(page): \(pageJobs.count) jobs")
            jobs.append(contentsOf: pageJobs)

            if pageJobs.isEmpty || !ResultsParser.hasNextPage(response.body, page: page) { break }
            if config.resultsSortedByDate && pageJobs.allSatisfy({ $0.posted < cutoff }) { break }
            if page == config.maxPages { break }
            try await sleep(config.requestDelaySeconds)
            page += 1
        }
        return jobs
    }
}

/// What "Test this city" found on the first results page.
public struct ProbeResult: Equatable, Sendable {
    /// Jobs on the first page.
    public let found: Int
    /// How many of those pass the keyword and date filters.
    public let matching: Int
}

extension SiteScanner {
    /// Fetches only the first results page for `search`, to check a city's settings.
    public func probe(config: ScanConfig, search: SearchTarget, today: Day) async throws -> ProbeResult {
        var firstPage = config
        firstPage.maxPages = 1
        let jobs = try await scanSearch(config: firstPage, search: search, today: today)
        let kept = ResultsParser.select(jobs, matcher: KeywordMatcher(keywords: config.keywords),
                                        cutoff: today.adding(days: -config.maxAgeDays))
        return ProbeResult(found: jobs.count, matching: kept.count)
    }
}
