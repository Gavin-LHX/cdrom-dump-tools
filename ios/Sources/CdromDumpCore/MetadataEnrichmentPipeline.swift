import Foundation

/// Controls the post-MusicBrainz enrichment phase. MusicBrainz remains the
/// identity anchor; domestic services are only allowed to replace display
/// metadata after the full album and every track duration pass the provider's
/// high-confidence checks.
struct MetadataEnrichmentOptions: Sendable {
    var sourcePriority: DomesticSourcePriority = .netEaseFirst
    var useNetEase = true
    var useQQMusic = true
    /// When disabled, domestic matches are still resolved for provider IDs,
    /// artwork and lyrics, but title/artist/date/genre tags stay MusicBrainz.
    var applyDomesticMetadata = true
    var fetchCover = true
    var fetchLyrics = true
    var lyrics = LyricsPipelineOptions()
}

protocol CoverArtworkFetching: Sendable {
    func artwork(from url: URL) async throws -> Data?
    func coverArtArchive(releaseID: String) async throws -> Data?
}

/// Downloads public artwork without cookies or credentials. A domestic cover
/// is attempted before Cover Art Archive, but an invalid/non-image response is
/// never embedded into an audio file.
struct URLSessionCoverArtworkFetcher: CoverArtworkFetching {
    private let session: URLSession
    private let musicBrainz: MusicBrainzClient

    init(appVersion: String = IOSAppVersion.current) {
        let session = SecureURLSessionFactory.ephemeralHTTPSRedirects(
            requestTimeout: 30,
            resourceTimeout: 60
        )
        self.session = session
        musicBrainz = MusicBrainzClient(session: session, appVersion: appVersion)
    }

    init(session: URLSession, appVersion: String = IOSAppVersion.current) {
        self.session = session
        musicBrainz = MusicBrainzClient(session: session, appVersion: appVersion)
    }

    func artwork(from url: URL) async throws -> Data? {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw NativeConversionError.message("封面服务只允许 HTTPS 请求。")
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue(IOSNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/jpeg, image/png;q=0.9, image/*;q=0.6", forHTTPHeaderField: "Accept")

        var delay = Duration.seconds(1)
        var lastError: Error = URLError(.unknown)
        for attempt in 1...4 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if response.statusCode == 404 { return nil }
                guard response.statusCode == 200 else {
                    guard [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(response.statusCode),
                          attempt < 4 else {
                        throw NativeConversionError.message("封面服务返回 HTTP \(response.statusCode)。")
                    }
                    let retry = Self.retryAfter(response) ?? delay
                    try await Task.sleep(for: retry)
                    delay = min(delay * 2, .seconds(16))
                    continue
                }
                guard response.url?.scheme?.lowercased() == "https" else {
                    throw NativeConversionError.message("封面服务发生了不安全的非 HTTPS 重定向。")
                }
                guard !data.isEmpty else { return nil }
                guard data.count <= 16_000_000 else {
                    throw NativeConversionError.message("封面文件超过 16 MB 安全上限。")
                }
                guard Self.isSupportedImage(data) else {
                    throw NativeConversionError.message("封面服务返回的不是受支持的 JPEG/PNG 图片。")
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < 4 else { break }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(16))
            }
        }
        throw lastError
    }

    func coverArtArchive(releaseID: String) async throws -> Data? {
        let data = try await musicBrainz.fetchFrontCover(releaseID: releaseID)
        guard let data, !data.isEmpty else { return nil }
        guard data.count <= 16_000_000, Self.isSupportedImage(data) else {
            throw NativeConversionError.message("Cover Art Archive 返回的封面格式无效。")
        }
        return data
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value), seconds > 0 else { return nil }
        return .seconds(min(seconds, 120))
    }

    private static func isSupportedImage(_ data: Data) -> Bool {
        data.starts(with: [0xff, 0xd8, 0xff])
            || data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }
}

/// Implements the desktop lyrics order exactly: NetEase -> QQ Music ->
/// LRCLIB. It continues past a valid foreign-language lyric looking for a
/// trustworthy Chinese translation, then machine-translates the earliest
/// usable original only when no provider supplied Chinese text.
struct IOSLyricsPipeline: Sendable {
    private let netEase: any OnlineLyricsProviding
    private let qqMusic: any OnlineLyricsProviding
    private let lrcLib: any OnlineLyricsProviding
    private let translator: LyricsTranslationService

    init(
        netEase: any OnlineLyricsProviding = NetEaseLyricsProvider(),
        qqMusic: any OnlineLyricsProviding = QQMusicLyricsProvider(),
        lrcLib: any OnlineLyricsProviding = LRCLIBLyricsProvider(),
        translator: LyricsTranslationService = LyricsTranslationService()
    ) {
        self.netEase = netEase
        self.qqMusic = qqMusic
        self.lrcLib = lrcLib
        self.translator = translator
    }

    func lyrics(
        for query: LyricsTrackQuery,
        options: LyricsPipelineOptions,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> TrackLyrics? {
        let providers: [(enabled: Bool, provider: any OnlineLyricsProviding)] = [
            (options.useNetEase, netEase),
            (options.useQQMusic, qqMusic),
            (options.useLRCLIB, lrcLib),
        ]

        var earliestValid: TrackLyrics?
        for entry in providers where entry.enabled {
            try Task.checkCancellation()
            progress?("歌词 \(query.position)：正在查询 \(entry.provider.sourceName)…")
            do {
                guard let candidate = try await entry.provider.lyrics(for: query),
                      candidate.instrumental || candidate.hasSubstantiveText else {
                    progress?("歌词 \(query.position)：\(entry.provider.sourceName) 无可用结果。")
                    continue
                }
                if earliestValid == nil { earliestValid = candidate }
                if LyricsChineseReliability.containsReliableChinese(candidate) {
                    progress?("歌词 \(query.position)：采用 \(entry.provider.sourceName) 的中文歌词/翻译。")
                    return candidate
                }
                if candidate.instrumental {
                    progress?("歌词 \(query.position)：已确认是纯音乐。")
                    return candidate
                }
                progress?("歌词 \(query.position)：已找到原文，继续寻找中文翻译。")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress?("歌词 \(query.position)：\(entry.provider.sourceName) 暂不可用，继续回退。")
            }
        }

        guard var selected = earliestValid else {
            progress?("歌词 \(query.position)：所有在线歌词源均未匹配。")
            return nil
        }
        guard options.translateMissingChinese,
              !selected.instrumental,
              !LyricsChineseReliability.containsReliableChinese(selected) else {
            return selected
        }

        let sourceLines = LyricsArtifacts.machineTranslationSourceLines(selected)
        guard !sourceLines.isEmpty else { return selected }
        let context = LyricsTranslationContext(
            title: query.title,
            artist: query.artist,
            album: query.album
        )
        guard let translated = await translator.translate(
            lines: sourceLines,
            context: context,
            configuration: options.translation,
            progress: progress
        ) else {
            progress?("歌词 \(query.position)：保留原文，机器翻译回退均不可用。")
            return selected
        }

        selected.translated = LyricsArtifacts.renderPlainMachineTranslation(
            original: selected.original,
            translatedLines: translated.lines
        )
        if LyricsArtifacts.isSyncedLRC(selected.synced) {
            selected.translatedSynced = try LyricsArtifacts.mergeMachineTranslation(
                originalLRC: selected.synced,
                translatedLines: translated.lines
            )
        }
        selected.translationProvider = translated.provider
        selected.translationModel = translated.model
        selected.machineTranslated = true
        return selected
    }
}

/// Rejects common false positives such as Japanese lyrics containing Kanji or
/// a single Chinese copyright/translation credit line. Provider translation
/// fields are trusted more strongly than language inference over originals.
enum LyricsChineseReliability {
    static func containsReliableChinese(_ lyrics: TrackLyrics) -> Bool {
        if containsChineseTranslation(lyrics.translatedSynced)
            || containsChineseTranslation(lyrics.translated) {
            return true
        }

        let original = lyrics.synced ?? lyrics.original ?? ""
        let meaningful = contentLines(original)
        guard !meaningful.isEmpty else { return false }
        let joined = meaningful.joined(separator: "")
        guard !containsKana(joined), !containsHangul(joined) else { return false }
        let hanCount = joined.unicodeScalars.filter(Self.isHan).count
        let letterCount = joined.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        let chineseLineCount = meaningful.filter { line in
            line.unicodeScalars.filter(Self.isHan).count >= 2
        }.count
        return hanCount >= 8
            && chineseLineCount >= min(2, meaningful.count)
            && Double(hanCount) / Double(max(1, letterCount)) >= 0.35
    }

    private static func containsChineseTranslation(_ value: String?) -> Bool {
        guard let value else { return false }
        return containsReliableTranslatedText(value)
    }

    static func containsReliableTranslatedText(_ value: String) -> Bool {
        let joined = contentLines(value).joined(separator: "")
        // Some providers echo Japanese or Korean originals into the
        // translation field. A target-language result may contain Latin
        // names, but any Kana/Hangul means it cannot be accepted as a Chinese
        // translation.
        return !containsKana(joined)
            && !containsHangul(joined)
            && LyricsText.containsLikelyChinese(joined)
    }

    private static func contentLines(_ value: String) -> [String] {
        let plain = LyricsArtifacts.plainText(fromLRC: value) ?? value
        return plain.components(separatedBy: .newlines).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  !LyricsText.isInstrumentalPlaceholder(text),
                  text.range(
                    of: #"^(?i:QQ\s*音乐享有|本翻译作品|本翻譯作品|翻译\s*[:：]|译者\s*[:：])"#,
                    options: .regularExpression
                  ) == nil else { return nil }
            return text
        }
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func containsKana(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3040...0x30ff).contains(scalar.value)
                || (0x31f0...0x31ff).contains(scalar.value)
                || (0xff66...0xff9f).contains(scalar.value)
        }
    }

    private static func containsHangul(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x1100...0x11ff).contains(scalar.value)
                || (0x3130...0x318f).contains(scalar.value)
                || (0xac00...0xd7af).contains(scalar.value)
        }
    }
}

/// Orchestrates the entire post-identification chain while keeping
/// MusicBrainz as the immutable release/disc anchor.
struct MetadataEnrichmentService: Sendable {
    private let netEase: any DomesticAlbumMetadataProviding
    private let qqMusic: any DomesticAlbumMetadataProviding
    private let netEaseTrackFallback: any DomesticTrackFallbackProviding
    private let qqMusicTrackFallback: any DomesticTrackFallbackProviding
    private let lyricsPipeline: IOSLyricsPipeline
    private let artworkFetcher: any CoverArtworkFetching

    init(
        netEase: any DomesticAlbumMetadataProviding = NetEaseMetadataProvider(),
        qqMusic: any DomesticAlbumMetadataProviding = QQMusicMetadataProvider(),
        netEaseTrackFallback: any DomesticTrackFallbackProviding = NetEaseTrackFallbackProvider(),
        qqMusicTrackFallback: any DomesticTrackFallbackProviding = QQMusicTrackFallbackProvider(),
        lyricsPipeline: IOSLyricsPipeline = IOSLyricsPipeline(),
        artworkFetcher: any CoverArtworkFetching = URLSessionCoverArtworkFetcher()
    ) {
        self.netEase = netEase
        self.qqMusic = qqMusic
        self.netEaseTrackFallback = netEaseTrackFallback
        self.qqMusicTrackFallback = qqMusicTrackFallback
        self.lyricsPipeline = lyricsPipeline
        self.artworkFetcher = artworkFetcher
    }

    func enrich(
        musicBrainz album: AlbumCandidate,
        cdTracks: [CDTrack],
        options: MetadataEnrichmentOptions = MetadataEnrichmentOptions(),
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MetadataEnrichmentResult {
        let sortedCDTracks = cdTracks.sorted { $0.number < $1.number }
        guard !sortedCDTracks.isEmpty else {
            throw NativeConversionError.message("没有音轨，无法执行在线元数据补全。")
        }
        let anchor = makeAnchor(album: album, cdTracks: sortedCDTracks)
        try DomesticMetadataScorer.validate(anchor)
        progress?("已用 MusicBrainz 发行版锁定光盘，开始整专多源比对。")

        var matches: [DomesticMetadataSource: DomesticAlbumMetadataMatch] = [:]
        var notes = ["MusicBrainz anchor: \(album.releaseID), disc \(album.mediumPosition)"]

        let providerEntries: [(Bool, any DomesticAlbumMetadataProviding)] = [
            (options.useNetEase, netEase),
            (options.useQQMusic, qqMusic),
        ]
        for entry in providerEntries where entry.0 {
            try Task.checkCancellation()
            let source = entry.1.source
            progress?("正在用 \(source.localizedName) 比对整张专辑与逐轨时长…")
            do {
                let candidates = try await entry.1.searchCandidates(anchor: anchor)
                let sorted = candidates.sorted(by: DomesticMetadataOrdering.isPreferred)
                if let accepted = sorted.first(where: { $0.score.isConfident }) {
                    matches[source] = accepted
                    let ratio = Int((accepted.score.durationMatchRatio * 100).rounded())
                    progress?("\(source.localizedName) 整专验证通过：逐轨匹配 \(ratio)%，平均差 \(Int(accepted.score.averageDurationDeltaMilliseconds.rounded())) ms。")
                    notes.append("\(source.rawValue): accepted \(accepted.albumIdentifier), score \(accepted.score.totalScore), duration ratio \(ratio)%")
                } else if let rejected = sorted.first {
                    progress?("\(source.localizedName) 候选未通过整专/逐轨时长门槛，不写入标签。")
                    notes.append("\(source.rawValue): rejected best candidate, score \(rejected.score.totalScore)")
                } else {
                    progress?("\(source.localizedName) 没有找到整专候选。")
                    notes.append("\(source.rawValue): no candidate")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress?("\(source.localizedName) 暂不可用，继续其他来源。")
                notes.append("\(source.rawValue): unavailable (\(Self.safeErrorName(error)))")
            }
        }

        // A failed whole-album match no longer means losing domestic IDs and
        // canonical track names entirely. Query that source track by track,
        // but only retain results that independently pass strict
        // title/artist/album/version/duration validation. A source with an
        // accepted album is intentionally skipped here to avoid duplicate
        // requests and inconsistent IDs.
        var trackFallbacks: [DomesticMetadataSource: [Int: DomesticTrackFallbackMatch]] = [:]
        let fallbackEntries: [(Bool, any DomesticTrackFallbackProviding)] = [
            (options.useNetEase, netEaseTrackFallback),
            (options.useQQMusic, qqMusicTrackFallback),
        ]
        for entry in fallbackEntries where entry.0 && matches[entry.1.source] == nil {
            let source = entry.1.source
            progress?("\(source.localizedName) 整专未验证，开始逐轨严格匹配…")
            var sourceMatches: [Int: DomesticTrackFallbackMatch] = [:]
            var providerUnavailable = false
            for track in anchor.tracks.sorted(by: { $0.position < $1.position }) {
                try Task.checkCancellation()
                let fallbackAnchor = DomesticTrackFallbackAnchor(
                    position: track.position,
                    titleAliases: track.titleAliases,
                    artist: DomesticMetadataScorer.nonempty(track.artist) ?? album.artist,
                    albumAliases: anchor.albumAliases,
                    durationMilliseconds: track.durationMilliseconds
                )
                do {
                    if let match = try await entry.1.searchTrack(anchor: fallbackAnchor) {
                        sourceMatches[track.position] = match
                        progress?("\(source.localizedName) 逐轨 \(String(format: "%02d", track.position)) 验证通过（时长差 \(Int(match.durationDeltaMilliseconds.rounded())) ms）。")
                    } else {
                        progress?("\(source.localizedName) 逐轨 \(String(format: "%02d", track.position)) 未找到高置信匹配。")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    providerUnavailable = true
                    progress?("\(source.localizedName) 逐轨服务暂不可用，停止该源剩余查询。")
                    notes.append("\(source.rawValue) track fallback unavailable (\(Self.safeErrorName(error)))")
                    break
                }
            }
            if !sourceMatches.isEmpty {
                trackFallbacks[source] = sourceMatches
            }
            if !providerUnavailable {
                notes.append("\(source.rawValue) track fallback: \(sourceMatches.count)/\(anchor.tracks.count) verified")
                progress?("\(source.localizedName) 逐轨严格匹配完成：\(sourceMatches.count)/\(anchor.tracks.count) 首通过。")
            }
        }

        let preferredSources = Self.sourceOrder(options.sourcePriority)
        let orderedMatches = preferredSources.compactMap { matches[$0] }
        var enriched = makeEnrichedAlbum(
            musicBrainz: album,
            cdTracks: sortedCDTracks,
            orderedMatches: orderedMatches,
            allMatches: matches,
            trackFallbacks: trackFallbacks,
            preferredSources: preferredSources,
            applyDomesticMetadata: options.applyDomesticMetadata
        )

        var coverData: Data?
        if options.fetchCover {
            (coverData, enriched.coverSource) = try await fetchCover(
                album: album,
                orderedMatches: orderedMatches,
                progress: progress,
                notes: &notes
            )
        }

        if options.fetchLyrics {
            for index in enriched.tracks.indices {
                try Task.checkCancellation()
                let track = enriched.tracks[index]
                let duration = sortedCDTracks.first(where: { $0.number == track.position })?.duration
                    ?? (sortedCDTracks.indices.contains(index) ? sortedCDTracks[index].duration : 0)
                let query = LyricsTrackQuery(
                    position: track.position,
                    title: track.title,
                    artist: track.artist,
                    album: enriched.title,
                    durationSeconds: max(0, Int(duration.rounded())),
                    netEaseTrackID: track.netEaseTrackID,
                    qqMusicTrackMID: track.qqMusicTrackMID,
                    qqMusicTrackID: track.qqMusicTrackID
                )
                enriched.tracks[index].lyrics = try await lyricsPipeline.lyrics(
                    for: query,
                    options: options.lyrics,
                    progress: progress
                )
            }
            let found = enriched.tracks.filter { $0.lyrics?.hasSubstantiveText == true }.count
            let translated = enriched.tracks.filter { $0.lyrics?.hasChineseContent == true }.count
            notes.append("Lyrics: \(found)/\(enriched.tracks.count) found, \(translated) with Chinese content")
            progress?("歌词链路完成：找到 \(found)/\(enriched.tracks.count)，含中文 \(translated) 首。")
        }

        enriched.sourceNotes = notes
        return MetadataEnrichmentResult(album: enriched, coverData: coverData, sourceNotes: notes)
    }

    private func makeAnchor(album: AlbumCandidate, cdTracks: [CDTrack]) -> DomesticAlbumAnchor {
        let musicBrainzByPosition = Dictionary(uniqueKeysWithValues: album.tracks.map { ($0.position, $0) })
        let tracks = cdTracks.map { track -> DomesticTrackAnchor in
            let metadata = musicBrainzByPosition[track.number]
            return DomesticTrackAnchor(
                position: track.number,
                titleAliases: [metadata?.title ?? String(format: "Track %02d", track.number)],
                artist: metadata?.artist,
                durationMilliseconds: track.duration * 1_000
            )
        }
        return DomesticAlbumAnchor(
            albumAliases: [album.title],
            artist: album.artist,
            year: album.year,
            discNumber: album.mediumPosition,
            tracks: tracks
        )
    }

    private func makeEnrichedAlbum(
        musicBrainz album: AlbumCandidate,
        cdTracks: [CDTrack],
        orderedMatches: [DomesticAlbumMetadataMatch],
        allMatches: [DomesticMetadataSource: DomesticAlbumMetadataMatch],
        trackFallbacks: [DomesticMetadataSource: [Int: DomesticTrackFallbackMatch]],
        preferredSources: [DomesticMetadataSource],
        applyDomesticMetadata: Bool
    ) -> EnrichedAlbumMetadata {
        let netEase = allMatches[.netEase]
        let qqMusic = allMatches[.qqMusic]
        let primary = applyDomesticMetadata ? orderedMatches.first : nil
        let title = applyDomesticMetadata
            ? (firstNonempty(orderedMatches.map(\.title) + [album.title]) ?? album.title)
            : album.title
        let artist = applyDomesticMetadata
            ? (firstNonempty(orderedMatches.map(\.artist) + [album.artist]) ?? album.artist)
            : album.artist
        let date = applyDomesticMetadata
            ? firstNonempty(orderedMatches.compactMap(\.date) + [album.date].compactMap { $0 })
            : album.date
        let genre = applyDomesticMetadata
            ? GenreNormalizer.english(firstNonempty(orderedMatches.map { $0.genres.joined(separator: ", ") }))
            : nil
        let musicBrainzByPosition = Dictionary(uniqueKeysWithValues: album.tracks.map { ($0.position, $0) })
        let domesticTracks = Dictionary(uniqueKeysWithValues: allMatches.values.map { match in
            (match.source, Dictionary(uniqueKeysWithValues: match.tracks.map { ($0.position, $0) }))
        })

        let tracks = cdTracks.enumerated().map { offset, cdTrack -> EnrichedTrackMetadata in
            let musicBrainzTrack = musicBrainzByPosition[cdTrack.number]
                ?? (album.tracks.indices.contains(offset) ? album.tracks[offset] : nil)
            let domesticCandidates: [(DomesticMetadataSource, DomesticTrackMetadata)] = preferredSources.compactMap { source in
                if let wholeAlbumTrack = domesticTracks[source]?[cdTrack.number] {
                    return (source, wholeAlbumTrack)
                }
                if let fallbackTrack = trackFallbacks[source]?[cdTrack.number]?.track {
                    return (source, fallbackTrack)
                }
                return nil
            }
            let candidates = applyDomesticMetadata ? domesticCandidates : []
            let primaryTrack = candidates.first
            let netEaseTrack = netEase?.tracks.first { $0.position == cdTrack.number }
                ?? trackFallbacks[.netEase]?[cdTrack.number]?.track
            let qqTrack = qqMusic?.tracks.first { $0.position == cdTrack.number }
                ?? trackFallbacks[.qqMusic]?[cdTrack.number]?.track
            return EnrichedTrackMetadata(
                position: cdTrack.number,
                title: firstNonempty(candidates.map { $0.1.title } + [musicBrainzTrack?.title].compactMap { $0 })
                    ?? String(format: "Track %02d", cdTrack.number),
                artist: firstNonempty(candidates.map { $0.1.artist } + [musicBrainzTrack?.artist].compactMap { $0 })
                    ?? album.artist,
                recordingID: musicBrainzTrack?.recordingID,
                isrc: cdTrack.isrc,
                netEaseTrackID: netEaseTrack?.numericIdentifier ?? netEaseTrack?.identifier,
                qqMusicTrackMID: qqTrack?.identifier,
                qqMusicTrackID: qqTrack?.numericIdentifier,
                tagSource: primaryTrack?.0.rawValue ?? "MusicBrainz",
                lyrics: nil
            )
        }

        return EnrichedAlbumMetadata(
            title: title,
            artist: artist,
            date: date,
            genre: genre,
            musicBrainzReleaseID: album.releaseID,
            netEaseAlbumID: netEase?.numericAlbumIdentifier ?? netEase?.albumIdentifier,
            qqMusicAlbumMID: qqMusic?.albumIdentifier,
            tagSource: applyDomesticMetadata ? (primary?.source.rawValue ?? "MusicBrainz") : "MusicBrainz",
            coverSource: nil,
            sourceNotes: [],
            tracks: tracks
        )
    }

    private func fetchCover(
        album: AlbumCandidate,
        orderedMatches: [DomesticAlbumMetadataMatch],
        progress: (@Sendable (String) -> Void)?,
        notes: inout [String]
    ) async throws -> (Data?, String?) {
        var seenURLs = Set<URL>()
        for match in orderedMatches {
            guard let url = match.coverURL, seenURLs.insert(url).inserted else { continue }
            try Task.checkCancellation()
            progress?("正在下载 \(match.source.localizedName) 专辑封面…")
            do {
                if let data = try await artworkFetcher.artwork(from: url) {
                    notes.append("Cover: \(match.source.rawValue)")
                    return (data, match.source.rawValue)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress?("\(match.source.localizedName) 封面不可用，继续回退。")
            }
        }

        progress?("正在回退到 Cover Art Archive 封面…")
        do {
            if let data = try await artworkFetcher.coverArtArchive(releaseID: album.releaseID) {
                notes.append("Cover: Cover Art Archive")
                return (data, "Cover Art Archive")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            progress?("Cover Art Archive 封面不可用。")
        }
        notes.append("Cover: unavailable")
        return (nil, nil)
    }

    private func firstNonempty(_ values: [String]) -> String? {
        values.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func sourceOrder(_ priority: DomesticSourcePriority) -> [DomesticMetadataSource] {
        switch priority {
        case .netEaseFirst: return [.netEase, .qqMusic]
        case .qqMusicFirst: return [.qqMusic, .netEase]
        }
    }

    private static func safeErrorName(_ error: Error) -> String {
        switch error {
        case is DomesticMetadataError: return "provider error"
        case is URLError: return "network error"
        default: return "unavailable"
        }
    }
}

private extension DomesticMetadataSource {
    var localizedName: String {
        switch self {
        case .netEase: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        }
    }
}
