import Foundation
import CryptoKit
import Darwin

@main
struct CoreSelfTest {
    static func main() async {
        do {
            try await run()
        } catch {
            let value = error as NSError
            let details = value.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "IOS CORE SELF-TEST ERROR: type=\(String(reflecting: type(of: error))) domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription) userInfo={\(details)}\n".utf8
            ))
            Darwin.exit(1)
        }
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdrom-ios-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("fixture.bin")
        var bin = Data()
        for _ in 0..<588 { bin.append(contentsOf: [0x12, 0x34, 0xff, 0xfe]) }
        for _ in 0..<588 { bin.append(contentsOf: [0x80, 0x00, 0x7f, 0xff]) }
        try bin.write(to: binURL)
        require(sha256(bin) == "70ab904dfa5c7b50c2cdcd02f19f12b2e66dd6d8d76783251c1b755331ca7407", "fixture BIN hash")

        let tocURL = root.appendingPathComponent("fixture.toc")
        let toc = """
        CD_DA
        TRACK AUDIO
        FILE "fixture.bin" 0 00:00:01
        TRACK AUDIO
        FILE "fixture.bin" 588 0
        """
        try toc.write(to: tocURL, atomically: true, encoding: .utf8)
        let tracks = try TOCParser.parse(url: tocURL, binSize: Int64(bin.count))
        require(tracks.count == 2, "TOC track count")
        require(tracks[0].offsetBytes == 0 && tracks[0].lengthBytes == 2_352, "first track range")
        require(tracks[1].offsetBytes == 2_352 && tracks[1].lengthBytes == 2_352, "zero length means EOF")

        let identity = try DiscIdentity.musicBrainz(tracks: tracks, binSize: Int64(bin.count))
        require(identity.trackOffsets == [150, 151], "MusicBrainz offsets")
        require(identity.leadoutSector == 152, "MusicBrainz leadout")

        let pregapTracks = try TOCParser.parse(
            text: """
            CD_DA
            TRACK AUDIO
            FILE "fixture.bin" 0 00:00:01
            START 00:00:01
            TRACK AUDIO
            FILE "fixture.bin" 588 0
            """,
            binSize: Int64(bin.count)
        )
        let pregapIdentity = try DiscIdentity.musicBrainz(tracks: pregapTracks, binSize: Int64(bin.count))
        require(pregapIdentity.trackOffsets[0] == 151, "START contributes to INDEX 01")

        stage("domestic metadata fixture providers")
        try await DomesticMetadataProviderSelfTest.run()
        stage("30-day online provider caches and stale fallback")
        try await OnlineProviderCacheSelfTest.run(root: root)
        stage("lyrics merge, subtitle, and translation fallback")
        try await testLyricsPipeline(root: root)
        stage("enriched WAV tags, lyrics artifacts, metadata, and checksums")
        try testEnrichedWAVOutput(root: root)

        stage("WAV conversion and decoded PCM verification")
        try testConversion(format: .wav, root: root, binURL: binURL, tocURL: tocURL)
        stage("short FLAC conversion and decoded PCM verification")
        try testConversion(format: .flac, root: root, binURL: binURL, tocURL: tocURL)
        stage("chunked FLAC conversion and decoded PCM verification")
        try testFLACAcrossChunkBoundary(root: root)
        print("IOS CORE SELF-TEST PASS: TOC, domestic metadata, lyrics/translation, enriched WAV artifacts, WAV, chunked FLAC, and decoded PCM verification")
    }

    private static func testLyricsPipeline(root: URL) async throws {
        let original = "[00:01.00]Hello\n[00:03.50]World"
        let translated = "[00:01.10]你好\n[00:03.40]世界"
        let merged = LyricsArtifacts.mergeSynced(original: original, translated: translated)
        require(merged?.contains("[00:01.000]你好") == true, "timestamp-tolerant translated LRC merge")
        let srt = LyricsArtifacts.srt(fromLRC: merged, trackDurationMilliseconds: 6_000)
        require(srt?.contains("00:00:01,000 --> 00:00:03,490") == true, "VLC-compatible SRT timeline")
        require(!LyricsText.containsLikelyChinese("これは音楽です"), "Japanese text is not accepted as a Chinese translation")
        require(LyricsText.containsLikelyChinese("这是中文翻译"), "Chinese translation detection")
        require(GenreNormalizer.english("テクノ") == "Techno", "localized genre is normalized to English")
        require(GenreNormalizer.english("Dance 舞曲") == "Dance", "bilingual domestic genre prefers English")
        require(!LyricsText.hasSubstantiveContent("[00:00.00]暂无歌词"), "placeholder filtering")

        let netEaseClient = LyricsHTTPClient(transport: ClosureLyricsHTTPTransport { request in
            guard request.url?.host?.contains("163.com") == true else { throw URLError(.badURL) }
            return LyricsHTTPResponse(
                data: Data(#"{"lrc":{"lyric":"[00:01.00]Hello"},"tlyric":{"lyric":"[00:01.00]你好"},"romalrc":{"lyric":"[00:01.00]hello"}}"#.utf8),
                statusCode: 200,
                headers: [:]
            )
        })
        let online = try await NetEaseLyricsProvider(client: netEaseClient).lyrics(for: LyricsTrackQuery(
            position: 1,
            title: "Hello",
            artist: "Artist",
            album: "Album",
            durationSeconds: 10,
            netEaseTrackID: "1",
            qqMusicTrackMID: nil,
            qqMusicTrackID: nil
        ))
        require(online?.translated == "你好", "NetEase original/translated/romanized decoding")
        require(online?.translatedSynced?.contains("你好") == true, "NetEase bilingual synced lyrics")

        let providerPriorityPipeline = IOSLyricsPipeline(
            netEase: FixedLyricsProvider(
                sourceName: "NetEase Cloud Music",
                result: TrackLyrics(
                    original: "Hello", synced: "[00:01.00]Hello", translated: nil,
                    translatedSynced: nil, romanized: nil, source: "NetEase Cloud Music",
                    translationProvider: nil, translationModel: nil,
                    machineTranslated: false, instrumental: false
                )
            ),
            qqMusic: FixedLyricsProvider(
                sourceName: "QQ Music",
                result: TrackLyrics(
                    original: "Hello", synced: "[00:01.00]Hello", translated: "你好",
                    translatedSynced: "[00:01.00]Hello\n[00:01.00]你好", romanized: nil,
                    source: "QQ Music", translationProvider: "QQ Music", translationModel: nil,
                    machineTranslated: false, instrumental: false
                )
            ),
            lrcLib: FixedLyricsProvider(sourceName: "LRCLIB", result: nil)
        )
        let providerPriorityResult = try await providerPriorityPipeline.lyrics(
            for: LyricsTrackQuery(
                position: 1, title: "Hello", artist: "Artist", album: "Album",
                durationSeconds: 10, netEaseTrackID: "1", qqMusicTrackMID: "mid", qqMusicTrackID: "2"
            ),
            options: LyricsPipelineOptions()
        )
        require(providerPriorityResult?.source == "QQ Music", "foreign NetEase lyrics continue to QQ Chinese translation")

        let translationClient = LyricsHTTPClient(transport: ClosureLyricsHTTPTransport { request in
            guard request.url?.host == "translate.googleapis.com" else { throw URLError(.badURL) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "q" })?.value ?? ""
            let value = query == "Hello" ? "你好" : "世界"
            let json = "[[[\"\(value)\",\"\(query)\",null,null,10]],null,\"en\"]"
            return LyricsHTTPResponse(data: Data(json.utf8), statusCode: 200, headers: [:])
        })
        var configuration = TranslationServiceConfiguration()
        configuration.mode = .google
        let service = LyricsTranslationService(
            client: translationClient,
            cache: LyricsCache(root: root.appendingPathComponent("translation-cache", isDirectory: true))
        )
        let result = await service.translate(
            lines: ["Hello", "World"],
            context: LyricsTranslationContext(title: "Song", artist: "Artist", album: "Album"),
            configuration: configuration
        )
        require(result?.provider == "Google GTX (no key)", "no-key translation fallback order")
        require(result?.lines == ["你好", "世界"], "GTX result reconstruction")

        let japaneseEchoClient = LyricsHTTPClient(transport: ClosureLyricsHTTPTransport { request in
            guard request.url?.host == "translate.googleapis.com" else { throw URLError(.cannotConnectToHost) }
            let source = "世界最後の日、君は笑う"
            let json = "[[[\"\(source)\",\"\(source)\",null,null,10]],null,\"ja\"]"
            return LyricsHTTPResponse(data: Data(json.utf8), statusCode: 200, headers: [:])
        })
        let japaneseEcho = await LyricsTranslationService(
            client: japaneseEchoClient,
            cache: LyricsCache(root: root.appendingPathComponent("japanese-echo-cache", isDirectory: true))
        ).translate(
            lines: ["世界最後の日、君は笑う"],
            context: LyricsTranslationContext(title: "Song", artist: "Artist", album: "Album"),
            configuration: configuration
        )
        require(japaneseEcho == nil, "Japanese echo is not cached or accepted as Chinese translation")

        let openAIClient = LyricsHTTPClient(transport: ClosureLyricsHTTPTransport { request in
            guard request.url?.absoluteString == "https://api.example.test/v1/chat/completions",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key" else {
                throw URLError(.badURL)
            }
            let content = try makeAITranslationJSON(from: request)
            let midpoint = content.index(content.startIndex, offsetBy: content.count / 2)
            let response: [String: Any] = [
                "choices": [[
                    "finish_reason": "stop",
                    "message": ["content": [
                        ["type": "output_text", "text": String(content[..<midpoint])],
                        ["type": "output_text", "text": String(content[midpoint...])],
                    ]],
                ]],
            ]
            return LyricsHTTPResponse(
                data: try JSONSerialization.data(withJSONObject: response),
                statusCode: 200,
                headers: [:]
            )
        })
        var openAIConfiguration = TranslationServiceConfiguration()
        openAIConfiguration.mode = .ai
        openAIConfiguration.aiProvider = .openAI
        openAIConfiguration.openAIAPIKey = "unit-test-key"
        openAIConfiguration.openAIBaseURL = "https://api.example.test/v1"
        openAIConfiguration.openAIModel = "test-model"
        let openAIResult = await LyricsTranslationService(
            client: openAIClient,
            cache: LyricsCache(root: root.appendingPathComponent("openai-cache", isDirectory: true))
        ).translate(
            lines: ["Hello", "World"],
            context: LyricsTranslationContext(title: "Song", artist: "Artist", album: "Album"),
            configuration: openAIConfiguration
        )
        require(openAIResult?.lines == ["你好", "世界"], "OpenAI-compatible structured translation and content parts")

        let anthropicClient = LyricsHTTPClient(transport: ClosureLyricsHTTPTransport { request in
            guard request.url?.absoluteString == "https://anthropic.example.test/v1/messages",
                  request.value(forHTTPHeaderField: "x-api-key") == "anthropic-test-key" else {
                throw URLError(.badURL)
            }
            let content = try makeAITranslationJSON(from: request)
            let midpoint = content.index(content.startIndex, offsetBy: content.count / 2)
            let response: [String: Any] = [
                "stop_reason": "end_turn",
                "content": [
                    ["type": "text", "text": String(content[..<midpoint])],
                    ["type": "text", "text": String(content[midpoint...])],
                ],
            ]
            return LyricsHTTPResponse(
                data: try JSONSerialization.data(withJSONObject: response),
                statusCode: 200,
                headers: [:]
            )
        })
        var anthropicConfiguration = TranslationServiceConfiguration()
        anthropicConfiguration.mode = .ai
        anthropicConfiguration.aiProvider = .anthropic
        anthropicConfiguration.anthropicAPIKey = "anthropic-test-key"
        anthropicConfiguration.anthropicBaseURL = "https://anthropic.example.test/v1"
        anthropicConfiguration.anthropicModel = "claude-test"
        let anthropicResult = await LyricsTranslationService(
            client: anthropicClient,
            cache: LyricsCache(root: root.appendingPathComponent("anthropic-cache", isDirectory: true))
        ).translate(
            lines: ["Hello", "World"],
            context: LyricsTranslationContext(title: "Song", artist: "Artist", album: "Album"),
            configuration: anthropicConfiguration
        )
        require(anthropicResult?.lines == ["你好", "世界"], "Anthropic-compatible structured translation and text block joining")
    }

    private static func testEnrichedWAVOutput(root: URL) throws {
        let binURL = root.appendingPathComponent("enriched-fixture.bin")
        let tocURL = root.appendingPathComponent("enriched-fixture.toc")
        try Data(repeating: 0x5a, count: 75 * 2_352).write(to: binURL)
        try """
        CD_DA
        TRACK AUDIO
        ISRC JPABC2400001
        FILE "enriched-fixture.bin" 0 00:01:00
        """.write(to: tocURL, atomically: true, encoding: .utf8)

        let musicBrainz = AlbumCandidate(
            releaseID: "00000000-0000-4000-8000-000000000001",
            mediumPosition: 1,
            title: "MusicBrainz Fixture Album",
            artist: "MusicBrainz Fixture Artist",
            date: "2023-01-02",
            country: "JP",
            barcode: "0000000000000",
            tracks: [
                AlbumTrackMetadata(
                    position: 1,
                    title: "MusicBrainz Fixture Track",
                    artist: "MusicBrainz Fixture Artist",
                    recordingID: "00000000-0000-4000-8000-000000000002"
                ),
            ]
        )
        let lyrics = TrackLyrics(
            original: "Fixture original\nSecond line",
            synced: "[00:00.10]Fixture original\n[00:00.60]Second line",
            translated: "夹具翻译\n第二行",
            translatedSynced: "[00:00.10]Fixture original\n[00:00.10]夹具翻译\n[00:00.60]Second line\n[00:00.60]第二行",
            romanized: "fikuchaa orijinaru\nsekando rain",
            source: "NetEase fixture",
            translationProvider: "OpenAI-compatible fixture",
            translationModel: "offline-fixture-model",
            machineTranslated: true,
            instrumental: false
        )
        let enrichment = EnrichedAlbumMetadata(
            title: "Fixture Album",
            artist: "Fixture Album Artist",
            date: "2024-02-03",
            genre: "Techno",
            musicBrainzReleaseID: musicBrainz.releaseID,
            netEaseAlbumID: "netease-album-fixture",
            qqMusicAlbumMID: "qq-album-fixture",
            tagSource: "NetEase Cloud Music",
            coverSource: nil,
            sourceNotes: ["offline fixture"],
            tracks: [
                EnrichedTrackMetadata(
                    position: 1,
                    title: "Canonical Song",
                    artist: "Fixture Track Artist",
                    recordingID: musicBrainz.tracks[0].recordingID,
                    isrc: "JPABC2400001",
                    netEaseTrackID: "netease-track-fixture",
                    qqMusicTrackMID: "qq-track-mid-fixture",
                    qqMusicTrackID: "qq-track-id-fixture",
                    tagSource: "NetEase Cloud Music",
                    lyrics: lyrics
                ),
            ]
        )

        let summary = try NativeAudioConverter.convert(
            NativeConversionRequest(
                binURL: binURL,
                tocURL: tocURL,
                outputParentURL: root.appendingPathComponent("output-enriched-wav", isDirectory: true),
                format: .wav,
                verifyAudio: true,
                album: musicBrainz,
                enrichment: enrichment,
                coverData: nil,
                appVersion: IOSAppVersion.fallback
            ),
            progress: { _ in }
        )

        require(summary.outputDirectory.lastPathComponent == "Fixture Album Artist - Fixture Album (2024) [WAV]", "enriched output directory name")
        require(summary.tracks.count == 1 && summary.tracks[0].verified, "enriched WAV decoded PCM verification")
        require(summary.tracks[0].title == "Canonical Song", "enriched canonical track title")
        require(summary.tracks[0].artist == "Fixture Track Artist", "enriched canonical track artist")

        let stem = "01 - Canonical Song"
        let wavURL = summary.outputDirectory.appendingPathComponent("\(stem).wav")
        let lrcURL = summary.outputDirectory.appendingPathComponent("\(stem).lrc")
        let srtRelativePath = "Subtitles/\(stem).srt"
        let srtURL = summary.outputDirectory.appendingPathComponent(srtRelativePath)
        let metadataURL = summary.outputDirectory.appendingPathComponent("metadata.json")
        let lyricsMetadataURL = summary.outputDirectory.appendingPathComponent("lyrics-metadata.json")
        let checksumURL = summary.outputDirectory.appendingPathComponent("SHA256SUMS.txt")

        let wavInfo = try readWAVInfo(wavURL)
        require(wavInfo["INAM"] == "Canonical Song", "WAV INFO title tag")
        require(wavInfo["IART"] == "Fixture Track Artist", "WAV INFO artist tag")
        require(wavInfo["IPRD"] == "Fixture Album", "WAV INFO album tag")
        require(wavInfo["ICRD"] == "2024-02-03", "WAV INFO date tag")
        require(wavInfo["IGNR"] == "Techno", "WAV INFO genre tag")
        require(wavInfo["ISRC"] == "JPABC2400001", "WAV INFO ISRC tag")

        let lrc = try String(contentsOf: lrcURL, encoding: .utf8)
        require(lrc.contains("[00:00.10]Fixture original"), "same-name LRC original line")
        require(lrc.contains("[00:00.10]夹具翻译"), "same-name LRC translated line")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        require(srt.contains("00:00:00,100 --> 00:00:00,590"), "SRT first cue timing")
        require(srt.contains("Fixture original\r\n夹具翻译"), "SRT bilingual cue")

        let decodedMetadata = try JSONDecoder().decode(
            EnrichedAlbumMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        require(decodedMetadata.title == enrichment.title, "metadata.json album title")
        require(decodedMetadata.netEaseAlbumID == enrichment.netEaseAlbumID, "metadata.json NetEase album ID")
        require(decodedMetadata.tracks.first?.qqMusicTrackMID == "qq-track-mid-fixture", "metadata.json QQ track MID")

        guard let lyricsManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: lyricsMetadataURL)
        ) as? [[String: Any]], let firstLyrics = lyricsManifest.first else {
            throw NativeConversionError.message("lyrics-metadata.json fixture could not be decoded.")
        }
        require(firstLyrics["source"] as? String == "NetEase fixture", "lyrics metadata source")
        require(firstLyrics["machineTranslated"] as? Bool == true, "lyrics metadata machine translation flag")
        require(firstLyrics["translationProvider"] as? String == "OpenAI-compatible fixture", "lyrics metadata translation provider")

        let manifest = try readChecksumManifest(checksumURL)
        let requiredManifestEntries = [
            "\(stem).wav",
            "\(stem).lrc",
            srtRelativePath,
            "metadata.json",
            "musicbrainz-metadata.json",
            "lyrics-metadata.json",
            "conversion-metadata.json",
            "audio-verification.json",
            "audio-verification.txt",
            "tracks.m3u8",
        ]
        for relativePath in requiredManifestEntries {
            guard let recordedHash = manifest[relativePath] else {
                throw NativeConversionError.message("SHA256SUMS.txt omitted fixture output: \(relativePath)")
            }
            let fileURL = summary.outputDirectory.appendingPathComponent(relativePath)
            let actualHash = sha256(try Data(contentsOf: fileURL))
            require(recordedHash == actualHash, "checksum matches \(relativePath)")
        }
        require(manifest["SHA256SUMS.txt"] == nil, "checksum manifest does not hash itself")
    }

    private static func readWAVInfo(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw NativeConversionError.message("Enriched WAV fixture is not a RIFF/WAVE file.")
        }

        var fields: [String: String] = [:]
        var cursor = 12
        while cursor + 8 <= data.count {
            let identifier = String(decoding: data[cursor..<(cursor + 4)], as: UTF8.self)
            let size = try readLittleEndianUInt32(data, at: cursor + 4)
            let payloadStart = cursor + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else {
                throw NativeConversionError.message("Enriched WAV fixture contains a truncated chunk.")
            }
            if identifier == "LIST", size >= 4,
               String(decoding: data[payloadStart..<(payloadStart + 4)], as: UTF8.self) == "INFO" {
                var infoCursor = payloadStart + 4
                while infoCursor + 8 <= payloadEnd {
                    let field = String(decoding: data[infoCursor..<(infoCursor + 4)], as: UTF8.self)
                    let fieldSize = try readLittleEndianUInt32(data, at: infoCursor + 4)
                    let valueStart = infoCursor + 8
                    let valueEnd = valueStart + fieldSize
                    guard valueEnd <= payloadEnd else {
                        throw NativeConversionError.message("Enriched WAV fixture contains a truncated INFO field.")
                    }
                    let valueBytes = data[valueStart..<valueEnd].prefix { $0 != 0 }
                    fields[field] = String(decoding: valueBytes, as: UTF8.self)
                    infoCursor = valueEnd + (fieldSize % 2)
                }
            }
            cursor = payloadEnd + (size % 2)
        }
        return fields
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else {
            throw NativeConversionError.message("Fixture UInt32 read exceeded the data boundary.")
        }
        return Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
    }

    private static func readChecksumManifest(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: " *"), marker.lowerBound != line.startIndex else {
                throw NativeConversionError.message("Invalid fixture SHA256SUMS line: \(line)")
            }
            let hash = String(line[..<marker.lowerBound])
            let name = String(line[marker.upperBound...])
            guard hash.count == 64, !name.isEmpty else {
                throw NativeConversionError.message("Invalid fixture SHA256SUMS entry: \(line)")
            }
            result[name] = hash
        }
        return result
    }

    private static func makeAITranslationJSON(from request: URLRequest) throws -> String {
        guard let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]],
              let content = messages.last?["content"] as? String,
              let inputData = content.data(using: .utf8),
              let input = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              let requestID = input["request_id"] as? String,
              let lines = input["lines"] as? [[String: Any]] else {
            throw NativeConversionError.message("AI fixture request was not structured as expected.")
        }
        let translations: [[String: String]] = try lines.map { line in
            guard let id = line["id"] as? String, let text = line["text"] as? String else {
                throw NativeConversionError.message("AI fixture line was not structured as expected.")
            }
            return ["id": id, "text": text == "Hello" ? "你好" : "世界"]
        }
        let output: [String: Any] = [
            "schema": "lyrics-zh-hans-v1",
            "request_id": requestID,
            "lines": translations,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
    }

    private static func testConversion(format: AudioOutputFormat, root: URL, binURL: URL, tocURL: URL) throws {
        let outputParent = root.appendingPathComponent("output-\(format.rawValue)", isDirectory: true)
        let summary = try NativeAudioConverter.convert(
            NativeConversionRequest(
                binURL: binURL,
                tocURL: tocURL,
                outputParentURL: outputParent,
                format: format,
                verifyAudio: true,
                album: nil,
                coverData: nil,
                appVersion: IOSAppVersion.fallback
            ),
            progress: { _ in }
        )
        require(summary.tracks.count == 2, "\(format.rawValue) track count")
        require(summary.audioVerification == "passed", "\(format.rawValue) verification state")
        require(summary.tracks.allSatisfy(\.verified), "\(format.rawValue) per-track verification")
        require(
            summary.tracks.map(\.sourceSegmentSHA256) == [
                "0ca147508e4f0d789ac794d57753aff9f93918ec5d4b787a4a9ecf1cc7a6446b",
                "a5932dab71115b7537307dce4e96d9c50dc1a93ee4af91dc6892a5c55a719802",
            ],
            "\(format.rawValue) source hashes"
        )
        require(
            summary.tracks.map(\.decodedOutputPCMSHA256) == summary.tracks.map { Optional($0.sourceSegmentSHA256) },
            "\(format.rawValue) decoded hashes"
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: summary.outputDirectory.path)
        require(files.contains("conversion-metadata.json"), "\(format.rawValue) metadata manifest")
        require(files.contains("SHA256SUMS.txt"), "\(format.rawValue) checksums")
        require(files.filter { $0.hasSuffix(".\(format.rawValue)") }.count == 2, "\(format.rawValue) output files")
        if format == .flac {
            for name in files.filter({ $0.hasSuffix(".flac") }) {
                let url = summary.outputDirectory.appendingPathComponent(name)
                let header = try Data(contentsOf: url, options: .mappedIfSafe).prefix(4)
                require(header == Data("fLaC".utf8), "FLAC native container marker")
            }
        }
    }

    private static func testFLACAcrossChunkBoundary(root: URL) throws {
        // 112 CD sectors contain 65,856 stereo frames, slightly more than the
        // converter's 65,536-frame input chunk. This catches encoders that lose
        // a buffered tail when the write calls do not end on a FLAC packet.
        let binURL = root.appendingPathComponent("chunk-boundary.bin")
        let tocURL = root.appendingPathComponent("chunk-boundary.toc")
        try Data(repeating: 0x5a, count: 112 * 2_352).write(to: binURL)
        try """
        CD_DA
        TRACK AUDIO
        FILE "chunk-boundary.bin" 0 00:01:37
        """.write(to: tocURL, atomically: true, encoding: .utf8)

        let summary = try NativeAudioConverter.convert(
            NativeConversionRequest(
                binURL: binURL,
                tocURL: tocURL,
                outputParentURL: root.appendingPathComponent("output-flac-chunked", isDirectory: true),
                format: .flac,
                verifyAudio: true,
                album: nil,
                coverData: nil,
                appVersion: IOSAppVersion.fallback
            ),
            progress: { _ in }
        )
        require(summary.tracks.count == 1, "chunked FLAC track count")
        require(summary.tracks[0].sampleCount == 65_856, "chunked FLAC sample count")
        require(summary.tracks[0].verified, "chunked FLAC decoded verification")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stage(_ value: String) {
        FileHandle.standardError.write(Data("IOS CORE SELF-TEST STAGE: \(value)\n".utf8))
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("IOS CORE SELF-TEST FAIL: \(label)\n".utf8))
            Darwin.exit(1)
        }
    }
}

private struct FixedLyricsProvider: OnlineLyricsProviding {
    let sourceName: String
    let result: TrackLyrics?

    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics? {
        result
    }
}
