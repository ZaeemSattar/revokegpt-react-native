import Foundation

/// RevokeGPT bot protection for native iOS apps (protocol v1 section 23).
///
/// ```swift
/// try await RevokeGPT.shared.configure(Configuration(siteKey: "rgpk_..."))
/// let token = try await RevokeGPT.shared.execute(action: "login")
/// // Send `token` to your server, which verifies it with siteverify.
/// ```
///
/// The SDK solves a proof of work natively, attests the app with App Attest (DeviceCheck where
/// App Attest is unsupported), and, when the site's rules escalate, shows the hosted challenge
/// page in a sheet. It never reads an advertising identifier, the device name, location or
/// contacts, and stores only the App Attest key id, in the Keychain.
///
/// All state lives in an actor, so the class is `Sendable` without locks (ruling C4).
public final class RevokeGPT: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The instance apps use.
    public static let shared = RevokeGPT(dependencies: .system)

    private let state: SDKState

    init(dependencies: Dependencies) {
        state = SDKState(dependencies: dependencies)
    }

    public var description: String { "RevokeGPT" }
    public var debugDescription: String { "RevokeGPT" }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    /// Sets the configuration. A later call replaces it (a new site key takes effect on the next
    /// call). Fails with `invalidArgument` for a malformed field (the first one is named), and
    /// with `busy` while a call is running.
    public func configure(_ configuration: Configuration) async throws(RevokeGPTError) {
        try await state.configure(configuration)
    }

    /// A RevokeGPT token for this app and `action` (1 to 100 of `A-Z a-z 0-9 / _`) and `cdata`
    /// (0 to 255 of `A-Z a-z 0-9 _ -`). When the site's rules ask for a puzzle, the hosted page is
    /// shown according to `presentation`; with `.never`, the call fails with
    /// `challengeRequired` instead. Calls may run concurrently. Cancelling the task cancels the
    /// call (`cancelled`).
    public func execute(
        action: String? = nil, cdata: String? = nil, presentation: Presentation = .automatic
    ) async throws(RevokeGPTError) -> String {
        let executor = try await state.begin()
        do {
            let token = try await executor.execute(
                action: action, cdata: cdata, presentation: presentation)
            await state.end()
            return token
        } catch {
            await state.end()
            throw error
        }
    }

    /// Account verification (protocol v1 section 17): shows the hosted page for the request token
    /// your server got from RevokeGPT, and returns the token the page produces.
    public func challengeAccount(
        requestToken: String, languageCode: String? = nil, presentation: Presentation = .automatic
    ) async throws(RevokeGPTError) -> String {
        let executor = try await state.begin()
        do {
            let token = try await executor.challengeAccount(
                requestToken: requestToken, languageCode: languageCode, presentation: presentation)
            await state.end()
            return token
        } catch {
            await state.end()
            throw error
        }
    }

    /// Generates the App Attest key ahead of time (call it at launch), so the first `execute`
    /// only attests it. Does nothing before `configure` or where App Attest is unavailable.
    public func prewarm() async {
        guard let (provider, log) = await state.prewarmTarget else { return }
        await provider.prewarm(log: log)
    }

    /// The sample app's benchmark: solves a fixed proof of work of `count` sub-puzzles at
    /// `difficultyBits` and returns the seconds it took. Not part of the public API.
    @_spi(Sample) public static func benchmarkProofOfWork(
        difficultyBits: Int = 16, count: Int = 16
    ) async throws(RevokeGPTError) -> TimeInterval {
        // swift-format-ignore: NeverForceUnwrap
        let salt = Base64URL.decode("WytiEULD3JbU4jQWWjXUiQ")!
        let start = Date()
        do {
            _ = try await Pow.solve(
                salt: salt, difficultyBits: difficultyBits, count: count,
                deadline: Deadline(after: 60))
        } catch {
            throw Executor.map(error)
        }
        return Date().timeIntervalSince(start)
    }

    /// Tests: the provider in use.
    var currentProvider: (any AttestationProvider)? {
        get async { await state.provider }
    }
}

/// What the SDK is built from; tests replace each part.
struct Dependencies: Sendable {
    var bundleId: @Sendable () -> String?
    var transport: @Sendable (_ endpoint: URL, _ log: Log) -> any Transport
    var provider: @Sendable (_ siteKey: String, _ keyScope: String?) -> any AttestationProvider
    var presenter: @Sendable (_ log: Log) -> any ChallengePresenter
    /// Tests only: receives every logged event.
    var logSink: (@Sendable (Log.Event) -> Void)?

    init(
        bundleId: @escaping @Sendable () -> String?,
        transport: @escaping @Sendable (URL, Log) -> any Transport,
        provider: @escaping @Sendable (String, String?) -> any AttestationProvider,
        presenter: @escaping @Sendable (Log) -> any ChallengePresenter,
        logSink: (@Sendable (Log.Event) -> Void)? = nil
    ) {
        self.bundleId = bundleId
        self.transport = transport
        self.provider = provider
        self.presenter = presenter
        self.logSink = logSink
    }

    static let system = Dependencies(
        bundleId: { Bundle.main.bundleIdentifier },
        transport: { URLSessionTransport(endpoint: $0, log: $1) },
        provider: { AppAttestProvider.system(siteKey: $0, keyScope: $1) },
        presenter: { log in
            #if canImport(UIKit) && canImport(WebKit)
                SheetPresenter(log: log)
            #else
                UnavailablePresenter()
            #endif
        })
}

/// The SDK's state: the configuration in use and the number of calls running.
actor SDKState: RedactedDescription {
    nonisolated var redactedName: String { "SDKState" }

    private struct Configured: Sendable {
        let configuration: Configuration
        let executor: Executor
    }

    private let dependencies: Dependencies
    private var current: Configured?
    private var running = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func configure(_ c: Configuration) throws(RevokeGPTError) {
        guard running == 0 else { throw .busy }
        try c.validate()
        guard let bundleId = dependencies.bundleId(), Validation.isIOSBundleId(bundleId) else {
            throw .invalidArgument(field: "bundleId")
        }
        let log = Log(isEnabled: c.debugLogging, sink: dependencies.logSink)
        // The same site key and scope keep the provider: one gate per Keychain item (R§2), so
        // an abandoned App Attest call can never overlap a new one on the same key. The log
        // travels with each call, so a logging change needs no new provider.
        let provider: any AttestationProvider
        if let old = current, old.configuration.siteKey == c.siteKey,
           old.configuration.keyScope == c.keyScope {
            provider = old.executor.provider
        } else {
            provider = dependencies.provider(c.siteKey, c.keyScope)
        }
        let settings = Executor.Settings(
            siteKey: c.siteKey, widgetOrigin: c.widgetOrigin, timeout: c.timeout,
            locale: c.locale ?? Self.preferredLanguage(), theme: c.theme,
            sdk: c._wrapper ?? .native, bundleId: bundleId, log: log)
        current = Configured(
            configuration: c,
            executor: Executor(
                settings: settings, transport: dependencies.transport(c.endpoint, log),
                provider: provider, presenter: dependencies.presenter(log)))
    }

    func begin() throws(RevokeGPTError) -> Executor {
        guard let current else { throw .notConfigured }
        running += 1
        return current.executor
    }

    func end() {
        running -= 1
    }

    var provider: (any AttestationProvider)? { current?.executor.provider }

    var prewarmTarget: (any AttestationProvider, Log)? {
        current.map { ($0.executor.provider, $0.executor.settings.log) }
    }

    /// The app's first preferred language when it is a language code, else `en`.
    private static func preferredLanguage() -> String {
        guard let first = Locale.preferredLanguages.first, first.utf8.count <= 35,
              Validation.isLanguageCode(first)
        else { return "en" }
        return first
    }
}
