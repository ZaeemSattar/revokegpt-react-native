/// Whole-string charset checks (protocol v1 sections 2, 7 and 10), by scanning every UTF-8 byte:
/// no regex, so there is no anchor to get wrong (a trailing newline, or any non-ASCII byte, is
/// outside every charset here). Pinned by `fields.json` and the site-key cases of `keys.json`.
enum Validation {
    /// `rgpk_` and 20 of `0-9 A-Z a-z` (`SITE_KEY`).
    static func isSiteKey(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == 25 && b.starts(with: Array("rgpk_".utf8)) && b[5...].allSatisfy(isAlnum)
    }

    /// 1 to 100 of `A-Z a-z 0-9 / _` (`ACTION`).
    static func isAction(_ s: String) -> Bool {
        all(s, 1...100) { isAlnum($0) || $0 == 0x2F || $0 == 0x5F }
    }

    /// 0 to 255 of `A-Z a-z 0-9 _ -` (`CDATA`).
    static func isCdata(_ s: String) -> Bool {
        all(s, 0...255) { isAlnum($0) || $0 == 0x5F || $0 == 0x2D }
    }

    /// One or more of the base64url alphabet `A-Z a-z 0-9 _ -` (`BASE64URL`, shape only).
    static func isBase64URL(_ s: String, length: ClosedRange<Int> = 1...Int.max) -> Bool {
        all(s, length, isBase64URLByte)
    }

    /// A siteverify response token: 1 to 2048 base64url characters (`RESPONSE_TOKEN`).
    static func isResponseToken(_ s: String) -> Bool { isBase64URL(s, length: 1...2048) }

    /// A lowercase canonical UUID (`SITE_ID`).
    static func isSiteId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 36 else { return false }
        for (i, c) in b.enumerated() {
            let ok = switch i {
            case 8, 13, 18, 23: c == 0x2D
            default: (0x30...0x39).contains(c) || (0x61...0x66).contains(c)
            }
            if !ok { return false }
        }
        return true
    }

    /// A server request id the SDK repeats in an error description: 1 to 128 of
    /// `A-Z a-z 0-9 . _ : -`. Anything else is dropped, so server text never reaches a description.
    static func isRequestId(_ s: String) -> Bool {
        all(s, 1...128) { isAlnum($0) || [0x2E, 0x5F, 0x3A, 0x2D].contains($0) }
    }

    /// An App Attest key id: canonical padded standard base64 of 32 bytes, 44 characters
    /// (`APP_ATTEST_KEY_ID`): 42 of `A-Z a-z 0-9 + /`, one of `AEIMQUYcgkosw048`, then `=`.
    static func isAppAttestKeyId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 44, b[43] == 0x3D, Array("AEIMQUYcgkosw048".utf8).contains(b[42])
        else { return false }
        return b[0..<42].allSatisfy { isAlnum($0) || $0 == 0x2B || $0 == 0x2F }
    }

    /// A language code (`LANGUAGE_CODE`): 2 or 3 letters, then up to three `-` subtags of 2 to 8
    /// letters or digits (35 characters at most).
    static func isLanguageCode(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (1...4).contains(parts.count),
              (2...3).contains(first.utf8.count),
              first.utf8.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) })
        else { return false }
        return parts.dropFirst().allSatisfy { p in
            (2...8).contains(p.utf8.count) && p.utf8.allSatisfy(isAlnum)
        }
    }

    /// An iOS bundle id (`IOS_BUNDLE_ID`): two or more `.`-separated segments of
    /// `A-Z a-z 0-9 -`, at most 155 characters.
    static func isIOSBundleId(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return s.utf8.count <= 155 && parts.count >= 2 && parts.allSatisfy { p in
            !p.isEmpty && p.utf8.allSatisfy { isAlnum($0) || $0 == 0x2D }
        }
    }

    /// An Android package name (`ANDROID_PACKAGE`): two or more `.`-separated segments, each a
    /// letter then `A-Z a-z 0-9 _`, at most 255 characters.
    static func isAndroidPackage(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return s.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { p in
            guard let first = p.utf8.first,
                  (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first)
            else { return false }
            return p.utf8.allSatisfy { isAlnum($0) || $0 == 0x5F }
        }
    }

    static func isAlnum(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }

    static func isBase64URLByte(_ c: UInt8) -> Bool { isAlnum(c) || c == 0x2D || c == 0x5F }

    /// Every UTF-8 byte of `s` passes `allowed`, and the byte count is in `length` (equal to the
    /// character count, since every charset here is ASCII).
    private static func all(_ s: String, _ length: ClosedRange<Int>, _ allowed: (UInt8) -> Bool)
        -> Bool {
        length.contains(s.utf8.count) && s.utf8.allSatisfy(allowed)
    }
}
