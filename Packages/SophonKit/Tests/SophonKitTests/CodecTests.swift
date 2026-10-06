import Foundation
import Testing
@testable import SophonKit

// libzstd's own XXH64 (namespaced with ZSTD_), used as the reference implementation.
@_silgen_name("ZSTD_XXH64")
private func referenceXXH64(_ input: UnsafeRawPointer?, _ length: Int, _ seed: UInt64) -> UInt64

struct CodecTests {
    @Test func xxh64KnownVectors() {
        #expect(XXH64.hash([]) == 0xEF46_DB37_51D8_E999)
        #expect(XXH64.hash(Array("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
    }

    @Test func xxh64MatchesReferenceAcrossLengthsAndSplits() {
        var rng = SystemRandomNumberGenerator()
        for length in [0, 1, 3, 4, 7, 8, 15, 31, 32, 33, 63, 64, 100, 1000, 1 << 20] {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let expected = bytes.withUnsafeBytes { referenceXXH64($0.baseAddress, $0.count, 0) }
            #expect(XXH64.hash(bytes) == expected, "length \(length)")

            // Same digest when fed in uneven pieces.
            var hasher = XXH64()
            var i = 0
            var step = 1
            while i < bytes.count {
                let end = min(i + step, bytes.count)
                hasher.update(Array(bytes[i..<end]))
                i = end
                step = step * 3 % 97 + 1
            }
            #expect(hasher.finalize() == expected, "split, length \(length)")
        }
    }

    @Test func contentHashPicksAlgorithmByLength() {
        let data = Data("hello".utf8)
        #expect(ContentHash(md5Hex(data)).kind == .md5)
        #expect(ContentHash(md5Hex(data)).matches(data))
        let xxh = XXH64.hash(Array(data))
        let hex = String(format: "%016llx", xxh)
        #expect(ContentHash(hex).kind == .xxh64)
        #expect(ContentHash(hex).matches(data))
        #expect(ContentHash(objectName: "manifest_\(hex)_0d35fc0ac9d4ce16353cca1a2ea56e4b")?.matches(data) == true)
        #expect(ContentHash(objectName: "\(hex)_0d35fc0ac9d4ce16353cca1a2ea56e4b")?.hex == hex)
        #expect(ContentHash(objectName: "not-a-hash") == nil)
    }

    @Test func zstdRoundTripAndSizeCheck() throws {
        // `printf 'hello hello hello' | zstd -c --no-check`; piped input, so the frame has no content size.
        let frame = Data([
            0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x65, 0x00, 0x00, 0x30, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20,
            0x01, 0x00, 0x31, 0x4A, 0x11,
        ])
        let text = try Zstd.decompress(frame, expectedSize: 17)
        #expect(String(bytes: text, encoding: .utf8) == "hello hello hello")
        #expect(throws: SophonError.self) { try Zstd.decompress(frame, expectedSize: 16) }
        #expect(throws: SophonError.self) { try Zstd.decompress(frame, expectedSize: 18) }
    }

    @Test(arguments: [
        ("a\\b\\c.dat", "a/b/c.dat"),
        ("./a//b/./c", "a/b/c"),
        ("StreamingAssets/x.pck", "StreamingAssets/x.pck"),
    ])
    func safePathNormalizes(raw: String, expected: String) throws {
        #expect(try SafePath.normalize(raw) == expected)
    }

    @Test(arguments: ["/etc/passwd", "..\\x", "a/../../b", "C:\\Windows", "", "./"])
    func safePathRejects(raw: String) {
        #expect(throws: SophonError.self) { try SafePath.normalize(raw) }
    }

    @Test func decodesStringNumbersAndIntFlags() throws {
        let json = """
        {"encryption": 0, "password": "", "compression": "1", "url_prefix": "https://x/y/", "url_suffix": ""}
        """
        let info = try JSONDecoder().decode(SophonDownloadInfo.self, from: Data(json.utf8))
        #expect(info.compression && !info.encryption)
        #expect(try info.url(for: "abc").absoluteString == "https://x/y/abc")

        let stats = try JSONDecoder().decode(SophonStats.self, from: Data("""
        {"compressed_size": "60642059824", "uncompressed_size": 61915564404,
         "file_count": "10692", "chunk_count": "58382"}
        """.utf8))
        #expect(stats.compressedSize == 60_642_059_824 && stats.uncompressedSize == 61_915_564_404)
    }

    @Test func decodesEnvelopeWithNullData() throws {
        let envelope = try JSONDecoder().decode(APIEnvelope<SophonBuild>.self, from: Data("""
        {"retcode": -202, "message": "not found", "data": null}
        """.utf8))
        #expect(envelope.data == nil && envelope.retcode == -202)
    }
}
