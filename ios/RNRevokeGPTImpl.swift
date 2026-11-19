import Foundation
import UIKit

/// The React Native module's Swift half, over the vendored native iOS SDK, which compiles into
/// this pod's module (tools/mobile-vendor, at pack time; plan R8). It only translates: calls go to
/// `RevokeGPT.shared`, a challenge sheet is presented on the view controller the module's
/// `presenter` returns (React Native's presented view controller), the `sdk` field names
/// `revokegpt-react-native` (R10), and every failure becomes an SDK error code plus at most three
/// details: the HTTP status, the server's request id and the retry-after seconds. No message, no
/// lower layer's text.
///
/// The module's invalidation (a reload, or the React instance going away) cancels the calls in
/// flight; they fail with `cancelled`, as on Android and in the Flutter plugin.
@objc(RNRevokeGPTImpl)
public final class RNRevokeGPTImpl: NSObject {
    /// The package version, in lockstep with the native SDKs (R7).
    static let version = "0.1.1"

    /// How a call ends: a token (or nil for `configure`), or a code and its details.
    public typealias Completion = @Sendable (_ value: String?, _ code: String?, _ details: [String: Any]?) -> Void

    private let presenter: Presenter
    private let calls = Calls()

    /// `presenter` returns the view controller to show a challenge sheet on; it is called on the
    /// main thread only.
    @objc public init(presenter: @escaping () -> UIViewController?) {
        self.presenter = Presenter(presenter)
    }

    @objc public func configure(
        siteKey: String, endpoint: String?, widgetOrigin: String?, timeoutMs: NSNumber?,
        locale: String?, theme: String?, keyScope: String?, debugLogging: NSNumber?,
        completion: @escaping Completion
    ) {
        let timeout = timeoutMs?.doubleValue
        let debug = debugLogging?.boolValue ?? false
        run(completion) {
            var c = Configuration(
                siteKey: siteKey,
                endpoint: try Self.url(endpoint, "endpoint") ?? Configuration.defaultEndpoint,
                widgetOrigin: try Self.url(widgetOrigin, "widgetOrigin")
                    ?? Configuration.defaultWidgetOrigin,
                timeout: try Self.seconds(timeout),
                locale: locale,
                theme: try Self.theme(theme),
                keyScope: keyScope,
                debugLogging: debug)
            c._wrapper = try SDKIdentity(name: "revokegpt-react-native", version: Self.version)
            try await RevokeGPT.shared.configure(c)
            return nil
        }
    }

    @objc public func execute(action: String?, cdata: String?, completion: @escaping Completion) {
        let presentation = presentation()
        run(completion) {
            try await RevokeGPT.shared.execute(
                action: action, cdata: cdata, presentation: presentation)
        }
    }

    @objc public func challengeAccount(
        requestToken: String, languageCode: String?, completion: @escaping Completion
    ) {
        let presentation = presentation()
        run(completion) {
            try await RevokeGPT.shared.challengeAccount(
                requestToken: requestToken, languageCode: languageCode,
                presentation: presentation)
        }
    }

    /// Cancels every call in flight (the module was invalidated).
    @objc public func cancelAll() {
        calls.cancelAll()
    }

    private func presentation() -> Presentation {
        let presenter = presenter
        return .viewController { presenter.viewController() }
    }

    /// Runs `work` as a tracked task and completes exactly once, with its value or its error's
    /// code and details.
    private func run(
        _ completion: @escaping Completion,
        _ work: @escaping @Sendable () async throws -> String?
    ) {
        let calls = calls
        let id = UUID()
        calls.add(id) {
            Task {
                defer { calls.remove(id) }
                do {
                    let value = try await work()
                    completion(value, nil, nil)
                } catch {
                    let (code, details) = Self.rejection(error)
                    completion(nil, code, details)
                }
            }
        }
    }

    /// The code JavaScript sees (a known code, else `internal`) and its details: only the
    /// status, the request id and the retry-after seconds, each only when present.
    static func rejection(_ error: any Error) -> (String, [String: Any]) {
        let e: RevokeGPTError
        switch error {
        case let r as RevokeGPTError: e = r
        case is CancellationError: e = .cancelled
        default: e = .internal
        }
        var details: [String: Any] = [:]
        switch e {
        case .httpError(let status, _):
            details["status"] = status
        case .api(_, let status, let requestId, _):
            if status != 0 { details["status"] = status }
            if let requestId { details["requestId"] = requestId }
        default: break
        }
        if let seconds = e.retryAfterSeconds { details["retryAfterSeconds"] = seconds }
        let code = codes.contains(e.code) ? e.code : "internal"
        return (code, details)
    }

    /// `MOBILE_SDK_ERRORS` (protocol v1 section 23.3).
    static let codes = Set(RevokeGPTError.ownCodes + RevokeGPTError.apiErrorCodes)

    private static func url(_ s: String?, _ field: String) throws(RevokeGPTError) -> URL? {
        guard let s else { return nil }
        guard let u = URL(string: s) else { throw .invalidArgument(field: field) }
        return u
    }

    /// Milliseconds (a whole number, 1000 to 60000; the JavaScript layer checks it too) to
    /// seconds; nil is the SDK's default.
    private static func seconds(_ ms: Double?) throws(RevokeGPTError) -> TimeInterval {
        guard let ms else { return 10 }
        guard ms.isFinite, ms.rounded() == ms, (1000...60000).contains(ms) else {
            throw .invalidArgument(field: "timeout")
        }
        return ms / 1000
    }

    private static func theme(_ s: String?) throws(RevokeGPTError) -> Configuration.Theme {
        guard let s else { return .auto }
        guard let t = Configuration.Theme(rawValue: s) else { throw .invalidArgument(field: "theme") }
        return t
    }
}

/// The presenter block, called on the main actor only (the SDK's `Presentation.viewController`
/// contract), so it can cross into the SDK's `@Sendable` closure.
private final class Presenter: @unchecked Sendable {
    private let block: () -> UIViewController?

    init(_ block: @escaping () -> UIViewController?) { self.block = block }

    @MainActor func viewController() -> UIViewController? { block() }
}

/// The calls in flight, so an invalidation can cancel them. Locked rather than an actor so
/// that a call is tracked before `run` returns: an invalidation right after a call starts still
/// cancels it, and a call started after an invalidation is cancelled at once.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false

    func add(_ id: UUID, _ start: () -> Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        let task = start()
        if invalidated { task.cancel() } else { tasks[id] = task }
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = nil
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        invalidated = true
        for t in tasks.values { t.cancel() }
        tasks = [:]
    }
}
