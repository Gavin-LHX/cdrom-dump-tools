import Foundation
import AudioToolbox
import CryptoKit

enum NativeAudioConverter {
    private static let sampleRate = 44_100.0
    private static let channels: UInt32 = 2
    private static let bytesPerFrame = 4
    private static let chunkFrames: UInt32 = 65_536

    static func convert(
        _ request: NativeConversionRequest,
        progress: @escaping @Sendable (ConversionProgressEvent) -> Void
    ) throws -> ConversionSummary {
        let attributes = try FileManager.default.attributesOfItem(atPath: request.binURL.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw NativeConversionError.message("无法读取 BIN 文件大小。")
        }
        let binSize = number.int64Value
        let tracks = try TOCParser.parse(url: request.tocURL, binSize: binSize)
        if let album = request.album, album.tracks.count != tracks.count {
            throw NativeConversionError.message("所选专辑有 \(album.tracks.count) 轨，但 TOC 有 \(tracks.count) 轨。")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: request.outputParentURL, withIntermediateDirectories: true)
        let desiredName = outputDirectoryName(album: request.album, format: request.format, fallback: request.binURL.deletingPathExtension().lastPathComponent)
        let finalURL = uniqueDirectory(parent: request.outputParentURL, desiredName: desiredName)
        let partialURL = request.outputParentURL.appendingPathComponent(".\(desiredName).partial.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: partialURL, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: partialURL) }
        }

        if let cover = request.coverData, !cover.isEmpty {
            let extensionName = cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
            try cover.write(to: partialURL.appendingPathComponent("cover.\(extensionName)"), options: .atomic)
            try cover.write(to: partialURL.appendingPathComponent("folder.\(extensionName)"), options: .atomic)
        }

        let input = try FileHandle(forReadingFrom: request.binURL)
        defer { try? input.close() }
        var summaries: [TrackConversionSummary] = []
        var playlist: [String] = ["#EXTM3U"]

        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let metadata = request.album?.tracks.first(where: { $0.position == track.number })
            let title = metadata?.title ?? String(format: "Track %02d", track.number)
            let artist = metadata?.artist ?? request.album?.artist ?? "未知艺术家"
            let stem = safeFileName(String(format: "%02d - %@", track.number, title))
            let fileName = "\(stem).\(request.format.rawValue)"
            let outputURL = partialURL.appendingPathComponent(fileName)
            let trackBaseFraction = Double(index) / Double(tracks.count)
            progress(ConversionProgressEvent(
                currentTrack: index + 1,
                totalTracks: tracks.count,
                fraction: trackBaseFraction,
                message: "正在转换第 \(index + 1)/\(tracks.count) 轨：\(title)"
            ))

            let sourceHash: String
            switch request.format {
            case .wav:
                sourceHash = try writeWAV(
                    input: input,
                    track: track,
                    outputURL: outputURL,
                    onBytes: { completed in
                        let within = Double(completed) / Double(track.lengthBytes)
                        progress(ConversionProgressEvent(
                            currentTrack: index + 1,
                            totalTracks: tracks.count,
                            fraction: (Double(index) + within) / Double(tracks.count),
                            message: "正在写入第 \(index + 1)/\(tracks.count) 轨"
                        ))
                    }
                )
            case .flac:
                sourceHash = try writeFLAC(
                    input: input,
                    track: track,
                    outputURL: outputURL,
                    onBytes: { completed in
                        let within = Double(completed) / Double(track.lengthBytes)
                        progress(ConversionProgressEvent(
                            currentTrack: index + 1,
                            totalTracks: tracks.count,
                            fraction: (Double(index) + within) / Double(tracks.count),
                            message: "正在编码第 \(index + 1)/\(tracks.count) 轨 FLAC"
                        ))
                    }
                )
            }

            try AudioMetadataWriter.write(
                format: request.format,
                url: outputURL,
                tags: AudioTags(
                    title: title,
                    artist: artist,
                    album: request.album?.title,
                    albumArtist: request.album?.artist,
                    date: request.album?.date,
                    trackNumber: track.number,
                    trackTotal: tracks.count,
                    isrc: track.isrc,
                    musicBrainzReleaseID: request.album?.releaseID
                ),
                coverData: request.coverData
            )

            var decodedHash: String?
            var verified = false
            if request.verifyAudio {
                progress(ConversionProgressEvent(
                    currentTrack: index + 1,
                    totalTracks: tracks.count,
                    fraction: (Double(index) + 0.98) / Double(tracks.count),
                    message: "正在无损校验第 \(index + 1)/\(tracks.count) 轨"
                ))
                let verification = try decodedPCMHash(url: outputURL)
                decodedHash = verification.hash
                guard verification.frames == track.frameCount else {
                    throw NativeConversionError.message("第 \(track.number) 轨校验失败：样本数 \(verification.frames)，预期 \(track.frameCount)。")
                }
                guard verification.hash == sourceHash else {
                    throw NativeConversionError.message("第 \(track.number) 轨无损校验失败：解码 PCM 与 BIN 段不一致。")
                }
                verified = true
            }

            summaries.append(TrackConversionSummary(
                number: track.number,
                file: fileName,
                title: title,
                artist: artist,
                sampleCount: track.frameCount,
                sourceSegmentSHA256: sourceHash,
                decodedOutputPCMSHA256: decodedHash,
                verified: verified
            ))
            playlist.append("#EXTINF:\(Int(track.duration.rounded())),\(artist) - \(title)")
            playlist.append(fileName)
        }

        try (playlist.joined(separator: "\n") + "\n").write(
            to: partialURL.appendingPathComponent("tracks.m3u8"),
            atomically: true,
            encoding: .utf8
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = ConversionSummary(
            schema: "cdrom-ios-native-conversion-v1",
            appVersion: request.appVersion,
            createdAt: formatter.string(from: Date()),
            sourceBIN: request.binURL.lastPathComponent,
            sourceTOC: request.tocURL.lastPathComponent,
            outputFormat: request.format.rawValue,
            albumTitle: request.album?.title,
            albumArtist: request.album?.artist,
            musicBrainzReleaseID: request.album?.releaseID,
            audioVerification: request.verifyAudio ? "passed" : "not_requested",
            tracks: summaries,
            outputDirectory: finalURL
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: partialURL.appendingPathComponent("conversion-metadata.json"), options: .atomic)

        try writeChecksums(in: partialURL)
        try Task.checkCancellation()
        try fileManager.moveItem(at: partialURL, to: finalURL)
        published = true
        progress(ConversionProgressEvent(
            currentTrack: tracks.count,
            totalTracks: tracks.count,
            fraction: 1,
            message: "转换与无损校验完成"
        ))
        return summary
    }

    private static func writeWAV(
        input: FileHandle,
        track: CDTrack,
        outputURL: URL,
        onBytes: (Int64) -> Void
    ) throws -> String {
        guard track.lengthBytes <= Int64(UInt32.max) else {
            throw NativeConversionError.message("单轨超过普通 RIFF/WAV 的 4 GiB 限制。")
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        try output.write(contentsOf: wavHeader(dataLength: UInt32(track.lengthBytes)))
        try input.seek(toOffset: UInt64(track.offsetBytes))

        var remaining = track.lengthBytes
        var completed: Int64 = 0
        var hasher = SHA256()
        let chunkSize = Int(chunkFrames) * bytesPerFrame
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(Int64(chunkSize), remaining))
            guard var data = try input.read(upToCount: requested), data.count == requested else {
                throw NativeConversionError.message("读取 BIN 第 \(track.number) 轨时提前到达文件末尾。")
            }
            hasher.update(data: data)
            swapInt16ByteOrder(&data)
            try output.write(contentsOf: data)
            remaining -= Int64(requested)
            completed += Int64(requested)
            onBytes(completed)
        }
        return hex(hasher.finalize())
    }

    private static func writeFLAC(
        input: FileHandle,
        track: CDTrack,
        outputURL: URL,
        onBytes: (Int64) -> Void
    ) throws -> String {
        let framesPerPacket = try flacFramesPerPacket(for: track.frameCount)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var outputReference: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileFLACType,
            &fileFormat,
            nil,
            0,
            &outputReference
        )
        guard createStatus == noErr, let output = outputReference else {
            throw NativeConversionError.message(
                "无法创建原生 FLAC 文件：\(osStatusDescription(createStatus))。请改用 WAV。"
            )
        }
        var needsDispose = true
        defer {
            if needsDispose { ExtAudioFileDispose(output) }
        }

        let clientFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let clientStatus = ExtAudioFileSetProperty(
            output,
            kExtAudioFileProperty_ClientDataFormat,
            clientFormatSize,
            &clientFormat
        )
        guard clientStatus == noErr else {
            throw NativeConversionError.message(
                "无法配置 FLAC 编码器的 CD-DA PCM 输入：\(osStatusDescription(clientStatus))。请改用 WAV。"
            )
        }

        try input.seek(toOffset: UInt64(track.offsetBytes))
        var remaining = track.lengthBytes
        var completed: Int64 = 0
        var hasher = SHA256()
        let chunkSize = Int(chunkFrames) * bytesPerFrame
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(Int64(chunkSize), remaining))
            guard var data = try input.read(upToCount: requested), data.count == requested else {
                throw NativeConversionError.message("读取 BIN 第 \(track.number) 轨时提前到达文件末尾。")
            }
            hasher.update(data: data)
            swapInt16ByteOrder(&data)
            let frameCount = UInt32(requested / bytesPerFrame)
            let writeStatus = data.withUnsafeMutableBytes { source -> OSStatus in
                var audioBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(source.count),
                        mData: source.baseAddress
                    )
                )
                return ExtAudioFileWrite(output, frameCount, &audioBufferList)
            }
            guard writeStatus == noErr else {
                throw NativeConversionError.message("FLAC 编码失败：\(osStatusDescription(writeStatus))")
            }
            remaining -= Int64(requested)
            completed += Int64(requested)
            onBytes(completed)
        }

        let disposeStatus = ExtAudioFileDispose(output)
        needsDispose = false
        guard disposeStatus == noErr else {
            throw NativeConversionError.message("FLAC 编码器未能正常完成文件：\(osStatusDescription(disposeStatus))")
        }
        return hex(hasher.finalize())
    }

    private static func flacFramesPerPacket(for frameCount: Int64) throws -> UInt32 {
        // Apple's FLAC encoder does not flush a final partial packet when used
        // through ExtAudioFile. Pick a legal packet size that divides the track
        // exactly. CD-DA sector-aligned tracks always have 588 as a divisor.
        let largestPreferred = Int(min(frameCount, 4_608))
        if largestPreferred >= 192 {
            for candidate in stride(from: largestPreferred, through: 192, by: -1)
                where frameCount % Int64(candidate) == 0 {
                return UInt32(candidate)
            }
        }
        if frameCount >= 192, frameCount <= 65_535 {
            return UInt32(frameCount)
        }
        throw NativeConversionError.message(
            "该轨的采样数无法被系统 FLAC 编码器完整分包。请改用 WAV。"
        )
    }

    private static func osStatusDescription(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        let bytes = [
            UInt8((raw >> 24) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8(raw & 0xff),
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")' (\(status))"
        }
        return String(status)
    }

    private static func decodedPCMHash(url: URL) throws -> (hash: String, frames: Int64) {
        var fileReference: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &fileReference)
        guard openStatus == noErr, let file = fileReference else {
            throw NativeConversionError.message(
                "无法打开 \(url.lastPathComponent) 进行无损校验：\(osStatusDescription(openStatus))"
            )
        }
        var needsDispose = true
        defer {
            if needsDispose { ExtAudioFileDispose(file) }
        }

        var sourceFormat = AudioStreamBasicDescription()
        var sourceFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let sourceFormatStatus = ExtAudioFileGetProperty(
            file,
            kExtAudioFileProperty_FileDataFormat,
            &sourceFormatSize,
            &sourceFormat
        )
        guard sourceFormatStatus == noErr else {
            throw NativeConversionError.message(
                "无法读取 \(url.lastPathComponent) 的音频格式：\(osStatusDescription(sourceFormatStatus))"
            )
        }
        guard sourceFormat.mSampleRate == sampleRate,
              sourceFormat.mChannelsPerFrame == channels else {
            throw NativeConversionError.message("解码后的音频格式不是 44.1 kHz/双声道 PCM。")
        }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let clientFormatStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard clientFormatStatus == noErr else {
            throw NativeConversionError.message(
                "无法配置 \(url.lastPathComponent) 的 16-bit PCM 校验解码：\(osStatusDescription(clientFormatStatus))"
            )
        }

        var hasher = SHA256()
        var totalFrames: Int64 = 0
        var buffer = Data(count: Int(chunkFrames) * bytesPerFrame)
        while true {
            try Task.checkCancellation()
            var decodedFrames = chunkFrames
            let readStatus = buffer.withUnsafeMutableBytes { storage -> OSStatus in
                var audioBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(storage.count),
                        mData: storage.baseAddress
                    )
                )
                return ExtAudioFileRead(file, &decodedFrames, &audioBufferList)
            }
            if readStatus == kAudioFileEndOfFileError { break }
            guard readStatus == noErr else {
                throw NativeConversionError.message(
                    "解码 \(url.lastPathComponent) 失败：\(osStatusDescription(readStatus))"
                )
            }
            if decodedFrames == 0 { break }

            let byteCount = Int(decodedFrames) * bytesPerFrame
            var decodedData = Data(buffer.prefix(byteCount))
            swapInt16ByteOrder(&decodedData)
            hasher.update(data: decodedData)
            totalFrames += Int64(decodedFrames)
        }

        let disposeStatus = ExtAudioFileDispose(file)
        needsDispose = false
        guard disposeStatus == noErr else {
            throw NativeConversionError.message(
                "关闭 \(url.lastPathComponent) 的校验解码器失败：\(osStatusDescription(disposeStatus))"
            )
        }
        return (hex(hasher.finalize()), totalFrames)
    }

    private static func wavHeader(dataLength: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(36 &+ dataLength)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt32(44_100))
        data.appendLittleEndian(UInt32(176_400))
        data.appendLittleEndian(UInt16(4))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataLength)
        return data
    }

    private static func swapInt16ByteOrder(_ data: inout Data) {
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var index = 0
            while index + 1 < rawBuffer.count {
                let first = base[index]
                base[index] = base[index + 1]
                base[index + 1] = first
                index += 2
            }
        }
    }

    private static func outputDirectoryName(album: AlbumCandidate?, format: AudioOutputFormat, fallback: String) -> String {
        let base: String
        if let album {
            let year = album.year.map { " (\($0))" } ?? ""
            base = "\(album.artist) - \(album.title)\(year) [\(format.rawValue.uppercased())]"
        } else {
            base = "\(fallback) [\(format.rawValue.uppercased())]"
        }
        return safeFileName(base)
    }

    private static func uniqueDirectory(parent: URL, desiredName: String) -> URL {
        let manager = FileManager.default
        var candidate = parent.appendingPathComponent(desiredName, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(desiredName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0000}")
        let components = value.components(separatedBy: invalid)
        let collapsed = components.joined(separator: "_")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((collapsed.isEmpty ? "Untitled" : collapsed).prefix(160))
    }

    private static func writeChecksums(in directory: URL) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NativeConversionError.message("无法枚举输出目录以生成校验和。")
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true, file.lastPathComponent != "SHA256SUMS.txt" { files.append(file) }
        }
        files.sort { $0.path < $1.path }
        let lines = try files.map { file -> String in
            let relative = file.path.replacingOccurrences(of: directory.path + "/", with: "")
            return "\(try fileSHA256(file)) *\(relative)"
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("SHA256SUMS.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
