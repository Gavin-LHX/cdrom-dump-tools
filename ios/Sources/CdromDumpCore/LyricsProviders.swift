import Foundation

struct LyricsTrackQuery: Codable, Hashable, Sendable {
    let position: Int
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let netEaseTrackID: String?
    let qqMusicTrackMID: String?
    let qqMusicTrackID: String?
}

protocol OnlineLyricsProviding: Sendable {
    var sourceName: String { get }
    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics?
}

struct LyricsHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

protocol LyricsHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LyricsHTTPResponse
}

struct URLSessionLyricsHTTPTransport: LyricsHTTPTransport {
    private let session: URLSession

    init() {
        session = SecureURLSessionFactory.ephemeral(requestTimeout: 30, resourceTimeout: 45)
    }

    func send(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return LyricsHTTPResponse(data: data, statusCode: response.statusCode, headers: headers)
    }
}

struct ClosureLyricsHTTPTransport: LyricsHTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> LyricsHTTPResponse

    func send(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        try await handler(request)
    }
}

actor LyricsHTTPClient {
    private let transport: any LyricsHTTPTransport
    private var lastRequestByHost: [String: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()

    init(transport: any LyricsHTTPTransport = URLSessionLyricsHTTPTransport()) {
        self.transport = transport
    }

    func data(
        for request: URLRequest,
        minimumInterval: Duration = .milliseconds(800),
        maximumAttempts: Int = 4,
        acceptedStatusCodes: Set<Int> = [200]
    ) async throws -> Data {
        guard let url = request.url, let host = url.host else {
            throw NativeConversionError.message("歌词服务请求地址无效。")
        }
        let scheme = url.scheme?.lowercased()
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw NativeConversionError.message("歌词和翻译服务只允许 HTTPS；仅本机回环地址允许 HTTP。")
        }
        var delay = Duration.seconds(1)
        var lastError: Error = URLError(.unknown)
        for attempt in 1...max(1, maximumAttempts) {
            try Task.checkCancellation()
            if let previous = lastRequestByHost[host] {
                let elapsed = previous.duration(to: clock.now)
                if elapsed < minimumInterval { try await Task.sleep(for: minimumInterval - elapsed) }
            }
            lastRequestByHost[host] = clock.now
            do {
                let response = try await transport.send(request)
                if acceptedStatusCodes.contains(response.statusCode) { return response.data }
                if response.statusCode == 404 { throw LyricsProviderError.notFound }
                guard [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(response.statusCode),
                      attempt < maximumAttempts else {
                    throw LyricsProviderError.httpStatus(response.statusCode)
                }
                let retry = Self.retryAfter(response.headers) ?? delay
                try await Task.sleep(for: retry)
                delay = min(delay * 2, .seconds(16))
            } catch is CancellationError {
                throw CancellationError()
            } catch LyricsProviderError.notFound {
                throw LyricsProviderError.notFound
            } catch {
                lastError = error
                guard attempt < maximumAttempts else { break }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(16))
            }
        }
        throw lastError
    }

    private static func retryAfter(_ headers: [String: String]) -> Duration? {
        guard let text = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value, let seconds = Int(text), seconds > 0 else { return nil }
        return .seconds(min(seconds, 120))
    }
}

enum LyricsProviderError: LocalizedError, Sendable {
    case notFound
    case invalidResponse(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notFound: return "没有找到歌词。"
        case .invalidResponse(let reason): return "歌词服务响应无效：\(reason)"
        case .httpStatus(let status): return "歌词服务请求失败（HTTP \(status)）。"
        }
    }
}

struct NetEaseLyricsProvider: OnlineLyricsProviding {
    let sourceName = "NetEase Cloud Music"
    private let client: LyricsHTTPClient
    private let cache: LyricsCache

    init(
        client: LyricsHTTPClient = LyricsHTTPClient(),
        cache: LyricsCache = LyricsCache(
            lifetime: LyricsCache.onlineContentLifetime,
            namespace: "OnlineLyrics-v1"
        )
    ) {
        self.client = client
        self.cache = cache
    }

    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics? {
        guard let id = query.netEaseTrackID?.nonempty else { return nil }
        let cacheKey = try LyricsCache.key(
            schema: "online-lyrics-v1",
            source: sourceName,
            payload: query
        )
        if let cached = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<TrackLyrics>.self
        ) {
            return cached.value
        }
        let stale = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<TrackLyrics>.self,
            allowExpired: true
        )
        do {
            let result = try await fetchLyrics(query: query, id: id)
            try? await cache.store(OptionalDiskCacheValue(value: result), for: cacheKey)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let stale { return stale.value }
            throw error
        }
    }

    private func fetchLyrics(query: LyricsTrackQuery, id: String) async throws -> TrackLyrics? {
        var lastError: Error?
        for host in ["music.163.com", "interface.music.163.com", "interface3.music.163.com"] {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/api/song/lyric"
            components.queryItems = [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "lv", value: "-1"),
                URLQueryItem(name: "kv", value: "-1"), URLQueryItem(name: "tv", value: "-1"),
                URLQueryItem(name: "rv", value: "-1"), URLQueryItem(name: "yv", value: "-1"),
                URLQueryItem(name: "ytv", value: "-1"), URLQueryItem(name: "yrv", value: "-1"),
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.setValue(IOSNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            do {
                let data = try await client.data(for: request)
                let response = try JSONDecoder().decode(NetEaseLyricsResponse.self, from: data)
                if response.uncollected == true { return nil }
                let original = Self.cleanLRC(response.lrc?.lyric)
                let translated = Self.cleanLRC(response.tlyric?.lyric)
                let romanized = Self.cleanLRC(response.romalrc?.lyric)
                let instrumental = response.nolyric == true || LyricsText.isInstrumentalPlaceholder(original)
                if !instrumental, !LyricsText.hasSubstantiveContent(original ?? "") { return nil }
                return TrackLyrics(
                    original: LyricsArtifacts.plainText(fromLRC: original),
                    synced: LyricsArtifacts.isSyncedLRC(original) ? original : nil,
                    translated: LyricsArtifacts.plainText(fromLRC: translated),
                    translatedSynced: LyricsArtifacts.mergeSynced(original: original, translated: translated),
                    romanized: romanized,
                    source: sourceName,
                    translationProvider: translated?.nonempty == nil ? nil : sourceName,
                    translationModel: nil,
                    machineTranslated: false,
                    instrumental: instrumental
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func cleanLRC(_ value: String?) -> String? {
        guard var text = value?.htmlDecoded.nonempty else { return nil }
        text = text.replacingOccurrences(
            of: #"(\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?)-\d+\]"#,
            with: "$1]",
            options: .regularExpression
        )
        return text
    }
}

private struct NetEaseLyricsResponse: Decodable {
    let uncollected: Bool?
    let nolyric: Bool?
    let lrc: NetEaseLyricsPart?
    let tlyric: NetEaseLyricsPart?
    let romalrc: NetEaseLyricsPart?
}

private struct NetEaseLyricsPart: Decodable { let lyric: String? }

struct QQMusicLyricsProvider: OnlineLyricsProviding {
    let sourceName = "QQ Music"
    private let client: LyricsHTTPClient
    private let cache: LyricsCache

    init(
        client: LyricsHTTPClient = LyricsHTTPClient(),
        cache: LyricsCache = LyricsCache(
            lifetime: LyricsCache.onlineContentLifetime,
            namespace: "OnlineLyrics-v1"
        )
    ) {
        self.client = client
        self.cache = cache
    }

    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics? {
        guard let mid = query.qqMusicTrackMID?.nonempty else { return nil }
        let cacheKey = try LyricsCache.key(
            schema: "online-lyrics-v1",
            source: sourceName,
            payload: query
        )
        if let cached = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<TrackLyrics>.self
        ) {
            return cached.value
        }
        let stale = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<TrackLyrics>.self,
            allowExpired: true
        )
        do {
            let result = try await fetchLyrics(query: query, mid: mid)
            try? await cache.store(OptionalDiskCacheValue(value: result), for: cacheKey)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let stale { return stale.value }
            throw error
        }
    }

    private func fetchLyrics(query: LyricsTrackQuery, mid: String) async throws -> TrackLyrics? {
        let body = QQMusicLyricsRequest(
            comm: .init(ct: 11, cv: "12080008", v: "12080008"),
            request: .init(
                module: "music.musichallSong.PlayLyricInfo",
                method: "GetPlayLyricInfo",
                param: .init(songMID: mid, trans: 1, roma: 1, qrc: 0, crypt: 0)
            )
        )
        let encoded = try JSONEncoder().encode(body)
        var lastError: Error?
        for host in ["u.y.qq.com", "u6.y.qq.com"] {
            guard let url = URL(string: "https://\(host)/cgi-bin/musicu.fcg") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = encoded
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(IOSNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            do {
                let data = try await client.data(for: request)
                let response = try JSONDecoder().decode(QQMusicLyricsResponse.self, from: data)
                guard response.code == 0 else { throw LyricsProviderError.invalidResponse("QQ 顶层代码 \(response.code)") }
                guard let result = response.request else { throw LyricsProviderError.invalidResponse("缺少 req_1") }
                if result.code == 24_001 { return nil }
                guard result.code == 0 else { throw LyricsProviderError.invalidResponse("QQ 歌词代码 \(result.code)") }
                let original = Self.decodeLyrics(result.data?.lyric)
                let translated = Self.decodeLyrics(result.data?.trans)
                let romanized = Self.decodeLyrics(result.data?.roma)
                let instrumental = LyricsText.isInstrumentalPlaceholder(original)
                if !instrumental, !LyricsText.hasSubstantiveContent(original ?? "") { return nil }
                return TrackLyrics(
                    original: LyricsArtifacts.plainText(fromLRC: original),
                    synced: LyricsArtifacts.isSyncedLRC(original) ? original : nil,
                    translated: LyricsArtifacts.plainText(fromLRC: translated),
                    translatedSynced: LyricsArtifacts.mergeSyncedBySequence(original: original, translated: translated),
                    romanized: romanized,
                    source: sourceName,
                    translationProvider: translated?.nonempty == nil ? nil : sourceName,
                    translationModel: nil,
                    machineTranslated: false,
                    instrumental: instrumental
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    static func decodeLyrics(_ value: String?) -> String? {
        guard var text = value?.htmlDecoded.nonempty else { return nil }
        if text.count >= 128, text.allSatisfy({ $0.isHexDigit }) { return nil }
        if text.count.isMultiple(of: 4),
           text.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil,
           let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8)?.nonempty {
            text = decoded
        }
        return text
    }
}

private struct QQMusicLyricsRequest: Encodable {
    struct Comm: Encodable { let ct: Int; let cv: String; let v: String }
    struct Request: Encodable {
        struct Param: Encodable { let songMID: String; let trans: Int; let roma: Int; let qrc: Int; let crypt: Int }
        let module: String; let method: String; let param: Param
    }
    let comm: Comm
    let request: Request
    enum CodingKeys: String, CodingKey { case comm; case request = "req_1" }
}

private struct QQMusicLyricsResponse: Decodable {
    struct Request: Decodable {
        struct Payload: Decodable { let lyric: String?; let trans: String?; let roma: String? }
        let code: Int
        let data: Payload?
    }
    let code: Int
    let request: Request?
    enum CodingKeys: String, CodingKey { case code; case request = "req_1" }
}

struct LRCLIBLyricsProvider: OnlineLyricsProviding {
    let sourceName = "LRCLIB"
    private let client: LyricsHTTPClient
    private let cache: LyricsCache

    init(
        client: LyricsHTTPClient = LyricsHTTPClient(),
        cache: LyricsCache = LyricsCache(
            lifetime: LyricsCache.onlineContentLifetime,
            namespace: "OnlineLyrics-v1"
        )
    ) {
        self.client = client
        self.cache = cache
    }

    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics? {
        let cacheKey = try LyricsCache.key(
            schema: "online-lyrics-v1",
            source: sourceName,
            payload: query
        )
        if let cached = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<TrackLyrics>.self
        ) {
            return cached.value
        }
        let stale = await cache.value(
            for: cacheKey,
            as: OptionalDiskCacheValue<TrackLyrics>.self,
            allowExpired: true
        )
        do {
            let result = try await fetchLyrics(query: query)
            try? await cache.store(OptionalDiskCacheValue(value: result), for: cacheKey)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let stale { return stale.value }
            throw error
        }
    }

    private func fetchLyrics(query: LyricsTrackQuery) async throws -> TrackLyrics? {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "album_name", value: query.album),
            URLQueryItem(name: "duration", value: String(query.durationSeconds)),
        ]
        do {
            if let candidate = try await fetchOne(exact.url!) {
                return makeLyrics(candidate, detail: "LRCLIB exact match")
            }
        } catch LyricsProviderError.notFound {
            // Continue with scored searches.
        }

        var field = URLComponents(string: "https://lrclib.net/api/search")!
        field.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "album_name", value: query.album),
        ]
        let fieldResults = try await fetchMany(field.url!)
        if let match = best(fieldResults, query: query) { return makeLyrics(match.candidate, detail: "LRCLIB field match (score \(match.score))") }

        var broad = URLComponents(string: "https://lrclib.net/api/search")!
        broad.queryItems = [URLQueryItem(name: "q", value: "\(query.artist) \(query.title)")]
        let broadResults = try await fetchMany(broad.url!)
        guard let match = best(broadResults, query: query) else { return nil }
        return makeLyrics(match.candidate, detail: "LRCLIB broad match (score \(match.score))")
    }

    private func fetchOne(_ url: URL) async throws -> LRCLIBCandidate? {
        var request = URLRequest(url: url)
        request.setValue(IOSNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        do { return try JSONDecoder().decode(LRCLIBCandidate.self, from: await client.data(for: request, minimumInterval: .milliseconds(350))) }
        catch LyricsProviderError.notFound { return nil }
    }

    private func fetchMany(_ url: URL) async throws -> [LRCLIBCandidate] {
        var request = URLRequest(url: url)
        request.setValue(IOSNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return try JSONDecoder().decode([LRCLIBCandidate].self, from: await client.data(for: request, minimumInterval: .milliseconds(350)))
    }

    private func best(_ candidates: [LRCLIBCandidate], query: LyricsTrackQuery) -> (candidate: LRCLIBCandidate, score: Int)? {
        candidates.compactMap { candidate -> (LRCLIBCandidate, Int)? in
            let score = Self.score(candidate, query: query)
            return score >= 85 ? (candidate, score) : nil
        }.max { $0.1 < $1.1 }
    }

    static func score(_ candidate: LRCLIBCandidate, query: LyricsTrackQuery) -> Int {
        let title = DomesticMetadataScorer.matchText(candidate.trackName ?? "")
        let artist = DomesticMetadataScorer.matchText(candidate.artistName ?? "")
        let album = DomesticMetadataScorer.matchText(candidate.albumName ?? "")
        let expectedTitle = DomesticMetadataScorer.matchText(query.title)
        let expectedArtist = DomesticMetadataScorer.matchText(query.artist)
        let expectedAlbum = DomesticMetadataScorer.matchText(query.album)
        var score = title == expectedTitle && !title.isEmpty ? 60 : (title.contains(expectedTitle) || expectedTitle.contains(title) ? 30 : 0)
        score += artist == expectedArtist && !artist.isEmpty ? 30 : (artist.contains(expectedArtist) || expectedArtist.contains(artist) ? 15 : 0)
        score += album == expectedAlbum && !album.isEmpty ? 15 : (album.contains(expectedAlbum) || expectedAlbum.contains(album) ? 8 : 0)
        if let duration = candidate.duration {
            let difference = abs(duration - Double(query.durationSeconds))
            score += difference <= 2 ? 30 : (difference <= 5 ? 10 : 0)
        }
        if candidate.syncedLyrics?.nonempty != nil { score += 5 }
        if candidate.instrumental == true, !LyricsText.isInstrumentalTitle(query.title) { score -= 40 }
        return score
    }

    private func makeLyrics(_ candidate: LRCLIBCandidate, detail: String) -> TrackLyrics? {
        let instrumental = candidate.instrumental == true
        guard instrumental || LyricsText.hasSubstantiveContent(candidate.syncedLyrics ?? candidate.plainLyrics ?? "") else { return nil }
        return TrackLyrics(
            original: candidate.plainLyrics?.nonempty ?? LyricsArtifacts.plainText(fromLRC: candidate.syncedLyrics),
            synced: candidate.syncedLyrics?.nonempty,
            translated: nil,
            translatedSynced: nil,
            romanized: nil,
            source: detail,
            translationProvider: nil,
            translationModel: nil,
            machineTranslated: false,
            instrumental: instrumental
        )
    }
}

struct LRCLIBCandidate: Decodable, Sendable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum IOSNetworkIdentity {
    static var userAgent: String { "CdromDumpToolsIOS/\(IOSAppVersion.current) (+https://github.com/Gavin-LHX/cdrom-dump-tools)" }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var htmlDecoded: String {
        var output = self
        let replacements = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in replacements { output = output.replacingOccurrences(of: entity, with: value) }
        return output
    }
}

extension LyricsText {
    static func isInstrumentalTitle(_ value: String) -> Bool {
        let text = DomesticMetadataScorer.matchText(value)
        return ["instrumental", "offvocal", "karaoke", "伴奏", "纯音乐"].contains { text.contains(DomesticMetadataScorer.matchText($0)) }
    }

    static func isInstrumentalPlaceholder(_ value: String?) -> Bool {
        guard let value else { return false }
        let text = DomesticMetadataScorer.matchText(LyricsArtifacts.plainText(fromLRC: value) ?? value)
        return ["纯音乐请欣赏", "純音楽お楽しみください", "instrumental", "musiconly"].contains {
            text == DomesticMetadataScorer.matchText($0)
        }
    }
}
