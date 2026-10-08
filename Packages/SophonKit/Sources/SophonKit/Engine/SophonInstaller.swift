import Foundation

/// Installs, repairs and updates a game folder with the Sophon protocol.
///
/// All operations are resumable: re-running after an interruption or a failure picks up where it stopped.
/// Cancel the calling task to stop.
public final class SophonInstaller: Sendable {
    public let client: SophonClient
    public let concurrency: SophonConcurrency

    /// Test hook: restricts every manifest to the paths it accepts (lowercased).
    let assetFilter: (@Sendable (String) -> Bool)?

    public convenience init(client: SophonClient? = nil, concurrency: SophonConcurrency = .default) {
        self.init(client: client, concurrency: concurrency, assetFilter: nil)
    }

    init(client: SophonClient?, concurrency: SophonConcurrency, assetFilter: (@Sendable (String) -> Bool)?) {
        self.client = client ?? SophonClient(maxConnectionsPerHost: concurrency.connections)
        self.concurrency = concurrency
        self.assetFilter = assetFilter
    }

    /// The default selection (spec 2.3): the base game plus one voice language, if the game has voice packs.
    public static func defaultMatchingFields(for branch: SophonBranch, voice: String = "en-us") -> [String] {
        let fields = branch.categories.map(\.matchingField)
        return ["game"] + (fields.contains(voice) ? [voice] : [])
    }

    /// Fresh install (spec section 5). Also resumes an interrupted install.
    public func install(
        _ game: SophonGameBranches,
        matchingFields: [String],
        into root: URL,
        events: @escaping @Sendable (SophonEvent) -> Void = { _ in }
    ) async throws {
        let job = makeJob(root, events)
        let build = try await client.build(game.main)
        job.tracker.log("Installing \(game.game.biz) \(build.tag)")
        let (manifests, fields) = try await loadManifests(build, fields: matchingFields, job: job)
        try await job.installAll(manifests)
        try finish(job, SophonInstallState(gameID: game.id, biz: game.game.biz, tag: build.tag, matchingFields: fields))
    }

    /// Verifies every file of the installed version and re-downloads what is missing or damaged.
    /// Optionally adds or keeps `matchingFields` (defaults to what is installed).
    public func repair(
        _ game: SophonGameBranches,
        in root: URL,
        matchingFields: [String]? = nil,
        events: @escaping @Sendable (SophonEvent) -> Void = { _ in }
    ) async throws {
        var state = try installedState(game, root)
        let job = makeJob(root, events)
        let build = try await client.build(game.main, tag: state.tag)
        job.tracker.log("Verifying \(game.game.biz) \(build.tag)")
        let wanted = matchingFields ?? state.matchingFields
        let (manifests, fields) = try await loadManifests(build, fields: wanted, job: job)
        try await job.installAll(manifests)
        state.matchingFields = fields
        try finish(job, state)
    }

    /// Updates the installed version to the live one (spec section 6). Uses a patch build where one exists for the
    /// installed version and `usePatches` is set, and chunk reuse for everything else. `matchingFields` (defaults to
    /// what is installed) can add packages, which are downloaded, or drop them, which deletes their files.
    public func update(
        _ game: SophonGameBranches,
        in root: URL,
        matchingFields: [String]? = nil,
        usePatches: Bool = true,
        events: @escaping @Sendable (SophonEvent) -> Void = { _ in }
    ) async throws {
        var state = try installedState(game, root)
        guard state.tag != game.main.tag else { throw SophonError.nothingToDo("Already up to date (\(state.tag))") }
        let job = makeJob(root, events)
        job.tracker.log("Updating \(game.game.biz) \(state.tag) → \(game.main.tag)")
        let updater = Updater(installer: self, job: job, state: state, fields: matchingFields ?? state.matchingFields,
                              current: game.main, target: game.main, usePatches: usePatches)
        state.matchingFields = try await updater.run(preDownloadOnly: false)
        state.tag = game.main.tag
        state.preDownloadedTag = nil
        try finish(job, state)
    }

    /// Downloads the next version's update data ahead of release. Once it is live, run
    /// ``update(_:in:matchingFields:usePatches:events:)`` with the same `matchingFields`.
    public func preDownload(
        _ game: SophonGameBranches,
        in root: URL,
        matchingFields: [String]? = nil,
        usePatches: Bool = true,
        events: @escaping @Sendable (SophonEvent) -> Void = { _ in }
    ) async throws {
        var state = try installedState(game, root)
        guard let next = game.preDownload else { throw SophonError.nothingToDo("No pre-download is available") }
        guard state.tag != next.tag else { throw SophonError.nothingToDo("Already on \(next.tag)") }
        let job = makeJob(root, events)
        job.tracker.log("Pre-downloading \(game.game.biz) \(state.tag) → \(next.tag)")
        let updater = Updater(installer: self, job: job, state: state, fields: matchingFields ?? state.matchingFields,
                              current: game.main, target: next, usePatches: usePatches)
        _ = try await updater.run(preDownloadOnly: true)
        state.preDownloadedTag = next.tag
        try finish(job, state)
    }

    // MARK: - Internals

    func manifest(_ entry: SophonBuildManifest) async throws -> SophonManifest {
        try await client.manifest(entry).filtered(assetFilter)
    }

    private func makeJob(_ root: URL, _ events: @escaping @Sendable (SophonEvent) -> Void) -> Job {
        Job(root: root, client: client, concurrency: concurrency, tracker: ProgressTracker(events))
    }

    private func installedState(_ game: SophonGameBranches, _ root: URL) throws -> SophonInstallState {
        guard let state = SophonInstallState.load(from: root) else { throw SophonError.notInstalled }
        guard state.gameID == game.id else {
            throw SophonError.io("This folder holds \(state.biz) (\(state.gameID)), not \(game.game.biz) (\(game.id))")
        }
        return state
    }

    private func finish(_ job: Job, _ state: SophonInstallState) throws {
        try state.save(to: job.root)
        job.tracker.setPhase(.done)
        job.tracker.log("Done: \(state.biz) \(state.tag)")
    }

    /// Picks manifests by matching field (spec 2.3). `game` is required; other missing fields are skipped with a
    /// warning.
    func loadManifests(
        _ build: SophonBuild,
        fields: [String],
        job: Job
    ) async throws -> (manifests: [SophonManifest], fields: [String]) {
        var wanted = fields
        if !wanted.contains("game") { wanted.insert("game", at: 0) }
        var manifests: [SophonManifest] = []
        for field in wanted {
            guard let entry = build.manifest(for: field) else {
                if field == "game" { throw SophonError.missingMatchingField(field) }
                job.tracker.log("Warning: \(build.tag) has no \"\(field)\" package, skipping it")
                continue
            }
            job.tracker.log("Fetching manifest for \(field)")
            manifests.append(try await manifest(entry))
        }
        return (manifests, manifests.map(\.matchingField))
    }
}
