import Foundation

// JSON models for the HoYoPlay discovery APIs (spec section 2).
// The API sends most numbers as strings and flags as 0/1, so decoding is tolerant of both.

struct APIEnvelope<T: Decodable>: Decodable {
    let retcode: Int
    let message: String
    let data: T?
}

/// One game as listed by `getGames`; only used for display names.
public struct SophonGameInfo: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let biz: String
    public let name: String?

    private enum CodingKeys: String, CodingKey { case id, biz, display }
    private struct Display: Decodable { let name: String? }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        biz = try container.decode(String.self, forKey: .biz)
        name = try container.decodeIfPresent(Display.self, forKey: .display)?.name
    }
}

struct GamesData: Decodable {
    let games: [SophonGameInfo]
}

struct GameBranchesData: Decodable {
    let gameBranches: [SophonGameBranches]
    private enum CodingKeys: String, CodingKey { case gameBranches = "game_branches" }
}

/// A game's live and pre-download branches from `getGameBranches`.
///
/// Several entries can share a `biz` (Honkai Impact 3rd has one per region), so entries are identified by `game.id`.
public struct SophonGameBranches: Decodable, Sendable, Hashable, Identifiable {
    public struct Game: Decodable, Sendable, Hashable {
        public let id: String
        public let biz: String
    }

    public let game: Game
    public let main: SophonBranch
    public let preDownload: SophonBranch?

    public var id: String { game.id }

    private enum CodingKeys: String, CodingKey {
        case game, main
        case preDownload = "pre_download"
    }
}

/// The query parameters needed for `getBuild` / `getPatchBuild`. They can change between versions; fetch them
/// every run.
public struct SophonBranch: Decodable, Sendable, Hashable {
    public struct Category: Decodable, Sendable, Hashable {
        public let categoryID: String
        public let matchingField: String

        private enum CodingKeys: String, CodingKey {
            case categoryID = "category_id"
            case matchingField = "matching_field"
        }
    }

    public let packageID: String
    /// `main` or `predownload`.
    public let branch: String
    public let password: String
    /// The version this branch serves.
    public let tag: String
    /// Versions a patch build exists for.
    public let diffTags: [String]
    public let categories: [Category]

    private enum CodingKeys: String, CodingKey {
        case packageID = "package_id"
        case branch, password, tag
        case diffTags = "diff_tags"
        case categories
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageID = try container.decode(String.self, forKey: .packageID)
        branch = try container.decode(String.self, forKey: .branch)
        password = try container.decode(String.self, forKey: .password)
        tag = try container.decode(String.self, forKey: .tag)
        diffTags = try container.decodeIfPresent([String].self, forKey: .diffTags) ?? []
        categories = try container.decodeIfPresent([Category].self, forKey: .categories) ?? []
    }
}

public struct SophonManifestFileInfo: Decodable, Sendable, Hashable {
    /// `manifest_<16 hex xxh64 of the downloaded file>_<32 hex md5>`.
    public let id: String
    public let checksum: String
    public let compressedSize: Int64
    public let uncompressedSize: Int64

    private enum CodingKeys: String, CodingKey {
        case id, checksum
        case compressedSize = "compressed_size"
        case uncompressedSize = "uncompressed_size"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        checksum = try container.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        compressedSize = try container.decodeFlexibleInt(forKey: .compressedSize)
        uncompressedSize = try container.decodeFlexibleInt(forKey: .uncompressedSize)
    }
}

public struct SophonDownloadInfo: Decodable, Sendable, Hashable {
    public let encryption: Bool
    public let compression: Bool
    public let urlPrefix: String

    private enum CodingKeys: String, CodingKey {
        case encryption, compression
        case urlPrefix = "url_prefix"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        encryption = try container.decodeFlexibleBool(forKey: .encryption)
        compression = try container.decodeFlexibleBool(forKey: .compression)
        urlPrefix = try container.decode(String.self, forKey: .urlPrefix)
    }

    /// `{url_prefix}/{name}`, with any trailing slash on the prefix trimmed.
    func url(for name: String) throws(SophonError) -> URL {
        var prefix = urlPrefix
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard let url = URL(string: "\(prefix)/\(name)") else { throw .badResponse("invalid URL prefix \(urlPrefix)") }
        return url
    }
}

public struct SophonStats: Decodable, Sendable, Hashable {
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let fileCount: Int64
    public let chunkCount: Int64

    private enum CodingKeys: String, CodingKey {
        case compressedSize = "compressed_size"
        case uncompressedSize = "uncompressed_size"
        case fileCount = "file_count"
        case chunkCount = "chunk_count"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        compressedSize = try container.decodeFlexibleInt(forKey: .compressedSize)
        uncompressedSize = try container.decodeFlexibleInt(forKey: .uncompressedSize)
        fileCount = try container.decodeFlexibleInt(forKey: .fileCount)
        chunkCount = try container.decodeFlexibleInt(forKey: .chunkCount)
    }
}

/// `getBuild` response data.
public struct SophonBuild: Decodable, Sendable, Hashable {
    public let buildID: String
    public let tag: String
    public let manifests: [SophonBuildManifest]

    private enum CodingKeys: String, CodingKey {
        case buildID = "build_id"
        case tag, manifests
    }

    public func manifest(for matchingField: String) -> SophonBuildManifest? {
        manifests.first { $0.matchingField == matchingField }
    }
}

public struct SophonBuildManifest: Decodable, Sendable, Hashable {
    public let categoryID: String
    public let categoryName: String
    public let matchingField: String
    public let manifest: SophonManifestFileInfo
    public let manifestDownload: SophonDownloadInfo
    public let chunkDownload: SophonDownloadInfo
    public let stats: SophonStats?
    public let deduplicatedStats: SophonStats?

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
        case matchingField = "matching_field"
        case manifest
        case manifestDownload = "manifest_download"
        case chunkDownload = "chunk_download"
        case stats
        case deduplicatedStats = "deduplicated_stats"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = try container.decodeIfPresent(String.self, forKey: .categoryID) ?? ""
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName) ?? ""
        matchingField = try container.decode(String.self, forKey: .matchingField)
        manifest = try container.decode(SophonManifestFileInfo.self, forKey: .manifest)
        manifestDownload = try container.decode(SophonDownloadInfo.self, forKey: .manifestDownload)
        chunkDownload = try container.decode(SophonDownloadInfo.self, forKey: .chunkDownload)
        stats = try container.decodeIfPresent(SophonStats.self, forKey: .stats)
        deduplicatedStats = try container.decodeIfPresent(SophonStats.self, forKey: .deduplicatedStats)
    }
}

/// `getPatchBuild` response data.
public struct SophonPatchBuild: Decodable, Sendable, Hashable {
    public let buildID: String
    public let tag: String
    public let patchID: String
    public let manifests: [SophonPatchBuildManifest]

    private enum CodingKeys: String, CodingKey {
        case buildID = "build_id"
        case tag
        case patchID = "patch_id"
        case manifests
    }

    public func manifest(for matchingField: String) -> SophonPatchBuildManifest? {
        manifests.first { $0.matchingField == matchingField }
    }
}

public struct SophonPatchBuildManifest: Decodable, Sendable, Hashable {
    public let categoryID: String
    public let categoryName: String
    public let matchingField: String
    public let manifest: SophonManifestFileInfo
    public let manifestDownload: SophonDownloadInfo
    public let diffDownload: SophonDownloadInfo
    /// Keyed by the *source* version. No key for the installed version means no patch exists for it.
    public let stats: [String: SophonStats]

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
        case matchingField = "matching_field"
        case manifest
        case manifestDownload = "manifest_download"
        case diffDownload = "diff_download"
        case stats
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = try container.decodeIfPresent(String.self, forKey: .categoryID) ?? ""
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName) ?? ""
        matchingField = try container.decode(String.self, forKey: .matchingField)
        manifest = try container.decode(SophonManifestFileInfo.self, forKey: .manifest)
        manifestDownload = try container.decode(SophonDownloadInfo.self, forKey: .manifestDownload)
        diffDownload = try container.decode(SophonDownloadInfo.self, forKey: .diffDownload)
        stats = try container.decodeIfPresent([String: SophonStats].self, forKey: .stats) ?? [:]
    }
}

extension KeyedDecodingContainer {
    /// Accepts `123` or `"123"`; a missing key or empty string decodes as 0.
    func decodeFlexibleInt(forKey key: Key) throws -> Int64 {
        guard contains(key), try !decodeNil(forKey: key) else { return 0 }
        if let value = try? decode(Int64.self, forKey: key) { return value }
        let string = try decode(String.self, forKey: key)
        if string.isEmpty { return 0 }
        guard let value = Int64(string) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not an integer: \(string)")
        }
        return value
    }

    /// Accepts `true`/`false`, `0`/`1` and their string forms; a missing key decodes as false.
    func decodeFlexibleBool(forKey key: Key) throws -> Bool {
        guard contains(key), try !decodeNil(forKey: key) else { return false }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        return try decodeFlexibleInt(forKey: key) != 0
    }
}
