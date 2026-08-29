import Foundation

enum GenreNormalizer {
    private static let aliases: [String: String] = [
        "テクノ": "Techno", "科技舞曲": "Techno",
        "エレクトロニカ": "Electronica", "电子": "Electronic", "電子": "Electronic",
        "ロック": "Rock", "摇滚": "Rock", "搖滾": "Rock",
        "ポップ": "Pop", "流行": "Pop",
        "ジャズ": "Jazz", "爵士": "Jazz",
        "クラシック": "Classical", "古典": "Classical",
        "ヒップホップ": "Hip-Hop", "说唱": "Hip-Hop", "說唱": "Hip-Hop",
        "ハウス": "House", "浩室": "House",
        "トランス": "Trance",
        "ドラムンベース": "Drum and Bass",
        "アンビエント": "Ambient",
        "ダンス": "Dance", "舞曲": "Dance",
        "メタル": "Metal", "金属": "Metal", "金屬": "Metal",
        "パンク": "Punk",
        "アニメ": "Anime", "动漫": "Anime", "動漫": "Anime",
        "ゲーム": "Game", "游戏": "Game", "遊戲": "Game",
    ]

    static func english(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.components(separatedBy: CharacterSet(charactersIn: ",;；、/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var output: [String] = []
        for part in parts {
            let normalized = aliases[part]
                ?? extractEnglishFromBilingual(part).map(normalizeKnownEnglish)
                ?? normalizeKnownEnglish(part)
            if !output.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                output.append(normalized)
            }
        }
        return output.isEmpty ? nil : output.prefix(3).joined(separator: ", ")
    }

    private static func extractEnglishFromBilingual(_ value: String) -> String? {
        let patterns = [
            #"^([A-Za-z0-9&+.' -]+?)\s+[\p{Han}\p{Hiragana}\p{Katakana}].*$"#,
            #"^[\p{Han}\p{Hiragana}\p{Katakana}].*?\s+([A-Za-z0-9&+.' -]+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                  ),
                  let range = Range(match.range(at: 1), in: value) else { continue }
            let extracted = String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty { return extracted }
        }
        return nil
    }

    private static func normalizeKnownEnglish(_ value: String) -> String {
        let key = value.lowercased().replacingOccurrences(of: "＆", with: "&")
        let english: [String: String] = [
            "techno": "Techno", "electronic": "Electronic", "electronica": "Electronica",
            "j-pop": "J-Pop", "jpop": "J-Pop", "pop": "Pop", "rock": "Rock",
            "hip-hop": "Hip-Hop", "hip hop": "Hip-Hop", "r&b": "R&B",
            "house": "House", "trance": "Trance", "ambient": "Ambient",
            "drum and bass": "Drum and Bass", "drum & bass": "Drum and Bass",
            "classical": "Classical", "jazz": "Jazz", "metal": "Metal", "punk": "Punk",
        ]
        return english[key] ?? value
    }
}
