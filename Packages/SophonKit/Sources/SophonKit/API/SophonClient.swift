import Foundation

/// Discovery API client (spec section 2).
public final class SophonClient: Sendable {
    public struct Endpoints: Sendable, Hashable {
        public var launcherAPI: URL
        public var sophonAPI: URL
        public var launcherID: String

        public init(launcherAPI: URL, sophonAPI: URL, launcherID: String) {
            self.launcherAPI = launcherAPI
            self.sophonAPI = sophonAPI
            self.launcherID = launcherID
        }

        /// The global HoYoPlay launcher.
        public static let global = Endpoints(
            launcherAPI: URL(string: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api")!,
            sophonAPI: URL(string: "https://sg-public-api.hoyoverse.com/downloader/sophon_chunk/api")!,
            launcherID: "VYTpXlbWo8"
        )
    }

    public let endpoints: Endpoints
    let http: HTTP

    public init(endpoints: Endpoints = .global, maxConnectionsPerHost: Int = SophonConcurrency.default.connections) {
        self.endpoints = endpoints
        self.http = HTTP(maxConnectionsPerHost: maxConnectionsPerHost)
    }

    /// Display names for the launcher's games.
    public func games(language: String = "en-us") async throws -> [SophonGameInfo] {
        let data: GamesData = try await get(endpoints.launcherAPI, "getGames", [
            "launcher_id": endpoints.launcherID, "language": language,
        ])
        return data.games
    }

    public func gameBranches() async throws -> [SophonGameBranches] {
        let data: GameBranchesData = try await get(endpoints.launcherAPI, "getGameBranches", [
            "launcher_id": endpoints.launcherID,
        ])
        return data.gameBranches
    }

    /// `getBuild` for `branch`. Pass `tag` to request a specific (e.g. the installed, older) version.
    public func build(_ branch: SophonBranch, tag: String? = nil) async throws -> SophonBuild {
        var query = branchQuery(branch)
        if let tag { query["tag"] = tag }
        return try await get(endpoints.sophonAPI, "getBuild", query)
    }

    /// `getPatchBuild` for `branch`. This endpoint is a POST with the parameters in the query string.
    public func patchBuild(_ branch: SophonBranch) async throws -> SophonPatchBuild {
        try await request(endpoints.sophonAPI, "getPatchBuild", branchQuery(branch), method: "POST")
    }

    private func branchQuery(_ branch: SophonBranch) -> [String: String] {
        ["branch": branch.branch, "package_id": branch.packageID, "password": branch.password]
    }

    private func get<T: Decodable>(_ base: URL, _ path: String, _ query: [String: String]) async throws -> T {
        try await request(base, path, query, method: "GET")
    }

    private func request<T: Decodable>(
        _ base: URL,
        _ path: String,
        _ query: [String: String],
        method: String
    ) async throws -> T {
        var url = base.appending(path: path)
        url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        var request = URLRequest(url: url)
        request.httpMethod = method
        let body = try await withRetries(attempts: 3) { try await http.fetch(request) }
        let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: body)
        guard let data = envelope.data else {
            throw SophonError.api(retcode: envelope.retcode, message: envelope.message)
        }
        return data
    }
}
