import Foundation

struct NetEaseMetadataProvider: DomesticAlbumMetadataProviding {
    let source = DomesticMetadataSource.netEase

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
            source: .netEase,
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
            let search: NetEaseSearchResponse = try await response(
                NetEaseSearchResponse.self,
                url: try searchURL(query: query)
            )
            let candidates = Array((search.result?.albums ?? []).prefix(10))

            for (resultIndex, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                guard let albumIdentifier = candidate.id?.stringValue,
                      !albumIdentifier.isEmpty,
                      seenAlbumIdentifiers.insert(albumIdentifier).inserted else {
                    continue
                }
                guard let detail = try await albumDetail(
                    identifier: albumIdentifier,
                    discNumber: anchor.discNumber,
                    expectedTrackCount: anchor.tracks.count
                ) else {
                    continue
                }
                let songs = detail.songs
                let album = detail.response.album
                guard let title = DomesticMetadataScorer.nonempty(album?.name),
                      let artist = albumArtist(album),
                      songs.count == anchor.tracks.count else {
                    continue
                }

                let date = DomesticMetadataScorer.netEaseDate(
                    milliseconds: album?.publishTime?.doubleValue
                )
                let durations = songs.map(songDurationMilliseconds)
                let score = DomesticMetadataScorer.score(
                    candidateAlbum: title,
                    candidateArtist: artist,
                    candidateDate: date,
                    candidateDurationsMilliseconds: durations,
                    anchor: anchor,
                    resultIndex: resultIndex
                )
                guard let tracks = canonicalTracks(songs, albumArtist: artist) else { continue }
                let identifier = albumIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                    ?? albumIdentifier
                let coverText = DomesticMetadataScorer.nonempty(album?.picURL)
                    ?? DomesticMetadataScorer.nonempty(album?.blurPicURL)
                let match = DomesticAlbumMetadataMatch(
                    source: .netEase,
                    albumIdentifier: albumIdentifier,
                    numericAlbumIdentifier: albumIdentifier,
                    title: title,
                    artist: artist,
                    date: date,
                    year: DomesticMetadataScorer.year(date),
                    genres: DomesticMetadataScorer.genres(album?.tags),
                    coverURL: coverText.flatMap(URL.init(string:)),
                    webURL: URL(string: "https://music.163.com/#/album?id=\(identifier)"),
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
        var components = URLComponents(string: "https://music.163.com/api/search/get")
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "10"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        guard let url = components?.url else { throw DomesticMetadataError.invalidURL(.netEase) }
        return url
    }

    private func albumDetail(
        identifier: String,
        discNumber: Int,
        expectedTrackCount: Int
    ) async throws -> (response: NetEaseAlbumResponse, songs: [NetEaseSongPayload])? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let urls = [
            URL(string: "https://music.163.com/api/v1/album/\(encoded)"),
            URL(string: "https://music.163.com/api/album/\(encoded)"),
        ].compactMap { $0 }

        for url in urls {
            do {
                let detail: NetEaseAlbumResponse = try await response(NetEaseAlbumResponse.self, url: url)
                let songs = discSongs(
                    detail,
                    discNumber: discNumber,
                    expectedTrackCount: expectedTrackCount
                )
                if songs.count == expectedTrackCount { return (detail, songs) }
                if !(detail.album?.songs ?? detail.songs ?? []).isEmpty { return nil }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    private func response<T: NetEaseResponseEnvelope>(_ type: T.Type, url: URL) async throws -> T {
        var lastCode = "missing"
        for validationAttempt in 1...2 {
            var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            let data = try await client.data(for: request)
            let decoded: T
            do {
                decoded = try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw DomesticMetadataError.invalidResponse(.netEase, "JSON 格式无法解析。")
            }
            lastCode = decoded.code?.stringValue ?? "missing"
            if decoded.code?.intValue == 200 { return decoded }
            if validationAttempt < 2 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw DomesticMetadataError.invalidResponse(.netEase, "API 状态码 \(lastCode)。")
    }

    private func discSongs(
        _ response: NetEaseAlbumResponse,
        discNumber: Int,
        expectedTrackCount: Int
    ) -> [NetEaseSongPayload] {
        let source = response.album?.songs ?? response.songs ?? []
        let ordered = source.enumerated().sorted {
            let left = $0.element.number?.intValue ?? Int.max
            let right = $1.element.number?.intValue ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        if ordered.count == expectedTrackCount { return ordered }
        let filtered = ordered.filter {
            ($0.disc?.intValue ?? $0.compactDisc?.intValue) == discNumber
        }
        return filtered.count == expectedTrackCount ? filtered : []
    }

    private func canonicalTracks(
        _ songs: [NetEaseSongPayload],
        albumArtist: String
    ) -> [DomesticTrackMetadata]? {
        var tracks: [DomesticTrackMetadata] = []
        for (index, song) in songs.enumerated() {
            guard let title = DomesticMetadataScorer.nonempty(song.name),
                  let identifier = DomesticMetadataScorer.nonempty(song.id?.stringValue) else {
                return nil
            }
            let artist = songArtist(song) ?? albumArtist
            let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? identifier
            tracks.append(DomesticTrackMetadata(
                position: index + 1,
                title: title,
                artist: artist,
                durationMilliseconds: songDurationMilliseconds(song),
                identifier: identifier,
                numericIdentifier: identifier,
                webURL: URL(string: "https://music.163.com/#/song?id=\(encoded)")
            ))
        }
        return tracks
    }

    private func albumArtist(_ album: NetEaseAlbumPayload?) -> String? {
        let artists = album?.artists ?? album?.shortArtists
        return DomesticMetadataScorer.artists(artists, fallback: album?.artist?.name)
    }

    private func songArtist(_ song: NetEaseSongPayload) -> String? {
        DomesticMetadataScorer.artists(song.artists ?? song.shortArtists)
    }

    private func songDurationMilliseconds(_ song: NetEaseSongPayload) -> Double {
        song.duration?.doubleValue ?? song.compactDuration?.doubleValue ?? 0
    }
}

private protocol NetEaseResponseEnvelope: Codable, Sendable {
    var code: DomesticScalar? { get }
}

private struct NetEaseSearchResponse: NetEaseResponseEnvelope {
    let code: DomesticScalar?
    let result: NetEaseSearchResult?
}

private struct NetEaseSearchResult: Codable, Sendable {
    let albums: [NetEaseAlbumSearchPayload]?
}

private struct NetEaseAlbumSearchPayload: Codable, Sendable {
    let id: DomesticScalar?
}

private struct NetEaseAlbumResponse: NetEaseResponseEnvelope {
    let code: DomesticScalar?
    let album: NetEaseAlbumPayload?
    let songs: [NetEaseSongPayload]?
}

private struct NetEaseAlbumPayload: Codable, Sendable {
    let name: String?
    let publishTime: DomesticScalar?
    let picURL: String?
    let blurPicURL: String?
    let tags: String?
    let artists: [DomesticArtistPayload]?
    let shortArtists: [DomesticArtistPayload]?
    let artist: DomesticArtistPayload?
    let songs: [NetEaseSongPayload]?

    private enum CodingKeys: String, CodingKey {
        case name, publishTime, tags, artists, artist, songs
        case picURL = "picUrl"
        case blurPicURL = "blurPicUrl"
        case shortArtists = "ar"
    }
}

private struct NetEaseAlbumSummaryPayload: Codable, Sendable {
    let name: String?
}

private struct NetEaseSongPayload: Codable, Sendable {
    let id: DomesticScalar?
    let name: String?
    let artists: [DomesticArtistPayload]?
    let shortArtists: [DomesticArtistPayload]?
    let album: NetEaseAlbumSummaryPayload?
    let compactAlbum: NetEaseAlbumSummaryPayload?
    let duration: DomesticScalar?
    let compactDuration: DomesticScalar?
    let number: DomesticScalar?
    let disc: DomesticScalar?
    let compactDisc: DomesticScalar?

    private enum CodingKeys: String, CodingKey {
        case id, name, artists, album, duration, disc
        case shortArtists = "ar"
        case compactAlbum = "al"
        case compactDuration = "dt"
        case number = "no"
        case compactDisc = "cd"
    }
}
