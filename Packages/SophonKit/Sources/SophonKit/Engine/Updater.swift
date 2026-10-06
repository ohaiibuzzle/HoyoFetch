import Foundation

/// What one update does to each file of the new version (spec section 6).
struct UpdatePlan: Sendable {
    /// A file rebuilt from its old version's chunks, pre-downloaded chunks and the CDN (spec 6.A).
    struct Rebuild: Sendable {
        let asset: SophonAsset
        let old: SophonAsset?
        let sources: [SophonDownloadInfo]

        var chunkBytes: Int64 { asset.chunks.reduce(0) { $0 + $1.compressedSize } }
    }

    /// A file produced from a patch blob (spec 6.B), rebuilt instead if that fails.
    struct Patch: Sendable {
        let asset: SophonAsset
        let patch: SophonPatchManifest.Patch
        let source: SophonDownloadInfo
        let fallback: Rebuild
    }

    var unchanged = 0
    var patches: [Patch] = []
    var rebuilds: [Rebuild] = []
    /// Paths the new version no longer has.
    var removals: [String] = []

    /// One patch per distinct blob; blobs are shared between files, so each is fetched once.
    var blobs: [Patch] {
        var seen = Set<String>()
        return patches.filter { seen.insert($0.patch.blobName).inserted }
    }

    var blobBytes: Int64 { blobs.reduce(0) { $0 + $1.patch.blobSize } }
}

/// Runs one update or pre-download from the installed version (`state.tag`) to `target`.
struct Updater {
    let installer: SophonInstaller
    let job: Job
    let state: SophonInstallState
    /// The live branch, whose parameters also serve the installed version's manifests by tag.
    let current: SophonBranch
    let target: SophonBranch
    let usePatches: Bool

    private var tracker: ProgressTracker { job.tracker }
    private var concurrency: SophonConcurrency { job.concurrency }
    private var fields: [String] { state.matchingFields }

    /// Returns true when the folder is now at `target.tag`.
    func run(preDownloadOnly: Bool) async throws -> Bool {
        let newBuild = try await installer.client.build(target)

        // The installed version's manifests, requested by tag (spec 6.A).
        let oldBuild: SophonBuild
        do {
            oldBuild = try await installer.client.build(current, tag: state.tag)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !preDownloadOnly else { throw error }
            tracker.log("Could not fetch the \(state.tag) manifests (\(error.localizedDescription)); "
                + "falling back to a full verify")
            try await job.installAll(installer.loadManifests(newBuild, fields: fields, job: job).manifests)
            return true
        }

        let newManifests = try await installer.loadManifests(newBuild, fields: fields, job: job).manifests
        let plan = try plan(
            newManifests: newManifests,
            oldAssets: try await oldAssets(oldBuild),
            oldSources: Dictionary(oldBuild.manifests.map { ($0.matchingField, $0.chunkDownload) },
                                   uniquingKeysWith: { first, _ in first }),
            patchManifests: usePatches ? try await patchManifests() : [:]
        )
        tracker.log("\(plan.unchanged) files unchanged, \(plan.patches.count) to patch, "
            + "\(plan.rebuilds.count) to rebuild, \(plan.removals.count) to remove")

        if preDownloadOnly {
            try await preDownload(plan)
            return false
        }
        try await apply(plan)
        return true
    }

    // MARK: - Inputs

    private func oldAssets(_ oldBuild: SophonBuild) async throws -> [String: SophonAsset] {
        var assets: [String: SophonAsset] = [:]
        for field in fields {
            guard let entry = oldBuild.manifest(for: field) else { continue }
            tracker.log("Fetching \(state.tag) manifest for \(field)")
            for asset in try await installer.manifest(entry).files { assets[asset.key] = asset }
        }
        return assets
    }

    /// Patch manifests for fields whose patch build covers the installed version (spec 2.4).
    private func patchManifests() async throws -> [String: SophonPatchManifest] {
        var manifests: [String: SophonPatchManifest] = [:]
        do {
            let patchBuild = try await installer.client.patchBuild(target)
            for field in fields {
                guard let entry = patchBuild.manifest(for: field) else { continue }
                guard entry.stats[state.tag] != nil else {
                    tracker.log("No \(field) patch from \(state.tag); using chunk reuse")
                    continue
                }
                tracker.log("Fetching patch manifest for \(field)")
                manifests[field] = try await installer.client.patchManifest(entry, sourceTag: state.tag)
                    .filtered(installer.assetFilter)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            tracker.log("No patch build available (\(error.localizedDescription)); using chunk reuse")
        }
        return manifests
    }

    // MARK: - Planning

    private func plan(
        newManifests: [SophonManifest],
        oldAssets: [String: SophonAsset],
        oldSources: [String: SophonDownloadInfo],
        patchManifests: [String: SophonPatchManifest]
    ) throws -> UpdatePlan {
        var plan = UpdatePlan()
        var newKeys = Set<String>()
        for manifest in newManifests {
            try job.createDirectories(manifest.assets)
            let sources = [manifest.chunkDownload] + (oldSources[manifest.matchingField].map { [$0] } ?? [])
            let patchManifest = patchManifests[manifest.matchingField]
            for asset in manifest.files where newKeys.insert(asset.key).inserted {
                let old = oldAssets[asset.key]
                let rebuild = UpdatePlan.Rebuild(asset: asset, old: old, sources: sources)
                if let old, old.hash == asset.hash, FileManager.default.fileSize(job.url(asset.path)) == asset.size {
                    plan.unchanged += 1
                } else if let patchManifest, let patch = patchManifest.patches[asset.key] {
                    plan.patches.append(.init(asset: asset, patch: patch, source: patchManifest.diffDownload,
                                              fallback: rebuild))
                } else {
                    plan.rebuilds.append(rebuild)
                }
            }
        }

        // `UnusedAssets` also lists the originals of files patched in place, so anything still in the new
        // version is kept.
        var removable = oldAssets.mapValues(\.path)
        for path in patchManifests.values.flatMap(\.unused) { removable[path.lowercased()] = path }
        for key in newKeys { removable[key] = nil }
        plan.removals = Array(removable.values)
        return plan
    }

    // MARK: - Pre-download

    /// Fetches the blobs, and stages raw the chunks the installed files can't supply, for the real update.
    private func preDownload(_ plan: UpdatePlan) async throws {
        var staged = Set<String>()
        var stage: [(chunk: SophonChunk, source: SophonDownloadInfo)] = []
        for rebuild in plan.rebuilds {
            let reusable = Set(rebuild.old?.chunks.map(\.md5) ?? [])
            for chunk in rebuild.asset.chunks
            where !reusable.contains(chunk.md5) && staged.insert(chunk.name).inserted {
                stage.append((chunk, rebuild.sources[0]))
            }
        }
        let stageBytes = stage.reduce(0) { $0 + $1.chunk.compressedSize }
        try job.checkSpace(needed: plan.blobBytes + stageBytes)
        tracker.begin(.downloading, totalBytes: plan.blobBytes + stageBytes, totalFiles: plan.blobs.count + stage.count)

        let job = job
        let tracker = tracker
        try await forEachConcurrently(plan.blobs, limit: concurrency.files) { blob in
            _ = try await job.ensureBlob(blob.patch, from: blob.source)
            tracker.add(files: 1)
        }
        try await forEachConcurrently(stage, limit: concurrency.files * concurrency.chunksPerFile) { item in
            try await job.stageChunk(item.chunk, from: item.source)
            tracker.add(files: 1)
        }
    }

    // MARK: - Applying

    private func apply(_ plan: UpdatePlan) async throws {
        let rebuildBytes = plan.rebuilds.reduce(0) { $0 + $1.chunkBytes }
        let fileBytes = (plan.patches.map(\.asset) + plan.rebuilds.map(\.asset)).reduce(0) { $0 + $1.size }
        try job.checkSpace(needed: plan.blobBytes + fileBytes)
        tracker.begin(.downloading, totalBytes: plan.blobBytes + rebuildBytes,
                      totalFiles: plan.patches.count + plan.rebuilds.count)

        let blobURLs = Mutexed([String: URL]())
        let job = job
        try await forEachConcurrently(plan.blobs, limit: concurrency.files) { blob in
            let url = try await job.ensureBlob(blob.patch, from: blob.source)
            blobURLs.withLock { $0[blob.patch.blobName] = url }
        }

        let (patched, failed) = try await applyPatches(plan.patches, blobs: blobURLs.withLock { $0 })

        // Everything else, plus failed patches, by chunk reuse. Each of these only reads its own old file.
        tracker.setPhase(.downloading)
        if !failed.isEmpty {
            let extra = failed.reduce(0) { $0 + $1.chunkBytes }
            tracker.log("Adding \(ByteCountFormatter.string(fromByteCount: extra, countStyle: .file)) "
                + "of downloads for failed patches")
        }
        try await forEachConcurrently(plan.rebuilds + failed, limit: concurrency.files) { rebuild in
            try await job.updateFile(rebuild.asset, old: rebuild.old, sources: rebuild.sources)
        }

        try finalize(plan, patched: patched)
    }

    /// Writes every patched file to its temp name. Nothing is renamed here: one file's original can be another
    /// file's target, so all patches must have read their originals first.
    private func applyPatches(
        _ patches: [UpdatePlan.Patch],
        blobs: [String: URL]
    ) async throws -> (patched: [(temp: URL, final: URL)], failed: [UpdatePlan.Rebuild]) {
        tracker.setPhase(.patching)
        let patched = Mutexed([(temp: URL, final: URL)]())
        let failed = Mutexed([UpdatePlan.Rebuild]())
        let job = job
        let tracker = tracker
        try await forEachConcurrently(patches, limit: max(2, concurrency.files / 2)) { item in
            do {
                guard let blob = blobs[item.patch.blobName] else {
                    throw SophonError.io("missing blob \(item.patch.blobName)")
                }
                let temp = try await job.applyPatch(item.asset, item.patch, blob: blob)
                patched.withLock { $0.append((temp, job.url(item.asset.path))) }
                tracker.add(files: 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                tracker.log("Patch failed for \(item.asset.path) (\(error.localizedDescription)); "
                    + "downloading it instead")
                failed.withLock { $0.append(item.fallback) }
            }
        }
        return (patched.withLock { $0 }, failed.withLock { $0 })
    }

    /// Moves patched files into place, drops what the new version no longer has, and cleans up.
    private func finalize(_ plan: UpdatePlan, patched: [(temp: URL, final: URL)]) throws {
        let fileManager = FileManager.default
        tracker.setPhase(.finalizing)
        for (temp, final) in patched {
            try fileManager.replace(final, with: temp)
        }
        for path in plan.removals {
            let url = job.url(path)
            if fileManager.fileSize(url) != nil {
                try? fileManager.removeItem(at: url)
            }
        }
        for blob in plan.blobs {
            let url = job.patchDirectory.appending(path: blob.patch.blobName)
            try? fileManager.removeItem(at: url)
            try? fileManager.removeItem(at: url.appendingPathExtension("verified"))
        }
        if (try? fileManager.contentsOfDirectory(atPath: job.patchDirectory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: job.patchDirectory)
        }
        try? fileManager.removeItem(at: job.stagingDirectory)
    }
}
