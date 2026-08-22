import XCTest
@testable import PisakaCore

/// SHA-256 against the published vectors, and against itself across chunk
/// boundaries.
///
/// This is the one piece of the provisioning layer where "looks right" is worth
/// nothing: a digest that is wrong in any way at all is wrong in a way that is
/// indistinguishable from a tampered download, and a digest that is right for
/// short inputs but wrong at a padding boundary would pass a careless suite and
/// then reject every real 50 MB tarball. So the expected values here come from
/// *outside* this implementation — FIPS 180-4 / NIST's own examples for the
/// classic four, and `shasum -a 256` for the boundary sweep — never from running
/// the code under test and writing down what it said.
final class SHA256Tests: XCTestCase {
    // MARK: - The published vectors

    func testEmptyMessage() {
        XCTAssertEqual(
            SHA256.hexadecimalDigest(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testABC() {
        // FIPS 180-4 Appendix B.1: the one-block message.
        XCTAssertEqual(
            SHA256.hexadecimalDigest(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testFourHundredFortyEightBitMessage() {
        // FIPS 180-4 Appendix B.2: 56 bytes — the length that *just* forces a
        // second block, because the padding no longer fits behind it.
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(message.utf8.count, 56)
        XCTAssertEqual(
            SHA256.hexadecimalDigest(of: Data(message.utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testEightHundredNinetySixBitMessage() {
        // FIPS 180-4 Appendix B.3's two-block message: 112 bytes, i.e. exactly
        // two blocks of input, so the padding takes a whole third block.
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
            + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        XCTAssertEqual(message.utf8.count, 112)
        XCTAssertEqual(
            SHA256.hexadecimalDigest(of: Data(message.utf8)),
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
    }

    func testOneMillionA() {
        // FIPS 180-4's long-message example. Also the only test here that
        // exercises the buffering at scale: 15 625 blocks, none of which is
        // aligned with the `update` call that delivered it.
        let message = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(
            SHA256.hexadecimalDigest(of: message),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    // MARK: - Padding boundaries

    /// `shasum -a 256` over `"a" * n`, for the lengths where padding changes
    /// shape: 55 is the last that fits its length field in the same block, 56 is
    /// the first that does not, 64 fills a block exactly, and each of those
    /// repeats one block later.
    private static let repeatedADigests: [Int: String] = [
        0: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        1: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
        54: "a3f01b6939256127582ac8ae9fb47a382a244680806a3f613a118851c1ca1d47",
        55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
        56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
        57: "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6",
        63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
        64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
        65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
        66: "ac137fce49837c7c2945f6160d3c0e679e6f40070850420a22bc10e0692cbdc7",
        119: "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
        120: "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
        127: "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a",
        128: "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e",
        129: "c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae"
    ]

    func testLengthBoundarySweep() {
        for (length, expected) in Self.repeatedADigests.sorted(by: { $0.key < $1.key }) {
            let message = Data(repeating: UInt8(ascii: "a"), count: length)
            XCTAssertEqual(
                SHA256.hexadecimalDigest(of: message), expected,
                "wrong digest for a message of \(length) bytes"
            )
        }
    }

    // MARK: - The incremental form

    func testChunkedUpdatesEqualTheOneShotDigest() {
        // 1 000 bytes is long enough that every split below lands somewhere
        // different relative to the 64-byte block grid.
        let message = Data((0..<1_000).map { UInt8($0 % 251) })
        let expected = SHA256.hexadecimalDigest(of: message)

        for chunkSize in [1, 2, 3, 7, 31, 63, 64, 65, 100, 127, 128, 999, 1_000, 4_096] {
            var hasher = SHA256()
            var offset = 0
            while offset < message.count {
                let end = min(offset + chunkSize, message.count)
                hasher.update(message.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(
                hasher.finalizeHexadecimal(), expected,
                "chunking at \(chunkSize) bytes changed the digest"
            )
        }
    }

    func testUnevenChunksEqualTheOneShotDigest() {
        // The realistic shape: pieces of wildly different sizes, including empty
        // ones, in the order a stream would deliver them.
        let pieces = ["", "a", "", "bcdefghij", String(repeating: "x", count: 63), "y",
                      String(repeating: "z", count: 129), ""]
        var hasher = SHA256()
        for piece in pieces { hasher.update(Data(piece.utf8)) }
        XCTAssertEqual(
            hasher.finalizeHexadecimal(),
            SHA256.hexadecimalDigest(of: Data(pieces.joined().utf8))
        )
    }

    func testUpdateAcceptsRawBytesAndDataAlike() {
        let bytes: [UInt8] = Array("the quick brown fox".utf8)
        var fromArray = SHA256()
        fromArray.update(bytes)
        var fromData = SHA256()
        fromData.update(Data(bytes))
        XCTAssertEqual(fromArray.finalizeHexadecimal(), fromData.finalizeHexadecimal())
    }

    func testFinalizeIsRepeatable() {
        // The engine hands one digest to a comparison and may well read it again
        // for an error message; a second `finalize` must not pad a second time.
        var hasher = SHA256()
        hasher.update(Data("abc".utf8))
        let first = hasher.finalize()
        XCTAssertEqual(hasher.finalize(), first)
        XCTAssertEqual(SHA256.hexadecimal(first), SHA256.hexadecimalDigest(of: Data("abc".utf8)))
    }

    func testHashersAreIndependentValues() {
        // A value type: copying a partially fed hasher must not share state with
        // the original.
        var base = SHA256()
        base.update(Data("abc".utf8))
        var copy = base
        copy.update(Data("def".utf8))

        XCTAssertEqual(base.finalizeHexadecimal(), SHA256.hexadecimalDigest(of: Data("abc".utf8)))
        XCTAssertEqual(copy.finalizeHexadecimal(), SHA256.hexadecimalDigest(of: Data("abcdef".utf8)))
    }

    // MARK: - The rendering

    func testDigestIsThirtyTwoBytesAndSixtyFourLowercaseHexCharacters() {
        let digest = SHA256.digest(of: Data("abc".utf8))
        XCTAssertEqual(digest.count, SHA256.digestByteCount)

        let hex = SHA256.hexadecimal(digest)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
    }

    func testHexadecimalPadsEveryByteToTwoDigits() {
        // A byte below 0x10 rendered as one character would shift the rest of the
        // string and turn a match into a mismatch — the failure that looks like a
        // corrupted download.
        XCTAssertEqual(SHA256.hexadecimal(Data([0x00, 0x0f, 0x10, 0xff])), "000f10ff")
    }
}
