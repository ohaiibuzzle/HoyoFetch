import Crypto
import Foundation

/// One install / update run against one game folder. Holds the per-file workers.
final class Job: Sendable {
    static let installSuffix = "_tempSophon"
    static let updateSuffix = "_tempUpdate"
    static let patchSuffix = "_tempPatch"

    let root: URL
    let client: SophonClient
    let concurrency: SophonConcurrency
    let tracker: ProgressTracker

    init(root: URL, client: SophonClient, concurrency: SophonConcurrency, tracker: ProgressTracker) {
        self.root = root
        self.client = client
        self.concurrency = concurrency
        self.tracker = tracker
    }

    var http: HTTP { client.http }
    var stagingDirectory: URL { root.appending(path: SophonInstallState.directoryName).appending(path: "staging") }
    /// The folder HoYoPlay and Collapse keep patch blobs in.
    var patchDirectory: URL { root.appending(path: "ldiff") }

    func url(_ path: String) -> URL { SafePath.url(path, in: root) }

    func checkSpace(needed: Int64) throws {
        guard needed > 0, let available = availableCapacity(at: root) else { return }
        // Keep some slack for temp files and the filesystem itself.
        let margin: Int64 = 512 << 20
        if needed + margin > available {
            throw SophonError.insufficientSpace(needed: needed + margin, available: available)
        }
    }

    func createDirectories(_ assets: some Sequence<SophonAsset>) throws {
        for asset in assets where asset.isDirectory {
            try FileManager.default.createDirectory(at: url(asset.path), withIntermediateDirectories: true)
        }
    }

    // MARK: - Chunks

    /// True when `file` already holds `chunk` at its offset (spec section 4, step 1: the resume mechanism).
    func regionMatches(
        _ file: RandomAccessFile,
        length: Int64,
        _ chunk: SophonChunk,
        at offset: Int64? = nil
    ) throws -> Bool {
        let start = offset ?? chunk.offset
        guard length >= start + chunk.size else { return false }
        var md5 = Insecure.MD5()
        try file.read(range: start..<start + chunk.size) { md5.update(bufferPointer: $0) }
        return md5.finalize().hex == chunk.md5
    }

    /// Downloads, decompresses and MD5-verifies one chunk, trying each source in order
    /// (the update path falls back to the old build's prefix, spec 6.A).
    func fetchChunk(_ chunk: SophonChunk, from sources: [SophonDownloadInfo]) async throws -> Data {
        var lastError: (any Error)?
        for source in sources {
            do {
                let url = try source.url(for: chunk.name)
                return try await withRetries(onRetry: { attempt, error in
                    self.tracker.log("Retrying \(chunk.name) (\(attempt)): \(error.localizedDescription)")
                }, {
                    let raw = try await http.fetch(url)
                    tracker.add(downloaded: Int64(raw.count))
                    let data = source.compression ? try Zstd.decompress(raw, expectedSize: Int(chunk.size)) : raw
                    guard data.count == chunk.size, md5Hex(data) == chunk.md5 else {
                        throw SophonError.integrity("chunk \(chunk.name)")
                    }
                    return data
                })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SophonError.badResponse("no download source for \(chunk.name)")
    }

    func stagedChunkURL(_ chunk: SophonChunk) -> URL {
        stagingDirectory.appending(path: chunk.name)
    }

    /// A chunk staged by pre-download, decompressed and verified; nil if absent or bad.
    func stagedChunk(_ chunk: SophonChunk, compression: Bool) -> Data? {
        let url = stagedChunkURL(chunk)
        guard FileManager.default.fileSize(url) == chunk.compressedSize,
              let raw = try? Data(contentsOf: url) else { return nil }
        let data = compression ? try? Zstd.decompress(raw, expectedSize: Int(chunk.size)) : raw
        guard let data, md5Hex(data) == chunk.md5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    /// Downloads a chunk without decompressing it into the staging folder (spec 6.A, pre-download).
    func stageChunk(_ chunk: SophonChunk, from source: SophonDownloadInfo) async throws {
        let url = stagedChunkURL(chunk)
        let marker = url.appendingPathExtension("verified")
        if FileManager.default.fileSize(url) == chunk.compressedSize,
           FileManager.default.fileExists(atPath: marker.path) {
            tracker.add(completed: chunk.compressedSize)
            return
        }
        let remote = try source.url(for: chunk.name)
        let raw = try await withRetries {
            let raw = try await http.fetch(remote)
            tracker.add(downloaded: Int64(raw.count))
            let valid = if let hash = ContentHash(objectName: chunk.name) {
                raw.count == chunk.compressedSize && hash.matches(raw)
            } else {
                (try? md5Hex(source.compression ? Zstd.decompress(raw, expectedSize: Int(chunk.size)) : raw))
                    == chunk.md5
            }
            guard valid else { throw SophonError.integrity("chunk \(chunk.name)") }
            return raw
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try raw.write(to: url, options: .atomic)
        _ = FileManager.default.createFile(atPath: marker.path, contents: nil)
        tracker.add(completed: chunk.compressedSize)
    }

    // MARK: - Install / repair (spec sections 4 and 5)

    func installFile(_ asset: SophonAsset, source: SophonDownloadInfo) async throws {
        let final = url(asset.path)
        try FileManager.default.createDirectory(
            at: final.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { tracker.add(files: 1) }

        // An existing file is repaired in place; a new one is built under a temp name and renamed when complete.
        let target = FileManager.default.fileSize(final) != nil ? final : Self.suffixed(final, Self.installSuffix)
        let file = try RandomAccessFile(target, mode: .readWrite)
        var length = try file.length()
        if length > asset.size {
            try file.truncate(to: asset.size)
            length = asset.size
        }
        let initialLength = length

        try await forEachConcurrently(asset.chunks, limit: concurrency.chunksPerFile) { chunk in
            if try self.regionMatches(file, length: initialLength, chunk) {
                self.tracker.add(completed: chunk.compressedSize)
                return
            }
            let data = try await self.fetchChunk(chunk, from: [source])
            try file.write(data, at: chunk.offset)
            self.tracker.add(completed: chunk.compressedSize)
        }
        // Covers zero-length files (no chunks, spec section 7) and trailing holes.
        if try file.length() != asset.size { try file.truncate(to: asset.size) }
        if target != final { try FileManager.default.replace(final, with: target) }
    }

    func installAll(_ manifests: [SophonManifest]) async throws {
        try createDirectories(manifests.flatMap(\.assets))
        let files = Self.dedupe(manifests.flatMap { manifest in manifest.files.map { ($0, manifest.chunkDownload) } })

        var needed: Int64 = 0
        for (asset, _) in files {
            let final = url(asset.path)
            let existing = FileManager.default.fileSize(final)
                ?? FileManager.default.fileSize(Self.suffixed(final, Self.installSuffix)) ?? 0
            needed += max(asset.size - existing, 0)
        }
        try checkSpace(needed: needed)

        let totalBytes = files.reduce(0) { $0 + $1.0.chunks.reduce(0) { $0 + $1.compressedSize } }
        tracker.begin(.downloading, totalBytes: totalBytes,
                      totalFiles: files.count)
        try await forEachConcurrently(files, limit: concurrency.files) { asset, source in
            try await self.installFile(asset, source: source)
        }
    }

    // MARK: - Update by chunk reuse (spec 6.A)

    func updateFile(_ asset: SophonAsset, old: SophonAsset?, sources: [SophonDownloadInfo]) async throws {
        let final = url(asset.path)
        let temp = Self.suffixed(final, Self.updateSuffix)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { tracker.add(files: 1) }
        let chunkBytes = asset.chunks.reduce(0) { $0 + $1.compressedSize }

        // Already replaced by an interrupted earlier run?
        if fileManager.fileSize(temp) == nil,
           fileManager.fileSize(final) == asset.size,
           try ContentHash(asset.hash).matches(fileAt: final) {
            tracker.add(completed: chunkBytes)
            return
        }

        let oldFile = fileManager.fileSize(final) != nil ? try RandomAccessFile(final, mode: .read) : nil
        let oldLength = try oldFile?.length() ?? 0
        let oldOffsets = Dictionary(
            old?.chunks.map { ($0.md5, $0.offset) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        let compression = sources.first?.compression ?? true

        let out = try RandomAccessFile(temp, mode: .readWrite)
        var length = try out.length()
        if length > asset.size {
            try out.truncate(to: asset.size)
            length = asset.size
        }
        let initialLength = length

        try await forEachConcurrently(asset.chunks, limit: concurrency.chunksPerFile) { chunk in
            defer { self.tracker.add(completed: chunk.compressedSize) }
            if try self.regionMatches(out, length: initialLength, chunk) { return }
            // 1. The same bytes in the installed file.
            if let oldFile, let offset = oldOffsets[chunk.md5], oldLength >= offset + chunk.size {
                let data = try oldFile.read(at: offset, count: Int(chunk.size))
                if md5Hex(data) == chunk.md5 {
                    try out.write(data, at: chunk.offset)
                    return
                }
            }
            // 2. A pre-downloaded chunk.
            if let data = self.stagedChunk(chunk, compression: compression) {
                try out.write(data, at: chunk.offset)
                return
            }
            // 3. The CDN.
            try out.write(try await self.fetchChunk(chunk, from: sources), at: chunk.offset)
        }
        if try out.length() != asset.size { try out.truncate(to: asset.size) }
        try fileManager.replace(final, with: temp)
    }

    // MARK: - Helpers

    static func suffixed(_ url: URL, _ suffix: String) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + suffix)
    }

    /// Drops repeated paths across manifests, keeping the first.
    static func dedupe<T>(_ files: [(SophonAsset, T)]) -> [(SophonAsset, T)] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.0.key).inserted }
    }
}
