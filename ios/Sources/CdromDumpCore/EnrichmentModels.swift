import Foundation

enum DomesticSourcePriority: String, CaseIterable, Codable, Sendable, Identifiable {
    case netEaseFirst
    case qqMusicFirst

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .netEaseFirst: return "网易云 → QQ 音乐"
        case .qqMusicFirst: return "QQ 音乐 → 网易云"
        }
    }
}

enum LyricsTranslationMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case auto
    case ai
    case google
    case aiThenGoogle
    case googleThenAI

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "不自动翻译"
        case .auto: return "自动（AI 优先）"
        case .ai: return "仅 AI"
        case .google: return "Google / 微软 / 免 Key"
        case .aiThenGoogle: return "AI → Google → 微软 → 免 Key"
        case .googleThenAI: return "Google → 微软 → AI → 免 Key"
        }
    }
}

enum AITranslationProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case openAI
    case anthropic

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return "自动（OpenAI → Anthropic）"
        case .openAI: return "OpenAI 兼容接口"
        case .anthropic: return "Anthropic 兼容接口"
        }
    }
}

struct TranslationServiceConfiguration: Sendable {
    var mode: LyricsTranslationMode = .auto
    var aiProvider: AITranslationProvider = .auto

    var openAIAPIKey = ""
    var openAIBaseURL = "https://api.openai.com/v1"
    var openAIModel = "gpt-5-mini"
    var openAIOrganization = ""
    var openAIProject = ""

    var anthropicAPIKey = ""
    var anthropicBaseURL = "https://api.anthropic.com/v1"
    var anthropicModel = "claude-sonnet-4-6"
    var anthropicVersion = "2023-06-01"

    var googleCloudAPIKey = ""
    var microsoftTranslatorAPIKey = ""
    var microsoftTranslatorRegion = ""
    var microsoftTranslatorEndpoint = "https://api.cognitive.microsofttranslator.com"

    var customSystemPrompt = ""

    var hasConfiguredAI: Bool {
        !openAIAPIKey.trimmed.isEmpty || !anthropicAPIKey.trimmed.isEmpty
    }

    var hasConfiguredOfficialTranslation: Bool {
        !googleCloudAPIKey.trimmed.isEmpty || !microsoftTranslatorAPIKey.trimmed.isEmpty
    }
}

struct EnrichedTrackMetadata: Identifiable, Codable, Hashable, Sendable {
    let position: Int
    var title: String
    var artist: String
    var recordingID: String?
    var isrc: String?
    var netEaseTrackID: String?
    var qqMusicTrackMID: String?
    var qqMusicTrackID: String?
    var tagSource: String
    var lyrics: TrackLyrics?

    var id: Int { position }
}

struct EnrichedAlbumMetadata: Codable, Hashable, Sendable {
    var title: String
    var artist: String
    var date: String?
    var genre: String?
    var musicBrainzReleaseID: String?
    var netEaseAlbumID: String?
    var qqMusicAlbumMID: String?
    var tagSource: String
    var coverSource: String?
    var sourceNotes: [String]
    var tracks: [EnrichedTrackMetadata]

    var year: String? {
        guard let date, date.count >= 4 else { return nil }
        let prefix = String(date.prefix(4))
        return prefix.allSatisfy(\.isNumber) ? prefix : nil
    }
}

struct TrackLyrics: Codable, Hashable, Sendable {
    var original: String?
    var synced: String?
    var translated: String?
    var translatedSynced: String?
    var romanized: String?
    var source: String
    var translationProvider: String?
    var translationModel: String?
    var machineTranslated: Bool
    var instrumental: Bool

    var hasSubstantiveText: Bool {
        [synced, original, translatedSynced, translated].contains { value in
            guard let value else { return false }
            return LyricsText.hasSubstantiveContent(value)
        }
    }

    var hasChineseContent: Bool {
        [translatedSynced, translated, synced, original].contains { value in
            guard let value else { return false }
            return LyricsText.containsLikelyChinese(value)
        }
    }
}

struct MetadataEnrichmentResult: Sendable {
    var album: EnrichedAlbumMetadata
    var coverData: Data?
    var sourceNotes: [String]
}

struct LyricsPipelineOptions: Sendable {
    var useNetEase = true
    var useQQMusic = true
    var useLRCLIB = true
    var translateMissingChinese = true
    var translation = TranslationServiceConfiguration()
}

enum LyricsText {
    static func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    static func containsLikelyChinese(_ value: String) -> Bool {
        var han = 0
        var kana = 0
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                han += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                kana += 1
            default:
                break
            }
        }
        guard han >= 2 else { return false }
        // Platform responses occasionally put the Japanese original into the
        // translation field.  A conservative kana ratio prevents that result
        // from suppressing QQ/LRCLIB or the machine-translation fallback.
        return kana == 0 || (han >= 6 && han >= kana * 2)
    }

    static func hasSubstantiveContent(_ value: String) -> Bool {
        let stripped = value
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .lowercased()
        guard !stripped.isEmpty else { return false }
        let placeholders = ["instrumental", "纯音乐", "暂无歌词", "无歌词", "music only"]
        return !placeholders.contains(where: { stripped.contains($0.replacingOccurrences(of: " ", with: "")) })
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
