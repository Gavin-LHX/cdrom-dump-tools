import Foundation

enum DomesticMetadataScorer {
    static func validate(_ anchor: DomesticAlbumAnchor) throws {
        guard anchor.albumAliases.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DomesticMetadataError.invalidAnchor("缺少 MusicBrainz 专辑标题。")
        }
        guard !anchor.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomesticMetadataError.invalidAnchor("缺少 MusicBrainz 专辑艺术家。")
        }
        guard (1...99).contains(anchor.discNumber) else {
            throw DomesticMetadataError.invalidAnchor("光盘序号必须在 1 到 99 之间。")
        }
        guard !anchor.tracks.isEmpty else {
            throw DomesticMetadataError.invalidAnchor("没有可用于时长比对的 CD 音轨。")
        }
        guard anchor.tracks.allSatisfy({ $0.durationMilliseconds > 0 }) else {
            throw DomesticMetadataError.invalidAnchor("CD 音轨时长必须大于零。")
        }
    }

    static func queries(for anchor: DomesticAlbumAnchor) -> [String] {
        guard let album = nonempty(anchor.albumAliases.first) else { return [] }
        return uniqueNonempty(["\(anchor.artist) \(album)", album])
    }

    static func score(
        candidateAlbum: String,
        candidateArtist: String,
        candidateDate: String?,
        candidateDurationsMilliseconds: [Double],
        anchor: DomesticAlbumAnchor,
        resultIndex: Int
    ) -> DomesticAlbumMatchScore {
        let candidateAlbumText = matchText(candidateAlbum)
        let candidateArtistText = matchText(candidateArtist)
        let expectedArtistText = matchText(anchor.artist)
        let aliasTexts = Set(anchor.albumAliases.map(matchText).filter { !$0.isEmpty })

        var baseScore = 0
        var artistScore = 0
        if !candidateAlbumText.isEmpty, aliasTexts.contains(candidateAlbumText) {
            baseScore += 60
        } else if !candidateAlbumText.isEmpty, aliasTexts.contains(where: {
            $0.contains(candidateAlbumText) || candidateAlbumText.contains($0)
        }) {
            baseScore += 30
        }

        if !candidateArtistText.isEmpty, candidateArtistText == expectedArtistText {
            artistScore = 30
        } else if !candidateArtistText.isEmpty,
                  !expectedArtistText.isEmpty,
                  candidateArtistText.contains(expectedArtistText) || expectedArtistText.contains(candidateArtistText) {
            artistScore = 15
        }
        baseScore += artistScore

        if candidateDurationsMilliseconds.count == anchor.tracks.count {
            baseScore += 10
        }
        if let expectedYear = year(anchor.year), year(candidateDate) == expectedYear {
            baseScore += 15
        }
        if resultIndex == 0 {
            baseScore += 5
        }

        let deltas = zip(anchor.tracks, candidateDurationsMilliseconds).map {
            abs($0.0.durationMilliseconds - $0.1)
        }
        let durationMatches = deltas.filter { $0 <= 3_000 }.count
        let nearExactDurationMatches = deltas.filter { $0 <= 750 }.count
        let averageDelta = deltas.isEmpty ? .infinity : deltas.reduce(0, +) / Double(deltas.count)
        let maximumDelta = deltas.max() ?? .infinity
        let denominator = Double(max(1, anchor.tracks.count))
        let durationMatchRatio = Double(durationMatches) / denominator
        let nearExactDurationRatio = Double(nearExactDurationMatches) / denominator
        var durationScore = Int((durationMatchRatio * 100).rounded(.toNearestOrEven))
        durationScore += Int((nearExactDurationRatio * 30).rounded(.toNearestOrEven))
        if averageDelta.isFinite {
            durationScore -= min(25, Int(floor(averageDelta / 200)))
        } else {
            durationScore -= 25
        }

        let totalScore = baseScore + durationScore
        let passedStructuralThreshold = artistScore >= 15
            && baseScore >= 85
            && durationMatchRatio >= 0.8
            && averageDelta <= 2_500
        return DomesticAlbumMatchScore(
            baseScore: baseScore,
            durationScore: durationScore,
            totalScore: totalScore,
            durationMatches: durationMatches,
            nearExactDurationMatches: nearExactDurationMatches,
            averageDurationDeltaMilliseconds: roundedMillisecond(averageDelta),
            maximumDurationDeltaMilliseconds: roundedMillisecond(maximumDelta),
            durationMatchRatio: durationMatchRatio,
            passedStructuralThreshold: passedStructuralThreshold,
            isConfident: passedStructuralThreshold && totalScore >= 180
        )
    }

    static func matchText(_ value: String) -> String {
        let decomposed = value.lowercased().decomposedStringWithCanonicalMapping
        let allowed = CharacterSet.alphanumerics
        let marks = CharacterSet.nonBaseCharacters
        let scalars = decomposed.unicodeScalars.filter {
            !marks.contains($0) && allowed.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap(nonempty).filter { seen.insert($0).inserted }
    }

    static func year(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        let prefix = String(value.prefix(4))
        return prefix.count == 4 && prefix.allSatisfy(\.isNumber) ? prefix : nil
    }

    static func isoDate(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        if let match = value.firstMatch(of: /^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?/) {
            if let day = match.3 { return "\(match.1)-\(match.2!)-\(day)" }
            if let month = match.2 { return "\(match.1)-\(month)" }
            return String(match.1)
        }

        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            let output = DateFormatter()
            output.locale = Locale(identifier: "en_US_POSIX")
            output.timeZone = TimeZone(secondsFromGMT: 0)
            output.dateFormat = "yyyy-MM-dd"
            return output.string(from: date)
        }
        return nil
    }

    static func netEaseDate(milliseconds: Double?) -> String? {
        guard let milliseconds, milliseconds > 0, milliseconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1_000).addingTimeInterval(8 * 60 * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func genres(_ value: String?) -> [String] {
        guard let value = nonempty(value) else { return [] }
        let separators = CharacterSet(charactersIn: ",;；、")
        let values = value.components(separatedBy: separators)
        let parsed = uniqueNonempty(values)
        return parsed.isEmpty ? [value] : parsed
    }

    static func artists(_ values: [DomesticArtistPayload]?, fallback: String? = nil) -> String? {
        let names = uniqueNonempty((values ?? []).compactMap(\.name))
        if !names.isEmpty { return names.joined(separator: " / ") }
        return nonempty(fallback)
    }

    private static func roundedMillisecond(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value * 10).rounded(.toNearestOrEven) / 10
    }
}

struct DomesticArtistPayload: Codable, Hashable, Sendable {
    let name: String?
}

struct DomesticScalar: Codable, Hashable, Sendable {
    let stringValue: String

    var doubleValue: Double? { Double(stringValue) }
    var intValue: Int? {
        if let value = Int(stringValue) { return value }
        guard let value = Double(stringValue), value.isFinite else { return nil }
        return Int(value)
    }

    init(_ value: String) {
        self.stringValue = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            stringValue = value
        } else if let value = try? container.decode(Int64.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Double.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Bool.self) {
            stringValue = String(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a string or scalar JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}
