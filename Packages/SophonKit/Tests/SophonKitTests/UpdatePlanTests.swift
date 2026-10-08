import Foundation
import Testing
@testable import SophonKit

/// `Updater.plan` decides which installed files an update deletes, so it is checked offline here.
struct UpdatePlanTests {
    private let fileManager = FileManager.default

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func file(_ path: String, hash: String) -> SophonAsset {
        SophonAsset(path: path, size: 1, hash: hash, isDirectory: false, chunks: [])
    }

    private func unused(_ tag: String, _ names: [String]) -> SophonUnusedAssetProperty {
        var info = SophonUnusedAssetInfo()
        info.assets = names.map { name in
            var file = SophonUnusedAssetFile()
            file.fileName = name
            return file
        }
        var property = SophonUnusedAssetProperty()
        property.versionTag = tag
        property.assetInfos = [info]
        return property
    }

    @Test func removesOnlyWhatTheNewVersionDropped() throws {
        let root = fileManager.temporaryDirectory.appending(path: "SophonPlan-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let job = Job(root: root, client: SophonClient(), concurrency: .default, tracker: ProgressTracker { _ in })
        let branch: SophonBranch = try decode(#"{"package_id": "p", "branch": "main", "password": "", "tag": "1.1"}"#)
        let download: SophonDownloadInfo = try decode(#"{"encryption": 0, "compression": 1, "url_prefix": "x"}"#)
        let updater = Updater(
            installer: SophonInstaller(),
            job: job,
            state: SophonInstallState(gameID: "g", biz: "b", tag: "1.0", matchingFields: ["game"]),
            fields: ["game"],
            current: branch,
            target: branch,
            usePatches: true
        )

        let same = file("Data/Same.pak", hash: "aa")
        try fileManager.createDirectory(at: root.appending(path: "Data"), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: job.url(same.path).path, contents: Data("x".utf8))
        let old = [same, file("Data/Case.PAK", hash: "bb"), file("Data/Old.pak", hash: "cc")]
        let new = [same, file("data/case.pak", hash: "dd"), file("Data/New.pak", hash: "ee")]

        var chunk = SophonPatchAssetChunk()
        chunk.patchName = "blob"
        chunk.patchSize = 10
        chunk.patchLength = 10
        var info = SophonPatchAssetInfo()
        info.versionTag = "1.0"
        info.chunk = chunk
        var patched = SophonPatchAssetProperty()
        patched.assetName = "Data/New.pak"
        patched.assetInfos = [info]
        var proto = SophonPatchProto()
        proto.patchAssets = [patched]
        // `Same.pak` is still in the new version, and `Other.pak` belongs to another source version: both stay.
        proto.unusedAssets = [unused("1.0", ["Data/Unused.pak", "Data/Same.pak"]), unused("0.9", ["Data/Other.pak"])]
        let patches = try SophonPatchManifest(matchingField: "game", proto: proto, sourceTag: "1.0",
                                              diffDownload: download)

        let plan = try updater.plan(
            newManifests: [SophonManifest(matchingField: "game", assets: new, chunkDownload: download)],
            oldAssets: Dictionary(uniqueKeysWithValues: old.map { ($0.key, $0) }),
            oldSources: [:],
            patchManifests: ["game": patches]
        )

        #expect(plan.unchanged == 1)
        #expect(plan.patches.map(\.asset.path) == ["Data/New.pak"])
        #expect(plan.rebuilds.map(\.asset.path) == ["data/case.pak"])
        #expect(Set(plan.removals) == ["Data/Old.pak", "Data/Unused.pak"])
    }
}
