import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// Thin URLSession wrapper with the library's retry policy (spec section 4): 10 attempts, 1 s apart,
/// 20 s inactivity timeout.
final class HTTP: Sendable {
    static let attempts = 10
    static let retryDelay: Duration = .seconds(1)

    let session: URLSession
    private let transfers = TransferDelegate()

    init(maxConnectionsPerHost: Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20 // inactivity, reset by every received packet
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: transfers, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Fetches `url` once and checks for a 2xx status.
    func fetch(_ request: URLRequest) async throws -> Data {
        let body = Mutexed(Data())
        try await transfer(request) { chunk in body.withLock { $0.append(chunk) } }
        return body.withLock { $0 }
    }

    func fetch(_ url: URL) async throws -> Data {
        try await fetch(URLRequest(url: url))
    }

    /// Downloads `url` to `destination` (replacing it), reporting received bytes as they arrive.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fileManager = FileManager.default
        // Next to the destination, so it lands on the same volume and the final move is a rename.
        let temp = destination.appendingPathExtension("part")
        guard fileManager.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        defer { try? fileManager.removeItem(at: temp) }
        let file = try FileHandle(forWritingTo: temp)
        do {
            try await transfer(URLRequest(url: url)) { chunk in
                try file.write(contentsOf: chunk)
                progress(Int64(chunk.count))
            }
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        try fileManager.replace(destination, with: temp)
    }

    /// Runs `request` as a plain data task, handing each received chunk to `receive`, and throws for a
    /// non-2xx status. Every request goes through here rather than URLSession's async or download-task
    /// conveniences, which behave differently across Foundation implementations (swift-corelibs-foundation
    /// writes a delegate-observed download twice; Apple's never reports its progress).
    private func transfer(_ request: URLRequest, receive: @escaping @Sendable (Data) throws -> Void) async throws {
        let running = Mutexed<URLSessionDataTask?>(nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.dataTask(with: request)
                transfers.start(task, url: request.url!, receive: receive, continuation: continuation)
                running.withLock { $0 = task }
                task.resume()
                // Cancelled before `running` was set: the handler below had nothing to cancel.
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            running.withLock { $0 }?.cancel()
        }
    }

    static func check(_ response: URLResponse, _ url: URL) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SophonError.http(status: http.statusCode, url: url)
        }
    }
}

/// The session delegate: routes each data task's callbacks to the transfer that started it.
private final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct Transfer: Sendable {
        let url: URL
        let receive: @Sendable (Data) throws -> Void
        let continuation: CheckedContinuation<Void, any Error>
        var failure: (any Error)?
    }

    private let transfers = Mutex<[Int: Transfer]>([:])

    func start(
        _ task: URLSessionTask,
        url: URL,
        receive: @escaping @Sendable (Data) throws -> Void,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        let transfer = Transfer(url: url, receive: receive, continuation: continuation)
        transfers.withLock { $0[task.taskIdentifier] = transfer }
    }

    /// Records the first error for `task`, which then reports it instead of the cancellation it causes.
    private func fail(_ task: URLSessionTask, _ error: any Error) {
        transfers.withLock { transfers in
            if transfers[task.taskIdentifier]?.failure == nil { transfers[task.taskIdentifier]?.failure = error }
        }
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let url = transfers.withLock({ $0[dataTask.taskIdentifier]?.url }) else {
            return completionHandler(.cancel)
        }
        do {
            try HTTP.check(response, url)
            completionHandler(.allow)
        } catch {
            fail(dataTask, error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let receive = transfers.withLock({ $0[dataTask.taskIdentifier]?.receive }) else { return }
        do {
            try receive(data)
        } catch {
            fail(dataTask, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = transfers.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = transfer.failure ?? error {
            transfer.continuation.resume(throwing: error)
        } else {
            transfer.continuation.resume()
        }
    }
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
