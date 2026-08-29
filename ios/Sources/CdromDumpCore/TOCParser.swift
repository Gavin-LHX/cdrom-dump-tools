import Foundation

enum TOCParser {
    private struct PendingTrack {
        var number: Int
        var type: String
        var sourceFile: String?
        var startSpec: String?
        var lengthSpec: String?
        var pregapSpec: String?
        var isrc: String?
        var hasPreEmphasis = false
    }

    static func parse(url: URL, binSize: Int64) throws -> [CDTrack] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw NativeConversionError.message("TOC 文件不是可识别的文本编码。")
        }
        return try parse(text: text, binSize: binSize)
    }

    static func parse(text: String, binSize: Int64) throws -> [CDTrack] {
        guard binSize > 0 else {
            throw NativeConversionError.message("BIN 文件为空。")
        }

        var pending: [PendingTrack] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("//"), !line.hasPrefix("#") else { continue }

            let tokens = tokenize(line)
            guard let keyword = tokens.first?.uppercased() else { continue }
            switch keyword {
            case "TRACK":
                guard tokens.count >= 2 else {
                    throw NativeConversionError.message("TOC 的 TRACK 行缺少轨道类型：\(line)")
                }
                let type = tokens[1].uppercased()
                guard type == "AUDIO" else {
                    throw NativeConversionError.message("TOC 包含非音频轨道 \(type)；iOS 版只处理 CD-DA。")
                }
                guard tokens.count == 2 else {
                    throw NativeConversionError.message("不支持带 RW/RW_RAW 子通道数据的 TRACK AUDIO。")
                }
                pending.append(PendingTrack(number: pending.count + 1, type: type))

            case "FILE", "AUDIOFILE":
                guard !pending.isEmpty else {
                    throw NativeConversionError.message("TOC 在首个 TRACK 之前出现了 FILE。")
                }
                guard tokens.count >= 3 else {
                    throw NativeConversionError.message("TOC 的 FILE 行不完整：\(line)")
                }
                guard pending[pending.count - 1].startSpec == nil else {
                    throw NativeConversionError.message("第 \(pending.count) 轨使用了多个源片段，暂不支持。")
                }
                pending[pending.count - 1].sourceFile = tokens[1]
                pending[pending.count - 1].startSpec = tokens[2]
                pending[pending.count - 1].lengthSpec = tokens.count >= 4 ? tokens[3] : nil

            case "START":
                guard !pending.isEmpty, tokens.count >= 2 else {
                    throw NativeConversionError.message("TOC 的 START 行位置或内容无效：\(line)")
                }
                pending[pending.count - 1].pregapSpec = tokens[1]

            case "ISRC":
                guard !pending.isEmpty, tokens.count >= 2 else { continue }
                pending[pending.count - 1].isrc = tokens[1]

            case "PRE_EMPHASIS":
                guard !pending.isEmpty else { continue }
                pending[pending.count - 1].hasPreEmphasis = true

            case "NO", "TWO_CHANNEL_AUDIO", "CD_DA", "CATALOG", "CD_TEXT", "LANGUAGE_MAP", "LANGUAGE", "TITLE", "PERFORMER", "SONGWRITER", "COMPOSER", "ARRANGER", "MESSAGE", "DISC_ID", "UPC_EAN", "COPY":
                continue

            case "FOUR_CHANNEL_AUDIO", "SILENCE", "PREGAP", "FIFO", "DATAFILE":
                throw NativeConversionError.message("iOS 原生转换器暂不支持 TOC 指令 \(keyword)。")

            default:
                continue
            }
        }

        guard !pending.isEmpty else {
            throw NativeConversionError.message("TOC 中没有找到音频轨道。")
        }

        var result: [CDTrack] = []
        for item in pending {
            guard let sourceFile = item.sourceFile, let startSpec = item.startSpec else {
                throw NativeConversionError.message("第 \(item.number) 轨没有 FILE/AUDIOFILE 源片段。")
            }
            let offset = try positionToBytes(startSpec)
            let parsedLength: Int64?
            if let lengthSpec = item.lengthSpec {
                let value = try positionToBytes(lengthSpec)
                parsedLength = value == 0 ? nil : value
            } else {
                parsedLength = nil
            }
            let length = parsedLength ?? (binSize - offset)
            let pregap = try item.pregapSpec.map(positionToBytes) ?? 0

            guard offset >= 0, length > 0, pregap >= 0 else {
                throw NativeConversionError.message("第 \(item.number) 轨的字节范围无效。")
            }
            guard offset <= binSize, length <= binSize - offset else {
                throw NativeConversionError.message("第 \(item.number) 轨超出 BIN 文件末尾。")
            }
            guard pregap <= length else {
                throw NativeConversionError.message("第 \(item.number) 轨的 START pregap 超出该轨长度。")
            }
            guard offset % 4 == 0, length % 4 == 0, pregap % 4 == 0 else {
                throw NativeConversionError.message("第 \(item.number) 轨未按 16-bit 双声道样本对齐。")
            }
            result.append(CDTrack(
                number: item.number,
                sourceFile: sourceFile,
                offsetBytes: offset,
                lengthBytes: length,
                pregapBytes: pregap,
                isrc: item.isrc,
                hasPreEmphasis: item.hasPreEmphasis
            ))
        }

        let sourceFiles = Set(result.map { URL(fileURLWithPath: $0.sourceFile).lastPathComponent.lowercased() })
        guard sourceFiles.count == 1 else {
            throw NativeConversionError.message("TOC 引用了多个不同源文件；iOS 版一次只接受一个 BIN。")
        }

        for pair in zip(result, result.dropFirst()) {
            guard pair.0.offsetBytes <= pair.1.offsetBytes else {
                throw NativeConversionError.message("TOC 的轨道偏移不是递增顺序。")
            }
            guard pair.0.offsetBytes + pair.0.lengthBytes <= pair.1.offsetBytes else {
                throw NativeConversionError.message("TOC 的第 \(pair.0.number) 与第 \(pair.1.number) 轨范围重叠。")
            }
        }
        return result
    }

    static func positionToBytes(_ value: String) throws -> Int64 {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 3,
           let minutes = Int64(parts[0]),
           let seconds = Int64(parts[1]),
           let frames = Int64(parts[2]) {
            guard minutes >= 0, seconds >= 0, seconds < 60, frames >= 0, frames < 75 else {
                throw NativeConversionError.message("无效的 TOC MSF 位置：\(value)")
            }
            let sectors = try checkedAdd(try checkedMultiply(minutes, 4_500), try checkedAdd(try checkedMultiply(seconds, 75), frames))
            return try checkedMultiply(sectors, 2_352)
        }
        if let samples = Int64(value), samples >= 0 {
            return try checkedMultiply(samples, 4)
        }
        throw NativeConversionError.message("不支持的 TOC 位置：\(value)")
    }

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == "/" && !inQuotes {
                if let next = iterator.next() {
                    if next == "/" { break }
                    current.append(character)
                    current.append(next)
                } else {
                    current.append(character)
                }
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func checkedMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let value = lhs.multipliedReportingOverflow(by: rhs)
        guard !value.overflow else { throw NativeConversionError.message("TOC 位置数值溢出。") }
        return value.partialValue
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let value = lhs.addingReportingOverflow(rhs)
        guard !value.overflow else { throw NativeConversionError.message("TOC 位置数值溢出。") }
        return value.partialValue
    }
}
