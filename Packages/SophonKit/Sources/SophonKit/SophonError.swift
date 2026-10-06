import Foundation

public enum SophonError: Error, Sendable, CustomStringConvertible {
    /// The API returned `data: null`.
    case api(retcode: Int, message: String)
    case http(status: Int, url: URL)
    case badResponse(String)
    /// A downloaded object didn't match its expected hash or size.
    case integrity(String)
    case decompression(String)
    /// `encryption: 1` in a download descriptor; nothing in the protocol notes covers it.
    case encryptedDownload(String)
    case unsafePath(String)
    case missingMatchingField(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case notInstalled
    case nothingToDo(String)
    case io(String)

    public var description: String {
        switch self {
        case .api(let retcode, let message): "API error \(retcode): \(message)"
        case .http(let status, let url): "HTTP \(status) for \(url.absoluteString)"
        case .badResponse(let detail): "Unexpected response: \(detail)"
        case .integrity(let detail): "Integrity check failed: \(detail)"
        case .decompression(let detail): "Decompression failed: \(detail)"
        case .encryptedDownload(let detail): "Encrypted downloads are not supported (\(detail))"
        case .unsafePath(let detail): "Refusing unsafe path from manifest: \(detail)"
        case .missingMatchingField(let detail): "The build has no manifest for \"\(detail)\""
        case .insufficientSpace(let needed, let available):
            "Not enough disk space: need \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), "
                + "have \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
        case .notInstalled: "No installation found in this folder"
        case .nothingToDo(let detail): detail
        case .io(let detail): detail
        }
    }
}

extension SophonError: LocalizedError {
    public var errorDescription: String? { description }
}
