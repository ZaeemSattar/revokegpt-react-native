#if canImport(UIKit) && canImport(WebKit)
    import UIKit

    /// Shows the hosted page in the sheet (protocol v1 section 23.2).
    ///
    /// - One sheet at a time across the app: a second call while one is up gets `busy`. The
    ///   gate is released only once the sheet has fully gone, so a follow-up sheet (after
    ///   `puzzle-retry` or `puzzle-new`) never meets a host still dismissing the last one.
    /// - The host must be in a window and free (not presenting, not mid-transition), and UIKit
    ///   must accept and finish the presentation within `presentTimeout`; otherwise `noWindow`
    ///   (the call then fails with `challengeRequired`), never an invisible or hung sheet.
    /// - The page loads only once the sheet is on screen.
    /// - The sheet's whole time is bounded (`sheetTimeout`, default 10 minutes: `timedOut`).
    /// - Cancelling the calling task closes the sheet: `cancelled`.
    ///
    /// App extensions: the SDK compiles with `APPLICATION_EXTENSION_API_ONLY` (it never names
    /// `UIApplication.shared`), and in an extension `.automatic` finds no window (`noWindow`).
    struct SheetPresenter: ChallengePresenter {
        let log: Log
        var sheetTimeout: TimeInterval = 600
        /// How long UIKit may take to finish presenting the sheet.
        var presentTimeout: TimeInterval = 5

        /// The single-sheet rule's state (a reference to one actor: no mutable static).
        static let gate = SheetGate()

        func present(_ sheet: ChallengeSheet, presentation: Presentation) async -> ChallengeResult {
            guard await Self.gate.enter() else { return .busy }
            let result = await Self.show(
                sheet, presentation: presentation, log: log, timeout: sheetTimeout,
                presentTimeout: presentTimeout)
            await Self.gate.leave()
            return result
        }

        @MainActor private static func show(
            _ sheet: ChallengeSheet, presentation: Presentation, log: Log, timeout: TimeInterval,
            presentTimeout: TimeInterval
        ) async -> ChallengeResult {
            guard let session = ChallengeWebSession(sheet: sheet, log: log) else {
                return .invalidMessage
            }
            if Task.isCancelled { return .cancelled }
            guard let host = host(for: presentation), canPresent(on: host) else {
                log.event(.sheetNoWindow)
                return .noWindow
            }
            let controller = ChallengeSheetController(session: session)
            guard await present(controller, on: host, within: presentTimeout),
                  controller.viewIfLoaded?.window != nil
            else {
                await controller.dismissAndWait()
                log.event(.sheetNoWindow)
                return .noWindow
            }
            let result = await session.runCancellable(timeout: timeout)
            await controller.dismissAndWait()
            return result
        }

        /// A host UIKit will present on: in a window, not presenting, not mid-transition.
        @MainActor static func canPresent(on host: UIViewController) -> Bool {
            host.viewIfLoaded?.window != nil && host.presentedViewController == nil
                && !host.isBeingDismissed && !host.isBeingPresented
        }

        /// Presents and waits for the presentation to finish; false when UIKit refused it (it
        /// then neither sets `presentingViewController` nor calls the completion) or did not
        /// finish within `seconds`.
        @MainActor private static func present(
            _ controller: UIViewController, on host: UIViewController, within seconds: TimeInterval
        ) async -> Bool {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let once = ResumeOnce(c)
                host.present(controller, animated: true) { once.resume(true) }
                if controller.presentingViewController == nil {
                    once.resume(false)
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    once.resume(false)
                }
            }
        }

        /// Where to present: the caller's view controller, or the top-most one of the foreground
        /// key window. Nil when there is none (always in an app extension for `.automatic`).
        @MainActor static func host(for presentation: Presentation) -> UIViewController? {
            let root: UIViewController?
            switch presentation {
            case .never: return nil
            case .viewController(let make): root = make()
            case .automatic: root = keyWindowRoot()
            }
            guard var top = root else { return nil }
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            return top
        }

        /// The foreground key window's root view controller. The application object is reached
        /// through the Objective-C runtime, so the SDK compiles for app extensions (which have no
        /// `UIApplication.shared`); in an extension it is not used at all.
        @MainActor private static func keyWindowRoot() -> UIViewController? {
            guard !Bundle.main.bundlePath.hasSuffix(".appex"),
                  let app = (UIApplication.self as AnyObject)
                      .value(forKey: "sharedApplication") as? UIApplication
            else { return nil }
            return app.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?.rootViewController
        }
    }

    /// Resumes a continuation once, whichever of two paths comes first.
    @MainActor private final class ResumeOnce {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ c: CheckedContinuation<Bool, Never>) { continuation = c }

        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// One sheet at a time.
    actor SheetGate {
        private var open = false

        func enter() -> Bool {
            if open { return false }
            open = true
            return true
        }

        func leave() { open = false }
    }
#endif
