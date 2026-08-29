import Foundation

enum DomesticTrackFallbackSelfTest {
    static func run() async throws {
        try verifyStrictMatcher()
        try await verifyNetEaseTrackSearch()
        try await verifyQQMusicTrackSearch()
        try await verifyEnrichmentIntegration()
        try await verifyWholeAlbumMatchSkipsTrackFallback()
    }

    private static let anchor = DomesticTrackFallbackAnchor(
        position: 1,
        titleAliases: ["First Song"],
        artist: "Anchor Artist",
        albumAliases: ["Anchor Album"],
        durationMilliseconds: 100_000
    )

    private static func verifyStrictMatcher() throws {
        let accepted = DomesticTrackFallbackMatcher.match(
            candidate: candidate(title: "First Songs", album: "Anchor Album", duration: 102_999),
            anchor: anchor
        )
        guard let accepted,
              accepted.titleScore >= 85,
              accepted.titleScore < 95,
              accepted.albumIsExact,
              accepted.durationDeltaMilliseconds == 2_999 else {
            throw DomesticTrackFallbackFixtureError.assertion(
                "A strong but sub-95 title should require and accept an exact album plus <=3 s duration."
            )
        }

        guard DomesticTrackFallbackMatcher.match(
            candidate: candidate(title: "First Songs", album: "Anchor Albu"),
            anchor: anchor
        ) == nil else {
            throw DomesticTrackFallbackFixtureError.assertion(
                "A sub-95 title was incorrectly accepted with a merely fuzzy album."
            )
        }
        guard DomesticTrackFallbackMatcher.match(
            candidate: candidate(title: "First Song (Live)"),
            anchor: anchor
        ) == nil else {
            throw DomesticTrackFallbackFixtureError.assertion("Live edition conflict was not rejected.")
        }
        guard DomesticTrackFallbackMatcher.match(
            candidate: candidate(title: "First Song (Remix)"),
            anchor: anchor
        ) == nil else {
            throw DomesticTrackFallbackFixtureError.assertion("Remix edition conflict was not rejected.")
        }
        guard DomesticTrackFallbackMatcher.match(
            candidate: candidate(title: "First Song", artist: "Different Artist"),
            anchor: anchor
        ) == nil else {
            throw DomesticTrackFallbackFixtureError.assertion("Weak artist match was not rejected.")
        }
        guard DomesticTrackFallbackMatcher.match(
            candidate: candidate(title: "First Song", duration: 103_001),
            anchor: anchor
        ) == nil else {
            throw DomesticTrackFallbackFixtureError.assertion("A duration delta above 3 s was not rejected.")
        }
    }

    private static func verifyNetEaseTrackSearch() async throws {
        let cacheRoot = temporaryCacheRoot("netease-track")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = DomesticMetadataFixtureTransport(routes: [
            .init(
                host: "music.163.com",
                path: "/api/search/get",
                requiredQueryItems: ["type": "1"],
                responses: [fixtureJSON(#"""
                {
                  "code":200,
                  "result":{"songs":[
                    {"id":9000,"name":"First Song (Live)","duration":100000,"artists":[{"name":"Anchor Artist"}],"album":{"name":"Anchor Album"}},
                    {"id":1001,"name":"First Song","duration":100400,"artists":[{"name":"Anchor Artist"}],"album":{"name":"Anchor Album"}}
                  ]}
                }
                """#)]
            ),
        ])
        let provider = NetEaseTrackFallbackProvider(
            transport: transport,
            appVersion: "test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: LyricsCache(root: cacheRoot, lifetime: LyricsCache.onlineContentLifetime)
        )
        let match = try await provider.searchTrack(anchor: anchor)
        guard match?.source == .netEase,
              match?.track.identifier == "1001",
              match?.track.numericIdentifier == "1001",
              match?.track.title == "First Song",
              match?.durationDeltaMilliseconds == 400 else {
            throw DomesticTrackFallbackFixtureError.assertion("NetEase type=1 fallback did not select the strict track match.")
        }
        let requests = await transport.recordedRequests()
        guard requests.count == 1,
              requests[0].queryItems["type"] == "1" else {
            throw DomesticTrackFallbackFixtureError.assertion("NetEase fallback did not use the required type=1 endpoint.")
        }
    }

    private static func verifyQQMusicTrackSearch() async throws {
        let cacheRoot = temporaryCacheRoot("qq-track")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = DomesticMetadataFixtureTransport(routes: [
            .init(
                host: "c.y.qq.com",
                path: "/soso/fcgi-bin/client_search_cp",
                requiredQueryItems: ["t": "0"],
                responses: [fixtureJSON(#"""
                {
                  "code":0,
                  "data":{"song":{"list":[
                    {"songmid":"qq-track-1","songid":2001,"songname":"First Song","albumname":"Anchor Album","interval":100,"singer":[{"name":"Anchor Artist"}]}
                  ]}}
                }
                """#)]
            ),
        ])
        let provider = QQMusicTrackFallbackProvider(
            transport: transport,
            appVersion: "test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: LyricsCache(root: cacheRoot, lifetime: LyricsCache.onlineContentLifetime)
        )
        let match = try await provider.searchTrack(anchor: anchor)
        guard match?.source == .qqMusic,
              match?.track.identifier == "qq-track-1",
              match?.track.numericIdentifier == "2001",
              match?.durationDeltaMilliseconds == 0 else {
            throw DomesticTrackFallbackFixtureError.assertion("QQ t=0 fallback did not decode MID/numeric ID.")
        }
        let requests = await transport.recordedRequests()
        guard requests.count == 1,
              requests[0].queryItems["t"] == "0" else {
            throw DomesticTrackFallbackFixtureError.assertion("QQ fallback did not use the required t=0 endpoint.")
        }
    }

    private static func verifyEnrichmentIntegration() async throws {
        let netEaseTrack = FixedDomesticTrackFallbackProvider(
            source: .netEase,
            titlePrefix: "NetEase Canonical",
            identifierPrefix: "ne"
        )
        let qqTrack = FixedDomesticTrackFallbackProvider(
            source: .qqMusic,
            titlePrefix: "QQ Canonical",
            identifierPrefix: "qq"
        )
        let service = MetadataEnrichmentService(
            netEase: EmptyDomesticAlbumProvider(source: .netEase),
            qqMusic: EmptyDomesticAlbumProvider(source: .qqMusic),
            netEaseTrackFallback: netEaseTrack,
            qqMusicTrackFallback: qqTrack
        )
        var options = MetadataEnrichmentOptions()
        options.fetchCover = false
        options.fetchLyrics = false
        options.sourcePriority = .netEaseFirst
        let result = try await service.enrich(
            musicBrainz: fixtureAlbum(),
            cdTracks: fixtureCDTracks(),
            options: options
        )
        guard result.album.title == "Anchor Album",
              result.album.artist == "Anchor Artist",
              result.album.netEaseAlbumID == nil,
              result.album.qqMusicAlbumMID == nil,
              result.album.tracks.map(\.title) == ["NetEase Canonical 1", "NetEase Canonical 2"],
              result.album.tracks.map(\.netEaseTrackID) == ["ne-1", "ne-2"],
              result.album.tracks.map(\.qqMusicTrackMID) == ["qq-1", "qq-2"],
              result.album.tracks.allSatisfy({ $0.tagSource == DomesticMetadataSource.netEase.rawValue }) else {
            throw DomesticTrackFallbackFixtureError.assertion(
                "Per-track fallback did not preserve MusicBrainz album identity or configured source priority."
            )
        }
    }

    private static func verifyWholeAlbumMatchSkipsTrackFallback() async throws {
        let counter = CountingDomesticTrackFallbackProvider(source: .netEase)
        let albumMatch = fixtureWholeAlbumMatch()
        let service = MetadataEnrichmentService(
            netEase: FixedDomesticAlbumProvider(source: .netEase, matches: [albumMatch]),
            qqMusic: EmptyDomesticAlbumProvider(source: .qqMusic),
            netEaseTrackFallback: counter,
            qqMusicTrackFallback: FixedDomesticTrackFallbackProvider(
                source: .qqMusic,
                titlePrefix: "QQ Canonical",
                identifierPrefix: "qq"
            )
        )
        var options = MetadataEnrichmentOptions()
        options.useQQMusic = false
        options.fetchCover = false
        options.fetchLyrics = false
        _ = try await service.enrich(
            musicBrainz: fixtureAlbum(),
            cdTracks: fixtureCDTracks(),
            options: options
        )
        guard await counter.requestCount() == 0 else {
            throw DomesticTrackFallbackFixtureError.assertion(
                "A verified full-album source was queried again through the per-track fallback."
            )
        }
    }

    private static func candidate(
        title: String,
        artist: String = "Anchor Artist",
        album: String = "Anchor Album",
        duration: Double = 100_000
    ) -> DomesticTrackFallbackMatcher.Candidate {
        DomesticTrackFallbackMatcher.Candidate(
            source: .netEase,
            title: title,
            artist: artist,
            album: album,
            durationMilliseconds: duration,
            identifier: "candidate",
            numericIdentifier: "candidate",
            webURL: nil,
            searchResultIndex: 0
        )
    }

    private static func temporaryCacheRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "cdrom-ios-\(label)-cache-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static func fixtureAlbum() -> AlbumCandidate {
        AlbumCandidate(
            releaseID: "mb-release",
            mediumPosition: 1,
            title: "Anchor Album",
            artist: "Anchor Artist",
            date: "2024-01-01",
            country: "JP",
            barcode: nil,
            tracks: [
                AlbumTrackMetadata(position: 1, title: "First Song", artist: "Anchor Artist", recordingID: "recording-1"),
                AlbumTrackMetadata(position: 2, title: "Second Song", artist: "Anchor Artist", recordingID: "recording-2"),
            ]
        )
    }

    private static func fixtureCDTracks() -> [CDTrack] {
        [
            CDTrack(
                number: 1,
                sourceFile: "fixture.bin",
                offsetBytes: 0,
                lengthBytes: 17_640_000,
                pregapBytes: 0,
                isrc: nil,
                hasPreEmphasis: false
            ),
            CDTrack(
                number: 2,
                sourceFile: "fixture.bin",
                offsetBytes: 17_640_000,
                lengthBytes: 21_168_000,
                pregapBytes: 0,
                isrc: nil,
                hasPreEmphasis: false
            ),
        ]
    }

    private static func fixtureWholeAlbumMatch() -> DomesticAlbumMetadataMatch {
        DomesticAlbumMetadataMatch(
            source: .netEase,
            albumIdentifier: "ne-album",
            numericAlbumIdentifier: "100",
            title: "Anchor Album",
            artist: "Anchor Artist",
            date: "2024-01-01",
            year: "2024",
            genres: ["Techno"],
            coverURL: nil,
            webURL: nil,
            tracks: [
                DomesticTrackMetadata(position: 1, title: "First Song", artist: "Anchor Artist", durationMilliseconds: 100_000, identifier: "ne-1", numericIdentifier: "ne-1", webURL: nil),
                DomesticTrackMetadata(position: 2, title: "Second Song", artist: "Anchor Artist", durationMilliseconds: 120_000, identifier: "ne-2", numericIdentifier: "ne-2", webURL: nil),
            ],
            score: DomesticAlbumMatchScore(
                baseScore: 120,
                durationScore: 130,
                totalScore: 250,
                durationMatches: 2,
                nearExactDurationMatches: 2,
                averageDurationDeltaMilliseconds: 0,
                maximumDurationDeltaMilliseconds: 0,
                durationMatchRatio: 1,
                passedStructuralThreshold: true,
                isConfident: true
            ),
            searchResultIndex: 0
        )
    }

    private static func fixtureJSON(_ value: String) -> DomesticMetadataHTTPResponse {
        DomesticMetadataHTTPResponse(
            data: Data(value.utf8),
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"]
        )
    }
}

private struct EmptyDomesticAlbumProvider: DomesticAlbumMetadataProviding {
    let source: DomesticMetadataSource

    func searchCandidates(anchor: DomesticAlbumAnchor) async throws -> [DomesticAlbumMetadataMatch] {
        []
    }
}

private struct FixedDomesticAlbumProvider: DomesticAlbumMetadataProviding {
    let source: DomesticMetadataSource
    let matches: [DomesticAlbumMetadataMatch]

    func searchCandidates(anchor: DomesticAlbumAnchor) async throws -> [DomesticAlbumMetadataMatch] {
        matches
    }
}

private struct FixedDomesticTrackFallbackProvider: DomesticTrackFallbackProviding {
    let source: DomesticMetadataSource
    let titlePrefix: String
    let identifierPrefix: String

    func searchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch? {
        let identifier = "\(identifierPrefix)-\(anchor.position)"
        return DomesticTrackFallbackMatch(
            source: source,
            track: DomesticTrackMetadata(
                position: anchor.position,
                title: "\(titlePrefix) \(anchor.position)",
                artist: anchor.artist,
                durationMilliseconds: anchor.durationMilliseconds,
                identifier: identifier,
                numericIdentifier: source == .netEase ? identifier : "numeric-\(identifier)",
                webURL: nil
            ),
            titleScore: 100,
            artistScore: 100,
            albumScore: 100,
            albumIsExact: true,
            durationDeltaMilliseconds: 0,
            searchResultIndex: 0
        )
    }
}

private actor CountingDomesticTrackFallbackProvider: DomesticTrackFallbackProviding {
    nonisolated let source: DomesticMetadataSource
    private var count = 0

    init(source: DomesticMetadataSource) {
        self.source = source
    }

    func searchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch? {
        count += 1
        return nil
    }

    func requestCount() -> Int { count }
}

private enum DomesticTrackFallbackFixtureError: LocalizedError, Sendable {
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .assertion(let message): return message
        }
    }
}
