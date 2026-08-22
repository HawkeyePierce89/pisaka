import Foundation

/// FIPS 180-4 SHA-256, in Foundation alone.
///
/// **Why this exists at all.** The provisioning layer downloads executable code —
/// a Node runtime and two language servers — and the only thing standing between
/// a pinned manifest and whatever the network actually handed over is a checksum
/// comparison. That comparison is therefore a Core decision, and Core may not
/// import `CryptoKit` (the whole library is Foundation-only so the domain logic
/// stays portable and testable; see the conventions in `CLAUDE.md`). So the digest
/// is written here rather than borrowed.
///
/// This is deliberately the textbook algorithm: 64 rounds over a 16-word message
/// schedule, no table tricks, no unrolling, no unchecked arithmetic beyond the
/// `&+`/`&<<` the specification's mod-2³² words require. It hashes ~50 MB per
/// install, once, on a background hop — the cost of being obvious here is
/// irrelevant next to the download it verifies, and being obvious is what makes
/// the published-vector tests a real check rather than a re-derivation of
/// whatever this file happens to do.
///
/// **The incremental shape is the honest one.** The engine hashes exactly one
/// `Data`, so `digest(of:)` is the whole caller-facing surface it needs. But a
/// one-shot-only implementation hides its padding in a code path no test can vary:
/// the interesting failures of SHA-256 are all at block boundaries (a message that
/// ends at 55, 56, 63 or 64 bytes takes three different padding routes), and the
/// only cheap way to prove the buffering is right is to feed the same bytes in
/// different-sized pieces and demand the same answer. `update`/`finalize` is what
/// makes that test expressible.
public struct SHA256 {
    /// A SHA-256 digest is 32 bytes, always.
    public static let digestByteCount = 32

    /// The block size the compression function consumes, in bytes.
    private static let blockByteCount = 64

    /// The first 32 bits of the fractional parts of the cube roots of the first
    /// 64 primes (FIPS 180-4 §4.2.2).
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// The first 32 bits of the fractional parts of the square roots of the first
    /// eight primes (FIPS 180-4 §5.3.3).
    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private var state = SHA256.initialState
    /// Bytes that arrived since the last full block. Never 64 or more: a complete
    /// block is compressed the moment it exists rather than being held.
    private var pending: [UInt8] = []
    /// The message length the padding will encode. Counts *message* bytes only —
    /// `finalize` deliberately reads it before appending its own padding.
    private var messageByteCount: UInt64 = 0
    /// The digest, once computed. Present so `finalize` may be asked twice without
    /// producing a second, differently padded answer.
    private var digest: Data?

    public init() {
        pending.reserveCapacity(SHA256.blockByteCount)
    }

    // MARK: - One-shot

    /// The digest of `data`, as 32 raw bytes.
    public static func digest(of data: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data)
        return hasher.finalize()
    }

    /// The digest of `data` as 64 lowercase hexadecimal characters — the form the
    /// provisioning manifest pins and `nodejs.org`/`registry.npmjs.org` publish.
    public static func hexadecimalDigest(of data: Data) -> String {
        hexadecimal(digest(of: data))
    }

    /// Raw digest bytes as lowercase hex. Kept separate from the hashing so a
    /// caller holding a digest can render it without hashing anything again.
    public static func hexadecimal(_ digest: Data) -> String {
        var text = ""
        text.reserveCapacity(digest.count * 2)
        for byte in digest {
            text.append(hexadecimalDigits[Int(byte >> 4)])
            text.append(hexadecimalDigits[Int(byte & 0x0f)])
        }
        return text
    }

    private static let hexadecimalDigits = Array("0123456789abcdef")

    // MARK: - Incremental

    /// Absorb more of the message. Bytes may arrive in any sized pieces; the
    /// result depends only on their concatenation.
    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            absorb(raw.bindMemory(to: UInt8.self))
        }
    }

    /// The same, for callers that already hold bytes.
    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { absorb($0) }
    }

    /// Pad, compress the last block(s) and answer the 32-byte digest.
    ///
    /// Calling this twice answers the same digest; calling `update` afterwards is
    /// a programming error and traps, because silently starting a second message
    /// on a finalized hasher is the kind of mistake that produces a *plausible*
    /// wrong checksum.
    public mutating func finalize() -> Data {
        if let digest { return digest }

        // Read the length before padding: the padding's own bytes are not part of
        // the message the length describes.
        let bitCount = messageByteCount &* 8

        // 0x80, then zeros up to a 56-mod-64 boundary, then the 64-bit big-endian
        // bit count — FIPS 180-4 §5.1.1.
        var padding: [UInt8] = [0x80]
        let occupied = Int((messageByteCount &+ 1) % UInt64(SHA256.blockByteCount))
        padding.append(contentsOf: repeatElement(0, count: (56 - occupied + SHA256.blockByteCount) % SHA256.blockByteCount))
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        update(padding)

        var bytes = Data(capacity: SHA256.digestByteCount)
        for word in state {
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word))
        }
        digest = bytes
        return bytes
    }

    /// `finalize()` rendered as 64 lowercase hexadecimal characters.
    public mutating func finalizeHexadecimal() -> String {
        SHA256.hexadecimal(finalize())
    }

    // MARK: - The mechanism

    private mutating func absorb(_ bytes: UnsafeBufferPointer<UInt8>) {
        precondition(digest == nil, "SHA256.update after finalize: start a new hasher instead")
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        messageByteCount &+= UInt64(bytes.count)

        var offset = 0
        if !pending.isEmpty {
            let taken = min(SHA256.blockByteCount - pending.count, bytes.count)
            pending.append(contentsOf: UnsafeBufferPointer(start: base, count: taken))
            offset = taken
            guard pending.count == SHA256.blockByteCount else { return }
            pending.withUnsafeBufferPointer { compress(block: $0.baseAddress!) }
            pending.removeAll(keepingCapacity: true)
        }

        while bytes.count - offset >= SHA256.blockByteCount {
            compress(block: base + offset)
            offset += SHA256.blockByteCount
        }

        if offset < bytes.count {
            pending.append(contentsOf: UnsafeBufferPointer(start: base + offset, count: bytes.count - offset))
        }
    }

    /// One application of the compression function to 64 bytes (FIPS 180-4 §6.2.2).
    private mutating func compress(block: UnsafePointer<UInt8>) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let start = index * 4
            schedule[index] = UInt32(block[start]) << 24
                | UInt32(block[start + 1]) << 16
                | UInt32(block[start + 2]) << 8
                | UInt32(block[start + 3])
        }
        for index in 16..<64 {
            let previous15 = schedule[index - 15]
            let previous2 = schedule[index - 2]
            let s0 = rotateRight(previous15, 7) ^ rotateRight(previous15, 18) ^ (previous15 >> 3)
            let s1 = rotateRight(previous2, 17) ^ rotateRight(previous2, 19) ^ (previous2 >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in 0..<64 {
            let sigma1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sigma1 &+ choose &+ SHA256.roundConstants[index] &+ schedule[index]
            let sigma0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sigma0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotateRight(_ word: UInt32, _ distance: UInt32) -> UInt32 {
        (word >> distance) | (word << (32 - distance))
    }
}
