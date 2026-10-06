import Foundation

/// Thin URLSession wrapper with the library's retry policy (spec section 4): 10 attempts, 1 s apart,
/// 20 s inactivity timeout.
final class HTTP: Sendable {
    static let attempts = 10
    static let retryDelay: Duration = .seconds(1)

    let session: URLSession

    init(maxConnectionsPerHost: Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20 // inactivity, reset by every received packet
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Fetches `url` once and checks for a 2xx status.
    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.check(response, request.url!)
        return data
    }

    func fetch(_ url: URL) async throws -> Data {
        try await fetch(URLRequest(url: url))
    }

    /// Downloads `url` to `destination` (replacing it), reporting received bytes as they arrive.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (temp, response) = try await session.download(from: url, delegate: DownloadProgressDelegate(progress))
        defer { try? FileManager.default.removeItem(at: temp) }
        try Self.check(response, url)
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    static func check(_ response: URLResponse, _ url: URL) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SophonError.http(status: http.statusCode, url: url)
        }
    }
}

/// Forwards byte-count deltas from a download task.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void

    init(_ progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(bytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

/// Runs `body` up to `attempts` times, waiting `delay` between tries. Cancellation is never retried.
func withRetries<T>(
    attempts: Int = HTTP.attempts,
    delay: Duration = HTTP.retryDelay,
    onRetry: (Int, any Error) -> Void = { _, _ in },
    _ body: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await body()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            guard attempt < attempts else { throw error }
            onRetry(attempt, error)
            attempt += 1
            try await Task.sleep(for: delay)
        }
    }
}
