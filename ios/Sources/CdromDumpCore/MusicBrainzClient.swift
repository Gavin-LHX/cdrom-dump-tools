import Foundation

struct MusicBrainzClient: Sendable {
    private let session: URLSession
    private let userAgent: String

    init(
        session: URLSession = SecureURLSessionFactory.ephemeral(
            requestTimeout: 30,
            resourceTimeout: 60
        ),
        appVersion: String = IOSAppVersion.current
    ) {
        self.session = session
        self.userAgent = "CdromDumpToolsiOS/\(appVersion) (https://github.com/Gavin-LHX/cdrom-dump-tools)"
    }

    func lookup(tracks: [CDTrack], binSize: Int64) async throws -> [AlbumCandidate] {
        let identity = try DiscIdentity.musicBrainz(tracks: tracks, binSize: binSize)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/discid/\(identity.discID)"
        components.queryItems = [
            URLQueryItem(name: "inc", value: "recordings+artist-credits+release-groups+isrcs"),
            URLQueryItem(name: "toc", value: identity.toc),
            URLQueryItem(name: "cdstubs", value: "no"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else {
            throw NativeConversionError.message("无法构造 MusicBrainz Disc ID 请求。")
        }

        let data = try await request(url: url)
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = root as? [String: Any] else {
            throw NativeConversionError.message("MusicBrainz 返回了无效的 JSON 根对象。")
        }
        let releases = dictionary["releases"] as? [[String: Any]] ?? []
        var candidates: [AlbumCandidate] = []

        for release in releases {
            guard let releaseID = nonempty(release["id"]),
                  let title = nonempty(release["title"]) else { continue }
            let releaseArtist = artistCredit(release["artist-credit"]) ?? "未知艺术家"
            let date = nonempty(release["date"])
            let country = nonempty(release["country"])
            let barcode = nonempty(release["barcode"])
            let media = release["media"] as? [[String: Any]] ?? []

            for (mediumIndex, medium) in media.enumerated() {
                let mediumTracks = medium["tracks"] as? [[String: Any]] ?? []
                let declaredTrackCount = integer(medium["track-count"]) ?? mediumTracks.count
                guard declaredTrackCount == tracks.count, mediumTracks.count == tracks.count else { continue }

                let discs = medium["discs"] as? [[String: Any]] ?? []
                if !discs.isEmpty {
                    let exactDisc = discs.contains { nonempty($0["id"]) == identity.discID }
                    guard exactDisc else { continue }
                }

                let convertedTracks = mediumTracks.enumerated().map { index, rawTrack -> AlbumTrackMetadata in
                    let recording = rawTrack["recording"] as? [String: Any]
                    let trackTitle = nonempty(rawTrack["title"])
                        ?? recording.flatMap { nonempty($0["title"]) }
                        ?? String(format: "Track %02d", index + 1)
                    let trackArtist = artistCredit(rawTrack["artist-credit"])
                        ?? recording.flatMap { artistCredit($0["artist-credit"]) }
                        ?? releaseArtist
                    return AlbumTrackMetadata(
                        position: integer(rawTrack["position"]) ?? index + 1,
                        title: trackTitle,
                        artist: trackArtist,
                        recordingID: recording.flatMap { nonempty($0["id"]) }
                    )
                }.sorted { $0.position < $1.position }

                candidates.append(AlbumCandidate(
                    releaseID: releaseID,
                    mediumPosition: integer(medium["position"]) ?? mediumIndex + 1,
                    title: title,
                    artist: releaseArtist,
                    date: date,
                    country: country,
                    barcode: barcode,
                    tracks: convertedTracks
                ))
            }
        }

        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let leftDate = $0.date ?? "9999"
                let rightDate = $1.date ?? "9999"
                if leftDate != rightDate { return leftDate < rightDate }
                if $0.country != $1.country { return ($0.country ?? "ZZ") < ($1.country ?? "ZZ") }
                return $0.id < $1.id
            }
    }

    func fetchFrontCover(releaseID: String) async throws -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let encoded = releaseID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://coverartarchive.org/release/\(encoded)/front-500") else {
            return nil
        }
        do {
            let data = try await request(url: url, acceptedStatus: [200, 404])
            return data.isEmpty ? nil : data
        } catch let error as HTTPStatusError where error.status == 404 {
            return nil
        }
    }

    private func request(url: URL, acceptedStatus: Set<Int> = [200]) async throws -> Data {
        var delay: UInt64 = 1_000_000_000
        var lastError: Error?
        for attempt in 1...5 {
            var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, image/*;q=0.9", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NativeConversionError.message("服务器响应不是 HTTP。")
                }
                if acceptedStatus.contains(http.statusCode) {
                    if http.statusCode == 404 { throw HTTPStatusError(status: 404) }
                    return data
                }
                let statusError = HTTPStatusError(status: http.statusCode)
                guard [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(http.statusCode), attempt < 5 else {
                    throw statusError
                }
                lastError = statusError
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(UInt64.init)
                try await Task.sleep(nanoseconds: (retryAfter ?? delay / 1_000_000_000) * 1_000_000_000)
                delay = min(delay * 2, 16_000_000_000)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let statusError = error as? HTTPStatusError,
                   ![408, 409, 425, 429, 500, 502, 503, 504, 529].contains(statusError.status) {
                    throw statusError
                }
                lastError = error
                guard attempt < 5 else { break }
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 16_000_000_000)
            }
        }
        throw lastError ?? NativeConversionError.message("网络请求失败。")
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private func artistCredit(_ value: Any?) -> String? {
        guard let entries = value as? [[String: Any]] else { return nil }
        let text = entries.compactMap { entry -> String? in
            guard let name = nonempty(entry["name"]) else { return nil }
            return name + (nonempty(entry["joinphrase"]) ?? "")
        }.joined()
        return text.isEmpty ? nil : text
    }
}

private struct HTTPStatusError: LocalizedError {
    let status: Int
    var errorDescription: String? { "HTTP 请求失败（状态码 \(status)）。" }
}
