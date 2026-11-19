import os

/// SDK logging (protocol v1 section 23.5): event names only (`os.Logger`, subsystem
/// `com.revokegpt`, the name public), and only when the app turns debug logging on
/// (`Configuration.debugLogging`). An event carries no value, so a token, site key, request token,
/// code, key id, attestation byte, lower-layer error message or URL can never reach a log line:
/// `event` takes a case of `Event`, nothing else. A value, not a global switch: each component
/// gets the `Log` of its configuration (no mutable static state, R§6).
struct Log: Sendable {
    enum Event: String, Sendable, CaseIterable {
        case powSolved = "pow_solved"
        case powCancelled = "pow_cancelled"
        case powDeadlineExceeded = "pow_deadline_exceeded"
        case powInvalidParams = "pow_invalid_params"
        case powExhausted = "pow_exhausted"
        case httpRedirectRefused = "http_redirect_refused"
        case httpBodyOverCap = "http_body_over_cap"
        case httpTimeout = "http_timeout"
        case httpNetworkError = "http_network_error"
        case httpCancelled = "http_cancelled"
        case attestSimulator = "attest_simulator"
        case attestAppExtension = "attest_app_extension"
        case attestUnsupported = "attest_unsupported"
        case attestDeviceCheck = "attest_devicecheck"
        case attestDeviceCheckFailed = "attest_devicecheck_failed"
        case attestAttestation = "attest_attestation"
        case attestAssertion = "attest_assertion"
        case attestServerUnavailable = "attest_server_unavailable"
        case attestKeyDropped = "attest_key_dropped"
        case attestKeyPromoted = "attest_key_promoted"
        case attestKeyStoreError = "attest_keystore_error"
        /// An error that is not a known DCError case (a missing App Attest entitlement may show
        /// up this way; R§2, unverified): debug aid only, the call sends `unavailable(internal)`.
        case attestErrorUnrecognized = "attest_error_unrecognized"
        case attestFailed = "attest_failed"
        case sheetPresented = "sheet_presented"
        case sheetToken = "sheet_token"
        case sheetCancelled = "sheet_cancelled"
        case sheetFailed = "sheet_failed"
        case sheetMessageDropped = "sheet_message_dropped"
        case sheetNavigationBlocked = "sheet_navigation_blocked"
        case sheetAuthChallengeCancelled = "sheet_auth_challenge_cancelled"
        case sheetProcessTerminated = "sheet_process_terminated"
        case sheetNoWindow = "sheet_no_window"
        case sheetSendFailed = "sheet_send_failed"

        /// A diagnostic aid only (R§2, C17): logged at debug level, the rest at info.
        var level: OSLogType { self == .attestErrorUnrecognized ? .debug : .info }
    }

    /// Whether events are logged at all.
    let isEnabled: Bool
    /// Tests only: also receives every logged event.
    private let sink: (@Sendable (Event) -> Void)?

    init(isEnabled: Bool, sink: (@Sendable (Event) -> Void)? = nil) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    /// The default: nothing is logged.
    static let off = Log(isEnabled: false)

    private static let logger = Logger(subsystem: "com.revokegpt", category: "sdk")

    func event(_ e: Event) {
        guard isEnabled else { return }
        sink?(e)
        Self.logger.log(level: e.level, "\(e.rawValue, privacy: .public)")
    }
}

/// A type whose values hold secrets (site keys, tokens, challenges, attestation): every printable
/// form, `description`, `debugDescription` and the mirror `dump` walks, is its name only
/// (protocol v1 section 23.5).
protocol RedactedDescription: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    var redactedName: String { get }
}

extension RedactedDescription {
    var description: String { redactedName }
    var debugDescription: String { redactedName }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}
