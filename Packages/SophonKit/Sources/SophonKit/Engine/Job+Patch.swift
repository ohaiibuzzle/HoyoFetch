import Foundation
import HPatch
import Synchronization

// Update by patch (spec 6.B).
extension Job {
    /// Downloads one patch blob into `ldiff/` unless a verified copy is already there.
    func ensureBlob(_ patch: SophonPatchManifest.Patch, from source: SophonDownloadInfo) async throws -> URL {
        let blob = patchDirectory.appending(path: patch.blobName)
        let marker = blob.appendingPathExtension("verified")
        let fileManager = FileManager.default
        let hash = ContentHash(objectName: patch.blobName) ?? ContentHash(patch.blobMD5)

        if fileManager.fileSize(blob) == patch.blobSize,
           fileManager.fileExists(atPath: marker.path) || (try? hash.matches(fileAt: blob)) == true {
            _ = fileManager.createFile(atPath: marker.path, contents: nil)
            tracker.add(completed: patch.blobSize)
            return blob
        }

        try fileManager.createDirectory(at: patchDirectory, withIntermediateDirectories: true)
        let remote = try source.url(for: patch.blobName)
        try await withRetries(onRetry: { attempt, error in
            self.tracker.log("Retrying \(patch.blobName) (\(attempt)): \(error.localizedDescription)")
        }, {
            let received = Atomic<Int64>(0)
            do {
                // Saved as-is: the library does not zstd-decode patch blobs.
                try await http.download(remote, to: blob) { bytes in
                    received.add(bytes, ordering: .relaxed)
                    self.tracker.add(completed: bytes, downloaded: bytes)
                }
                guard fileManager.fileSize(blob) == patch.blobSize, try hash.matches(fileAt: blob) else {
                    try? fileManager.removeItem(at: blob)
                    throw SophonError.integrity("patch blob \(patch.blobName)")
                }
            } catch {
                tracker.add(completed: -received.load(ordering: .relaxed))
                throw error
            }
        })
        _ = fileManager.createFile(atPath: marker.path, contents: nil)
        return blob
    }

    /// Writes the patched file to its temp path and verifies it. The caller renames it into place.
    func applyPatch(_ asset: SophonAsset, _ patch: SophonPatchManifest.Patch, blob: URL) async throws -> URL {
        let final = url(asset.path)
        let temp = Self.suffixed(final, Self.patchSuffix)
        let fileManager = FileManager.default
        let expected = ContentHash(asset.hash)
        try fileManager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileSize(temp) == asset.size, try expected.matches(fileAt: temp) { return temp }
        try? fileManager.removeItem(at: temp)

        let blobFile = try RandomAccessFile(blob, mode: .read)
        guard try blobFile.length() >= patch.offset + patch.length else {
            throw SophonError.integrity("patch slice outside \(patch.blobName)")
        }
        let slice = FileSlice(file: blobFile, offset: patch.offset, length: patch.length)
        let out = try RandomAccessFile(temp, mode: .readWrite)

        if let original = patch.original {
            let source = url(original.path)
            guard fileManager.fileSize(source) == original.size,
                  try ContentHash(original.hash).matches(fileAt: source) else {
                throw SophonError.integrity("original \(original.path) is not the expected version")
            }
            try await HPatch.apply(old: RandomAccessFile(source, mode: .read), diff: slice, output: out)
        } else if try patch.length >= 5 && blobFile.read(at: patch.offset, count: 5) == Data("HDIFF".utf8) {
            // CopyOver quirk: a diff against an empty file.
            try await HPatch.apply(old: nil, diff: slice, output: out)
        } else {
            try out.truncate(to: patch.length)
            var position: Int64 = 0
            try blobFile.read(range: patch.offset..<patch.offset + patch.length) { bytes in
                try out.write(Data(bytes), at: position)
                position += Int64(bytes.count)
            }
        }

        guard try out.length() == asset.size, try expected.matches(file: out) else {
            try? fileManager.removeItem(at: temp)
            throw SophonError.integrity("patched \(asset.path)")
        }
        return temp
    }
}
