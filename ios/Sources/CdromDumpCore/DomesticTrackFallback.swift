import Foundation

/// A MusicBrainz/CD anchored query used only when a domestic service could not
/// verify the complete album.  A per-track result may provide canonical track
/// display metadata and provider IDs, but it must never replace the selected
/// MusicBrainz release identity.
struct DomesticTrackFallbackAnchor: Codable, Hashable, Sendable {
    let position: Int
    let titleAliases: [String]
    let artist: String
    let albumAliases: [String]
    let durationMilliseconds: Double
}

struct DomesticTrackFallbackMatch: Codable, Hashable, Sendable {
    let source: DomesticMetadataSource
    let track: DomesticTrackMetadata
    let titleScore: Int
    let artistScore: Int
    let albumScore: Int
    let albumIsExact: Bool
    let durationDeltaMilliseconds: Double
    let searchResultIndex: Int

    var qualityScore: Int {
        titleScore * 4 + artistScore * 2 + albumScore
            + max(0, 30 - Int(durationDeltaMilliseconds / 100))
    }
}

protocol DomesticTrackFallbackProviding: Sendable {
    var source: DomesticMetadataSource { get }

    func searchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch?
}

/// Centralized conservative validator shared by both domestic services.  It
/// deliberately rejects a plausible-looking search hit unless title, artist,
/// album and CD-derived duration all agree.  Version qualifiers are checked
/// separately so punctuation normalization cannot turn a Live/Remix/etc.
/// edition into a false match.
enum DomesticTrackFallbackMatcher {
    struct Candidate: Sendable {
        let source: DomesticMetadataSource
        let title: String
        let artist: String
        let album: String
        let durationMilliseconds: Double
        let identifier: String
        let numericIdentifier: String?
        let webURL: URL?
        let searchResultIndex: Int
    }

    static func match(
        candidate: Candidate,
        anchor: DomesticTrackFallbackAnchor
    ) -> DomesticTrackFallbackMatch? {
        guard !anchor.titleAliases.isEmpty,
              !anchor.albumAliases.isEmpty,
              anchor.durationMilliseconds > 0,
              candidate.durationMilliseconds > 0,
              candidate.durationMilliseconds.isFinite else {
            return nil
        }

        let titleScores = anchor.titleAliases.map { similarity($0, candidate.title, kind: .title) }
        guard let titleScore = titleScores.max(), titleScore >= 85 else { return nil }
        let artistScore = similarity(anchor.artist, candidate.artist, kind: .artist)
        guard artistScore >= 85 else { return nil }

        let albumScores = anchor.albumAliases.map { similarity($0, candidate.album, kind: .album) }
        guard let albumScore = albumScores.max(), albumScore >= 85 else { return nil }
        let candidateAlbumText = canonicalText(candidate.album, kind: .album)
        let albumIsExact = anchor.albumAliases.contains {
            let value = canonicalText($0, kind: .album)
            return !value.isEmpty && value == candidateAlbumText
        }
        // A merely strong title is not sufficient to disambiguate similarly
        // named tracks across deluxe/single/compilation releases.
        guard titleScore >= 95 || albumIsExact else { return nil }

        let candidateMarkers = versionMarkers(candidate.title)
        guard anchor.titleAliases.contains(where: { versionMarkers($0) == candidateMarkers }) else {
            return nil
        }
        let delta = abs(anchor.durationMilliseconds - candidate.durationMilliseconds)
        guard delta <= 3_000 else { return nil }

        return DomesticTrackFallbackMatch(
            source: candidate.source,
            track: DomesticTrackMetadata(
                position: anchor.position,
                title: candidate.title,
                artist: candidate.artist,
                durationMilliseconds: candidate.durationMilliseconds,
                identifier: candidate.identifier,
                numericIdentifier: candidate.numericIdentifier,
                webURL: candidate.webURL
            ),
            titleScore: titleScore,
            artistScore: artistScore,
            albumScore: albumScore,
            albumIsExact: albumIsExact,
            durationDeltaMilliseconds: (delta * 10).rounded() / 10,
            searchResultIndex: candidate.searchResultIndex
        )
    }

    static func isPreferred(_ left: DomesticTrackFallbackMatch, _ right: DomesticTrackFallbackMatch) -> Bool {
        if left.qualityScore != right.qualityScore { return left.qualityScore > right.qualityScore }
        if left.titleScore != right.titleScore { return left.titleScore > right.titleScore }
        if left.albumIsExact != right.albumIsExact { return left.albumIsExact && !right.albumIsExact }
        if left.durationDeltaMilliseconds != right.durationDeltaMilliseconds {
            return left.durationDeltaMilliseconds < right.durationDeltaMilliseconds
        }
        if left.searchResultIndex != right.searchResultIndex {
            return left.searchResultIndex < right.searchResultIndex
        }
        return left.track.identifier < right.track.identifier
    }

    enum MatchKind {
        case title
        case artist
        case album
    }

    static func similarity(_ left: String, _ right: String, kind: MatchKind) -> Int {
        let lhs = canonicalText(left, kind: kind)
        let rhs = canonicalText(right, kind: kind)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 100 }

        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        let longest = max(lhsCharacters.count, rhsCharacters.count)
        guard longest > 0 else { return 0 }
        let editScore = Int(
            ((1 - Double(levenshtein(lhsCharacters, rhsCharacters)) / Double(longest)) * 100)
                .rounded(.toNearestOrEven)
        )
        var containmentScore = 0
        if lhs.contains(rhs) || rhs.contains(lhs) {
            containmentScore = Int(
                (Double(min(lhsCharacters.count, rhsCharacters.count)) / Double(longest) * 100)
                    .rounded(.toNearestOrEven)
            )
        }
        return max(0, min(100, max(editScore, containmentScore)))
    }

    private static func canonicalText(_ value: String, kind: MatchKind) -> String {
        var normalized = value.lowercased()
            .replacingOccurrences(of: "＆", with: "&")
            .replacingOccurrences(of: "／", with: "/")
        if kind == .title {
            // Artist credits frequently move between the title and artist
            // fields. Removing only explicit feat. clauses preserves actual
            // edition markers such as Live, Remix and Version.
            normalized = normalized.replacingOccurrences(
                of: #"(?i)\s*[\(\[]\s*(?:feat\.?|featuring)\s+[^\)\]]*[\)\]]"#,
                with: "",
                options: .regularExpression
            )
            normalized = normalized.replacingOccurrences(
                of: #"(?i)\s+(?:feat\.?|featuring)\s+.+$"#,
                with: "",
                options: .regularExpression
            )
        } else if kind == .artist {
            normalized = normalized.replacingOccurrences(
                of: #"(?i)\b(?:feat\.?|featuring|with|vs\.?)\b"#,
                with: " ",
                options: .regularExpression
            )
            normalized = normalized.replacingOccurrences(
                of: #"[&,/、;；×]"#,
                with: " ",
                options: .regularExpression
            )
        }
        return DomesticMetadataScorer.matchText(normalized)
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, right) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private enum VersionMarker: String, Hashable {
        case instrumental
        case live
        case remix
        case remaster
        case version
    }

    private static func versionMarkers(_ value: String) -> Set<VersionMarker> {
        let patterns: [(VersionMarker, String)] = [
            (.instrumental, #"(?i)(?:\binstrumental\b|\binst\.?\b|off\s*vocal|karaoke|纯音乐|純音樂|伴奏|インスト)"#),
            (.live, #"(?i)(?:\blive\b|ライブ|现场|現場)"#),
            (.remix, #"(?i)(?:\bremix(?:ed)?\b|リミックス|混音)"#),
            (.remaster, #"(?i)(?:\bremaster(?:ed)?\b|リマスター|重制|重製)"#),
            (.version, #"(?i)(?:\bversion\b|\bver\.?\b|\bedit\b|バージョン|版本)"#),
        ]
        return Set(patterns.compactMap { marker, pattern in
            value.range(of: pattern, options: .regularExpression) == nil ? nil : marker
        })
    }
}

struct NetEaseTrackFallbackProvider: DomesticTrackFallbackProviding {
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
            namespace: "DomesticTrack-v1"
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
            namespace: "DomesticTrack-v1"
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

    func searchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch? {
        let cacheKey = try LyricsCache.key(
            schema: "domestic-track-match-v1",
            source: source.rawValue,
            payload: anchor
        )
        if let cached = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<DomesticTrackFallbackMatch>.self
        ) {
            return cached.value
        }
        let stale = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<DomesticTrackFallbackMatch>.self,
            allowExpired: true
        )
        do {
            let match = try await fetchTrack(anchor: anchor)
            try? await cache.store(OptionalDiskCacheValue(value: match), for: cacheKey)
            return match
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let stale { return stale.value }
            throw error
        }
    }

    private func fetchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch? {
        var matches: [DomesticTrackFallbackMatch] = []
        var seen = Set<String>()
        for query in Self.queries(anchor) {
            var request = URLRequest(url: try Self.searchURL(query), timeoutInterval: 30)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            let data = try await client.data(for: request)
            let response: NetEaseTrackSearchResponse
            do {
                response = try JSONDecoder().decode(NetEaseTrackSearchResponse.self, from: data)
            } catch {
                throw DomesticMetadataError.invalidResponse(.netEase, "逐轨搜索 JSON 无法解析。")
            }
            guard response.code?.intValue == 200 else {
                throw DomesticMetadataError.invalidResponse(
                    .netEase,
                    "逐轨搜索 API 状态码 \(response.code?.stringValue ?? "missing")。"
                )
            }
            for (index, song) in (response.result?.songs ?? []).prefix(30).enumerated() {
                guard let identifier = DomesticMetadataScorer.nonempty(song.id?.stringValue),
                      seen.insert(identifier).inserted,
                      let title = DomesticMetadataScorer.nonempty(song.name),
                      let album = DomesticMetadataScorer.nonempty(song.album?.name ?? song.compactAlbum?.name),
                      let artist = DomesticMetadataScorer.artists(song.artists ?? song.compactArtists),
                      let duration = (song.duration ?? song.compactDuration)?.doubleValue else {
                    continue
                }
                let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                    ?? identifier
                let candidate = DomesticTrackFallbackMatcher.Candidate(
                    source: .netEase,
                    title: title,
                    artist: artist,
                    album: album,
                    durationMilliseconds: duration,
                    identifier: identifier,
                    numericIdentifier: identifier,
                    webURL: URL(string: "https://music.163.com/#/song?id=\(encoded)"),
                    searchResultIndex: index
                )
                if let match = DomesticTrackFallbackMatcher.match(candidate: candidate, anchor: anchor) {
                    matches.append(match)
                }
            }
            if matches.contains(where: { $0.titleScore == 100 && $0.artistScore == 100 && $0.albumIsExact && $0.durationDeltaMilliseconds <= 750 }) {
                break
            }
        }
        return matches.sorted(by: DomesticTrackFallbackMatcher.isPreferred).first
    }

    private static func queries(_ anchor: DomesticTrackFallbackAnchor) -> [String] {
        guard let title = DomesticMetadataScorer.nonempty(anchor.titleAliases.first),
              let album = DomesticMetadataScorer.nonempty(anchor.albumAliases.first) else { return [] }
        return DomesticMetadataScorer.uniqueNonempty([
            "\(title) \(anchor.artist) \(album)",
            "\(title) \(anchor.artist)",
        ])
    }

    private static func searchURL(_ query: String) throws -> URL {
        var components = URLComponents(string: "https://music.163.com/api/search/get")
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        guard let url = components?.url else { throw DomesticMetadataError.invalidURL(.netEase) }
        return url
    }
}

struct QQMusicTrackFallbackProvider: DomesticTrackFallbackProviding {
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
            namespace: "DomesticTrack-v1"
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
            namespace: "DomesticTrack-v1"
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

    func searchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch? {
        let cacheKey = try LyricsCache.key(
            schema: "domestic-track-match-v1",
            source: source.rawValue,
            payload: anchor
        )
        if let cached = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<DomesticTrackFallbackMatch>.self
        ) {
            return cached.value
        }
        let stale = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<DomesticTrackFallbackMatch>.self,
            allowExpired: true
        )
        do {
            let match = try await fetchTrack(anchor: anchor)
            try? await cache.store(OptionalDiskCacheValue(value: match), for: cacheKey)
            return match
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let stale { return stale.value }
            throw error
        }
    }

    private func fetchTrack(anchor: DomesticTrackFallbackAnchor) async throws -> DomesticTrackFallbackMatch? {
        var matches: [DomesticTrackFallbackMatch] = []
        var seen = Set<String>()
        for query in Self.queries(anchor) {
            var request = URLRequest(url: try Self.searchURL(query), timeoutInterval: 30)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            let data = try await client.data(for: request)
            let response: QQMusicTrackSearchResponse
            do {
                response = try JSONDecoder().decode(QQMusicTrackSearchResponse.self, from: data)
            } catch {
                throw DomesticMetadataError.invalidResponse(.qqMusic, "逐轨搜索 JSON 无法解析。")
            }
            guard response.code?.intValue == 0 else {
                throw DomesticMetadataError.invalidResponse(
                    .qqMusic,
                    "逐轨搜索 API 状态码 \(response.code?.stringValue ?? "missing")。"
                )
            }
            for (index, song) in (response.data?.song?.list ?? []).prefix(30).enumerated() {
                guard let identifier = DomesticMetadataScorer.nonempty(song.songMID?.stringValue),
                      seen.insert(identifier).inserted,
                      let title = DomesticMetadataScorer.nonempty(song.songName ?? song.name),
                      let album = DomesticMetadataScorer.nonempty(song.albumName),
                      let artist = DomesticMetadataScorer.artists(
                        song.singers ?? song.singerList,
                        fallback: song.singerName ?? song.alternateSingerName
                      ),
                      let seconds = song.interval?.doubleValue else {
                    continue
                }
                let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? identifier
                let candidate = DomesticTrackFallbackMatcher.Candidate(
                    source: .qqMusic,
                    title: title,
                    artist: artist,
                    album: album,
                    durationMilliseconds: seconds * 1_000,
                    identifier: identifier,
                    numericIdentifier: song.songID?.stringValue,
                    webURL: URL(string: "https://y.qq.com/n/ryqq/songDetail/\(encoded)"),
                    searchResultIndex: index
                )
                if let match = DomesticTrackFallbackMatcher.match(candidate: candidate, anchor: anchor) {
                    matches.append(match)
                }
            }
            if matches.contains(where: { $0.titleScore == 100 && $0.artistScore == 100 && $0.albumIsExact && $0.durationDeltaMilliseconds <= 750 }) {
                break
            }
        }
        return matches.sorted(by: DomesticTrackFallbackMatcher.isPreferred).first
    }

    private static func queries(_ anchor: DomesticTrackFallbackAnchor) -> [String] {
        guard let title = DomesticMetadataScorer.nonempty(anchor.titleAliases.first),
              let album = DomesticMetadataScorer.nonempty(anchor.albumAliases.first) else { return [] }
        return DomesticMetadataScorer.uniqueNonempty([
            "\(title) \(anchor.artist) \(album)",
            "\(title) \(anchor.artist)",
        ])
    }

    private static func searchURL(_ query: String) throws -> URL {
        var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")
        components?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "30"),
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "t", value: "0"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw DomesticMetadataError.invalidURL(.qqMusic) }
        return url
    }
}

private struct DomesticTrackAlbumPayload: Codable, Sendable {
    let name: String?
}

private struct NetEaseTrackSearchResponse: Codable, Sendable {
    let code: DomesticScalar?
    let result: NetEaseTrackSearchResult?
}

private struct NetEaseTrackSearchResult: Codable, Sendable {
    let songs: [NetEaseTrackSearchSong]?
}

private struct NetEaseTrackSearchSong: Codable, Sendable {
    let id: DomesticScalar?
    let name: String?
    let artists: [DomesticArtistPayload]?
    let compactArtists: [DomesticArtistPayload]?
    let album: DomesticTrackAlbumPayload?
    let compactAlbum: DomesticTrackAlbumPayload?
    let duration: DomesticScalar?
    let compactDuration: DomesticScalar?

    private enum CodingKeys: String, CodingKey {
        case id, name, artists, album, duration
        case compactArtists = "ar"
        case compactAlbum = "al"
        case compactDuration = "dt"
    }
}

private struct QQMusicTrackSearchResponse: Codable, Sendable {
    let code: DomesticScalar?
    let data: QQMusicTrackSearchData?
}

private struct QQMusicTrackSearchData: Codable, Sendable {
    let song: QQMusicTrackSearchBucket?
}

private struct QQMusicTrackSearchBucket: Codable, Sendable {
    let list: [QQMusicTrackSearchSong]?
}

private struct QQMusicTrackSearchSong: Codable, Sendable {
    let songMID: DomesticScalar?
    let songID: DomesticScalar?
    let songName: String?
    let name: String?
    let albumName: String?
    let interval: DomesticScalar?
    let singers: [DomesticArtistPayload]?
    let singerList: [DomesticArtistPayload]?
    let singerName: String?
    let alternateSingerName: String?

    private enum CodingKeys: String, CodingKey {
        case songMID = "songmid"
        case songID = "songid"
        case songName = "songname"
        case name, interval, singerName
        case albumName = "albumname"
        case singers = "singer"
        case singerList = "singer_list"
        case alternateSingerName = "singername"
    }
}
