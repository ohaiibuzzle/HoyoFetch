import Foundation
import Synchronization
import Testing
@testable import SophonKit

/// Talks to the real HoYoverse APIs and CDNs with small subsets of Honkai: Star Rail's Japanese voice pack.
/// Run with `SOPHON_LIVE=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOPHON_LIVE"] != nil), .serialized)
struct LiveTests {
    static let biz = "hkrpg_global"
    static let field = "ja-jp"

    let client = SophonClient()

    /// Files by case-insensitive path.
    static func index(_ files: [SophonAsset]) -> [String: SophonAsset] {
        Dictionary(files.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func game() async throws -> SophonGameBranches {
        try #require(try await client.gameBranches().first { $0.game.biz == Self.biz })
    }

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "SophonLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func job(_ root: URL) -> Job {
        Job(root: root, client: client, concurrency: .default, tracker: ProgressTracker { event in
            if case .log(let line) = event { print("  [job] \(line)") }
        })
    }

    @Test func discoveryAndManifest() async throws {
        let game = try await game()
        let build = try await client.build(game.main)
        #expect(build.tag == game.main.tag)
        let entry = try #require(build.manifest(for: Self.field))
        let manifest = try await client.manifest(entry)
        let files = manifest.files
        let directories = manifest.assets.count - files.count
        print("\(Self.biz) \(build.tag) \(Self.field): \(files.count) files, \(directories) dirs")
        #expect(Int64(files.count) == entry.stats?.fileCount)
        for file in files {
            // Chunks are non-overlapping and cover [0, size).
            let sorted = file.chunks.sorted { $0.offset < $1.offset }
            var end: Int64 = 0
            for chunk in sorted {
                #expect(chunk.offset == end, "\(file.path)")
                end = chunk.offset + chunk.size
            }
            #expect(end == file.size, "\(file.path)")
        }
    }

    @Test func installsSmallFiles() async throws {
        let game = try await game()
        let entry = try #require(try await client.build(game.main).manifest(for: Self.field))
        let manifest = try await client.manifest(entry)
        let picks = manifest.files.filter { $0.size > 0 }.sorted { $0.size < $1.size }.prefix(3)
            + manifest.files.filter { $0.chunks.count > 1 }.sorted { $0.size < $1.size }.prefix(1)
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = job(root)

        for asset in picks {
            try await job.installFile(asset, source: manifest.chunkDownload)
            #expect(try ContentHash(asset.hash).matches(fileAt: job.url(asset.path)), "\(asset.path)")
        }

        // Re-running is a no-op thanks to the per-chunk skip check.
        let before = job.tracker.snapshot.downloadedBytes
        for asset in picks { try await job.installFile(asset, source: manifest.chunkDownload) }
        #expect(job.tracker.snapshot.downloadedBytes == before)

        // Damage one chunk; repair re-downloads only that chunk.
        let victim = picks.last!
        let file = try RandomAccessFile(job.url(victim.path), mode: .readWrite)
        try file.write(Data(repeating: 0xAA, count: 16), at: victim.chunks[0].offset)
        try await job.installFile(victim, source: manifest.chunkDownload)
        #expect(try ContentHash(victim.hash).matches(fileAt: job.url(victim.path)))
        #expect(job.tracker.snapshot.downloadedBytes - before == victim.chunks[0].compressedSize)
    }

    @Test func updatesByChunkReuse() async throws {
        let game = try await game()
        let oldTag = try #require(game.main.diffTags.first)
        let newEntry = try #require(try await client.build(game.main).manifest(for: Self.field))
        let oldEntry = try #require(try await client.build(game.main, tag: oldTag).manifest(for: Self.field))
        let new = try await client.manifest(newEntry)
        let old = try await client.manifest(oldEntry)
        let oldByKey = Self.index(old.files)

        // Changed files that share some chunks with their previous version.
        let changed = new.files.compactMap { asset -> (SophonAsset, SophonAsset)? in
            guard let prev = oldByKey[asset.key], prev.hash != asset.hash else { return nil }
            let shared = Set(prev.chunks.map(\.md5)).intersection(asset.chunks.map(\.md5))
            return shared.isEmpty ? nil : (asset, prev)
        }
        print("\(oldTag) → \(new.matchingField): \(changed.count) changed files share chunks with their old version")
        let (asset, prev) = try #require(changed.min { $0.0.size < $1.0.size })

        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = job(root)
        try await job.installFile(prev, source: old.chunkDownload)
        let afterOld = job.tracker.snapshot.downloadedBytes

        try await job.updateFile(asset, old: prev, sources: [new.chunkDownload, old.chunkDownload])
        #expect(try ContentHash(asset.hash).matches(fileAt: job.url(asset.path)))
        let downloaded = job.tracker.snapshot.downloadedBytes - afterOld
        let full = asset.chunks.reduce(0) { $0 + $1.compressedSize }
        print("updated \(asset.path): downloaded \(downloaded) of \(full) bytes")
        #expect(downloaded < full)
    }

    @Test func updatesByPatch() async throws {
        let game = try await game()
        let oldTag = try #require(game.main.diffTags.first)
        let patchBuild = try await client.patchBuild(game.main)
        let patchEntry = try #require(patchBuild.manifest(for: Self.field))
        try #require(patchEntry.stats[oldTag] != nil)
        let patches = try await client.patchManifest(patchEntry, sourceTag: oldTag)
        let blobSizes = Dictionary(
            patches.patches.values.map { ($0.blobName, $0.blobSize) },
            uniquingKeysWith: { first, _ in first }
        )
        print("patch \(oldTag) → \(patchBuild.tag) \(Self.field): "
              + "\(patches.patches.count) files in \(blobSizes.count) blobs "
              + "(\(blobSizes.values.sorted())), \(patches.patches.values.filter { $0.original != nil }.count) diffs, "
              + "\(patches.unused.count) unused")

        let newEntry = try #require(try await client.build(game.main).manifest(for: Self.field))
        let oldEntry = try #require(try await client.build(game.main, tag: oldTag).manifest(for: Self.field))
        let new = Self.index(try await client.manifest(newEntry).files)
        let old = try await client.manifest(oldEntry)
        let oldByKey = Self.index(old.files)

        // The smallest blob that holds a real diff, then every diff in it whose original is small.
        let diffs = patches.patches.values.filter { patch in
            patch.original.map { oldByKey[$0.path.lowercased()] != nil } ?? false
        }
        let blobName = try #require(diffs.min { $0.blobSize < $1.blobSize }?.blobName)
        let chosen = diffs.filter { $0.blobName == blobName }.sorted { $0.original!.size < $1.original!.size }.prefix(3)

        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = job(root)
        let blob = try await job.ensureBlob(chosen[chosen.startIndex], from: patches.diffDownload)
        // Download progress covers every byte of the blob, once.
        #expect(job.tracker.snapshot.downloadedBytes == FileManager.default.fileSize(blob))
        let head = try RandomAccessFile(blob, mode: .read).read(at: 0, count: 8)
        let magic = head.map { String(format: "%02x", $0) }.joined()
        print("blob \(blobName): \(FileManager.default.fileSize(blob) ?? -1) bytes, starts \(magic)")

        for patch in chosen {
            let original = try #require(oldByKey[patch.original!.path.lowercased()])
            try await job.installFile(original, source: old.chunkDownload)
            let target = try #require(new[patch.targetPath.lowercased()])
            let temp = try await job.applyPatch(target, patch, blob: blob)
            #expect(try ContentHash(target.hash).matches(fileAt: temp), "\(target.path)")
            print("patched \(original.path) (\(original.size)) → \(target.path) (\(target.size)) "
                  + "with \(patch.length) diff bytes")
        }
    }

    /// The public `update()` end to end on a real 4.5.0 → 4.6.0 subset: patched, unchanged and removed files.
    @Test(arguments: [true, false])
    func updatesEndToEnd(usePatches: Bool) async throws {
        let game = try await game()
        let oldTag = try #require(game.main.diffTags.first)
        let fields = ["game", Self.field]
        let oldBuild = try await client.build(game.main, tag: oldTag)
        let newBuild = try await client.build(game.main)
        var old: [SophonManifest] = []
        var new: [SophonManifest] = []
        for field in fields {
            old.append(try await client.manifest(try #require(oldBuild.manifest(for: field))))
            new.append(try await client.manifest(try #require(newBuild.manifest(for: field))))
        }
        let oldVoice = Self.index(old[1].files)
        let newVoice = Self.index(new[1].files)
        let patchEntry = try #require(try await client.patchBuild(game.main).manifest(for: Self.field))
        let patches = try await client.patchManifest(patchEntry, sourceTag: oldTag)

        // Diffs from the smallest blob, a few unchanged files, and whatever the new version dropped.
        let diffs = patches.patches.values.filter { $0.original?.path.lowercased() == $0.targetPath.lowercased() }
        let blob = try #require(diffs.min { $0.blobSize < $1.blobSize }?.blobName)
        let patched = diffs.filter { $0.blobName == blob }.sorted { $0.original!.size < $1.original!.size }.prefix(2)
            .map { $0.targetPath.lowercased() }
        let unchanged = new[1].files.filter { oldVoice[$0.key]?.hash == $0.hash }
            .sorted { $0.size < $1.size }.prefix(2).map(\.key)
            + new[0].files.filter { $0.size > 0 }.sorted { $0.size < $1.size }.prefix(1).map(\.key)
        let removed = oldVoice.keys.filter { newVoice[$0] == nil }.sorted().prefix(1)
        let keys = Set(patched + unchanged + removed)
        print("subset: \(patched.count) patched, \(unchanged.count) unchanged, \(removed.count) removed")

        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try await job(root).installAll(old.map { $0.filtered { keys.contains($0) } })
        try SophonInstallState(gameID: game.id, biz: game.game.biz, tag: oldTag, matchingFields: fields).save(to: root)

        let logs = Mutex([String]())
        let installer = SophonInstaller(client: client, concurrency: .default, assetFilter: { keys.contains($0) })
        try await installer.update(game, in: root, usePatches: usePatches) { event in
            if case .log(let line) = event { logs.withLock { $0.append(line) }; print("  [update] \(line)") }
        }

        for manifest in new {
            for asset in manifest.files where keys.contains(asset.key) {
                #expect(try ContentHash(asset.hash).matches(fileAt: root.appending(path: asset.path)), "\(asset.path)")
            }
        }
        for key in removed {
            let path = root.appending(path: oldVoice[key]!.path).path
            #expect(!FileManager.default.fileExists(atPath: path), "\(key) not removed")
        }
        #expect(SophonInstallState.load(from: root)?.tag == game.main.tag)
        let leftovers = FileManager.default.enumerator(atPath: root.path)!.compactMap { $0 as? String }
            .filter { $0.hasSuffix(Job.patchSuffix) || $0.hasSuffix(Job.updateSuffix) || $0.hasPrefix("ldiff") }
        #expect(leftovers.isEmpty, "\(leftovers)")
        let summary = try #require(logs.withLock { $0 }.first { $0.contains("unchanged") })
        #expect(summary.contains(usePatches ? "\(patched.count) to patch" : "0 to patch"), "\(summary)")
    }
}
