import Foundation
import Testing
@testable import SophonKit

struct CleanupTests {
    private let fileManager = FileManager.default

    private func makeJob() throws -> Job {
        let root = fileManager.temporaryDirectory.appending(path: "SophonCleanup-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return Job(root: root, client: SophonClient(), concurrency: .default, tracker: ProgressTracker { _ in })
    }

    private func touch(_ url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: url.path, contents: Data("x".utf8))
    }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    @Test func removesOnlyOurLeftovers() throws {
        let job = try makeJob()
        defer { try? fileManager.removeItem(at: job.root) }
        let ldiff = job.patchDirectory
        let marked = ldiff.appending(path: "marked")
        let foreign = ldiff.appending(path: "foreign")
        let stray = ldiff.appending(path: "gone.verified")
        let temp = job.root.appending(path: "a/b/file" + Job.updateSuffix)
        let keep = job.root.appending(path: "a/b/file")
        let state = SophonInstallState.fileURL(in: job.root)
        let stateTemp = job.root.appending(path: SophonInstallState.directoryName + "/x" + Job.patchSuffix)
        for url in [marked, marked.appendingPathExtension("verified"), foreign, stray, temp, keep, state, stateTemp,
                    job.stagingDirectory.appending(path: "chunk")] {
            try touch(url)
        }

        job.cleanUpUpdateLeftovers()

        #expect(!exists(marked))
        #expect(!exists(marked.appendingPathExtension("verified")))
        #expect(!exists(stray))
        #expect(exists(foreign))
        #expect(!exists(job.stagingDirectory))
        #expect(!exists(temp))
        #expect(exists(keep))
        #expect(exists(state))
        #expect(exists(stateTemp))
    }

    @Test func removesEmptyLdiff() throws {
        let job = try makeJob()
        defer { try? fileManager.removeItem(at: job.root) }
        let blob = job.patchDirectory.appending(path: "blob")
        try touch(blob)
        try touch(blob.appendingPathExtension("verified"))

        job.cleanUpUpdateLeftovers()

        #expect(!exists(job.patchDirectory))
    }

    @Test func prunesEmptyParentsUpToRoot() throws {
        let job = try makeJob()
        defer { try? fileManager.removeItem(at: job.root) }
        let file = job.url("x/y/z.bin")
        try touch(file)
        try fileManager.removeItem(at: file)

        job.pruneEmptyParents(of: file)

        #expect(!exists(job.root.appending(path: "x")))
        #expect(exists(job.root))
    }

    @Test func pruningStopsAtNonEmptyFolder() throws {
        let job = try makeJob()
        defer { try? fileManager.removeItem(at: job.root) }
        let file = job.url("x/y/z.bin")
        let sibling = job.url("x/sibling.bin")
        try touch(file)
        try touch(sibling)
        try fileManager.removeItem(at: file)

        job.pruneEmptyParents(of: file)

        #expect(!exists(job.root.appending(path: "x/y")))
        #expect(exists(sibling))
    }
}
