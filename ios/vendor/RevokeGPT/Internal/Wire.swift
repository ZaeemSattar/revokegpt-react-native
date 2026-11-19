import Foundation

// MARK: - JSON tree

/// A parsed JSON value (protocol v1 section 23.4). Numbers are JavaScript numbers (`Double`), so an
/// integer is a value, not a spelling, as `z.int()` reads it. Every printable form is redacted:
/// a tree holds tokens and challenges.
indirect enum JSONValue: Sendable, Equatable, RedactedDescription {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The deepest nesting `parse` accepts. No schema nests past 4; a deeper body is refused
    /// rather than recursed into (a deliberate cap; `JSON.parse` has none).
    static let maxDepth = 64

    /// Strict reading, `JSON.parse` plus `hasDuplicateKeys`: UTF-8 (invalid bytes fail; a
    /// byte-order mark is not whitespace, so it fails), RFC 8259 grammar only (no trailing comma,
    /// comment, NaN, leading zero or unescaped control character), nothing after the value, and no
    /// duplicate key in any object. Strings keep every code point, a leading U+FEFF included.
    /// Three deliberate differences from JavaScript, all refusals (protocol v1 section 23.4): a
    /// lone surrogate escape (`\ud800`) cannot be a Swift `String`; nesting deeper than
    /// `maxDepth`; and keys are compared as Swift strings (canonical equivalence), so two
    /// non-ASCII keys that differ only in normalisation count as a duplicate.
    static func parse(_ data: Data) -> JSONValue? {
        var p = JSONParser(bytes: [UInt8](data))
        return p.document()
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    /// A safe integer (`Number.isSafeInteger`): integral and within +/- (2^53 - 1).
    var int: Int? {
        guard case .number(let d) = self, d.isFinite, d.rounded(.towardZero) == d,
              abs(d) <= 9_007_199_254_740_991
        else { return nil }
        return Int(d)
    }

    subscript(key: String) -> JSONValue? { object?[key] }

    var redactedName: String { "JSONValue" }
}

/// A recursive-descent reader over UTF-8 bytes (see `JSONValue.parse`).
private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    mutating func document() -> JSONValue? {
        skipWhitespace()
        guard let v = value(depth: 0) else { return nil }
        skipWhitespace()
        return i == bytes.count ? v : nil
    }

    private var current: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func skipWhitespace() {
        while let c = current, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
    }

    private mutating func value(depth: Int) -> JSONValue? {
        switch current {
        case 0x7B: return object(depth: depth + 1)
        case 0x5B: return array(depth: depth + 1)
        case 0x22: return string().map(JSONValue.string)
        case 0x74: return literal("true", .bool(true))
        case 0x66: return literal("false", .bool(false))
        case 0x6E: return literal("null", .null)
        case let c? where c == 0x2D || (0x30...0x39).contains(c): return number()
        default: return nil
        }
    }

    private mutating func literal(_ word: String, _ v: JSONValue) -> JSONValue? {
        let w = Array(word.utf8)
        guard bytes.count - i >= w.count, Array(bytes[i..<i + w.count]) == w else { return nil }
        i += w.count
        return v
    }

    private mutating func object(depth: Int) -> JSONValue? {
        guard depth <= JSONValue.maxDepth else { return nil }
        i += 1
        skipWhitespace()
        var out: [String: JSONValue] = [:]
        if current == 0x7D {
            i += 1
            return .object(out)
        }
        while true {
            guard current == 0x22, let key = string() else { return nil }
            skipWhitespace()
            guard current == 0x3A else { return nil }
            i += 1
            skipWhitespace()
            guard let v = value(depth: depth), out[key] == nil else { return nil }
            out[key] = v
            skipWhitespace()
            switch current {
            case 0x2C:
                i += 1
                skipWhitespace()
            case 0x7D:
                i += 1
                return .object(out)
            default:
                return nil
            }
        }
    }

    private mutating func array(depth: Int) -> JSONValue? {
        guard depth <= JSONValue.maxDepth else { return nil }
        i += 1
        skipWhitespace()
        var out: [JSONValue] = []
        if current == 0x5D {
            i += 1
            return .array(out)
        }
        while true {
            guard let v = value(depth: depth) else { return nil }
            out.append(v)
            skipWhitespace()
            switch current {
            case 0x2C:
                i += 1
                skipWhitespace()
            case 0x5D:
                i += 1
                return .array(out)
            default:
                return nil
            }
        }
    }

    /// A string at the opening quote. Raw bytes are kept as UTF-8 and validated at the end.
    private mutating func string() -> String? {
        i += 1
        var out: [UInt8] = []
        while let c = current {
            i += 1
            switch c {
            case 0x22:
                // Not `String(bytes:encoding:)`, which drops a leading U+FEFF. Invalid UTF-8
                // decodes to U+FFFD, so a round trip that changes the bytes means it was invalid.
                let s = String(decoding: out, as: UTF8.self)
                return s.utf8.elementsEqual(out) ? s : nil
            case 0x5C:
                guard let e = current else { return nil }
                i += 1
                switch e {
                case 0x22, 0x5C, 0x2F: out.append(e)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    guard let unit = hex4() else { return nil }
                    var scalar = UInt32(unit)
                    if (0xD800...0xDBFF).contains(unit) {
                        guard current == 0x5C, i + 1 < bytes.count, bytes[i + 1] == 0x75 else {
                            return nil
                        }
                        i += 2
                        guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                        scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(unit) {
                        return nil
                    }
                    guard let u = Unicode.Scalar(scalar) else { return nil }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    return nil
                }
            case 0x00..<0x20:
                return nil
            default:
                out.append(c)
            }
        }
        return nil
    }

    private mutating func hex4() -> UInt16? {
        guard bytes.count - i >= 4 else { return nil }
        var v: UInt16 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt8
            switch c {
            case 0x30...0x39: d = c - 0x30
            case 0x41...0x46: d = c - 0x41 + 10
            case 0x61...0x66: d = c - 0x61 + 10
            default: return nil
            }
            v = v << 4 | UInt16(d)
            i += 1
        }
        return v
    }

    private mutating func number() -> JSONValue? {
        let start = i
        if current == 0x2D { i += 1 }
        guard let first = current, (0x30...0x39).contains(first) else { return nil }
        i += 1
        if first != 0x30 { skipDigits() }
        if current == 0x2E {
            i += 1
            guard skipDigits() > 0 else { return nil }
        }
        if current == 0x65 || current == 0x45 {
            i += 1
            if current == 0x2B || current == 0x2D { i += 1 }
            guard skipDigits() > 0 else { return nil }
        }
        // The grammar is checked above; Double's parser rounds as JavaScript does (1e400 is inf).
        guard let d = Double(Self.bounded(bytes[start..<i])) else { return nil }
        return .number(d)
    }

    /// The numeral as `Double` reads it, bounded: `Double(String)` refuses numerals of more than
    /// about 16k digits, which `JSON.parse` reads (as inf, 0 or a rounded value). A long mantissa
    /// keeps its first 800 significant digits plus a sticky `1` when a nonzero digit was dropped
    /// (more than the 767 a double ever needs, so rounding is unchanged), and the exponent is
    /// clamped far beyond the double range.
    private static func bounded(_ numeral: ArraySlice<UInt8>) -> String {
        let text = String(decoding: numeral, as: UTF8.self)
        guard numeral.count > 400 else { return text }
        var negative = false
        var intDigits: [UInt8] = []
        var fracDigits: [UInt8] = []
        var exponent = 0
        var exponentNegative = false
        var part = 0 // 0 integer, 1 fraction, 2 exponent
        for c in numeral {
            switch c {
            case 0x2D where part == 0 && intDigits.isEmpty: negative = true
            case 0x2D: exponentNegative = true
            case 0x2B: break
            case 0x2E: part = 1
            case 0x65, 0x45: part = 2
            default:
                let d = c - 0x30
                switch part {
                case 0: intDigits.append(d)
                case 1: fracDigits.append(d)
                default: exponent = min(exponent * 10 + Int(d), 1_000_000)
                }
            }
        }
        if exponentNegative { exponent = -exponent }
        var digits = ArraySlice(intDigits + fracDigits)
        var e10 = exponent - fracDigits.count
        while digits.first == 0 { digits.removeFirst() }
        guard !digits.isEmpty else { return negative ? "-0" : "0" }
        while digits.last == 0 {
            digits.removeLast()
            e10 += 1
        }
        if digits.count > 800 {
            let sticky = digits.dropFirst(800).contains { $0 != 0 }
            e10 += digits.count - 800
            digits = digits.prefix(800)
            if sticky {
                digits.append(1)
                e10 -= 1
            }
        }
        let mantissa = String(decoding: digits.map { $0 + 0x30 }, as: UTF8.self)
        return (negative ? "-" : "") + mantissa + "e" + String(e10)
    }

    @discardableResult
    private mutating func skipDigits() -> Int {
        var n = 0
        while let c = current, (0x30...0x39).contains(c) {
            i += 1
            n += 1
        }
        return n
    }
}

// MARK: - Requests

/// Attestation evidence for a solve (protocol v1 section 10, `Attestation`). Produced by the
/// attestation providers (Task 10); encoded with its `kind`.
enum AttestationEvidence: Encodable, Sendable, Equatable, RedactedDescription {
    case appAttestAttestation(keyId: String, object: String)
    case appAttestAssertion(keyId: String, assertion: String)
    case deviceCheck(token: String)
    /// `code` is one of `ATTEST_UNAVAILABLE_CODES`.
    case unavailable(code: String)

    private enum Key: String, CodingKey { case kind, keyId, object, assertion, token, code }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .appAttestAttestation(let keyId, let object):
            try c.encode("app-attest-attestation", forKey: .kind)
            try c.encode(keyId, forKey: .keyId)
            try c.encode(object, forKey: .object)
        case .appAttestAssertion(let keyId, let assertion):
            try c.encode("app-attest-assertion", forKey: .kind)
            try c.encode(keyId, forKey: .keyId)
            try c.encode(assertion, forKey: .assertion)
        case .deviceCheck(let token):
            try c.encode("devicecheck", forKey: .kind)
            try c.encode(token, forKey: .token)
        case .unavailable(let code):
            try c.encode("unavailable", forKey: .kind)
            try c.encode(code, forKey: .code)
        }
    }

    var redactedName: String { "AttestationEvidence" }
}

enum Wire {
    /// `MOBILE_RESPONSE_MAX_BYTES`: the longest response body read.
    static let maxResponseBytes = 65536
    /// `MOBILE_RETRY_AFTER_MAX_SECONDS`.
    static let retryAfterMaxSeconds = 3600

    enum Operation: Sendable {
        case challenge
        case solve

        /// Relative to the API endpoint.
        var path: String {
            switch self {
            case .challenge: "v1/challenge"
            case .solve: "v1/solve"
            }
        }
    }

    /// `POST /v1/challenge`, the app shape (`AppChallengeRequest`): no `hostname`.
    struct ChallengeRequest: Encodable, Sendable, RedactedDescription {
        private struct App: Encodable, Sendable {
            let platform = "ios"
            let id: String
        }

        private let sitekey: String
        private let app: App
        private let action: String?
        private let cdata: String?
        private let sdk: SDKIdentity

        /// The caller validates `siteKey`, `action` and `cdata` first (`Validation`).
        init(
            siteKey: String, bundleId: String, action: String?, cdata: String?,
            sdk: SDKIdentity = .native
        ) {
            sitekey = siteKey
            app = App(id: bundleId)
            self.action = action
            self.cdata = cdata
            self.sdk = sdk
        }

        var redactedName: String { "ChallengeRequest" }
    }

    /// `POST /v1/solve`. An app solve sends the empty `signals` string (section 10).
    struct SolveRequest: Encodable, Sendable, RedactedDescription {
        private struct Pow: Encodable, Sendable { let solutions: [UInt64] }

        private let challenge: String
        private let pow: Pow
        private let signals = ""
        private let attestation: AttestationEvidence?

        init(challenge: String, solutions: [UInt64], attestation: AttestationEvidence?) {
            self.challenge = challenge
            pow = Pow(solutions: solutions)
            self.attestation = attestation
        }

        var redactedName: String { "SolveRequest" }
    }

    /// The SDK's fixed encoding: sorted keys and unescaped `/`, so a body is the same bytes on
    /// every OS version (older Foundation encoders do not keep declaration order).
    static func encode(_ value: some Encodable) throws(RevokeGPTError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw .internal
        }
    }

    // MARK: - Responses

    /// A challenge response's `pow` object, schema-checked (`PowParamsSchema`); `Pow.Params`
    /// checks it again, canonically, before solving.
    struct PowWire: Sendable, Equatable {
        let algorithm: String
        let salt: String
        let difficultyBits: Int
        let count: Int
    }

    /// `ChallengeResponse` (loose: unknown fields are ignored).
    struct ChallengeResponse: Sendable, Equatable, RedactedDescription {
        let challenge: String
        let pow: PowWire
        let expiresAt: Int
        /// `signals.key`: the hosted page needs it for a puzzle (section 23.1).
        let signalsKey: String
        /// App challenges: the site id the binding bytes carry.
        let siteId: String?
        /// App challenges since M10: the sealed app id (Task 11 checks it against the bundle id).
        let appId: String?

        init?(_ o: [String: JSONValue]) {
            guard let challenge = o["challenge"]?.string,
                  (1...4096).contains(challenge.utf16.count),
                  let p = o["pow"]?.object, p["algorithm"]?.string == Pow.algorithm,
                  let salt = p["salt"]?.string, Validation.isBase64URL(salt, length: 22...22),
                  let bits = p["difficultyBits"]?.int, Pow.bitsRange.contains(bits),
                  let count = p["count"]?.int, Pow.countRange.contains(count),
                  let signals = o["signals"]?.object,
                  let version = signals["version"]?.string, (1...40).contains(version.utf16.count),
                  let key = signals["key"]?.string, Validation.isBase64URL(key, length: 1...64),
                  let expiresAt = o["expiresAt"]?.int
            else { return nil }
            var siteId: String?
            if let v = o["siteId"] {
                guard let s = v.string, Validation.isSiteId(s) else { return nil }
                siteId = s
            }
            var appId: String?
            if let v = o["appId"] {
                guard let s = v.string, (1...255).contains(s.utf16.count) else { return nil }
                appId = s
            }
            self.challenge = challenge
            pow = PowWire(algorithm: Pow.algorithm, salt: salt, difficultyBits: bits, count: count)
            self.expiresAt = expiresAt
            signalsKey = key
            self.siteId = siteId
            self.appId = appId
        }

        var redactedName: String { "ChallengeResponse" }
    }

    /// A `puzzle` solve response. The puzzle object is schema-checked (`PuzzleSpec`) and then
    /// passed to the hosted page unread (unknown kinds and fields included).
    struct PuzzleResponse: Sendable, Equatable, RedactedDescription {
        let puzzle: JSONValue

        init?(_ p: [String: JSONValue]) {
            guard let kind = p["kind"]?.string, (1...40).contains(kind.utf16.count),
                  let challenge = p["challenge"]?.string,
                  (1...4096).contains(challenge.utf16.count),
                  let assets = p["assets"]?.array, (1...9).contains(assets.count),
                  assets.allSatisfy({ Self.length($0, 1...512) }),
                  p["attemptsLeft"]?.int == 1,
                  Self.optionalInt(p["options"], 2...9),
                  Self.optionalInt(p["step"], 1...3),
                  Self.optionalInt(p["steps"], 1...3)
            else { return nil }
            if let r = p["range"] {
                guard let range = r.object, range["min"] == .number(0), range["step"] == .number(1),
                      range["max"] == .number(359) || range["max"] == .number(100)
                else { return nil }
            }
            puzzle = .object(p)
        }

        /// A string whose UTF-16 length (JavaScript's `length`) is in `range`.
        private static func length(_ v: JSONValue, _ range: ClosedRange<Int>) -> Bool {
            v.string.map { range.contains($0.utf16.count) } ?? false
        }

        /// Absent, or an integer in `range` (zod `optional`: `null` is not absent).
        private static func optionalInt(_ v: JSONValue?, _ range: ClosedRange<Int>) -> Bool {
            guard let v else { return true }
            return v.int.map(range.contains) ?? false
        }

        var redactedName: String { "PuzzleResponse" }
    }

    /// The reading of one HTTP response of `/v1/challenge` or `/v1/solve`, a port of
    /// `interpretApiResponse` (protocol v1 section 23.4; `mobile-client.json` `responses`):
    ///
    /// 1. A 3xx is `http-error` (redirects are never followed; the body is not read).
    /// 2. A body over 64 KiB is `invalid-response`, whatever the status.
    /// 3. A non-200 is the `error.code` of a strict error body when the code is an API code,
    ///    else `http-error`; `Retry-After` (digits only, at most 3600) on 429 and 503.
    /// 4. A 200 must be a strict object matching the operation's schema, else `invalid-response`.
    /// 5. A token or puzzle whose `attestation` is `reattest` reports `reattest`.
    static func interpret(
        _ op: Operation, status: Int, headers: [String: String], body: Data
    ) -> ApiOutcome {
        func fail(_ code: String, requestId: String? = nil) -> ApiOutcome {
            let retry = status == 429 || status == 503 ? retryAfter(headers) : nil
            return .failure(APIFailure(
                code: code, status: status, retryAfterSeconds: retry, requestId: requestId))
        }
        if (300..<400).contains(status) { return fail("http-error") }
        if body.count > maxResponseBytes { return fail("invalid-response") }
        let parsed = JSONValue.parse(body)?.object
        guard status == 200 else {
            if let e = parsed?["error"]?.object, let code = e["code"]?.string,
               RevokeGPTError.apiErrorCodes.contains(code) {
                let id = e["requestId"]?.string.flatMap { Validation.isRequestId($0) ? $0 : nil }
                return fail(code, requestId: id)
            }
            return fail("http-error")
        }
        guard let o = parsed else { return fail("invalid-response") }
        switch op {
        case .challenge:
            return ChallengeResponse(o).map(ApiOutcome.challenge) ?? fail("invalid-response")
        case .solve:
            return solveOutcome(o) ?? fail("invalid-response")
        }
    }

    /// `SolveResponse`: discriminated on `type`, so an unknown or missing type is nil.
    private static func solveOutcome(_ o: [String: JSONValue]) -> ApiOutcome? {
        var attestation: String?
        if let a = o["attestation"] {
            guard let s = a.string, (1...40).contains(s.utf16.count) else { return nil }
            attestation = s
        }
        switch o["type"]?.string {
        case "token":
            guard let token = o["token"]?.string, Validation.isResponseToken(token),
                  let expiresAt = o["expiresAt"]?.int
            else { return nil }
            return .token(token: token, expiresAt: expiresAt, attestation: attestation)
        case "puzzle":
            guard let p = o["puzzle"]?.object, let puzzle = PuzzleResponse(p) else { return nil }
            return .puzzle(puzzle, attestation: attestation)
        default:
            return nil
        }
    }

    /// The first header named `Retry-After` (any case): 1 to 9 ASCII digits, clamped to 3600;
    /// any other value (an HTTP date, a sign, a fraction) is ignored.
    private static func retryAfter(_ headers: [String: String]) -> Int? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value,
              (1...9).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let n = Int(value)
        else { return nil }
        return min(n, retryAfterMaxSeconds)
    }
}

/// A failed response: the code (an own code or an API code), with what an error reports.
struct APIFailure: Sendable, Equatable {
    let code: String
    let status: Int
    var retryAfterSeconds: Int?
    var requestId: String?

    init(code: String, status: Int, retryAfterSeconds: Int? = nil, requestId: String? = nil) {
        self.code = code
        self.status = status
        self.retryAfterSeconds = retryAfterSeconds
        self.requestId = requestId
    }

    /// The public error.
    var error: RevokeGPTError {
        switch code {
        case "http-error": .httpError(status: status, retryAfterSeconds: retryAfterSeconds)
        case "invalid-response": .invalidResponse
        default:
            .api(
                code: code, status: status, requestId: requestId,
                retryAfterSeconds: retryAfterSeconds)
        }
    }
}

/// What the SDK does with one response (`ApiOutcome` of section 23.4).
enum ApiOutcome: Sendable, Equatable, RedactedDescription {
    case challenge(Wire.ChallengeResponse)
    /// `attestation`: the App Attest status as sent (`ok`, `reattest`, or a value to ignore).
    case token(token: String, expiresAt: Int, attestation: String?)
    case puzzle(Wire.PuzzleResponse, attestation: String?)
    case failure(APIFailure)

    /// A token or puzzle whose `attestation` is `reattest` (rule 5).
    var reattest: Bool {
        switch self {
        case .token(_, _, let a), .puzzle(_, let a): a == "reattest"
        default: false
        }
    }

    /// The kind, and the code of a failure: safe to print.
    var summary: String {
        switch self {
        case .challenge: "challenge"
        case .token: reattest ? "token(reattest)" : "token"
        case .puzzle: reattest ? "puzzle(reattest)" : "puzzle"
        case .failure(let f): "failure(\(f.code))"
        }
    }

    var redactedName: String { "ApiOutcome(\(summary))" }
}
