import Foundation
import HPatch

/// A file descriptor used with `pread`/`pwrite`, so concurrent chunk writers can share one handle.
final class RandomAccessFile: Sendable {
    enum Mode { case read, readWrite }

    let url: URL
    private let fd: Int32

    init(_ url: URL, mode: Mode) throws {
        self.url = url
        let flags = mode == .read ? O_RDONLY : (O_RDWR | O_CREAT)
        fd = url.withUnsafeFileSystemRepresentation { open($0!, flags | O_CLOEXEC, 0o644) }
        guard fd >= 0 else { throw Self.error("open", url) }
    }

    deinit {
        close(fd)
    }

    func length() throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.error("stat", url) }
        return Int64(info.st_size)
    }

    func truncate(to size: Int64) throws {
        guard ftruncate(fd, off_t(size)) == 0 else { throw Self.error("truncate", url) }
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try read(at: offset, into: $0) }
        return data
    }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws {
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.error("read", url)
            }
            if n == 0 { throw SophonError.io("unexpected end of file reading \(url.path)") }
            done += n
        }
    }

    /// Streams `range` through `body` in 1 MiB blocks.
    func read(range: Range<Int64>, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let block = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: block, alignment: 16)
        defer { buffer.deallocate() }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let n = Int(min(Int64(block), range.upperBound - offset))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<n])
            try read(at: offset, into: slice)
            try body(UnsafeRawBufferPointer(slice))
            offset += Int64(n)
        }
    }

    func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.error("write", url)
                }
                done += n
            }
        }
    }

    private static func error(_ operation: String, _ url: URL) -> SophonError {
        .io("\(operation) \(url.path): \(String(cString: strerror(errno)))")
    }
}

/// `[offset, offset + length)` of a file, as HPatch input. Used to read one file's diff out of a patch blob.
struct FileSlice: HPatchSource {
    let file: RandomAccessFile
    let offset: Int64
    let length: Int64

    var size: UInt64 { UInt64(length) }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        try file.read(at: self.offset + Int64(offset), into: buffer)
    }
}

extension RandomAccessFile: HPatchSource, HPatchSink {
    var size: UInt64 {
        get throws { UInt64(try length()) }
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        try read(at: Int64(offset), into: buffer)
    }

    func prepare(size: UInt64) throws {
        try truncate(to: Int64(size))
    }

    func write(at offset: UInt64, _ bytes: UnsafeRawBufferPointer) throws {
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
            count: bytes.count,
            deallocator: .none
        )
        try write(data, at: Int64(offset))
    }
}

extension FileManager {
    /// Atomically moves `source` over `destination` (rename(2)), creating the parent directory.
    func replace(_ destination: URL, with source: URL) throws {
        try createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ok = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in rename(src!, dst!) == 0 }
        }
        guard ok else {
            throw SophonError.io("rename \(source.path) -> \(destination.path): \(String(cString: strerror(errno)))")
        }
    }

    func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }
}
