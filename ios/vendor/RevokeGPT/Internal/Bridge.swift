import Foundation

/// The message bridge between the hosted challenge page and the native sheet (protocol v1
/// section 23.1), a port of `packages/protocol/src/mobile.ts` held to `mobile-bridge.json`:
/// `parsePageMessage` (page to native), `parseNativeMessage` with `isStrictBridgeText` and
/// `parseBridgePuzzle` (what the page accepts; every message the SDK writes is read back through
/// it before it is sent), and `appPageUrl`.
enum Bridge {
    static let version = 1
    /// `BRIDGE_MAX_BYTES`: the longest page message text read.
    static let maxPageBytes = 4096
    /// `NATIVE_MAX_BYTES`: the longest native message text the page reads.
    static let maxNativeBytes = 16384
    /// `BRIDGE_NAMES.iosHandler`: `window.webkit.messageHandlers.revokegpt`.
    static let handlerName = "revokegpt"
    /// `BRIDGE_NAMES.iosReceiver`: the page's `window.__rgNative(text)`.
    static let receiverCall = "window.__rgNative(m)"

    // MARK: Page to native

    enum PageMessage: Equatable, Sendable, RedactedDescription {
        case ready
        case token(id: String, token: String)
        case error(id: String, code: String)
        case cancel(id: String)
        case height(px: Int)

        var redactedName: String { "PageMessage" }
    }

    private static let pageFields: [String: Set<String>] = [
        "ready": ["rg", "type"],
        "token": ["rg", "type", "id", "token"],
        "error": ["rg", "type", "id", "code"],
        "cancel": ["rg", "type", "id"],
        "height": ["rg", "type", "px"],
    ]

    /// A page message: the text the page posts (at most 4096 UTF-8 bytes, no backslash at all,
    /// strict JSON with no duplicate key, `rg` and `px` written as plain integers), or an object
    /// a platform already decoded (NSDictionary of NSString and NSNumber), held to the same
    /// fields and ranges. Exactly the fields of its type; anything else is nil (dropped).
    static func parsePageMessage(_ body: Any) -> PageMessage? {
        if let text = body as? String {
            guard text.utf16.count <= maxPageBytes, text.utf8.count <= maxPageBytes,
                  !text.utf8.contains(0x5C),
                  case .object(let o)? = JSONValue.parse(Data(text.utf8)),
                  matches(rgText, text)
            else { return nil }
            if o["type"]?.string == "height", !matches(pxText, text) { return nil }
            return pageMessage(o)
        }
        guard let dict = body as? NSDictionary, case .object(let o)? = jsonValue(dict) else {
            return nil
        }
        return pageMessage(o)
    }

    private static func pageMessage(_ o: [String: JSONValue]) -> PageMessage? {
        guard let type = o["type"]?.string, let allowed = pageFields[type],
              Set(o.keys) == allowed, o.count == allowed.count, o["rg"] == .number(1)
        else { return nil }
        let id = o["id"]?.string.flatMap { isId($0) ? $0 : nil }
        switch type {
        case "ready":
            return .ready
        case "token":
            guard let id, let token = o["token"]?.string, Validation.isResponseToken(token)
            else { return nil }
            return .token(id: id, token: token)
        case "error":
            guard let id, let code = o["code"]?.string, isErrorCode(code) else { return nil }
            return .error(id: id, code: code)
        case "cancel":
            return id.map { .cancel(id: $0) }
        case "height":
            guard let px = o["px"]?.int, (120...2000).contains(px) else { return nil }
            return .height(px: px)
        default:
            return nil
        }
    }

    /// `"rg": 1` written as a plain integer, then `,` or `}` (the text form of `RG_TEXT`).
    private static let rgText = #""rg"[ \t\n\r]*:[ \t\n\r]*1[ \t\n\r]*[,}]"#
    /// `"px"` written as a plain non-negative integer (`PX_TEXT`).
    private static let pxText = #""px"[ \t\n\r]*:[ \t\n\r]*(?:0|[1-9][0-9]*)[ \t\n\r]*[,}]"#

    /// Whether `pattern` occurs in `text` (a search, as the reference's `test`).
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A decoded platform object as a JSON tree (booleans stay booleans; any other type is nil).
    private static func jsonValue(_ v: Any) -> JSONValue? {
        switch v {
        case let n as NSNumber:
            let isBool = CFGetTypeID(n) == CFBooleanGetTypeID()
            return isBool ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case is NSNull:
            return .null
        case let a as NSArray:
            var out: [JSONValue] = []
            for e in a {
                guard let j = jsonValue(e) else { return nil }
                out.append(j)
            }
            return .array(out)
        case let d as NSDictionary:
            var out: [String: JSONValue] = [:]
            for (k, e) in d {
                guard let k = k as? String, let j = jsonValue(e) else { return nil }
                out[k] = j
            }
            return .object(out)
        default:
            return nil
        }
    }

    /// `BRIDGE_ID_RE`: 1 to 64 of `A-Z a-z 0-9 _ -`.
    static func isId(_ s: String) -> Bool { Validation.isBase64URL(s, length: 1...64) }

    /// `BRIDGE_ERROR_CODE_RE`: 1 to 64 of `a-z 0-9 -`.
    static func isErrorCode(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count)
            && s.utf8.allSatisfy {
                (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D
            }
    }

    // MARK: Native to page

    /// The puzzle as the page shows it (`BridgePuzzle`): its known fields only.
    struct BridgePuzzle: Equatable, Sendable, RedactedDescription {
        let kind: String
        let challenge: String
        let assets: [String]
        let attemptsLeft: Int
        var step: Int?
        var steps: Int?
        var options: Int?
        /// `range.max` (100 or 359); `min` is 0 and `step` 1.
        var rangeMax: Int?

        var redactedName: String { "BridgePuzzle" }
    }

    enum NativeMessage: Equatable, Sendable, RedactedDescription {
        case puzzle(
            id: String, puzzle: BridgePuzzle, signalsKey: String, cid: String, locale: String,
            theme: Configuration.Theme)
        case mfa(id: String, requestToken: String, languageCode: String?)

        var redactedName: String { "NativeMessage" }
    }

    /// The page's reading of a native message (`parseNativeMessage`).
    static func parseNativeMessage(_ text: String) -> NativeMessage? {
        guard text.utf16.count <= maxNativeBytes, text.utf8.count <= maxNativeBytes,
              isStrictBridgeText(text), case .object(let o)? = JSONValue.parse(Data(text.utf8)),
              o["rg"] == .number(1), let id = o["id"]?.string, isId(id)
        else { return nil }
        let keys = Set(o.keys)
        switch o["type"]?.string {
        case "puzzle":
            guard keys == ["rg", "type", "id", "puzzle", "signalsKey", "cid", "locale", "theme"],
                  let p = o["puzzle"], let puzzle = parseBridgePuzzle(p),
                  let locale = o["locale"]?.string, isBridgeLocale(locale),
                  let signalsKey = o["signalsKey"]?.string, isKey64(signalsKey),
                  let cid = o["cid"]?.string, isKey64(cid),
                  let themeText = o["theme"]?.string,
                  let theme = Configuration.Theme(rawValue: themeText)
            else { return nil }
            return .puzzle(
                id: id, puzzle: puzzle, signalsKey: signalsKey, cid: cid, locale: locale,
                theme: theme)
        case "mfa":
            let hasCode = keys.contains("languageCode")
            let base: Set<String> = ["rg", "type", "id", "requestToken"]
            let fields = hasCode ? base.union(["languageCode"]) : base
            guard keys == fields, let requestToken = o["requestToken"]?.string,
                  Validation.isResponseToken(requestToken)
            else { return nil }
            var languageCode: String?
            if hasCode {
                guard let code = o["languageCode"]?.string, isBridgeLocale(code) else { return nil }
                languageCode = code
            }
            return .mfa(id: id, requestToken: requestToken, languageCode: languageCode)
        default:
            return nil
        }
    }

    /// `parseBridgePuzzle`: the known fields, each checked; a known kind must have its shape; an
    /// unknown kind is kept.
    static func parseBridgePuzzle(_ value: JSONValue) -> BridgePuzzle? {
        guard let v = value.object,
              let kind = v["kind"]?.string, (1...40).contains(kind.utf16.count),
              let challenge = v["challenge"]?.string, (1...4096).contains(challenge.utf16.count),
              let assetValues = v["assets"]?.array, (1...9).contains(assetValues.count)
        else { return nil }
        let assets = assetValues.compactMap(\.string)
        guard assets.count == assetValues.count, assets.allSatisfy(isAssetPath),
              let attemptsLeft = v["attemptsLeft"]?.int, (1...3).contains(attemptsLeft)
        else { return nil }
        var out = BridgePuzzle(
            kind: kind, challenge: challenge, assets: assets, attemptsLeft: attemptsLeft)
        if v["step"] != nil || v["steps"] != nil {
            guard let steps = v["steps"]?.int, (1...9).contains(steps),
                  let step = v["step"]?.int, (1...steps).contains(step)
            else { return nil }
            out.step = step
            out.steps = steps
        }
        if let o = v["options"] {
            guard let options = o.int, (2...9).contains(options) else { return nil }
            out.options = options
        }
        if let r = v["range"] {
            guard let range = r.object, range["min"] == .number(0), range["step"] == .number(1),
                  let max = range["max"], max == .number(100) || max == .number(359)
            else { return nil }
            out.rangeMax = max == .number(100) ? 100 : 359
        }
        switch kind {
        case "slider": if out.rangeMax != 100 || assets.count < 2 { return nil }
        case "rotate": if out.rangeMax != 359 { return nil }
        case "odd-one-out": if assets.count < 2 { return nil }
        case "audio": if out.options == nil || out.options != assets.count - 1 { return nil }
        default: break
        }
        return out
    }

    /// `^/v1/puzzle/asset/[A-Za-z0-9_.-]{1,500}$`.
    private static func isAssetPath(_ s: String) -> Bool {
        let prefix = Array("/v1/puzzle/asset/".utf8)
        let b = Array(s.utf8)
        guard b.count > prefix.count, b.count - prefix.count <= 500, b.starts(with: prefix) else {
            return false
        }
        return b[prefix.count...].allSatisfy { Validation.isBase64URLByte($0) || $0 == 0x2E }
    }

    /// `^[A-Za-z0-9_-]{1,64}$`.
    private static func isKey64(_ s: String) -> Bool { Validation.isBase64URL(s, length: 1...64) }

    /// A language code of at most 35 characters.
    private static func isBridgeLocale(_ s: String) -> Bool {
        s.utf16.count <= 35 && Validation.isLanguageCode(s)
    }

    /// `isStrictBridgeText`: one JSON value, no backslash at all, no control character in a
    /// string, no duplicate key in any object, every number a plain non-negative integer. A linear
    /// scan over the UTF-8 bytes, without recursion.
    static func isStrictBridgeText(_ s: String) -> Bool {
        let b = Array(s.utf8)
        if b.contains(0x5C) { return false }
        let n = b.count
        var i = 0
        var stack: [Set<[UInt8]>?] = []
        enum State { case value, key, after }
        var state = State.value
        func at(_ k: Int) -> UInt8? { k < n ? b[k] : nil }
        func isDigit(_ c: UInt8?) -> Bool { c.map { (0x30...0x39).contains($0) } ?? false }
        func ws() {
            while let c = at(i), c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
        }
        func str() -> [UInt8]? {
            i += 1
            let start = i
            while let c = at(i) {
                if c == 0x22 {
                    defer { i += 1 }
                    return Array(b[start..<i])
                }
                if c < 0x20 { return nil }
                i += 1
            }
            return nil
        }
        while true {
            ws()
            switch state {
            case .value:
                guard let c = at(i) else { return false }
                if c == 0x7B || c == 0x5B {
                    i += 1
                    ws()
                    if at(i) == (c == 0x7B ? 0x7D : 0x5D) {
                        i += 1
                        state = .after
                    } else if c == 0x7B {
                        stack.append([])
                        state = .key
                    } else {
                        stack.append(nil)
                    }
                    continue
                }
                if c == 0x22 {
                    if str() == nil { return false }
                } else if c == 0x74 || c == 0x66 || c == 0x6E {
                    let word = Array((c == 0x74 ? "true" : c == 0x66 ? "false" : "null").utf8)
                    guard n - i >= word.count, Array(b[i..<i + word.count]) == word else {
                        return false
                    }
                    i += word.count
                } else if c == 0x30 {
                    i += 1
                    if isDigit(at(i)) { return false }
                } else if (0x31...0x39).contains(c) {
                    while isDigit(at(i)) { i += 1 }
                } else {
                    return false
                }
                if let next = at(i), next == 0x2E || next == 0x65 || next == 0x45 { return false }
                state = .after
            case .key:
                guard at(i) == 0x22, let key = str(), let top = stack.last, var keys = top,
                      !keys.contains(key)
                else { return false }
                keys.insert(key)
                stack[stack.count - 1] = keys
                ws()
                guard at(i) == 0x3A else { return false }
                i += 1
                state = .value
            case .after:
                guard let top = stack.last else { return i == n }
                let c = at(i)
                if c == 0x2C {
                    i += 1
                    state = top == nil ? .value : .key
                } else if (c == 0x7D && top != nil) || (c == 0x5D && top == nil) {
                    i += 1
                    stack.removeLast()
                } else {
                    return false
                }
            }
        }
    }

    // MARK: Writing native messages

    /// The message for a sheet, or nil when the page would refuse it (the puzzle is reduced to
    /// the fields the page reads; its unknown fields would be dropped by the page anyway, and
    /// could not always be written as strict text).
    static func nativeMessage(for sheet: ChallengeSheet, id: String) -> NativeMessage? {
        let message: NativeMessage
        switch sheet.content {
        case .puzzle(let puzzle, let signalsKey, let cid):
            guard let p = parseBridgePuzzle(puzzle) else { return nil }
            message = .puzzle(
                id: id, puzzle: p, signalsKey: signalsKey, cid: cid, locale: sheet.locale,
                theme: sheet.theme)
        case .mfa(let requestToken, let languageCode):
            message = .mfa(id: id, requestToken: requestToken, languageCode: languageCode)
        }
        return text(of: message) == nil ? nil : message
    }

    /// The message as strict text, or nil when a value cannot be written without an escape (a
    /// quote, a backslash or a control character) or the result would not pass the page's
    /// reading. The text is read back through `parseNativeMessage` before it is returned.
    static func text(of message: NativeMessage) -> String? {
        var w = Writer()
        switch message {
        case .puzzle(let id, let p, let signalsKey, let cid, let locale, let theme):
            w.raw(#"{"rg":1,"type":"puzzle","id":"#)
            w.string(id)
            w.raw(#","puzzle":{"kind":"#)
            w.string(p.kind)
            w.raw(#","challenge":"#)
            w.string(p.challenge)
            w.raw(#","assets":["#)
            for (i, a) in p.assets.enumerated() {
                if i > 0 { w.raw(",") }
                w.string(a)
            }
            w.raw(#"],"attemptsLeft":"#)
            w.int(p.attemptsLeft)
            if let step = p.step, let steps = p.steps {
                w.raw(#","step":"#)
                w.int(step)
                w.raw(#","steps":"#)
                w.int(steps)
            }
            if let options = p.options {
                w.raw(#","options":"#)
                w.int(options)
            }
            if let max = p.rangeMax {
                w.raw(#","range":{"min":0,"max":"#)
                w.int(max)
                w.raw(#","step":1}"#)
            }
            w.raw(#"},"signalsKey":"#)
            w.string(signalsKey)
            w.raw(#","cid":"#)
            w.string(cid)
            w.raw(#","locale":"#)
            w.string(locale)
            w.raw(#","theme":"#)
            w.string(theme.rawValue)
            w.raw("}")
        case .mfa(let id, let requestToken, let languageCode):
            w.raw(#"{"rg":1,"type":"mfa","id":"#)
            w.string(id)
            w.raw(#","requestToken":"#)
            w.string(requestToken)
            if let languageCode {
                w.raw(#","languageCode":"#)
                w.string(languageCode)
            }
            w.raw("}")
        }
        guard w.ok, parseNativeMessage(w.text) == message else { return nil }
        return w.text
    }

    private struct Writer {
        var text = ""
        var ok = true

        mutating func raw(_ s: String) { text += s }

        mutating func int(_ v: Int) {
            if v < 0 { ok = false }
            text += String(v)
        }

        /// A string that needs no escape (no `"`, `\` or control character), quoted.
        mutating func string(_ s: String) {
            if s.utf8.contains(where: { $0 == 0x22 || $0 == 0x5C || $0 < 0x20 }) { ok = false }
            text += "\"" + s + "\""
        }
    }

    /// A fresh request id: 16 random bytes, base64url (22 characters).
    static func newRequestId() -> String {
        var rng = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }))
    }

    // MARK: The page URL

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "10.0.2.2"]

    /// `appPageUrl`: `<origin>/v1/app?k=&p=&id=&hl=&t=`, or nil where the reference throws. The
    /// origin must be bare and canonical (equal to its own origin, an optional trailing `/`
    /// aside): `https:`, or `http:` for loopback and the Android emulator host.
    static func appPageURL(
        widgetOrigin: String, siteKey: String, platform: String, appId: String, locale: String,
        theme: String
    ) -> String? {
        guard let c = URLComponents(string: widgetOrigin), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = c.port.flatMap { $0 == defaultPort ? nil : $0 }
        let origin = scheme + "://" + host + (port.map { ":\($0)" } ?? "")
        guard widgetOrigin == origin || widgetOrigin == origin + "/",
              scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)),
              Validation.isSiteKey(siteKey),
              (platform == "ios" && Validation.isIOSBundleId(appId))
                || (platform == "android" && Validation.isAndroidPackage(appId)),
              isBridgeLocale(locale), Configuration.Theme(rawValue: theme) != nil
        else { return nil }
        let e = encodeURIComponent
        return "\(origin)/v1/app?k=\(e(siteKey))&p=\(platform)&id=\(e(appId))"
            + "&hl=\(e(locale))&t=\(theme)"
    }

    /// The page URL of a sheet (the iOS app's own bundle id).
    static func pageURL(for sheet: ChallengeSheet) -> URL? {
        appPageURL(
            widgetOrigin: sheet.widgetOrigin.absoluteString, siteKey: sheet.siteKey,
            platform: "ios", appId: sheet.appId, locale: sheet.locale, theme: sheet.theme.rawValue
        ).flatMap(URL.init(string:))
    }

    /// JavaScript's `encodeURIComponent`.
    private static func encodeURIComponent(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            let unreserved = Validation.isAlnum(byte) || Array("-_.!~*'()".utf8).contains(byte)
            out += unreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return out
    }
}
