import Foundation
import Synchronization

/// Parallelism limits. Defaults follow Collapse (spec section 4).
public struct SophonConcurrency: Sendable, Hashable {
    public var files: Int
    public var chunksPerFile: Int
    public var connections: Int

    public init(files: Int, chunksPerFile: Int, connections: Int) {
        self.files = files
        self.chunksPerFile = chunksPerFile
        self.connections = connections
    }

    public static var `default`: SophonConcurrency {
        let root = Double(ProcessInfo.processInfo.activeProcessorCount).squareRoot()
        let files = min(max(Int(root.rounded()), 2), 64)
        return SophonConcurrency(
            files: files,
            chunksPerFile: min(max(files / 2, 2), 32),
            connections: min(max(Int((2 * root).rounded()), 4), 128)
        )
    }
}

public enum SophonPhase: String, Sendable {
    case preparing = "Preparing"
    case downloading = "Downloading"
    case patching = "Patching"
    case finalizing = "Finalizing"
    case done = "Done"
}

public struct SophonProgress: Sendable, Hashable {
    public var phase: SophonPhase = .preparing
    /// Work in compressed bytes; chunks count whether they are downloaded, reused or already present.
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    /// Bytes actually received from the network (for speed display).
    public var downloadedBytes: Int64 = 0
    public var totalFiles: Int = 0
    public var completedFiles: Int = 0

    public init() {}

    init(phase: SophonPhase, totalBytes: Int64, downloadedBytes: Int64, totalFiles: Int) {
        self.phase = phase
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.totalFiles = totalFiles
    }

    public var fraction: Double {
        totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : (phase == .done ? 1 : 0)
    }
}

public enum SophonEvent: Sendable {
    case progress(SophonProgress)
    case log(String)
}

/// Aggregates progress from concurrent workers and forwards it, throttled, to the caller's handler.
final class ProgressTracker: Sendable {
    private struct State {
        var progress = SophonProgress()
        var lastEmit = ContinuousClock.now - .seconds(1)
    }

    private let state = Mutex(State())
    private let handler: @Sendable (SophonEvent) -> Void

    init(_ handler: @escaping @Sendable (SophonEvent) -> Void) {
        self.handler = handler
    }

    func log(_ message: String) {
        handler(.log(message))
    }

    func begin(_ phase: SophonPhase, totalBytes: Int64, totalFiles: Int) {
        update(force: true) {
            $0 = SophonProgress(
                phase: phase, totalBytes: totalBytes, downloadedBytes: $0.downloadedBytes, totalFiles: totalFiles
            )
        }
    }

    func setPhase(_ phase: SophonPhase) {
        update(force: true) { $0.phase = phase }
    }

    func add(completed: Int64 = 0, downloaded: Int64 = 0, files: Int = 0) {
        update(force: false) {
            $0.completedBytes += completed
            $0.downloadedBytes += downloaded
            $0.completedFiles += files
        }
    }

    var snapshot: SophonProgress { state.withLock { $0.progress } }

    private func update(force: Bool, _ body: (inout SophonProgress) -> Void) {
        let emit: SophonProgress? = state.withLock { state in
            body(&state.progress)
            let now = ContinuousClock.now
            guard force || now - state.lastEmit >= .milliseconds(100) else { return nil }
            state.lastEmit = now
            return state.progress
        }
        if let emit { handler(.progress(emit)) }
    }
}

/// What is installed in a folder; written after every successful operation. Needed for updates (spec 5, step 7).
public struct SophonInstallState: Codable, Sendable, Hashable {
    public var gameID: String
    public var biz: String
    public var tag: String
    public var matchingFields: [String]
    /// Version whose update data was pre-downloaded, if any.
    public var preDownloadedTag: String?

    public init(gameID: String, biz: String, tag: String, matchingFields: [String], preDownloadedTag: String? = nil) {
        self.gameID = gameID
        self.biz = biz
        self.tag = tag
        self.matchingFields = matchingFields
        self.preDownloadedTag = preDownloadedTag
    }

    static let directoryName = ".sophon"

    static func fileURL(in root: URL) -> URL {
        root.appending(path: directoryName).appending(path: "state.json")
    }

    public static func load(from root: URL) -> SophonInstallState? {
        guard let data = try? Data(contentsOf: fileURL(in: root)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to root: URL) throws {
        let url = Self.fileURL(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Runs `body` for every element with at most `limit` running at once. The first error cancels the rest.
func forEachConcurrently<S: Sequence>(
    _ items: S,
    limit: Int,
    _ body: @escaping @Sendable (S.Element) async throws -> Void
) async throws where S.Element: Sendable {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var running = 0
        for item in items {
            if running >= limit {
                try await group.next()
                running -= 1
            }
            try Task.checkCancellation()
            group.addTask { try await body(item) }
            running += 1
        }
        try await group.waitForAll()
    }
}

func availableCapacity(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
}

/// A Mutex in a class, so task-group children can share it.
final class Mutexed<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = .init(value)
    }

    func withLock<Result: Sendable>(_ body: (inout sending Value) throws -> sending Result) rethrows -> Result {
        try mutex.withLock(body)
    }
}
