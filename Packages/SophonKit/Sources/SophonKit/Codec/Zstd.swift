import Foundation
import libzstd

enum Zstd {
    /// Decompresses `input`, which must produce exactly `expectedSize` bytes.
    static func decompress(_ input: Data, expectedSize: Int) throws(SophonError) -> Data {
        // One spare byte so an oversized frame fails the size check instead of looking like an exact fit.
        var output = Data(count: expectedSize + 1)
        let result = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                ZSTD_decompress(dst.baseAddress, dst.count, src.baseAddress, src.count)
            }
        }
        if ZSTD_isError(result) != 0 {
            throw .decompression(String(cString: ZSTD_getErrorName(result)))
        }
        guard result == expectedSize else {
            throw .decompression("expected \(expectedSize) bytes, got \(result)")
        }
        output.count = expectedSize
        return output
    }
}
