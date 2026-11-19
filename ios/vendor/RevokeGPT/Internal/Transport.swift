import Foundation

/// One HTTP POST to the RevokeGPT API (protocol v1 section 23.4). The status, the body (at most
/// 64 KiB plus one byte, so an oversize body is still seen as oversize) and the headers come back
/// unread; `Wire.interpret` reads them.
protocol Transport: Sendable {
    func post(path: String, body: Data, deadline: Deadline) async throws(RevokeGPTError)
        -> (status: Int, body: Data, headers: [String: String])
}

/// The default transport: an ephemeral URLSession with no cookies, cache or credential storage,
/// no waiting for connectivity, redirects refused, the body capped while it streams, and only
/// `Content-Type: application/json` added (URLSession adds its own automatic headers). TLS is the
/// system's trust evaluation and ATS minimums, and proxies are the system's: deliberately no
/// pinning, proxy override or TLS-version override (R9), so the device's managed network
/// settings apply.
final class URLSessionTransport: Transport, RedactedDescription {
    let endpoint: URL
    private let session: URLSession
    private let delegate = SessionDelegate()

    /// `protocolClasses` is for tests (a stub URLProtocol); the SDK passes none.
    private let log: Log

    init(endpoint: URL, protocolClasses: [AnyClass]? = nil, log: Log = .off) {
        self.log = log
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = nil
        if let protocolClasses { c.protocolClasses = protocolClasses + (c.protocolClasses ?? []) }
        self.endpoint = endpoint
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// A copy of the session's configuration (for tests).
    var configuration: URLSessionConfiguration { session.configuration }

    /// `path` (relative, `v1/solve`) under the endpoint's own path; query and fragment dropped.
    func url(for path: String) -> URL {
        guard var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.appendingPathComponent(path)
        }
        var base = c.path
        while base.hasSuffix("/") { base.removeLast() }
        c.path = base + "/" + path
        c.query = nil
        c.fragment = nil
        return c.url ?? endpoint.appendingPathComponent(path)
    }

    func post(path: String, body: Data, deadline: Deadline) async throws(RevokeGPTError)
        -> (status: Int, body: Data, headers: [String: String]) {
        let remaining = deadline.remaining
        guard remaining > 0 else {
            log.event(.httpTimeout)
            throw .timeout
        }
        var request = URLRequest(
            url: url(for: path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: remaining)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = session
        let delegate = delegate
        let log = log
        let sent = request
        do {
            return try await deadline.race {
                try await Self.fetch(sent, session: session, delegate: delegate, log: log)
            }
        } catch {
            throw Self.map(error, log: log)
        }
    }

    private static func fetch(
        _ request: URLRequest, session: URLSession, delegate: SessionDelegate, log: Log
    ) async throws -> (status: Int, body: Data, headers: [String: String]) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw RevokeGPTError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        let status = http.statusCode
        if (300..<400).contains(status) {
            bytes.task.cancel()
            log.event(.httpRedirectRefused)
            return (status, Data(), headers)
        }
        var data = Data()
        data.reserveCapacity(Int(min(max(http.expectedContentLength, 0), 65536)) + 1)
        for try await byte in bytes {
            data.append(byte)
            if data.count > Wire.maxResponseBytes {
                bytes.task.cancel()
                log.event(.httpBodyOverCap)
                break
            }
        }
        return (status, data, headers)
    }

    /// Codes only: no lower-layer error text survives.
    private static func map(_ error: any Error, log: Log) -> RevokeGPTError {
        if let e = error as? RevokeGPTError { return e }
        if error is DeadlineExceeded {
            log.event(.httpTimeout)
            return .timeout
        }
        if Task.isCancelled || error is CancellationError {
            log.event(.httpCancelled)
            return .cancelled
        }
        if let u = error as? URLError, u.code == .timedOut {
            log.event(.httpTimeout)
            return .timeout
        }
        log.event(.httpNetworkError)
        return .network
    }

    var redactedName: String { "URLSessionTransport" }
}

/// Refuses every redirect (the 3xx comes back as the response) and every HTTP authentication
/// challenge; server trust gets the system's default evaluation. No state, so it is Sendable.
private final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
