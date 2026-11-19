import Foundation

/// Why a RevokeGPT call failed (protocol v1 section 23.3). `code` is one of `MOBILE_SDK_ERRORS`:
/// the SDK's own codes, or an API error code passed through unchanged.
///
/// An error carries the code only. `description` never includes a value from the caller or the
/// network beyond the code, the HTTP status and the server's request id (itself charset-checked):
/// no site key, token, request token, server message or lower-layer error text.
public enum RevokeGPTError: Error, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, LocalizedError {
    /// An argument is malformed: `field` names it (`siteKey`, `endpoint`, `action`, `cdata`,
    /// `timeout`, ...), never its value.
    case invalidArgument(field: String)
    /// `execute` before `configure`.
    case notConfigured
    /// No connection, a TLS failure, or a refused connection.
    case network
    /// The call's total deadline passed.
    case timeout
    /// A 3xx (redirects are never followed), or a non-200 without an API error body of a known
    /// code; with `Retry-After` (whole seconds, at most 3600) on a 429 or 503.
    case httpError(status: Int, retryAfterSeconds: Int?)
    /// A 200 that is not a strict, schema-valid response, a body over 64 KiB, or an `appId` that is
    /// not this app's.
    case invalidResponse
    /// An API error (`code` from `API_ERROR_CODES`), with the server's request id when it sent a
    /// well-formed one, and `Retry-After` (whole seconds, at most 3600) on 429 and 503.
    case api(code: String, status: Int, requestId: String?, retryAfterSeconds: Int?)
    /// The solve needs a challenge the SDK may not show (`presentation: .never`, or no window).
    case challengeRequired
    /// The device cannot show the hosted challenge page safely.
    case challengeUnsupported
    /// The person closed the challenge, or the caller cancelled the call.
    case cancelled
    /// `configure` was called while a call was running (calls themselves run concurrently).
    case busy
    /// An unexpected state.
    case `internal`

    /// The code of this error, one of `MOBILE_SDK_ERRORS`.
    public var code: String {
        switch self {
        case .invalidArgument: "invalid-argument"
        case .notConfigured: "not-configured"
        case .network: "network-error"
        case .timeout: "timeout"
        case .httpError: "http-error"
        case .invalidResponse: "invalid-response"
        case .api(let code, _, _, _): code
        case .challengeRequired: "challenge-required"
        case .challengeUnsupported: "challenge-unsupported"
        case .cancelled: "cancelled"
        case .busy: "busy"
        case .internal: "internal"
        }
    }

    public var description: String {
        switch self {
        case .invalidArgument(let field): "RevokeGPTError(\(code), field \(field))"
        case .httpError(let status, _): "RevokeGPTError(\(code), status \(status))"
        case .api(_, let status, let requestId, _):
            if let requestId {
                "RevokeGPTError(\(code), status \(status), request \(requestId))"
            } else {
                "RevokeGPTError(\(code), status \(status))"
            }
        default: "RevokeGPTError(\(code))"
        }
    }

    /// The server's `Retry-After` on a 429 or 503 (whole seconds, at most 3600): wait at least this
    /// long before trying again. Nil for every other error.
    public var retryAfterSeconds: Int? {
        switch self {
        case .httpError(_, let seconds), .api(_, _, _, let seconds): seconds
        default: nil
        }
    }

    public var debugDescription: String { description }
    public var errorDescription: String? { description }

    /// The SDK's own codes (`MOBILE_OWN_ERROR_CODES`), in protocol order.
    static let ownCodes = [
        "invalid-argument", "not-configured", "network-error", "timeout", "http-error",
        "invalid-response", "challenge-required", "challenge-unsupported", "cancelled", "busy",
        "internal",
    ]

    /// `API_ERROR_CODES`, in protocol order: the codes passed through from an error body. Pinned
    /// to `mobile-client.json` (`apiErrorCodes`) by ErrorCodeTests.
    static let apiErrorCodes = [
        "bad-request", "not-found", "payload-too-large", "invalid-site-key",
        "hostname-not-allowed", "site-disabled", "challenge-expired", "challenge-invalid",
        "pow-invalid", "rate-limited", "quota-exceeded", "internal-error",
        "unsupported-media-type", "app-not-allowed", "plan-required", "plan-restricted",
    ]
}
