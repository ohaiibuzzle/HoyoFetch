// Names follow the xxHash spec (PRIME64_1…5, accumulators v1…v4, h64).
// swiftlint:disable identifier_name

/// Streaming XXH64 (https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md).
struct XXH64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var v1, v2, v3, v4: UInt64
    private var total: UInt64 = 0
    /// Input not yet consumed as a full 32-byte stripe.
    private var tail = [UInt8]()

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    static func hash(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var h = XXH64()
        h.update(Array(bytes))
        return h.finalize()
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        total &+= UInt64(buffer.count)
        var input = buffer[...]

        if !tail.isEmpty {
            let take = min(32 - tail.count, input.count)
            tail.append(contentsOf: input.prefix(take))
            input = input.dropFirst(take)
            guard tail.count == 32 else { return }
            let stripe = tail
            stripe.withUnsafeBytes { consumeStripes($0) }
            tail.removeAll(keepingCapacity: true)
        }

        let stripes = input.count / 32 * 32
        if stripes > 0 {
            consumeStripes(UnsafeRawBufferPointer(rebasing: input.prefix(stripes)))
        }
        tail.append(contentsOf: input.dropFirst(stripes))
    }

    private mutating func consumeStripes(_ data: UnsafeRawBufferPointer) {
        var offset = 0
        while offset + 32 <= data.count {
            v1 = Self.round(v1, data.loadLE(offset))
            v2 = Self.round(v2, data.loadLE(offset + 8))
            v3 = Self.round(v3, data.loadLE(offset + 16))
            v4 = Self.round(v4, data.loadLE(offset + 24))
            offset += 32
        }
    }

    func finalize() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = v1.rotl(1) &+ v2.rotl(7) &+ v3.rotl(12) &+ v4.rotl(18)
            h = Self.merge(h, v1)
            h = Self.merge(h, v2)
            h = Self.merge(h, v3)
            h = Self.merge(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= total

        tail.withUnsafeBytes { rest in
            var i = 0
            while i + 8 <= rest.count {
                h ^= Self.round(0, rest.loadLE(i))
                h = h.rotl(27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= rest.count {
                h ^= UInt64(UInt32(littleEndian: rest.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* Self.p1
                h = h.rotl(23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < rest.count {
                h ^= UInt64(rest[i]) &* Self.p5
                h = h.rotl(11) &* Self.p1
                i += 1
            }
        }

        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    /// The canonical (big-endian) digest as lowercase hex, which is how Sophon names objects.
    func hexDigest() -> String {
        let value = finalize()
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        (acc &+ input &* p2).rotl(31) &* p1
    }

    private static func merge(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        (acc ^ round(0, value)) &* p1 &+ p4
    }
}

private extension UInt64 {
    func rotl(_ n: UInt64) -> UInt64 { (self << n) | (self >> (64 - n)) }
}

private extension UnsafeRawBufferPointer {
    func loadLE(_ offset: Int) -> UInt64 {
        UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

// swiftlint:enable identifier_name
