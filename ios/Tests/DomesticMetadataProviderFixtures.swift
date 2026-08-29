import Foundation

enum DomesticMetadataProviderSelfTest {
    static func run() async throws {
        try verifyDifferentArtistIsRejected()
        try await verifyNetEaseProvider()
        try await verifyQQMusicProvider()
        try await DomesticTrackFallbackSelfTest.run()
    }

    private static func verifyDifferentArtistIsRejected() throws {
        let anchor = makeAnchor()
        let score = DomesticMetadataScorer.score(
            candidateAlbum: "Anchor Album",
            candidateArtist: "Unrelated Artist",
            candidateDate: "2024-01-01",
            candidateDurationsMilliseconds: [100_000, 120_000],
            anchor: anchor,
            resultIndex: 0
        )
        guard !score.passedStructuralThreshold, !score.isConfident else {
            throw DomesticMetadataFixtureError.assertion(
                "An exact-title same-year album by a different artist passed the confidence gate."
            )
        }
    }

    static func makeAnchor() -> DomesticAlbumAnchor {
        DomesticAlbumAnchor(
            albumAliases: ["Anchor Album"],
            artist: "Anchor Artist",
            year: "2024",
            discNumber: 1,
            tracks: [
                DomesticTrackAnchor(
                    position: 1,
                    titleAliases: ["First Song"],
                    artist: "Anchor Artist",
                    durationMilliseconds: 100_000
                ),
                DomesticTrackAnchor(
                    position: 2,
                    titleAliases: ["Second Song"],
                    artist: "Anchor Artist",
                    durationMilliseconds: 120_000
                ),
            ]
        )
    }

    private static func verifyNetEaseProvider() async throws {
        let cacheRoot = temporaryCacheRoot("netease-album")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = DomesticMetadataFixtureTransport(routes: [
            .init(
                host: "music.163.com",
                path: "/api/search/get",
                requiredQueryItems: ["type": "10"],
                responses: [
                    .init(data: Data(), statusCode: 503, headers: ["Retry-After": "0"]),
                    .json(netEaseSearchJSON),
                ]
            ),
            .init(
                host: "music.163.com",
                path: "/api/v1/album/12345",
                responses: [.json(netEaseAlbumJSON)]
            ),
        ])
        let provider = NetEaseMetadataProvider(
            transport: transport,
            appVersion: "test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: LyricsCache(root: cacheRoot, lifetime: LyricsCache.onlineContentLifetime)
        )
        let candidates = try await provider.searchCandidates(anchor: makeAnchor())
        guard let match = candidates.first else {
            throw DomesticMetadataFixtureError.assertion("NetEase fixture did not produce a candidate.")
        }
        try verifyCommonMatch(match, source: .netEase)
        guard match.albumIdentifier == "12345",
              match.coverURL?.absoluteString == "https://img.example/netease.jpg",
              match.tracks.map(\.identifier) == ["1001", "1002"],
              match.genres == ["Electronic", "Techno"] else {
            throw DomesticMetadataFixtureError.assertion("NetEase fields were not decoded as expected.")
        }
        let requests = await transport.recordedRequests()
        guard requests.filter({ $0.path == "/api/search/get" }).count == 2 else {
            throw DomesticMetadataFixtureError.assertion("NetEase transient HTTP retry was not exercised.")
        }
        try verifyCodableRoundTrip(match)
    }

    private static func verifyQQMusicProvider() async throws {
        let cacheRoot = temporaryCacheRoot("qq-album")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = DomesticMetadataFixtureTransport(routes: [
            .init(
                host: "c.y.qq.com",
                path: "/soso/fcgi-bin/client_search_cp",
                requiredQueryItems: ["t": "8"],
                responses: [.json(qqMusicSearchJSON)]
            ),
            .init(
                host: "c.y.qq.com",
                path: "/v8/fcg-bin/fcg_v8_album_info_cp.fcg",
                requiredQueryItems: ["albummid": "qq-mid"],
                responses: [.json(qqMusicAlbumJSON)]
            ),
        ])
        let provider = QQMusicMetadataProvider(
            transport: transport,
            appVersion: "test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: LyricsCache(root: cacheRoot, lifetime: LyricsCache.onlineContentLifetime)
        )
        let candidates = try await provider.searchCandidates(anchor: makeAnchor())
        guard let match = candidates.first else {
            throw DomesticMetadataFixtureError.assertion("QQ Music fixture did not produce a candidate.")
        }
        try verifyCommonMatch(match, source: .qqMusic)
        guard match.albumIdentifier == "qq-mid",
              match.numericAlbumIdentifier == "678",
              match.coverURL?.absoluteString == "https://y.gtimg.cn/music/photo_new/T002R1200x1200M000qq-mid.jpg",
              match.tracks.map(\.identifier) == ["song-mid-1", "song-mid-2"],
              match.genres == ["Techno"] else {
            throw DomesticMetadataFixtureError.assertion("QQ Music fields were not decoded as expected.")
        }
        try verifyCodableRoundTrip(match)
    }

    private static func verifyCommonMatch(
        _ match: DomesticAlbumMetadataMatch,
        source: DomesticMetadataSource
    ) throws {
        guard match.source == source,
              match.title == "Anchor Album",
              match.artist == "Anchor Artist",
              match.year == "2024",
              match.tracks.map(\.title) == ["First Song", "Second Song"],
              match.score.baseScore == 120,
              match.score.durationScore == 130,
              match.score.totalScore == 250,
              match.score.durationMatches == 2,
              match.score.nearExactDurationMatches == 2,
              match.score.isConfident else {
            throw DomesticMetadataFixtureError.assertion("\(source.rawValue) score or canonical metadata differed from the desktop rules.")
        }
    }

    private static func verifyCodableRoundTrip(_ match: DomesticAlbumMetadataMatch) throws {
        let encoded = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(DomesticAlbumMetadataMatch.self, from: encoded)
        guard decoded == match else {
            throw DomesticMetadataFixtureError.assertion("Domestic metadata model Codable round trip failed.")
        }
    }

    private static func temporaryCacheRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "cdrom-ios-\(label)-cache-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static let netEaseSearchJSON = #"""
    {"code":200,"result":{"albums":[{"id":12345}]}}
    """#

    private static let netEaseAlbumJSON = #"""
    {
      "code":200,
      "album":{
        "name":"Anchor Album",
        "publishTime":1704067200000,
        "picUrl":"https://img.example/netease.jpg",
        "tags":"Electronic; Techno",
        "artists":[{"name":"Anchor Artist"}],
        "songs":[
          {"id":1001,"name":"First Song","duration":100000,"no":1,"disc":1,"artists":[{"name":"Anchor Artist"}]},
          {"id":1002,"name":"Second Song","duration":120000,"no":2,"disc":1,"artists":[{"name":"Anchor Artist"}]}
        ]
      }
    }
    """#

    private static let qqMusicSearchJSON = #"""
    {
      "code":0,
      "data":{"album":{"list":[
        {"albumMID":"qq-mid","albumID":678,"albumName":"Anchor Album","publicTime":"2024-01-01","singer":[{"name":"Anchor Artist"}]}
      ]}}
    }
    """#

    private static let qqMusicAlbumJSON = #"""
    {
      "code":0,
      "data":{
        "name":"Anchor Album",
        "aDate":"2024-01-01",
        "genre":"Techno",
        "singer":[{"name":"Anchor Artist"}],
        "list":[
          {"songmid":"song-mid-1","songid":2001,"songname":"First Song","interval":100,"cdIdx":0,"singer":[{"name":"Anchor Artist"}]},
          {"songmid":"song-mid-2","songid":2002,"songname":"Second Song","interval":120,"cdIdx":0,"singer":[{"name":"Anchor Artist"}]}
        ]
      }
    }
    """#
}

actor DomesticMetadataFixtureTransport: DomesticMetadataTransport {
    struct Route: Sendable {
        let host: String
        let path: String
        let requiredQueryItems: [String: String]
        let responses: [DomesticMetadataHTTPResponse]

        init(
            host: String,
            path: String,
            requiredQueryItems: [String: String] = [:],
            responses: [DomesticMetadataHTTPResponse]
        ) {
            self.host = host
            self.path = path
            self.requiredQueryItems = requiredQueryItems
            self.responses = responses
        }
    }

    struct RecordedRequest: Codable, Hashable, Sendable {
        let method: String
        let host: String
        let path: String
        let queryItems: [String: String]
    }

    private let routes: [Route]
    private var responseOffsets: [Int: Int] = [:]
    private var requests: [RecordedRequest] = []

    init(routes: [Route]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> DomesticMetadataHTTPResponse {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw DomesticMetadataFixtureError.unmatchedRequest("invalid URL")
        }
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })
        requests.append(RecordedRequest(
            method: request.httpMethod ?? "GET",
            host: host,
            path: components.path,
            queryItems: query
        ))

        guard let routeIndex = routes.indices.first(where: { index in
            let route = routes[index]
            return route.host == host
                && route.path == components.path
                && route.requiredQueryItems.allSatisfy { query[$0.key] == $0.value }
        }) else {
            throw DomesticMetadataFixtureError.unmatchedRequest("\(host)\(components.path)")
        }
        let route = routes[routeIndex]
        guard !route.responses.isEmpty else {
            throw DomesticMetadataFixtureError.unmatchedRequest("empty response fixture")
        }
        let offset = responseOffsets[routeIndex, default: 0]
        responseOffsets[routeIndex] = offset + 1
        return route.responses[min(offset, route.responses.count - 1)]
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }
}

private enum DomesticMetadataFixtureError: LocalizedError, Sendable {
    case assertion(String)
    case unmatchedRequest(String)

    var errorDescription: String? {
        switch self {
        case .assertion(let message): return message
        case .unmatchedRequest(let route): return "No domestic metadata fixture matched \(route)."
        }
    }
}

private extension DomesticMetadataHTTPResponse {
    static func json(_ text: String, statusCode: Int = 200) -> DomesticMetadataHTTPResponse {
        DomesticMetadataHTTPResponse(
            data: Data(text.utf8),
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"]
        )
    }
}
