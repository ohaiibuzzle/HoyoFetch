import Foundation
import Observation
import SophonKit

struct GameRow: Identifiable, Hashable {
    let branches: SophonGameBranches
    let name: String
    let subtitle: String
    var id: String { branches.id }
}

enum OperationKind: String {
    case install = "Install"
    case update = "Update"
    case preDownload = "Pre-download"
    case repair = "Verify & Repair"
}

@Observable
final class OperationState {
    let gameID: String
    let kind: OperationKind
    var progress = SophonProgress()
    var log: [String] = []
    var error: String?
    var finished = false
    /// Bytes per second over the last few seconds.
    var speed: Double = 0
    fileprivate var samples: [(time: Date, bytes: Int64)] = []
    fileprivate var task: Task<Void, Never>?

    init(gameID: String, kind: OperationKind) {
        self.gameID = gameID
        self.kind = kind
    }

    var isRunning: Bool { !finished }
}

@Observable
final class AppModel {
    var games: [GameRow] = []
    var loadError: String?
    var isLoading = false
    var selection: String?
    /// The last operation per game, kept so its log stays visible after it ends.
    var operations: [String: OperationState] = [:]
    var builds: [String: SophonBuild] = [:]
    var buildErrors: [String: String] = [:]
    var folders: [String: URL] = [:]
    var installStates: [String: SophonInstallState] = [:]
    var usePatches = true

    @ObservationIgnored private let client: SophonClient
    @ObservationIgnored private let installer: SophonInstaller

    init() {
        installer = SophonInstaller()
        client = installer.client
    }

    var isBusy: Bool { operations.values.contains { $0.isRunning } }

    func game(_ id: String?) -> GameRow? { games.first { $0.id == id } }

    // MARK: - Loading

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let branchesRequest = client.gameBranches()
            let names = Dictionary((try? await client.games()).map { $0.map { ($0.id, $0.name ?? $0.biz) } } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            let branches = try await branchesRequest
            let namesByBiz = Dictionary(names.compactMap { id, name in
                branches.first { $0.id == id }.map { ($0.game.biz, name) }
            }, uniquingKeysWith: { first, _ in first })
            games = branches.map { entry in
                let shared = branches.filter { $0.game.biz == entry.game.biz }.count > 1
                let name = names[entry.id] ?? namesByBiz[entry.game.biz] ?? entry.game.biz
                let subtitle = shared ? "\(entry.game.biz) · \(entry.id)" : entry.game.biz
                return GameRow(branches: entry, name: name, subtitle: subtitle)
            }
            loadError = nil
            builds = [:]
            for game in games { restoreFolder(game.id) }
            if selection == nil { selection = games.first?.id }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadBuild(_ id: String) async {
        guard builds[id] == nil, let game = game(id) else { return }
        do {
            builds[id] = try await client.build(game.branches.main)
            buildErrors[id] = nil
        } catch {
            buildErrors[id] = error.localizedDescription
        }
    }

    // MARK: - Folders (security-scoped bookmarks, so access survives relaunches)

    func setFolder(_ url: URL, for id: String) {
        folders[id]?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        folders[id] = url
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: "folder.\(id)")
        }
        reloadInstallState(id)
    }

    private func restoreFolder(_ id: String) {
        guard folders[id] == nil, let data = UserDefaults.standard.data(forKey: "folder.\(id)") else { return }
        var stale = false
        let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        guard let url = resolved else { return }
        _ = url.startAccessingSecurityScopedResource()
        folders[id] = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(fresh, forKey: "folder.\(id)")
        }
        reloadInstallState(id)
    }

    func reloadInstallState(_ id: String) {
        installStates[id] = folders[id].flatMap { SophonInstallState.load(from: $0) }
    }

    // MARK: - Operations

    func start(_ kind: OperationKind, game: GameRow, matchingFields: [String]) {
        guard !isBusy, let folder = folders[game.id] else { return }
        let operation = OperationState(gameID: game.id, kind: kind)
        operations[game.id] = operation

        let (events, continuation) = AsyncStream<SophonEvent>.makeStream()
        let installer = installer
        let usePatches = usePatches
        let branches = game.branches
        let handler: @Sendable (SophonEvent) -> Void = { continuation.yield($0) }

        let work = Task.detached {
            defer { continuation.finish() }
            switch kind {
            case .install:
                try await installer.install(branches, matchingFields: matchingFields, into: folder, events: handler)
            case .update:
                try await installer.update(branches, in: folder, matchingFields: matchingFields,
                                             usePatches: usePatches, events: handler)
            case .preDownload:
                try await installer.preDownload(branches, in: folder, matchingFields: matchingFields,
                                                  usePatches: usePatches, events: handler)
            case .repair:
                try await installer.repair(branches, in: folder, matchingFields: matchingFields, events: handler)
            }
        }

        operation.task = Task {
            await withTaskCancellationHandler {
                for await event in events { self.handle(event, operation) }
                do {
                    try await work.value
                } catch is CancellationError {
                    operation.error = "Cancelled"
                } catch {
                    operation.error = error.localizedDescription
                }
            } onCancel: {
                work.cancel()
            }
            if let error = operation.error { operation.log.append("Error: \(error)") }
            operation.finished = true
            reloadInstallState(game.id)
        }
    }

    func cancel(_ id: String) {
        operations[id]?.task?.cancel()
    }

    private func handle(_ event: SophonEvent, _ operation: OperationState) {
        switch event {
        case .log(let line):
            operation.log.append(line)
            if operation.log.count > 500 { operation.log.removeFirst(operation.log.count - 500) }
        case .progress(let progress):
            operation.progress = progress
            let now = Date()
            operation.samples.append((now, progress.downloadedBytes))
            operation.samples.removeAll { now.timeIntervalSince($0.time) > 5 }
            if let first = operation.samples.first, let last = operation.samples.last, last.time > first.time {
                operation.speed = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
            }
        }
    }
}
