#if canImport(UIKit) && canImport(WebKit)
    import UIKit
    import WebKit

    /// One hosted challenge page in a hardened WKWebView (protocol v1 section 23.1, R§1, plan
    /// Review Focus 1). It ends exactly once, with the first of: the page's token, error or cancel
    /// for the open request id; Close; a page that cannot load (non-200, a download, a failed
    /// load, an HTTP authentication challenge); a crashed web content process.
    ///
    /// Hardening:
    /// - an ephemeral data store (`nonPersistent()`), dropped with the web view on close;
    /// - no script of the SDK's own in the page: one script message handler, `revokegpt`, in the
    ///   page world; native to page only through `callAsyncJavaScript` with the message text as an
    ///   argument (never string-built script);
    /// - navigation only to the widget origin (scheme, host and port); everything else (another
    ///   host, `javascript:`, `file:`, `data:`, `blob:`, `about:`) is cancelled; no windows
    ///   (`window.open` does nothing), no downloads, no link previews, no back-forward gestures, no
    ///   data detectors, media only on a user gesture, not inspectable;
    /// - HTTP authentication challenges are cancelled; server trust gets the system's default
    ///   evaluation (R9: no pinning);
    /// - a message counts only from the main frame of the widget origin, as text read strictly
    ///   (`Bridge.parsePageMessage`), with the open request's id;
    /// - camera, microphone and motion permission requests are denied.
    ///
    /// `limitsNavigationsToAppBoundDomains` is deliberately not set: it needs the host app's
    /// `WKAppBoundDomains`, which an SDK cannot require; the navigation policy above does the
    /// limiting. Fraudulent-website warnings keep their default (on).
    @MainActor final class ChallengeWebSession: NSObject, WKNavigationDelegate, WKUIDelegate,
        RedactedDescription {
        let pageURL: URL
        let requestId: String
        private let messageText: String
        private let origin: (scheme: String, host: String, port: Int)
        private let log: Log
        private(set) var webView: WKWebView?
        private var initialNavigation: WKNavigation?
        private var result: ChallengeResult?
        private var waiters: [CheckedContinuation<ChallengeResult, Never>] = []
        /// The page's content height (CSS pixels), for the sheet's detent.
        var onHeight: ((Int) -> Void)?

        nonisolated var redactedName: String { "ChallengeWebSession" }

        /// Nil when the sheet's page URL or message cannot be built (the page would refuse it).
        init?(sheet: ChallengeSheet, log: Log, requestId: String = Bridge.newRequestId()) {
            guard let url = Bridge.pageURL(for: sheet),
                  let message = Bridge.nativeMessage(for: sheet, id: requestId),
                  let text = Bridge.text(of: message),
                  let c = URLComponents(url: sheet.widgetOrigin, resolvingAgainstBaseURL: false),
                  let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased()
            else { return nil }
            pageURL = url
            self.requestId = requestId
            messageText = text
            origin = (scheme, host, c.port ?? Self.defaultPort(scheme))
            self.log = log
        }

        private static func defaultPort(_ scheme: String) -> Int { scheme == "http" ? 80 : 443 }

        /// The web view, made once.
        func makeWebView() -> WKWebView {
            if let webView { return webView }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.dataDetectorTypes = []
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.userContentController.add(
                MessageProxy(self), contentWorld: .page, name: Bridge.handlerName)
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.navigationDelegate = self
            wv.uiDelegate = self
            wv.allowsLinkPreview = false
            wv.allowsBackForwardNavigationGestures = false
            if #available(iOS 16.4, *) { wv.isInspectable = false }
            webView = wv
            return wv
        }

        /// Loads the page and waits for the end.
        func run() async -> ChallengeResult {
            if let result { return result }
            let wv = makeWebView()
            if initialNavigation == nil {
                log.event(.sheetPresented)
                initialNavigation = wv.load(URLRequest(
                    url: pageURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                    timeoutInterval: 30))
            }
            return await withCheckedContinuation { c in
                if let result {
                    c.resume(returning: result)
                } else {
                    waiters.append(c)
                }
            }
        }

        /// `run`, ending with `cancelled` (and the page closed) when the calling task is
        /// cancelled, and with `timedOut` after `timeout` seconds.
        func runCancellable(timeout: TimeInterval) async -> ChallengeResult {
            let nanoseconds = UInt64(max(0, min(timeout, 86_400)) * 1_000_000_000)
            let timer = Task { @MainActor in
                guard (try? await Task.sleep(nanoseconds: nanoseconds)) != nil else { return }
                self.finish(.timedOut)
            }
            let result = await withTaskCancellationHandler {
                await run()
            } onCancel: {
                Task { @MainActor in self.finish(.cancelled) }
            }
            timer.cancel()
            return result
        }

        /// The person closed the sheet.
        func close() { finish(.cancelled) }

        /// Ends the session with `r` unless it has already ended, and tears the web view down.
        func finish(_ r: ChallengeResult) {
            guard result == nil else { return }
            result = r
            log.event(Self.event(for: r))
            if let wv = webView {
                wv.stopLoading()
                wv.configuration.userContentController.removeScriptMessageHandler(
                    forName: Bridge.handlerName, contentWorld: .page)
                wv.navigationDelegate = nil
                wv.uiDelegate = nil
                wv.removeFromSuperview()
            }
            webView = nil
            for c in waiters { c.resume(returning: r) }
            waiters = []
        }

        private static func event(for r: ChallengeResult) -> Log.Event {
            switch r {
            case .token: .sheetToken
            case .cancelled: .sheetCancelled
            default: .sheetFailed
            }
        }

        // MARK: Messages

        fileprivate func received(_ message: WKScriptMessage) {
            guard result == nil, message.frameInfo.isMainFrame,
                  isWidgetOrigin(message.frameInfo.securityOrigin),
                  let m = Bridge.parsePageMessage(message.body)
            else {
                log.event(.sheetMessageDropped)
                return
            }
            switch m {
            case .ready:
                send()
            case .height(let px):
                onHeight?(px)
            case .token(let id, let token) where id == requestId:
                finish(.token(token))
            case .error(let id, let code) where id == requestId:
                finish(.error(code: code))
            case .cancel(let id) where id == requestId:
                finish(.cancelled)
            default:
                // Another request's id: dropped, not answered.
                log.event(.sheetMessageDropped)
            }
        }

        /// The request's message, as text, through the page's own receiver.
        private func send() {
            guard let wv = webView else { return }
            let text = messageText
            let log = log
            Task { @MainActor in
                do {
                    _ = try await wv.callAsyncJavaScript(
                        Bridge.receiverCall, arguments: ["m": text], in: nil, contentWorld: .page)
                } catch {
                    // A page without its receiver: the sheet waits for Close or its timeout.
                    log.event(.sheetSendFailed)
                }
            }
        }

        private func isWidgetOrigin(_ o: WKSecurityOrigin) -> Bool {
            o.protocol.lowercased() == origin.scheme && o.host.lowercased() == origin.host
                && (o.port == 0 ? Self.defaultPort(o.protocol.lowercased()) : o.port) == origin.port
        }

        private func isWidgetOrigin(_ url: URL?) -> Bool {
            guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased()
            else { return false }
            return scheme == origin.scheme && host == origin.host
                && (c.port ?? Self.defaultPort(scheme)) == origin.port
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let allowed = navigationAction.targetFrame != nil
                && !navigationAction.shouldPerformDownload
                && isWidgetOrigin(navigationAction.request.url)
            if !allowed { log.event(.sheetNavigationBlocked) }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            let ok = navigationResponse.canShowMIMEType
                && (!navigationResponse.isForMainFrame || status == 200)
            decisionHandler(ok ? .allow : .cancel)
            if !ok, navigationResponse.isForMainFrame { finish(.failed) }
        }

        func webView(
            _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor (
                URLSession.AuthChallengeDisposition, URLCredential?
            ) -> Void
        ) {
            let method = challenge.protectionSpace.authenticationMethod
            if method == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                log.event(.sheetAuthChallengeCancelled)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: any Error
        ) {
            // Only the page itself failing to load ends the session; a navigation the policy
            // cancelled leaves the page as it was.
            guard navigation == initialNavigation else { return }
            finish(Self.isNetwork(error) ? .network : .failed)
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error
        ) {
            guard navigation == initialNavigation else { return }
            finish(Self.isNetwork(error) ? .network : .failed)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log.event(.sheetProcessTerminated)
            finish(.failed)
        }

        /// A load that failed for want of a network. TLS failures (a bad or untrusted certificate,
        /// a failed handshake) are not: a man in the middle must not look like a retryable
        /// network error, so they are `failed`.
        private static func isNetwork(_ error: any Error) -> Bool {
            let e = error as NSError
            let tls = [
                NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                NSURLErrorClientCertificateRequired,
                NSURLErrorAppTransportSecurityRequiresSecureConnection,
            ]
            return e.domain == NSURLErrorDomain && e.code != NSURLErrorCancelled
                && !tls.contains(e.code)
        }

        // MARK: WKUIDelegate

        /// No windows: `window.open` and `target=_blank` do nothing.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            log.event(.sheetNavigationBlocked)
            return nil
        }

        /// No camera or microphone for the page.
        func webView(
            _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        /// No motion or orientation data for the page.
        func webView(
            _ webView: WKWebView,
            requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        /// The page closing itself (`window.close()`) is the person leaving it.
        func webViewDidClose(_ webView: WKWebView) {
            finish(.cancelled)
        }
    }

    /// Resumes a continuation once, whichever path comes first.
    @MainActor private final class VoidOnce {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ c: CheckedContinuation<Void, Never>) { continuation = c }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// The script message handler, holding the session weakly (WKUserContentController retains
    /// its handlers).
    @MainActor private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var session: ChallengeWebSession?

        init(_ session: ChallengeWebSession) { self.session = session }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            session?.received(message)
        }
    }

    /// The sheet: the page, a native Close button that is always there, and detents that follow
    /// the page's `height` message (medium and large on iOS 15; the page's height on iOS 16+).
    @MainActor final class ChallengeSheetController: UIViewController,
        UIAdaptivePresentationControllerDelegate {
        let session: ChallengeWebSession

        init(session: ChallengeWebSession) {
            self.session = session
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .pageSheet
            if let sheet = sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            presentationController?.delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let wv = session.makeWebView()
            wv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(wv)
            let close = UIButton(type: .close)
            close.translatesAutoresizingMaskIntoConstraints = false
            close.accessibilityIdentifier = "revokegpt.sheet.close"
            // The system close button has no label of its own: VoiceOver reads this one.
            close.accessibilityLabel = "Close"
            close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
            view.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                close.trailingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                wv.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 4),
                wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            session.onHeight = { [weak self] px in self?.fit(px) }
        }

        /// Close ends the session; the presenter then dismisses the sheet and waits for it.
        @objc private func closeTapped() {
            session.close()
        }

        /// Dismisses the sheet (or waits for a dismissal under way) and returns once it is gone,
        /// or after `seconds` at most: UIKit's completion is never waited for unbounded.
        func dismissAndWait(within seconds: TimeInterval = 3) async {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let once = VoidOnce(c)
                if isBeingDismissed {
                    if let coordinator = transitionCoordinator {
                        coordinator.animate(alongsideTransition: nil) { _ in once.resume() }
                    } else {
                        once.resume()
                        return
                    }
                } else if presentingViewController != nil {
                    // Animated only when the sheet really is on screen (a presentation that never
                    // finished is removed at once).
                    let animated = viewIfLoaded?.window != nil && !isBeingPresented
                    dismiss(animated: animated) { once.resume() }
                } else {
                    once.resume()
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    once.resume()
                }
            }
        }

        /// Swiping the sheet away is Close.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            session.close()
        }

        /// The page's height (plus the Close bar) as the sheet's detent, at most the largest the
        /// sheet allows; on iOS 15, medium or large.
        private func fit(_ px: Int) {
            guard let sheet = sheetPresentationController else { return }
            let height = CGFloat(px) + 56
            sheet.animateChanges {
                if #available(iOS 16.0, *) {
                    let page = UISheetPresentationController.Detent.Identifier("revokegpt.page")
                    sheet.detents = [
                        .custom(identifier: page) { context in
                            min(height, context.maximumDetentValue)
                        },
                        .large(),
                    ]
                    sheet.selectedDetentIdentifier = page
                } else {
                    let large = height > 480
                    sheet.detents = large ? [.large()] : [.medium(), .large()]
                    sheet.selectedDetentIdentifier = large ? .large : .medium
                }
            }
        }
    }
#endif
