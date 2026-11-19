import CryptoKit
import Foundation

/// Why a proof of work was not produced. Cancellation of the calling task is `CancellationError`.
enum PowError: Error, Equatable, Sendable {
    /// The parameters are outside protocol v1 section 8 (`POW_LIMITS`).
    case invalidParams
    /// No nonce up to 2^53 - 1 meets the difficulty (a reference solver must stop there).
    case exhausted
    /// The call's deadline passed before every sub-puzzle was solved.
    case deadlineExceeded
}

/// The `sha256-v1` proof of work (protocol v1 section 8), a native port of `solvePow` and
/// `verifyPow` in packages/protocol/src/pow.ts: for each sub-puzzle index `i` in `[0, count)`, the
/// lowest nonce `n` in `[0, 2^53 - 1]` such that SHA-256 of the 34-byte input
///
///     ASCII "rg-pow-v1" (9) || salt (16) || u8 i || u64 big-endian n
///
/// has at least `difficultyBits` leading zero bits. The 26-byte prefix is hashed once per
/// sub-puzzle and its state copied per nonce (`SHA256` is a value type; plan R1). Proof of work is
/// a cost signal, never proof that a client is human.
enum Pow {
    /// The challenge response's `pow` object, validated (treated as untrusted).
    struct Params: Equatable, Sendable {
        let salt: Data
        let difficultyBits: Int
        let count: Int

        init(algorithm: String, salt: String, difficultyBits: Int, count: Int) throws(PowError) {
            guard algorithm == Pow.algorithm, let decoded = Base64URL.decode(salt),
                  Pow.isValid(salt: decoded, difficultyBits: difficultyBits, count: count)
            else { throw .invalidParams }
            self.salt = decoded
            self.difficultyBits = difficultyBits
            self.count = count
        }
    }

    static let algorithm = "sha256-v1"
    static let maxNonce: UInt64 = (1 << 53) - 1
    static let saltBytes = 16
    static let bitsRange = 1...32
    static let countRange = 1...256
    /// Nonces hashed between cancellation and deadline checks: a few milliseconds of work, and the
    /// most a worker hashes after a cancel (PowTests pins it).
    static let checkInterval = 512
    private static let domain = Array("rg-pow-v1".utf8)

    static func isValid(salt: Data, difficultyBits: Int, count: Int) -> Bool {
        salt.count == saltBytes && bitsRange.contains(difficultyBits) && countRange.contains(count)
    }

    /// The lowest valid nonce per sub-puzzle, in order. Sub-puzzles are split across cores
    /// (one fewer worker than cores, so the app's other async work is not starved), and every
    /// worker yields between batches. Throws `invalidParams` before any hashing,
    /// `deadlineExceeded` once `deadline` passes, and `CancellationError` when the calling task
    /// is cancelled; the other workers stop with it.
    static func solve(
        salt: Data, difficultyBits: Int, count: Int, deadline: Deadline, log: Log = .off
    ) async throws -> [UInt64] {
        guard isValid(salt: salt, difficultyBits: difficultyBits, count: count) else {
            log.event(.powInvalidParams)
            throw PowError.invalidParams
        }
        do {
            let out = try await solveValid(
                salt: salt, difficultyBits: difficultyBits, count: count, deadline: deadline)
            log.event(.powSolved)
            return out
        } catch let e as PowError {
            log.event(e == .exhausted ? .powExhausted : .powDeadlineExceeded)
            throw e
        } catch let e as CancellationError {
            log.event(.powCancelled)
            throw e
        }
    }

    private static func solveValid(
        salt: Data, difficultyBits: Int, count: Int, deadline: Deadline
    ) async throws -> [UInt64] {
        try checkpoint(deadline)
        let workers = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        return try await withThrowingTaskGroup(of: (Int, UInt64).self) { group in
            var out = [UInt64](repeating: 0, count: count)
            var next = 0
            func spawn() {
                let i = next
                next += 1
                group.addTask {
                    (i, try await lowestNonce(
                        salt: salt, index: i, difficultyBits: difficultyBits, from: 0,
                        deadline: deadline))
                }
            }
            for _ in 0..<workers { spawn() }
            // A child's error ends the loop; leaving the closure by throwing cancels the rest.
            while let (i, n) = try await group.next() {
                out[i] = n
                if next < count { spawn() }
            }
            return out
        }
    }

    /// The lowest nonce at or above `from` for sub-puzzle `index`. `index` must be in 0...255
    /// (`count` <= 256 guarantees it, so the byte never wraps). Cancellation and the deadline are
    /// checked before every batch of `checkInterval` nonces, so at most one batch is hashed after
    /// a cancel. `onBatch` (tests only) runs as each batch starts, with the number of nonces
    /// hashed so far.
    static func lowestNonce(
        salt: Data, index: Int, difficultyBits: Int, from start: UInt64, deadline: Deadline,
        onBatch: (@Sendable (_ hashed: Int) -> Void)? = nil
    ) async throws -> UInt64 {
        precondition((0...255).contains(index) && salt.count == saltBytes)
        var prefix = SHA256()
        prefix.update(data: domain)
        prefix.update(data: salt)
        prefix.update(data: [UInt8(index)])
        var n = start
        var sinceCheck = 0
        var hashed = 0
        while true {
            if n > maxNonce { throw PowError.exhausted }
            if sinceCheck == 0 {
                try checkpoint(deadline)
                await Task.yield()
                try checkpoint(deadline)
                sinceCheck = checkInterval
                onBatch?(hashed)
            }
            hashed += 1
            sinceCheck -= 1
            if meets(prefix: prefix, nonce: n, difficultyBits: difficultyBits) { return n }
            n += 1
        }
    }

    /// Whether `solutions` solve the validated `params`. Never throws.
    static func verify(_ params: Params, solutions: [UInt64]) -> Bool {
        verify(
            salt: params.salt, difficultyBits: params.difficultyBits, count: params.count,
            solutions: solutions)
    }

    /// Whether `solutions` are a valid proof: one nonce per sub-puzzle (length checked before any
    /// hashing), each at most 2^53 - 1, each meeting the difficulty. Invalid parameters are false.
    static func verify(salt: Data, difficultyBits: Int, count: Int, solutions: [UInt64]) -> Bool {
        guard isValid(salt: salt, difficultyBits: difficultyBits, count: count),
              solutions.count == count, solutions.allSatisfy({ $0 <= maxNonce })
        else { return false }
        for (i, n) in solutions.enumerated() {
            var prefix = SHA256()
            prefix.update(data: domain)
            prefix.update(data: salt)
            prefix.update(data: [UInt8(i)])
            if !meets(prefix: prefix, nonce: n, difficultyBits: difficultyBits) { return false }
        }
        return true
    }

    private static func meets(prefix: SHA256, nonce: UInt64, difficultyBits: Int) -> Bool {
        var h = prefix
        var be = nonce.bigEndian
        withUnsafeBytes(of: &be) { h.update(bufferPointer: $0) }
        return leadingZeroBits(h.finalize()) >= difficultyBits
    }

    private static func checkpoint(_ deadline: Deadline) throws {
        try Task.checkCancellation()
        if deadline.isExpired { throw PowError.deadlineExceeded }
    }

    /// The number of leading zero bits of `bytes`.
    static func leadingZeroBits(_ bytes: some Sequence<UInt8>) -> Int {
        var bits = 0
        for byte in bytes {
            if byte == 0 {
                bits += 8
                continue
            }
            return bits + byte.leadingZeroBitCount
        }
        return bits
    }
}

/// Unpadded base64url (`A-Z a-z 0-9 - _`), canonical only: no padding, no other character, and
/// leftover bits zero (protocol v1 section 8), so one value has exactly one spelling. The whole
/// string is checked by a charset scan (no regex).
enum Base64URL {
    static func decode(_ s: String) -> Data? {
        let utf8 = Array(s.utf8)
        guard utf8.count % 4 != 1,
              utf8.allSatisfy({ c in
                  (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                      || c == 0x2D || c == 0x5F
              })
        else { return nil }
        var standard = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), encode(data) == s else { return nil }
        return data
    }

    static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
