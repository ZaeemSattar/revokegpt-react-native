import Foundation

/// How the SDK reaches RevokeGPT for one site (plan R10, protocol v1 section 23). Prints as its
/// type name only: the site key and the key scope never reach a log or a description.
public struct Configuration: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The hosted challenge page's theme.
    public enum Theme: String, Sendable {
        case light
        case dark
        case auto
    }

    // swift-format-ignore: NeverForceUnwrap
    /// `https://api.revokegpt.com`.
    public static let defaultEndpoint = URL(string: "https://api.revokegpt.com")!
    // swift-format-ignore: NeverForceUnwrap
    /// `https://js.revokegpt.com`.
    public static let defaultWidgetOrigin = URL(string: "https://js.revokegpt.com")!

    /// The site's public key, `rgpk_` and 20 letters and digits.
    public var siteKey: String
    /// The API origin, `https:` (plain `http:` only to a loopback host in a debug build). It may
    /// carry a path; never userinfo, a query or a fragment.
    public var endpoint: URL
    /// The hosted page's origin: a bare origin in canonical form (lowercase, no path or trailing
    /// `/`, no default port), with the same scheme rules as `endpoint`.
    public var widgetOrigin: URL
    /// The total deadline of one call, in seconds (1 to 60). It covers every network call, the
    /// proof of work and the attestation, not the time the challenge sheet is on screen. Seconds
    /// rather than `Duration`, which needs iOS 16.
    public var timeout: TimeInterval
    /// The hosted page's language (`en`, `pt-BR`, ...); nil uses the app's preferred language.
    public var locale: String?
    public var theme: Theme
    /// An optional per-user scope for the App Attest key: pass an opaque id of the app's signed-in
    /// account to get one key per account on this device (Apple's guidance), or nil for one
    /// key per install. Only a keyed hash of it is stored; use an opaque value, not an email.
    public var keyScope: String?
    /// Logs event names (never values) to `os.Logger`, subsystem `com.revokegpt`. Off by default.
    public var debugLogging: Bool
    /// Set by the Flutter and React Native plugins to name themselves in the `sdk` field.
    @_spi(Wrapper) public var _wrapper: SDKIdentity?

    public init(
        siteKey: String, endpoint: URL = Configuration.defaultEndpoint,
        widgetOrigin: URL = Configuration.defaultWidgetOrigin, timeout: TimeInterval = 10,
        locale: String? = nil, theme: Theme = .auto, keyScope: String? = nil,
        debugLogging: Bool = false
    ) {
        self.siteKey = siteKey
        self.endpoint = endpoint
        self.widgetOrigin = widgetOrigin
        self.timeout = timeout
        self.locale = locale
        self.theme = theme
        self.keyScope = keyScope
        self.debugLogging = debugLogging
    }

    public var description: String { "Configuration" }
    public var debugDescription: String { "Configuration" }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    /// Whether this build may use plain HTTP to a loopback host (debug builds only, section 23.1).
    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// Every field checked; the first bad one is named.
    func validate(allowLoopbackHTTP: Bool = Configuration.isDebugBuild) throws(RevokeGPTError) {
        guard Validation.isSiteKey(siteKey) else { throw .invalidArgument(field: "siteKey") }
        guard Self.isAllowed(endpoint, bareOrigin: false, allowLoopbackHTTP: allowLoopbackHTTP)
        else { throw .invalidArgument(field: "endpoint") }
        guard Self.isAllowed(widgetOrigin, bareOrigin: true, allowLoopbackHTTP: allowLoopbackHTTP)
        else { throw .invalidArgument(field: "widgetOrigin") }
        guard timeout.isFinite, (1...60).contains(timeout) else {
            throw .invalidArgument(field: "timeout")
        }
        if let locale, !Validation.isLanguageCode(locale) {
            throw .invalidArgument(field: "locale")
        }
        if let keyScope, !(1...1024).contains(keyScope.utf8.count) {
            throw .invalidArgument(field: "keyScope")
        }
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// `https:`, or `http:` to a loopback host when allowed; a host; no userinfo, query or
    /// fragment; for a bare origin, no path either.
    static func isAllowed(_ url: URL, bareOrigin: Bool, allowLoopbackHTTP: Bool) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              !bareOrigin || c.path.isEmpty || c.path == "/"
        else { return false }
        if bareOrigin, !isCanonicalOrigin(url, c) { return false }
        switch scheme {
        case "https": return true
        case "http": return allowLoopbackHTTP && loopbackHosts.contains(host)
        default: return false
        }
    }

    /// A bare origin in canonical form (section 23.1), so the sheet's origin checks compare equal
    /// strings: a lowercase scheme and host, no path (not even `/`), and no default port.
    private static func isCanonicalOrigin(_ url: URL, _ c: URLComponents) -> Bool {
        guard let scheme = c.scheme, let host = c.host, scheme == scheme.lowercased(),
              host == host.lowercased(), c.path.isEmpty
        else { return false }
        if let port = c.port {
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                return false
            }
            return url.absoluteString == "\(scheme)://\(host):\(port)"
        }
        return url.absoluteString == "\(scheme)://\(host)"
    }
}
