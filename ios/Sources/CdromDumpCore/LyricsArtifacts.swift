import Foundation

enum LyricsArtifacts {
    struct TimelineEntry: Hashable, Sendable {
        let milliseconds: Int64
        let text: String
        let sequence: Int
    }

    private static let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#

    static func isSyncedLRC(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: timestampPattern, options: .regularExpression) != nil
    }

    static func timeline(fromLRC value: String?) -> [TimelineEntry] {
        guard let value = value?.nonemptyArtifacts else { return [] }
        let timestampRegex = try! NSRegularExpression(pattern: timestampPattern)
        let inlineRegex = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>"#)
        var offset: Int64 = 0
        for line in value.components(separatedBy: .newlines) {
            if let match = line.firstMatch(of: /^\[offset\s*:\s*([+-]?\d+)\]\s*$/),
               let parsed = Int64(match.1) { offset = parsed }
        }

        var result: [TimelineEntry] = []
        var sequence = 0
        for line in value.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = timestampRegex.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }
            var text = timestampRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            let inlineRange = NSRange(text.startIndex..<text.endIndex, in: text)
            text = inlineRegex.stringByReplacingMatches(in: text, range: inlineRange, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let minutes = Int64(line[minuteRange]),
                      let seconds = Int64(line[secondRange]), seconds < 60 else { continue }
                var fraction: Int64 = 0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: line),
                   let value = Int64(line[fractionRange]) {
                    switch line[fractionRange].count {
                    case 1: fraction = value * 100
                    case 2: fraction = value * 10
                    default: fraction = value
                    }
                }
                result.append(TimelineEntry(
                    milliseconds: max(0, ((minutes * 60) + seconds) * 1_000 + fraction + offset),
                    text: text,
                    sequence: sequence
                ))
                sequence += 1
            }
        }
        return result
    }

    static func plainText(fromLRC value: String?) -> String? {
        guard let value = value?.nonemptyArtifacts else { return nil }
        if !isSyncedLRC(value) { return value }
        let lines = timeline(fromLRC: value).map(\.text).filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func mergeSynced(original: String?, translated: String?, maximumDeltaMilliseconds: Int64 = 300) -> String? {
        guard let original = original?.nonemptyArtifacts else { return nil }
        guard let translated = translated?.nonemptyArtifacts,
              !timeline(fromLRC: original).isEmpty,
              !timeline(fromLRC: translated).isEmpty else { return original }

        let originals = groupedTimeline(original)
        let translations = groupedTimeline(translated)
        var used = Set<Int>()
        var merged: [TimelineEntry] = []
        var sequence = 0
        for source in originals {
            if !source.text.isEmpty {
                merged.append(.init(milliseconds: source.milliseconds, text: source.text, sequence: sequence))
                sequence += 1
            }
            let best = translations.indices
                .filter { !used.contains($0) }
                .map { ($0, abs(translations[$0].milliseconds - source.milliseconds)) }
                .min { $0.1 < $1.1 }
            guard let best, best.1 <= maximumDeltaMilliseconds else { continue }
            used.insert(best.0)
            let text = translations[best.0].text
            if !text.isEmpty,
               DomesticMetadataScorer.matchText(text) != DomesticMetadataScorer.matchText(source.text) {
                merged.append(.init(milliseconds: source.milliseconds, text: text, sequence: sequence))
                sequence += 1
            }
        }
        for index in translations.indices where !used.contains(index) && !translations[index].text.isEmpty {
            merged.append(.init(milliseconds: translations[index].milliseconds, text: translations[index].text, sequence: sequence))
            sequence += 1
        }
        return renderLRC(merged)
    }

    static func mergeSyncedBySequence(original: String?, translated: String?) -> String? {
        guard let original = original?.nonemptyArtifacts else { return nil }
        let originals = groupedTimeline(original).filter { !$0.text.isEmpty }
        let translations = groupedTimeline(translated ?? "").filter {
            !$0.text.isEmpty && !isTranslationCreditLine($0.text)
        }
        guard !originals.isEmpty, originals.count == translations.count else {
            return mergeSynced(original: original, translated: translated)
        }
        var merged: [TimelineEntry] = []
        var sequence = 0
        for index in originals.indices {
            let source = originals[index]
            merged.append(.init(milliseconds: source.milliseconds, text: source.text, sequence: sequence))
            sequence += 1
            let translatedText = translations[index].text
            if translatedText != "//", !isTranslationCreditLine(translatedText),
               DomesticMetadataScorer.matchText(translatedText) != DomesticMetadataScorer.matchText(source.text) {
                merged.append(.init(milliseconds: source.milliseconds, text: translatedText, sequence: sequence))
                sequence += 1
            }
        }
        return renderLRC(merged)
    }

    static func mergeMachineTranslation(originalLRC: String?, translatedLines: [String]) throws -> String? {
        guard let originalLRC = originalLRC?.nonemptyArtifacts else { return nil }
        let sourceEntries = timeline(fromLRC: originalLRC).filter {
            !$0.text.isEmpty && !isTranslationCreditLine($0.text)
        }
        guard sourceEntries.count == translatedLines.count else {
            throw NativeConversionError.message("机器翻译歌词行数不一致（\(translatedLines.count)/\(sourceEntries.count)）。")
        }
        var merged: [TimelineEntry] = []
        var sequence = 0
        for (source, translation) in zip(sourceEntries, translatedLines) {
            merged.append(.init(milliseconds: source.milliseconds, text: source.text, sequence: sequence))
            sequence += 1
            let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty,
               DomesticMetadataScorer.matchText(value) != DomesticMetadataScorer.matchText(source.text) {
                merged.append(.init(milliseconds: source.milliseconds, text: value, sequence: sequence))
                sequence += 1
            }
        }
        return renderLRC(merged)
    }

    static func srt(fromLRC value: String?, trackDurationMilliseconds: Int64, maximumCueDurationMilliseconds: Int64 = 8_000) -> String? {
        let timeline = groupedTimeline(value ?? "").filter { !$0.text.isEmpty }
        guard !timeline.isEmpty else { return nil }
        var output: [String] = []
        for index in timeline.indices {
            let start = timeline[index].milliseconds
            var end = start + maximumCueDurationMilliseconds
            if index + 1 < timeline.count, timeline[index + 1].milliseconds > start {
                end = min(end, timeline[index + 1].milliseconds - 10)
            } else if trackDurationMilliseconds > start {
                end = min(end, trackDurationMilliseconds)
            }
            if trackDurationMilliseconds > 0 { end = min(end, trackDurationMilliseconds) }
            end = max(end, start + 1)
            let cueText = timeline[index].text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            output.append(String(index + 1))
            output.append("\(formatSRT(start)) --> \(formatSRT(end))")
            output.append(cueText)
            output.append("")
        }
        return output.joined(separator: "\r\n")
    }

    static func machineTranslationSourceLines(_ lyrics: TrackLyrics) -> [String] {
        if let synced = lyrics.synced, isSyncedLRC(synced) {
            return timeline(fromLRC: synced).filter {
                !$0.text.isEmpty && !isTranslationCreditLine($0.text)
            }.map(\.text)
        }
        return (lyrics.original ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isTranslationCreditLine($0) }
    }

    static func renderPlainMachineTranslation(original: String?, translatedLines: [String]) -> String {
        translatedLines.joined(separator: "\n")
    }

    private static func groupedTimeline(_ value: String) -> [TimelineEntry] {
        let grouped = Dictionary(grouping: timeline(fromLRC: value), by: \.milliseconds)
        return grouped.map { milliseconds, entries in
            let texts = entries.sorted { $0.sequence < $1.sequence }.map(\.text)
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { result, text in
                    if !result.contains(text) { result.append(text) }
                }
            return TimelineEntry(milliseconds: milliseconds, text: texts.joined(separator: "\n"), sequence: entries.map(\.sequence).min() ?? 0)
        }.sorted { $0.milliseconds == $1.milliseconds ? $0.sequence < $1.sequence : $0.milliseconds < $1.milliseconds }
    }

    private static func renderLRC(_ entries: [TimelineEntry]) -> String? {
        let lines = entries.sorted {
            $0.milliseconds == $1.milliseconds ? $0.sequence < $1.sequence : $0.milliseconds < $1.milliseconds
        }.map { "\(formatLRC($0.milliseconds))\($0.text)" }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func formatLRC(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        return String(format: "[%02lld:%02lld.%03lld]", value / 60_000, (value % 60_000) / 1_000, value % 1_000)
    }

    private static func formatSRT(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        return String(
            format: "%02lld:%02lld:%02lld,%03lld",
            value / 3_600_000,
            (value % 3_600_000) / 60_000,
            (value % 60_000) / 1_000,
            value % 1_000
        )
    }

    private static func isTranslationCreditLine(_ value: String) -> Bool {
        value.range(of: #"^(?i:QQ\s*音乐享有|本翻译作品|本翻譯作品)"#, options: .regularExpression) != nil
    }
}

private extension String {
    var nonemptyArtifacts: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
