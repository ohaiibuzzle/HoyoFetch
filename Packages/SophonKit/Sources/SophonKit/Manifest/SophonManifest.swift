import Foundation
import SwiftProtobuf

/// One file (or directory) of a build, with a sanitised relative path.
public struct SophonAsset: Sendable, Hashable {
    /// Relative path with `/` separators, checked against traversal.
    public let path: String
    public let size: Int64
    /// MD5 (32 hex) or XXH64 (16 hex) of the whole file; empty for directories.
    public let hash: String
    public let isDirectory: Bool
    public let chunks: [SophonChunk]

    /// Case-insensitive identity; manifests come from Windows and are matched without case.
    var key: String { path.lowercased() }
}

public struct SophonChunk: Sendable, Hashable {
    /// CDN object name, `<16 hex xxh64 of the compressed chunk>_<32 hex>`.
    public let name: String
    /// MD5 of the decompressed bytes.
    public let md5: String
    public let offset: Int64
    /// Bytes on the wire.
    public let compressedSize: Int64
    /// Bytes in the file.
    public let size: Int64
}

/// A parsed manifest plus where to download its chunks from.
public struct SophonManifest: Sendable {
    public let matchingField: String
    public let assets: [SophonAsset]
    public let chunkDownload: SophonDownloadInfo

    public var files: [SophonAsset] { assets.filter { !$0.isDirectory } }

    init(matchingField: String, assets: [SophonAsset], chunkDownload: SophonDownloadInfo) {
        self.matchingField = matchingField
        self.assets = assets
        self.chunkDownload = chunkDownload
    }

    func filtered(_ include: ((String) -> Bool)?) -> SophonManifest {
        guard let include else { return self }
        return SophonManifest(
            matchingField: matchingField,
            assets: assets.filter { include($0.key) },
            chunkDownload: chunkDownload
        )
    }

    init(matchingField: String, proto: SophonManifestProto, chunkDownload: SophonDownloadInfo) throws {
        self.matchingField = matchingField
        self.chunkDownload = chunkDownload
        assets = try proto.assets.map { asset in
            // Spec 3.3: AssetType != 0 or an empty hash marks a directory.
            let isDirectory = asset.assetType != 0 || asset.assetHashMd5.isEmpty
            return SophonAsset(
                path: try SafePath.normalize(asset.assetName),
                size: asset.assetSize,
                hash: asset.assetHashMd5.lowercased(),
                isDirectory: isDirectory,
                chunks: isDirectory ? [] : asset.assetChunks.map {
                    SophonChunk(
                        name: $0.chunkName,
                        md5: $0.chunkDecompressedHashMd5.lowercased(),
                        offset: $0.chunkOnFileOffset,
                        compressedSize: $0.chunkSize,
                        size: $0.chunkSizeDecompressed
                    )
                }
            )
        }
    }
}

/// The patch manifest of a patch build (spec 6.B), reduced to what one source version needs.
struct SophonPatchManifest: Sendable {
    struct Patch: Sendable {
        let targetPath: String
        let blobName: String
        let blobSize: Int64
        let blobMD5: String
        let offset: Int64
        let length: Int64
        /// nil: the slice is the complete new file (`CopyOver`). Otherwise apply the slice as a diff to this file
        /// (`Patch`).
        let original: Original?
    }

    struct Original: Sendable {
        let path: String
        let size: Int64
        let hash: String
    }

    let matchingField: String
    let diffDownload: SophonDownloadInfo
    /// Keyed by lowercased target path.
    let patches: [String: Patch]
    /// Files the source version had that the target no longer needs.
    let unused: [String]

    private init(matchingField: String, diffDownload: SophonDownloadInfo, patches: [String: Patch], unused: [String]) {
        self.matchingField = matchingField
        self.diffDownload = diffDownload
        self.patches = patches
        self.unused = unused
    }

    func filtered(_ include: ((String) -> Bool)?) -> SophonPatchManifest {
        guard let include else { return self }
        return SophonPatchManifest(
            matchingField: matchingField,
            diffDownload: diffDownload,
            patches: patches.filter { include($0.key) },
            unused: unused.filter { include($0.lowercased()) }
        )
    }

    init(matchingField: String, proto: SophonPatchProto, sourceTag: String, diffDownload: SophonDownloadInfo) throws {
        self.matchingField = matchingField
        self.diffDownload = diffDownload
        var patches: [String: Patch] = [:]
        for asset in proto.patchAssets {
            guard let info = asset.assetInfos.first(where: { $0.versionTag == sourceTag }), info.hasChunk else {
                continue
            }
            let chunk = info.chunk
            let path = try SafePath.normalize(asset.assetName)
            patches[path.lowercased()] = Patch(
                targetPath: path,
                blobName: chunk.patchName,
                blobSize: chunk.patchSize,
                blobMD5: chunk.patchMd5.lowercased(),
                offset: chunk.patchOffset,
                length: chunk.patchLength,
                original: chunk.originalFileName.isEmpty ? nil : Original(
                    path: try SafePath.normalize(chunk.originalFileName),
                    size: chunk.originalFileLength,
                    hash: chunk.originalFileMd5.lowercased()
                )
            )
        }
        self.patches = patches
        unused = try proto.unusedAssets
            .filter { $0.versionTag == sourceTag }
            .flatMap { $0.assetInfos.flatMap(\.assets) }
            .map { try SafePath.normalize($0.fileName) }
    }
}

enum SafePath {
    /// Normalises separators and rejects absolute paths and `..` components (spec 3.3, "Path safety").
    static func normalize(_ raw: String) throws(SophonError) -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") || unified.contains(":") { throw .unsafePath(raw) }
        let parts = unified.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if parts.isEmpty || parts.contains("..") || parts.contains(where: { $0.contains("\0") }) {
            throw .unsafePath(raw)
        }
        return parts.joined(separator: "/")
    }

    static func url(_ path: String, in root: URL) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }
}

extension SophonClient {
    /// Downloads, verifies (XXH64 from the manifest id) and parses the manifest of a full build.
    public func manifest(_ entry: SophonBuildManifest) async throws -> SophonManifest {
        guard !entry.chunkDownload.encryption else {
            throw SophonError.encryptedDownload("chunks of \(entry.matchingField)")
        }
        let data = try await manifestData(entry.manifest, entry.manifestDownload)
        return try SophonManifest(
            matchingField: entry.matchingField,
            proto: SophonManifestProto(serializedBytes: data),
            chunkDownload: entry.chunkDownload
        )
    }

    func patchManifest(_ entry: SophonPatchBuildManifest, sourceTag: String) async throws -> SophonPatchManifest {
        guard !entry.diffDownload.encryption else {
            throw SophonError.encryptedDownload("patches of \(entry.matchingField)")
        }
        let data = try await manifestData(entry.manifest, entry.manifestDownload)
        return try SophonPatchManifest(
            matchingField: entry.matchingField,
            proto: SophonPatchProto(serializedBytes: data),
            sourceTag: sourceTag,
            diffDownload: entry.diffDownload
        )
    }

    private func manifestData(_ file: SophonManifestFileInfo, _ download: SophonDownloadInfo) async throws -> Data {
        guard !download.encryption else { throw SophonError.encryptedDownload(file.id) }
        let url = try download.url(for: file.id)
        return try await withRetries {
            let raw = try await http.fetch(url)
            if let expected = ContentHash(objectName: file.id), !expected.matches(raw) {
                throw SophonError.integrity("manifest \(file.id)")
            }
            guard download.compression else { return raw }
            return try Zstd.decompress(raw, expectedSize: Int(file.uncompressedSize))
        }
    }
}
