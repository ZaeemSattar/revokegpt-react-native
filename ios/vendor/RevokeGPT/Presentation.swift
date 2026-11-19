import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// Where the SDK may show the hosted challenge page when a solve needs a puzzle, or for account
/// verification (protocol v1 section 23.2).
public enum Presentation: Sendable {
    /// On the foreground key window's top-most view controller.
    case automatic
    /// Never: a call that needs the page fails with `challengeRequired` and returns no token.
    case never
    #if canImport(UIKit)
        /// On the view controller this returns (nil: `challengeRequired`).
        case viewController(@MainActor @Sendable () -> UIViewController?)
    #endif

    /// For tests and events: the case name.
    var kind: String {
        switch self {
        case .automatic: "automatic"
        case .never: "never"
        #if canImport(UIKit)
            case .viewController: "viewController"
        #endif
        }
    }
}

/// What the hosted page is asked to show (section 23.1): the native-to-page message's content,
/// and the page URL's parameters.
struct ChallengeSheet: Sendable, Equatable, RedactedDescription {
    enum Content: Sendable, Equatable {
        /// A solve's puzzle, as received; the challenge's `signals.key` and id (the PoW salt).
        case puzzle(JSONValue, signalsKey: String, cid: String)
        /// Account verification (section 17).
        case mfa(requestToken: String, languageCode: String?)
    }

    let content: Content
    let widgetOrigin: URL
    let siteKey: String
    /// The page URL's app id: the bundle id, which the page matches against the site's app list
    /// (never the sealed `<teamId>.<bundleId>`, which belongs in the binding bytes only).
    let appId: String
    let locale: String
    let theme: Configuration.Theme

    var redactedName: String { "ChallengeSheet" }
}

/// How the sheet ended.
enum ChallengeResult: Sendable, Equatable, RedactedDescription {
    /// The page's token.
    case token(String)
    /// The person closed the page.
    case cancelled
    /// The page's error code: an API code passed through, or `puzzle-retry`/`puzzle-new`.
    case error(code: String)
    /// No window or view controller to show it on.
    case noWindow
    /// The device cannot show the page safely.
    case unsupported
    /// Another sheet is up.
    case busy
    /// The page could not be loaded or ended unexpectedly (a non-200 page, a download, an HTTP
    /// authentication challenge, a crashed web content process).
    case failed
    /// The page could not be reached.
    case network
    /// The page's URL or message could not be built for this sheet (a puzzle the page would
    /// refuse).
    case invalidMessage
    /// The sheet stayed up past its time limit.
    case timedOut

    var redactedName: String { "ChallengeResult" }
}

/// Shows the hosted challenge page (ruling C18: the seam the executor uses; the real sheet is
/// Task 12's). Must honour cancellation of the calling task by closing the sheet.
protocol ChallengePresenter: Sendable {
    func present(_ sheet: ChallengeSheet, presentation: Presentation) async -> ChallengeResult
}

/// The presenter where there is no WebKit UI (macOS builds of the package): it cannot show
/// anything.
struct UnavailablePresenter: ChallengePresenter {
    func present(_ sheet: ChallengeSheet, presentation: Presentation) async -> ChallengeResult {
        .unsupported
    }
}
