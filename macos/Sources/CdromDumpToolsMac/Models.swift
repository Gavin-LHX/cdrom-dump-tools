import Foundation

enum AppIdentity {
    static let fallbackVersion = "2.11.0"
    static var version: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return fallbackVersion
    }
    static var defaultMusicBrainzUserAgent: String {
        "CdromDumpToolsMac/\(version) (https://github.com/Gavin-LHX/cdrom-dump-tools)"
    }
}

enum AudioFormat: String, Codable, CaseIterable, Identifiable {
    case flac
    case wav

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum DomesticSourcePriority: String, Codable, CaseIterable, Identifiable {
    case netEaseFirst = "NetEaseFirst"
    case qqMusicFirst = "QQMusicFirst"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .netEaseFirst: return "网易云优先"
        case .qqMusicFirst: return "QQ 音乐优先"
        }
    }
}

enum LyricsTranslationFallback: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case none = "None"
    case google = "Google"
    case ai = "AI"
    case googleThenAI = "GoogleThenAI"
    case aiThenGoogle = "AIThenGoogle"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自动（AI → 正式翻译 → 免 Key 回退）"
        case .none: return "不翻译"
        case .google: return "仅机器翻译"
        case .ai: return "仅 AI"
        case .googleThenAI: return "机器翻译 → AI"
        case .aiThenGoogle: return "AI → 机器翻译"
        }
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case openAI = "OpenAI"
    case anthropic = "Anthropic"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自动选择"
        case .openAI: return "OpenAI / 兼容接口"
        case .anthropic: return "Anthropic / 兼容接口"
        }
    }
}

struct AIConfiguration: Codable, Equatable {
    static let defaultGoogleBaseURL = "https://translation.googleapis.com/language/translate/v2"
    static let defaultMicrosoftBaseURL = "https://api.cognitive.microsofttranslator.com"
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    static let defaultAnthropicBaseURL = "https://api.anthropic.com/v1"
    static let defaultAnthropicVersion = "2023-06-01"

    var googleAPIKey = ""
    var googleBaseURL = defaultGoogleBaseURL
    var microsoftAPIKey = ""
    var microsoftBaseURL = defaultMicrosoftBaseURL
    var microsoftRegion = ""
    var openAIAPIKey = ""
    var openAIBaseURL = defaultOpenAIBaseURL
    var openAIModel = ""
    var openAIOrganizationID = ""
    var openAIProjectID = ""
    var anthropicAPIKey = ""
    var anthropicBaseURL = defaultAnthropicBaseURL
    var anthropicModel = ""
    var anthropicVersion = defaultAnthropicVersion
    var anthropicMaxTokens = 4096
    var promptFile = ""

    enum CodingKeys: String, CodingKey {
        case googleBaseURL, microsoftBaseURL, microsoftRegion
        case openAIBaseURL, openAIModel, openAIOrganizationID, openAIProjectID
        case anthropicBaseURL, anthropicModel, anthropicVersion, anthropicMaxTokens
        case promptFile
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        googleBaseURL = try values.decodeIfPresent(String.self, forKey: .googleBaseURL) ?? Self.defaultGoogleBaseURL
        microsoftBaseURL = try values.decodeIfPresent(String.self, forKey: .microsoftBaseURL) ?? Self.defaultMicrosoftBaseURL
        microsoftRegion = try values.decodeIfPresent(String.self, forKey: .microsoftRegion) ?? ""
        openAIBaseURL = try values.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? Self.defaultOpenAIBaseURL
        openAIModel = try values.decodeIfPresent(String.self, forKey: .openAIModel) ?? ""
        openAIOrganizationID = try values.decodeIfPresent(String.self, forKey: .openAIOrganizationID) ?? ""
        openAIProjectID = try values.decodeIfPresent(String.self, forKey: .openAIProjectID) ?? ""
        anthropicBaseURL = try values.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? Self.defaultAnthropicBaseURL
        anthropicModel = try values.decodeIfPresent(String.self, forKey: .anthropicModel) ?? ""
        anthropicVersion = try values.decodeIfPresent(String.self, forKey: .anthropicVersion) ?? Self.defaultAnthropicVersion
        anthropicMaxTokens = try values.decodeIfPresent(Int.self, forKey: .anthropicMaxTokens) ?? 4096
        promptFile = try values.decodeIfPresent(String.self, forKey: .promptFile) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(googleBaseURL, forKey: .googleBaseURL)
        try values.encode(microsoftBaseURL, forKey: .microsoftBaseURL)
        try values.encode(microsoftRegion, forKey: .microsoftRegion)
        try values.encode(openAIBaseURL, forKey: .openAIBaseURL)
        try values.encode(openAIModel, forKey: .openAIModel)
        try values.encode(openAIOrganizationID, forKey: .openAIOrganizationID)
        try values.encode(openAIProjectID, forKey: .openAIProjectID)
        try values.encode(anthropicBaseURL, forKey: .anthropicBaseURL)
        try values.encode(anthropicModel, forKey: .anthropicModel)
        try values.encode(anthropicVersion, forKey: .anthropicVersion)
        try values.encode(anthropicMaxTokens, forKey: .anthropicMaxTokens)
        try values.encode(promptFile, forKey: .promptFile)
    }
}

struct MacAppSettings: Codable {
    var binPath = ""
    var tocPath = ""
    var environmentPath = ""
    var format = AudioFormat.flac
    var includeMetadata = true
    var includeCover = true
    var includeLyrics = true
    var useNetEase = true
    var useQQMusic = true
    var verifyAudio = true
    var domesticPriority = DomesticSourcePriority.netEaseFirst
    var lyricsFallback = LyricsTranslationFallback.auto
    var aiProvider = AIProvider.auto
    var releaseIndex = 0
    var musicBrainzUserAgent = AppIdentity.defaultMusicBrainzUserAgent
    var openOutputOnSuccess = false
    var rememberAPIKeys = true
    var aiConfiguration = AIConfiguration()
}

struct ReleaseCandidate: Identifiable, Hashable {
    let index: Int
    let artist: String
    let title: String
    let date: String
    let country: String
    let disc: String
    let releaseID: String
    let barcode: String

    var id: Int { index }
}

private struct ReleaseCandidatePayload: Decodable {
    let index: Int
    let artist: String?
    let title: String?
    let date: String?
    let country: String?
    let disc: String?
    let releaseID: String?
    let barcode: String?

    enum CodingKeys: String, CodingKey {
        case index, artist, title, date, country, disc, barcode
        case releaseID = "release_id"
    }
}

enum ReleaseSelectionProtocol {
    static let prefix = "CDROM_DUMP_TOOLS_RELEASE_SELECTION_V1:"
    private static let maximumEncodedLength = 1_000_000
    private static let maximumTextLength = 500

    static func parse(_ line: String) throws -> [ReleaseCandidate] {
        guard line.hasPrefix(prefix) else {
            throw AppError.message("不是 MusicBrainz 候选选择协议行。")
        }
        let encoded = String(line.dropFirst(prefix.count))
        guard !encoded.isEmpty, encoded.utf8.count <= maximumEncodedLength,
              let data = Data(base64Encoded: encoded) else {
            throw AppError.message("MusicBrainz 候选数据不是有效的 Base64。")
        }
        let payloads: [ReleaseCandidatePayload]
        do {
            payloads = try JSONDecoder().decode([ReleaseCandidatePayload].self, from: data)
        } catch {
            throw AppError.message("MusicBrainz 候选 JSON 无法解析。")
        }
        guard (2...1000).contains(payloads.count) else {
            throw AppError.message("MusicBrainz 候选数量无效。")
        }

        var seen = Set<Int>()
        let candidates = try payloads.map { payload -> ReleaseCandidate in
            guard (1...1000).contains(payload.index), seen.insert(payload.index).inserted else {
                throw AppError.message("MusicBrainz 候选序号无效或重复。")
            }
            let title = clean(payload.title)
            guard !title.isEmpty else {
                throw AppError.message("MusicBrainz 候选缺少专辑标题。")
            }
            let artist = clean(payload.artist)
            return ReleaseCandidate(
                index: payload.index,
                artist: artist.isEmpty ? "未知艺术家" : artist,
                title: title,
                date: clean(payload.date),
                country: clean(payload.country),
                disc: clean(payload.disc),
                releaseID: clean(payload.releaseID),
                barcode: clean(payload.barcode)
            )
        }.sorted { $0.index < $1.index }

        guard candidates.enumerated().allSatisfy({ $0.element.index == $0.offset + 1 }) else {
            throw AppError.message("MusicBrainz 候选序号不连续。")
        }
        return candidates
    }

    private static func clean(_ value: String?) -> String {
        let singleLine = (value ?? "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(maximumTextLength))
    }
}

enum ConversionProgress: Equatable {
    case indeterminate(String)
    case determinate(current: Int, total: Int, text: String)
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ConversionRequest {
    let binURL: URL
    let tocURL: URL
    let outputURL: URL?
    let environmentURL: URL?
    let format: AudioFormat
    let includeMetadata: Bool
    let includeCover: Bool
    let includeLyrics: Bool
    let useNetEase: Bool
    let useQQMusic: Bool
    let verifyAudio: Bool
    let domesticPriority: DomesticSourcePriority
    let lyricsFallback: LyricsTranslationFallback
    let aiProvider: AIProvider
    let releaseIndex: Int
    let musicBrainzUserAgent: String
    let aiConfiguration: AIConfiguration
}

struct BundledTools {
    let powerShellURL: URL
    let ffmpegURL: URL
    let converterScriptURL: URL

    static func locate(in bundle: Bundle = .main) throws -> BundledTools {
        guard let resources = bundle.resourceURL else {
            throw AppError.message("应用包缺少 Resources 目录。")
        }
        let powerShell = resources.appendingPathComponent("runtime/powershell/pwsh", isDirectory: false)
        let ffmpeg = resources.appendingPathComponent("runtime/ffmpeg", isDirectory: false)
        let script = resources.appendingPathComponent("bin_to_audio.ps1", isDirectory: false)
        let manager = FileManager.default

        guard manager.isReadableFile(atPath: powerShell.path), manager.isExecutableFile(atPath: powerShell.path) else {
            throw AppError.message("内置 PowerShell 不存在或不可执行：\n\(powerShell.path)")
        }
        guard manager.isReadableFile(atPath: ffmpeg.path), manager.isExecutableFile(atPath: ffmpeg.path) else {
            throw AppError.message("内置 FFmpeg 不存在或不可执行：\n\(ffmpeg.path)")
        }
        guard manager.isReadableFile(atPath: script.path) else {
            throw AppError.message("内置转换脚本不存在：\n\(script.path)")
        }
        return BundledTools(powerShellURL: powerShell, ffmpegURL: ffmpeg, converterScriptURL: script)
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}
