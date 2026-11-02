import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: String
    /// Header names in lower case.
    public let headers: [String: String]

    public init(statusCode: Int, body: String, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

/// Fetches a page. The app uses `URLSessionHTTPClient`; tests use a fake.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse
}

/// Like requests' `raise_for_status()`.
public struct HTTPStatusError: Error, LocalizedError, Equatable {
    public let statusCode: Int
    public let url: String

    public var errorDescription: String? {
        let kind = statusCode >= 500 ? "Server Error" : "Client Error"
        return "\(statusCode) \(kind): \(HTTPURLResponse.localizedString(forStatusCode: statusCode)) for url: \(url)"
    }
}

/// A short, upper-case description of a failed request, for report headings:
/// "BAD REQUEST", "NOT FOUND", "TIMED OUT", "CONNECTION LOST"…
public func errorLabel(for error: Error) -> String {
    if let http = error as? HTTPStatusError {
        return HTTPURLResponse.localizedString(forStatusCode: http.statusCode).uppercased()
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut: return "TIMED OUT"
        case .notConnectedToInternet: return "NO INTERNET CONNECTION"
        case .networkConnectionLost: return "CONNECTION LOST"
        case .cannotFindHost, .dnsLookupFailed: return "SITE NOT FOUND"
        case .cannotConnectToHost: return "CANNOT CONNECT"
        case .secureConnectionFailed: return "SECURE CONNECTION FAILED"
        case .badURL, .unsupportedURL: return "BAD ADDRESS"
        default: return "NETWORK ERROR"
        }
    }
    return "ERROR"
}

/// Waits for the given number of seconds (injectable so tests don't wait).
public typealias Sleeper = @Sendable (Double) async throws -> Void

public let taskSleep: Sleeper = { seconds in
    guard seconds > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

public struct URLSessionHTTPClient: HTTPClient {
    public static let userAgent = "jobscan/1.0 (personal daily job alert; one run per day)"

    /// No request may hang: 15 s without any data, or 20 s in total, and it fails.
    public static let requestTimeout: TimeInterval = 15
    public static let totalTimeout: TimeInterval = 20

    /// A session with those limits, no caching and no waiting for a connection to appear.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = totalTimeout
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false  // fail at once when offline
        #endif
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let session: URLSession

    public init(session: URLSession = URLSessionHTTPClient.defaultSession) {
        self.session = session
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        #if canImport(FoundationNetworking)
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, let response = response {
                    cont.resume(returning: (data, response))
                } else {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        #endif

        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self), headers: headers)
    }
}

/// Retries a failed request after 1, 2 and 3 seconds: busy servers (429, 500, 502, 503,
/// 504) and network errors (dropped connection, timeout…). Other errors, such as
/// 400 Bad Request or 404 Not Found, are returned at once. If the last retry also fails,
/// that failure is returned and the caller stops searching that city.
public struct RetryingHTTPClient: HTTPClient {
    public static let defaultDelays: [Double] = [1, 2, 3]
    static let retryStatuses: Set<Int> = [429, 500, 502, 503, 504]

    let base: HTTPClient
    /// Wait before each retry, in seconds; one retry per entry.
    let delays: [Double]
    let sleep: Sleeper
    let log: ScanLog?

    public init(base: HTTPClient, delays: [Double] = RetryingHTTPClient.defaultDelays,
                sleep: @escaping Sleeper = taskSleep, log: ScanLog? = nil) {
        self.base = base
        self.delays = delays
        self.sleep = sleep
        self.log = log
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            do {
                let response = try await base.get(url, timeout: timeout)
                guard Self.retryStatuses.contains(response.statusCode), attempt < delays.count else {
                    return response
                }
                try await wait(before: attempt, reason: "HTTP \(response.statusCode)")
            } catch let error as URLError where error.code != .cancelled && attempt < delays.count {
                try await wait(before: attempt, reason: error.localizedDescription)
            }
            attempt += 1
        }
    }

    private func wait(before attempt: Int, reason: String) async throws {
        let seconds = delays[attempt]
        let text = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        log?.info("  retry \(attempt + 1) of \(delays.count) in \(text) s (\(reason))")
        try await sleep(seconds)
    }
}
