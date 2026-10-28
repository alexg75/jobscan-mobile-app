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

/// Waits for the given number of seconds (injectable so tests don't wait).
public typealias Sleeper = @Sendable (Double) async throws -> Void

public let taskSleep: Sleeper = { seconds in
    guard seconds > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

public struct URLSessionHTTPClient: HTTPClient {
    public static let userAgent = "jobscan/1.0 (personal daily job alert; one run per day)"

    let session: URLSession

    public init(session: URLSession = .shared) {
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

/// Retries busy/failed requests: up to 3 retries on 429/5xx or network errors,
/// waiting 5s, 10s, 20s (or the server's Retry-After).
public struct RetryingHTTPClient: HTTPClient {
    let base: HTTPClient
    let retries: Int
    let backoffSeconds: Double
    let sleep: Sleeper
    static let retryStatuses: Set<Int> = [429, 500, 502, 503, 504]

    public init(base: HTTPClient, retries: Int = 3, backoffSeconds: Double = 5, sleep: @escaping Sleeper = taskSleep) {
        self.base = base
        self.retries = retries
        self.backoffSeconds = backoffSeconds
        self.sleep = sleep
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            do {
                let response = try await base.get(url, timeout: timeout)
                if Self.retryStatuses.contains(response.statusCode) && attempt < retries {
                    attempt += 1
                    try await sleep(delay(attempt: attempt, retryAfter: response.headers["retry-after"]))
                    continue
                }
                return response
            } catch let error as URLError where error.code != .cancelled && attempt < retries {
                attempt += 1
                try await sleep(delay(attempt: attempt, retryAfter: nil))
            }
        }
    }

    func delay(attempt: Int, retryAfter: String?) -> Double {
        if let text = retryAfter, let seconds = Double(text.trimmingCharacters(in: .whitespaces)) {
            return min(max(seconds, 0), 120)
        }
        return backoffSeconds * pow(2, Double(attempt - 1))
    }
}
