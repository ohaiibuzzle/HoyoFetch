import Foundation

// Clearing what updates leave behind.
extension Job {
    /// Clears what a finished update leaves behind: staged chunks, our patch blobs and orphaned temp files.
    func cleanUpUpdateLeftovers() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: stagingDirectory.path) { remove(stagingDirectory) }

        // `ldiff/` is shared with HoYoPlay and Collapse, so only blobs carrying our `.verified` marker go.
        if let names = try? fileManager.contentsOfDirectory(atPath: patchDirectory.path) {
            for name in names where name.hasSuffix(".verified") {
                let marker = patchDirectory.appending(path: name)
                let blob = marker.deletingPathExtension()
                if fileManager.fileExists(atPath: blob.path) { remove(blob) }
                remove(marker)
            }
            if (try? fileManager.contentsOfDirectory(atPath: patchDirectory.path))?.isEmpty == true {
                remove(patchDirectory)
            }
        }

        let suffixes = [Self.installSuffix, Self.updateSuffix, Self.patchSuffix]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                options: [.skipsPackageDescendants])
        var swept = 0
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == SophonInstallState.directoryName {
                enumerator?.skipDescendants()
                continue
            }
            guard suffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if remove(url) { swept += 1 }
        }
        if swept > 0 { tracker.log("Removed \(swept) leftover temp files") }
    }

    /// Removes empty folders from `url`'s parent upward, stopping at the first non-empty one or the root.
    func pruneEmptyParents(of url: URL) {
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.path + "/"
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(rootPath),
              (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true,
              remove(directory) {
            directory = directory.deletingLastPathComponent()
        }
    }

    /// Deletes `url`, logging rather than throwing on failure.
    @discardableResult
    func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            tracker.log("Could not remove \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}
