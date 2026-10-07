import Crypto
import Foundation

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func md5Hex(_ data: some DataProtocol) -> String {
    Insecure.MD5.hash(data: data).hex
}

/// A hash string from a manifest. The patch path picks the algorithm by digest length (spec 6.B),
/// so every verifier here does the same: 16 hex digits are XXH64, anything else is MD5.
struct ContentHash: Sendable, Hashable, CustomStringConvertible {
    enum Kind: Sendable { case xxh64, md5 }

    let kind: Kind
    let hex: String

    init(_ hex: String) {
        self.hex = hex.lowercased()
        kind = hex.count == 16 ? .xxh64 : .md5
    }

    /// The XXH64 prefix of a `<16 hex>_<...>` object name (chunks, manifests, patch blobs), if it has one.
    init?(objectName name: String) {
        let base = name.hasPrefix("manifest_") ? String(name.dropFirst("manifest_".count)) : name
        let parts = base.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 16, parts[0].allSatisfy(\.isHexDigit) else { return nil }
        self.init(String(parts[0]))
    }

    var description: String { "\(kind == .xxh64 ? "xxh64" : "md5"):\(hex)" }

    func matches(_ data: some DataProtocol) -> Bool {
        var hasher = Hasher(kind)
        for region in data.regions { region.withUnsafeBytes { hasher.update($0) } }
        return hasher.hex == hex
    }

    /// Hashes the first `length` bytes of `file` (the whole file when nil).
    func matches(file: RandomAccessFile, length: Int64? = nil) throws -> Bool {
        var hasher = Hasher(kind)
        try file.read(range: 0..<(length ?? file.length())) { hasher.update($0) }
        return hasher.hex == hex
    }

    func matches(fileAt url: URL) throws -> Bool {
        try matches(file: RandomAccessFile(url, mode: .read))
    }

    struct Hasher {
        private var md5: Insecure.MD5?
        private var xxh: XXH64?

        init(_ kind: Kind) {
            switch kind {
            case .md5: md5 = Insecure.MD5()
            case .xxh64: xxh = XXH64()
            }
        }

        mutating func update(_ buffer: UnsafeRawBufferPointer) {
            md5?.update(bufferPointer: buffer)
            xxh?.update(buffer)
        }

        var hex: String { md5.map { $0.finalize().hex } ?? xxh!.hexDigest() }
    }
}
