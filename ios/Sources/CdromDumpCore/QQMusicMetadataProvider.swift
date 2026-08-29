import Foundation

struct QQMusicMetadataProvider: DomesticAlbumMetadataProviding {
    let source = DomesticMetadataSource.qqMusic

    private let client: DomesticMetadataHTTPClient
    private let userAgent: String
    private let cache: LyricsCache

    init(
        session: URLSession = URLSessionDomesticMetadataTransport.secureSession,
        appVersion: String = IOSAppVersion.current,
        retryPolicy: DomesticMetadataRetryPolicy = .default,
        minimumIntervalNanoseconds: UInt64 = 800_000_000,
        cache: LyricsCache = LyricsCache(
            lifetime: LyricsCache.onlineContentLifetime,
            namespace: "DomesticMetadata-v1"
        )
    ) {
        self.init(
            transport: URLSessionDomesticMetadataTransport(session: session),
            appVersion: appVersion,
            retryPolicy: retryPolicy,
            minimumIntervalNanoseconds: minimumIntervalNanoseconds,
            cache: cache
        )
    }

    init(
        transport: any DomesticMetadataTransport,
        appVersion: String = IOSAppVersion.current,
        retryPolicy: DomesticMetadataRetryPolicy = .default,
        minimumIntervalNanoseconds: UInt64 = 800_000_000,
        cache: LyricsCache = LyricsCache(
            lifetime: LyricsCache.onlineContentLifetime,
            namespace: "DomesticMetadata-v1"
        )
    ) {
        client = DomesticMetadataHTTPClient(
            source: .qqMusic,
            transport: transport,
            retryPolicy: retryPolicy,
            minimumIntervalNanoseconds: minimumIntervalNanoseconds
        )
        userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) CdromDumpToolsiOS/\(appVersion)"
        self.cache = cache
    }

    func searchCandidates(anchor: DomesticAlbumAnchor) async throws -> [DomesticAlbumMetadataMatch] {
        let cacheKey = try LyricsCache.key(
            schema: "domestic-album-match-v2",
            source: source.rawValue,
            payload: anchor
        )
        if let cached = await cache.value(
            for: cacheKey,
            as: [DomesticAlbumMetadataMatch].self
        ) {
            return cached
        }
        let stale = await cache.value(
            for: cacheKey,
            as: [DomesticAlbumMetadataMatch].self,
            allowExpired: true
        )
        do {
            let matches = try await fetchCandidates(anchor: anchor)
            if matches.isEmpty, let stale { return stale }
            try? await cache.store(matches, for: cacheKey)
            return matches
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let stale { return stale }
            throw error
        }
    }

    private func fetchCandidates(anchor: DomesticAlbumAnchor) async throws -> [DomesticAlbumMetadataMatch] {
        try DomesticMetadataScorer.validate(anchor)
        let queries = DomesticMetadataScorer.queries(for: anchor)
        var seenAlbumIdentifiers = Set<String>()
        var matches: [DomesticAlbumMetadataMatch] = []
        var bestConfidentScore = Int.min

        queryLoop: for query in queries {
            let search: QQMusicSearchResponse = try await response(
                QQMusicSearchResponse.self,
                url: try searchURL(query: query)
            )
            let candidates = Array((search.data?.album?.list ?? []).prefix(10))

            for (resultIndex, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                guard let albumIdentifier = DomesticMetadataScorer.nonempty(candidate.albumMID?.stringValue),
                      seenAlbumIdentifiers.insert(albumIdentifier).inserted else {
                    continue
                }
                guard let detail = try await albumDetail(identifier: albumIdentifier) else { continue }
                let songs = discSongs(
                    detail,
                    discNumber: anchor.discNumber,
                    expectedTrackCount: anchor.tracks.count
                )
                guard songs.count == anchor.tracks.count,
                      let title = DomesticMetadataScorer.nonempty(detail.data?.name)
                        ?? DomesticMetadataScorer.nonempty(candidate.albumName),
                      let artist = albumArtist(detail.data)
                        ?? searchAlbumArtist(candidate) else {
                    continue
                }

                let date = DomesticMetadataScorer.isoDate(detail.data?.date)
                    ?? DomesticMetadataScorer.isoDate(candidate.publicTime)
                let durations = songs.map { ($0.interval?.doubleValue ?? 0) * 1_000 }
                let score = DomesticMetadataScorer.score(
                    candidateAlbum: title,
                    candidateArtist: artist,
                    candidateDate: date,
                    candidateDurationsMilliseconds: durations,
                    anchor: anchor,
                    resultIndex: resultIndex
                )
                guard let tracks = canonicalTracks(songs, albumArtist: artist) else { continue }
                let encoded = albumIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? albumIdentifier
                let match = DomesticAlbumMetadataMatch(
                    source: .qqMusic,
                    albumIdentifier: albumIdentifier,
                    numericAlbumIdentifier: candidate.albumID?.stringValue,
                    title: title,
                    artist: artist,
                    date: date,
                    year: DomesticMetadataScorer.year(date),
                    genres: DomesticMetadataScorer.genres(detail.data?.genre),
                    coverURL: URL(string: "https://y.gtimg.cn/music/photo_new/T002R1200x1200M000\(encoded).jpg"),
                    webURL: URL(string: "https://y.qq.com/n/ryqq/albumDetail/\(encoded)"),
                    tracks: tracks,
                    score: score,
                    searchResultIndex: resultIndex
                )
                matches.append(match)

                if score.isConfident {
                    bestConfidentScore = max(bestConfidentScore, score.totalScore)
                    if score.totalScore >= 200, score.durationMatches == anchor.tracks.count {
                        break
                    }
                }
            }

            if bestConfidentScore >= 180 {
                break queryLoop
            }
        }

        return matches.sorted(by: DomesticMetadataOrdering.isPreferred)
    }

    private func searchURL(query: String) throws -> URL {
        var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")
        components?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "20"),
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "t", value: "8"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw DomesticMetadataError.invalidURL(.qqMusic) }
        return url
    }

    private func albumDetail(identifier: String) async throws -> QQMusicAlbumResponse? {
        var components = URLComponents(string: "https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg")
        components?.queryItems = [
            URLQueryItem(name: "albummid", value: identifier),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "platform", value: "yqq"),
        ]
        guard let url = components?.url else { throw DomesticMetadataError.invalidURL(.qqMusic) }
        do {
            return try await response(QQMusicAlbumResponse.self, url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func response<T: QQMusicResponseEnvelope>(_ type: T.Type, url: URL) async throws -> T {
        var lastCode = "missing"
        for validationAttempt in 1...2 {
            var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            let data = try await client.data(for: request)
            let decoded: T
            do {
                decoded = try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw DomesticMetadataError.invalidResponse(.qqMusic, "JSON 格式无法解析。")
            }
            lastCode = decoded.code?.stringValue ?? "missing"
            if decoded.code?.intValue == 0 { return decoded }
            if validationAttempt < 2 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw DomesticMetadataError.invalidResponse(.qqMusic, "API 状态码 \(lastCode)。")
    }

    private func discSongs(
        _ response: QQMusicAlbumResponse,
        discNumber: Int,
        expectedTrackCount: Int
    ) -> [QQMusicSongPayload] {
        let songs = response.data?.list ?? []
        if songs.count == expectedTrackCount { return songs }
        let filtered = songs.filter {
            guard let discIndex = $0.discIndex?.intValue else { return false }
            return discIndex + 1 == discNumber
        }
        return filtered.count == expectedTrackCount ? filtered : []
    }

    private func canonicalTracks(
        _ songs: [QQMusicSongPayload],
        albumArtist: String
    ) -> [DomesticTrackMetadata]? {
        var tracks: [DomesticTrackMetadata] = []
        for (index, song) in songs.enumerated() {
            guard let title = DomesticMetadataScorer.nonempty(song.songName)
                    ?? DomesticMetadataScorer.nonempty(song.name),
                  let identifier = DomesticMetadataScorer.nonempty(song.songMID?.stringValue) else {
                return nil
            }
            let artist = songArtist(song) ?? albumArtist
            let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? identifier
            tracks.append(DomesticTrackMetadata(
                position: index + 1,
                title: title,
                artist: artist,
                durationMilliseconds: (song.interval?.doubleValue ?? 0) * 1_000,
                identifier: identifier,
                numericIdentifier: song.songID?.stringValue,
                webURL: URL(string: "https://y.qq.com/n/ryqq/songDetail/\(encoded)")
            ))
        }
        return tracks
    }

    private func albumArtist(_ album: QQMusicAlbumPayload?) -> String? {
        DomesticMetadataScorer.artists(
            album?.singers ?? album?.singerList,
            fallback: album?.singerName ?? album?.alternateSingerName
        )
    }

    private func searchAlbumArtist(_ album: QQMusicAlbumSearchPayload) -> String? {
        DomesticMetadataScorer.artists(
            album.singers ?? album.singerList,
            fallback: album.singerName ?? album.alternateSingerName
        )
    }

    private func songArtist(_ song: QQMusicSongPayload) -> String? {
        DomesticMetadataScorer.artists(
            song.singers ?? song.singerList,
            fallback: song.singerName ?? song.alternateSingerName
        )
    }
}

private protocol QQMusicResponseEnvelope: Codable, Sendable {
    var code: DomesticScalar? { get }
}

private struct QQMusicSearchResponse: QQMusicResponseEnvelope {
    let code: DomesticScalar?
    let data: QQMusicSearchData?
}

private struct QQMusicSearchData: Codable, Sendable {
    let album: QQMusicSearchAlbumBucket?
}

private struct QQMusicSearchAlbumBucket: Codable, Sendable {
    let list: [QQMusicAlbumSearchPayload]?
}

private struct QQMusicAlbumSearchPayload: Codable, Sendable {
    let albumMID: DomesticScalar?
    let albumID: DomesticScalar?
    let albumName: String?
    let publicTime: String?
    let singers: [DomesticArtistPayload]?
    let singerList: [DomesticArtistPayload]?
    let singerName: String?
    let alternateSingerName: String?

    private enum CodingKeys: String, CodingKey {
        case albumMID, albumID, albumName, publicTime, singerName
        case singers = "singer"
        case singerList = "singer_list"
        case alternateSingerName = "singername"
    }
}

private struct QQMusicAlbumResponse: QQMusicResponseEnvelope {
    let code: DomesticScalar?
    let data: QQMusicAlbumPayload?
}

private struct QQMusicAlbumPayload: Codable, Sendable {
    let name: String?
    let date: String?
    let genre: String?
    let list: [QQMusicSongPayload]?
    let singers: [DomesticArtistPayload]?
    let singerList: [DomesticArtistPayload]?
    let singerName: String?
    let alternateSingerName: String?

    private enum CodingKeys: String, CodingKey {
        case name, genre, list, singerName
        case date = "aDate"
        case singers = "singer"
        case singerList = "singer_list"
        case alternateSingerName = "singername"
    }
}

private struct QQMusicSongPayload: Codable, Sendable {
    let songMID: DomesticScalar?
    let songID: DomesticScalar?
    let songName: String?
    let name: String?
    let interval: DomesticScalar?
    let discIndex: DomesticScalar?
    let singers: [DomesticArtistPayload]?
    let singerList: [DomesticArtistPayload]?
    let singerName: String?
    let alternateSingerName: String?

    private enum CodingKeys: String, CodingKey {
        case songMID = "songmid"
        case songID = "songid"
        case songName = "songname"
        case name, interval, singerName
        case discIndex = "cdIdx"
        case singers = "singer"
        case singerList = "singer_list"
        case alternateSingerName = "singername"
    }
}
