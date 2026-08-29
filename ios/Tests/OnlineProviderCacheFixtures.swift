import Foundation

enum OnlineProviderCacheSelfTest {
    static func run(root: URL) async throws {
        try await verifyFreshAlbumAndTrackCaches(root: root)
        try await verifyFreshLyricsCaches(root: root)
        try await verifyExpiredAlbumAndTrackFallback(root: root)
        try await verifyExpiredLyricsFallback(root: root)
        try verifyCanonicalKeysIncludeSourceAndFullQuery()
    }

    private static func verifyFreshAlbumAndTrackCaches(root: URL) async throws {
        let cache = LyricsCache(
            root: root.appendingPathComponent("fresh-domestic-cache", isDirectory: true),
            lifetime: LyricsCache.onlineContentLifetime
        )
        let albumAnchor = DomesticMetadataProviderSelfTest.makeAnchor()
        let trackAnchor = makeTrackAnchor()
        let transport = OfflineDomesticMetadataTransport(statusCode: 503)

        for source in DomesticMetadataSource.allCases {
            let album = makeAlbumMatch(source: source)
            let albumKey = try LyricsCache.key(
                schema: "domestic-album-match-v2",
                source: source.rawValue,
                payload: albumAnchor
            )
            try await cache.store([album], for: albumKey)

            let track = makeTrackMatch(source: source)
            let trackKey = try LyricsCache.key(
                schema: "domestic-track-match-v1",
                source: source.rawValue,
                payload: trackAnchor
            )
            try await cache.store(OptionalDiskCacheValue(value: track), for: trackKey)
        }

        let netEaseAlbum = NetEaseMetadataProvider(
            transport: transport,
            appVersion: "cache-test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: cache
        )
        let qqAlbum = QQMusicMetadataProvider(
            transport: transport,
            appVersion: "cache-test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: cache
        )
        let netEaseTrack = NetEaseTrackFallbackProvider(
            transport: transport,
            appVersion: "cache-test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: cache
        )
        let qqTrack = QQMusicTrackFallbackProvider(
            transport: transport,
            appVersion: "cache-test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: cache
        )

        let netEaseAlbums = try await netEaseAlbum.searchCandidates(anchor: albumAnchor)
        let qqAlbums = try await qqAlbum.searchCandidates(anchor: albumAnchor)
        let netEaseTrackMatch = try await netEaseTrack.searchTrack(anchor: trackAnchor)
        let qqTrackMatch = try await qqTrack.searchTrack(anchor: trackAnchor)
        let requestCount = await transport.requestCount()
        try require(netEaseAlbums == [makeAlbumMatch(source: .netEase)], "fresh NetEase album cache")
        try require(qqAlbums == [makeAlbumMatch(source: .qqMusic)], "fresh QQ album cache")
        try require(netEaseTrackMatch == makeTrackMatch(source: .netEase), "fresh NetEase track cache")
        try require(qqTrackMatch == makeTrackMatch(source: .qqMusic), "fresh QQ track cache")
        try require(requestCount == 0, "fresh domestic cache must not access the network")
    }

    private static func verifyFreshLyricsCaches(root: URL) async throws {
        let cache = LyricsCache(
            root: root.appendingPathComponent("fresh-lyrics-cache", isDirectory: true),
            lifetime: LyricsCache.onlineContentLifetime
        )
        let query = makeLyricsQuery()
        let transport = OfflineLyricsTransport(statusCode: 503)
        let client = LyricsHTTPClient(transport: transport)
        let expected = makeLyrics()

        for source in ["NetEase Cloud Music", "QQ Music", "LRCLIB"] {
            let key = try LyricsCache.key(
                schema: "online-lyrics-v1",
                source: source,
                payload: query
            )
            try await cache.store(OptionalDiskCacheValue(value: expected), for: key)
        }

        let netEase = try await NetEaseLyricsProvider(client: client, cache: cache).lyrics(for: query)
        let qqMusic = try await QQMusicLyricsProvider(client: client, cache: cache).lyrics(for: query)
        let lrcLib = try await LRCLIBLyricsProvider(client: client, cache: cache).lyrics(for: query)
        try require(netEase == expected, "fresh NetEase lyrics cache")
        try require(qqMusic == expected, "fresh QQ lyrics cache")
        try require(lrcLib == expected, "fresh LRCLIB lyrics cache")
        let requestCount = await transport.requestCount()
        try require(requestCount == 0, "fresh lyrics cache must not access the network")
    }

    private static func verifyExpiredAlbumAndTrackFallback(root: URL) async throws {
        let cache = LyricsCache(
            root: root.appendingPathComponent("expired-domestic-cache", isDirectory: true),
            lifetime: -1
        )
        let albumAnchor = DomesticMetadataProviderSelfTest.makeAnchor()
        let trackAnchor = makeTrackAnchor()
        let album = makeAlbumMatch(source: .netEase)
        let track = makeTrackMatch(source: .netEase)
        try await cache.store([album], for: LyricsCache.key(
            schema: "domestic-album-match-v2",
            source: DomesticMetadataSource.netEase.rawValue,
            payload: albumAnchor
        ))
        try await cache.store(OptionalDiskCacheValue(value: track), for: LyricsCache.key(
            schema: "domestic-track-match-v1",
            source: DomesticMetadataSource.netEase.rawValue,
            payload: trackAnchor
        ))

        let transport = OfflineDomesticMetadataTransport(statusCode: 503)
        let albumProvider = NetEaseMetadataProvider(
            transport: transport,
            appVersion: "cache-test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: cache
        )
        let trackProvider = NetEaseTrackFallbackProvider(
            transport: transport,
            appVersion: "cache-test",
            retryPolicy: .immediateTest,
            minimumIntervalNanoseconds: 0,
            cache: cache
        )

        let albumResult = try await albumProvider.searchCandidates(anchor: albumAnchor)
        let trackResult = try await trackProvider.searchTrack(anchor: trackAnchor)
        let requestCount = await transport.requestCount()
        try require(albumResult == [album], "expired album cache survives HTTP 503")
        try require(trackResult == track, "expired track cache survives HTTP 503")
        try require(requestCount > 0, "expired domestic cache must attempt a refresh")
    }

    private static func verifyExpiredLyricsFallback(root: URL) async throws {
        let cache = LyricsCache(
            root: root.appendingPathComponent("expired-lyrics-cache", isDirectory: true),
            lifetime: -1
        )
        let query = makeLyricsQuery()
        let expected = makeLyrics()
        let key = try LyricsCache.key(
            schema: "online-lyrics-v1",
            source: "LRCLIB",
            payload: query
        )
        try await cache.store(OptionalDiskCacheValue(value: expected), for: key)

        let transport = OfflineLyricsTransport(statusCode: 503)
        let provider = LRCLIBLyricsProvider(
            client: LyricsHTTPClient(transport: transport),
            cache: cache
        )
        let result = try await provider.lyrics(for: query)
        try require(result == expected, "expired lyrics cache survives HTTP 503")
        let requestCount = await transport.requestCount()
        try require(requestCount > 0, "expired lyrics cache must attempt a refresh")
    }

    private static func verifyCanonicalKeysIncludeSourceAndFullQuery() throws {
        let first = makeLyricsQuery()
        let second = LyricsTrackQuery(
            position: first.position,
            title: first.title,
            artist: first.artist,
            album: first.album,
            durationSeconds: first.durationSeconds,
            netEaseTrackID: "different-id",
            qqMusicTrackMID: first.qqMusicTrackMID,
            qqMusicTrackID: first.qqMusicTrackID
        )
        let netEase = try LyricsCache.key(schema: "online-lyrics-v1", source: "NetEase Cloud Music", payload: first)
        let qqMusic = try LyricsCache.key(schema: "online-lyrics-v1", source: "QQ Music", payload: first)
        let changedQuery = try LyricsCache.key(schema: "online-lyrics-v1", source: "NetEase Cloud Music", payload: second)
        try require(netEase != qqMusic, "cache key includes source")
        try require(netEase != changedQuery, "cache key includes the complete query")
    }

    private static func makeTrackAnchor() -> DomesticTrackFallbackAnchor {
        DomesticTrackFallbackAnchor(
            position: 1,
            titleAliases: ["First Song"],
            artist: "Anchor Artist",
            albumAliases: ["Anchor Album"],
            durationMilliseconds: 100_000
        )
    }

    private static func makeAlbumMatch(source: DomesticMetadataSource) -> DomesticAlbumMetadataMatch {
        DomesticAlbumMetadataMatch(
            source: source,
            albumIdentifier: source == .netEase ? "100" : "qq-album",
            numericAlbumIdentifier: "100",
            title: "Anchor Album",
            artist: "Anchor Artist",
            date: "2024-01-01",
            year: "2024",
            genres: ["Techno"],
            coverURL: URL(string: "https://img.example/cover.jpg"),
            webURL: nil,
            tracks: [
                DomesticTrackMetadata(position: 1, title: "First Song", artist: "Anchor Artist", durationMilliseconds: 100_000, identifier: "1", numericIdentifier: "1", webURL: nil),
                DomesticTrackMetadata(position: 2, title: "Second Song", artist: "Anchor Artist", durationMilliseconds: 120_000, identifier: "2", numericIdentifier: "2", webURL: nil),
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

    private static func makeTrackMatch(source: DomesticMetadataSource) -> DomesticTrackFallbackMatch {
        DomesticTrackFallbackMatch(
            source: source,
            track: DomesticTrackMetadata(
                position: 1,
                title: "First Song",
                artist: "Anchor Artist",
                durationMilliseconds: 100_000,
                identifier: source == .netEase ? "1" : "qq-track",
                numericIdentifier: "1",
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

    private static func makeLyricsQuery() -> LyricsTrackQuery {
        LyricsTrackQuery(
            position: 1,
            title: "First Song",
            artist: "Anchor Artist",
            album: "Anchor Album",
            durationSeconds: 100,
            netEaseTrackID: "1",
            qqMusicTrackMID: "qq-track",
            qqMusicTrackID: "1"
        )
    }

    private static func makeLyrics() -> TrackLyrics {
        TrackLyrics(
            original: "Hello",
            synced: "[00:01.00]Hello",
            translated: "你好",
            translatedSynced: "[00:01.00]Hello\n[00:01.00]你好",
            romanized: nil,
            source: "cache fixture",
            translationProvider: "cache fixture",
            translationModel: nil,
            machineTranslated: false,
            instrumental: false
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw OnlineProviderCacheFixtureError.assertion(message) }
    }
}

private actor OfflineDomesticMetadataTransport: DomesticMetadataTransport {
    private let statusCode: Int
    private var count = 0

    init(statusCode: Int) { self.statusCode = statusCode }

    func send(_ request: URLRequest) async throws -> DomesticMetadataHTTPResponse {
        count += 1
        return DomesticMetadataHTTPResponse(data: Data(), statusCode: statusCode, headers: [:])
    }

    func requestCount() -> Int { count }
}

private actor OfflineLyricsTransport: LyricsHTTPTransport {
    private let statusCode: Int
    private var count = 0

    init(statusCode: Int) { self.statusCode = statusCode }

    func send(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        count += 1
        return LyricsHTTPResponse(data: Data(), statusCode: statusCode, headers: [:])
    }

    func requestCount() -> Int { count }
}

private enum OnlineProviderCacheFixtureError: LocalizedError, Sendable {
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .assertion(let message): return message
        }
    }
}
