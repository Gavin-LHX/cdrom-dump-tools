import Foundation
import ImageIO

struct AudioTags: Sendable {
    let title: String
    let artist: String
    let album: String?
    let albumArtist: String?
    let date: String?
    let trackNumber: Int
    let trackTotal: Int
    let isrc: String?
    let musicBrainzReleaseID: String?
    let musicBrainzRecordingID: String?
    let genre: String?
    let netEaseAlbumID: String?
    let netEaseTrackID: String?
    let qqMusicAlbumMID: String?
    let qqMusicTrackMID: String?
    let qqMusicTrackID: String?
    let lyrics: TrackLyrics?

    init(
        title: String,
        artist: String,
        album: String?,
        albumArtist: String?,
        date: String?,
        trackNumber: Int,
        trackTotal: Int,
        isrc: String?,
        musicBrainzReleaseID: String?,
        musicBrainzRecordingID: String? = nil,
        genre: String? = nil,
        netEaseAlbumID: String? = nil,
        netEaseTrackID: String? = nil,
        qqMusicAlbumMID: String? = nil,
        qqMusicTrackMID: String? = nil,
        qqMusicTrackID: String? = nil,
        lyrics: TrackLyrics? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.date = date
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.isrc = isrc
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.genre = genre
        self.netEaseAlbumID = netEaseAlbumID
        self.netEaseTrackID = netEaseTrackID
        self.qqMusicAlbumMID = qqMusicAlbumMID
        self.qqMusicTrackMID = qqMusicTrackMID
        self.qqMusicTrackID = qqMusicTrackID
        self.lyrics = lyrics
    }
}

enum AudioMetadataWriter {
    static func write(format: AudioOutputFormat, url: URL, tags: AudioTags, coverData: Data?) throws {
        switch format {
        case .flac:
            try writeFLAC(url: url, tags: tags, coverData: coverData)
        case .wav:
            try appendWAVInfo(url: url, tags: tags)
        }
    }

    private struct FLACBlock {
        let type: UInt8
        let data: Data
    }

    private static func writeFLAC(url: URL, tags: AudioTags, coverData: Data?) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data("fLaC".utf8) else {
            throw NativeConversionError.message("系统编码器生成的文件不是有效 FLAC。")
        }

        var blocks: [FLACBlock] = []
        var foundLast = false
        while !foundLast {
            guard let header = try input.read(upToCount: 4), header.count == 4 else {
                throw NativeConversionError.message("FLAC 元数据头提前结束。")
            }
            foundLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7f
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length <= 16_777_215,
                  let payload = try input.read(upToCount: length), payload.count == length else {
                throw NativeConversionError.message("FLAC 元数据块长度无效。")
            }
            if type != 4 && type != 6 { blocks.append(FLACBlock(type: type, data: payload)) }
        }
        let audioOffset = try input.offset()
        guard blocks.first?.type == 0 else {
            throw NativeConversionError.message("FLAC 缺少首个 STREAMINFO 块。")
        }

        blocks.append(FLACBlock(type: 4, data: vorbisComment(tags)))
        if let coverData, !coverData.isEmpty {
            blocks.append(FLACBlock(type: 6, data: pictureBlock(coverData)))
        }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tags.\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.write(contentsOf: Data("fLaC".utf8))
            for (index, block) in blocks.enumerated() {
                guard block.data.count <= 0x00ff_ffff else {
                    throw NativeConversionError.message("FLAC 元数据块超过 16 MiB 限制。")
                }
                let lastFlag: UInt8 = index == blocks.count - 1 ? 0x80 : 0
                let length = block.data.count
                try output.write(contentsOf: Data([
                    lastFlag | block.type,
                    UInt8((length >> 16) & 0xff),
                    UInt8((length >> 8) & 0xff),
                    UInt8(length & 0xff),
                ]))
                try output.write(contentsOf: block.data)
            }
            try input.seek(toOffset: audioOffset)
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.close()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func vorbisComment(_ tags: AudioTags) -> Data {
        let vendor = Data("CD-ROM Dump Tools iOS \(IOSAppVersion.current)".utf8)
        var comments: [String] = [
            "TITLE=\(clean(tags.title))",
            "ARTIST=\(clean(tags.artist))",
            "TRACKNUMBER=\(tags.trackNumber)",
            "TRACKTOTAL=\(tags.trackTotal)",
        ]
        if let value = tags.album { comments.append("ALBUM=\(clean(value))") }
        if let value = tags.albumArtist { comments.append("ALBUMARTIST=\(clean(value))") }
        if let value = tags.date { comments.append("DATE=\(clean(value))") }
        if let value = tags.isrc { comments.append("ISRC=\(clean(value))") }
        if let value = tags.musicBrainzReleaseID { comments.append("MUSICBRAINZ_ALBUMID=\(clean(value))") }
        if let value = tags.musicBrainzRecordingID { comments.append("MUSICBRAINZ_TRACKID=\(clean(value))") }
        if let value = tags.genre { comments.append("GENRE=\(clean(value))") }
        if let value = tags.netEaseAlbumID { comments.append("NETEASE_ALBUM_ID=\(clean(value))") }
        if let value = tags.netEaseTrackID { comments.append("NETEASE_TRACK_ID=\(clean(value))") }
        if let value = tags.qqMusicAlbumMID { comments.append("QQMUSIC_ALBUM_MID=\(clean(value))") }
        if let value = tags.qqMusicTrackMID { comments.append("QQMUSIC_TRACK_MID=\(clean(value))") }
        if let value = tags.qqMusicTrackID { comments.append("QQMUSIC_TRACK_ID=\(clean(value))") }
        if let lyrics = tags.lyrics {
            if let value = lyrics.original { comments.append("ORIGINAL_LYRICS=\(cleanMultiline(value))") }
            if let value = lyrics.synced { comments.append("ORIGINAL_SYNCED_LYRICS=\(cleanMultiline(value))") }
            if let value = lyrics.translated { comments.append("TRANSLATED_LYRICS=\(cleanMultiline(value))") }
            if let value = lyrics.translatedSynced { comments.append("TRANSLATED_SYNCED_LYRICS=\(cleanMultiline(value))") }
            if let value = lyrics.romanized { comments.append("ROMANIZED_LYRICS=\(cleanMultiline(value))") }
            if let value = lyrics.translated ?? lyrics.original { comments.append("LYRICS=\(cleanMultiline(value))") }
            if let value = lyrics.translatedSynced ?? lyrics.synced { comments.append("SYNCEDLYRICS=\(cleanMultiline(value))") }
            comments.append("LYRICS_SOURCE=\(clean(lyrics.source))")
            if let value = lyrics.translationProvider { comments.append("LYRICS_TRANSLATION_PROVIDER=\(clean(value))") }
            if let value = lyrics.translationModel { comments.append("LYRICS_TRANSLATION_MODEL=\(clean(value))") }
            comments.append("LYRICS_MACHINE_TRANSLATED=\(lyrics.machineTranslated ? "1" : "0")")
        }

        var payload = Data()
        payload.appendLittleEndianMetadata(UInt32(vendor.count))
        payload.append(vendor)
        payload.appendLittleEndianMetadata(UInt32(comments.count))
        for comment in comments {
            let data = Data(comment.utf8)
            payload.appendLittleEndianMetadata(UInt32(data.count))
            payload.append(data)
        }
        return payload
    }

    private static func pictureBlock(_ image: Data) -> Data {
        let isPNG = image.starts(with: [0x89, 0x50, 0x4e, 0x47])
        let mime = Data((isPNG ? "image/png" : "image/jpeg").utf8)
        var width: UInt32 = 0
        var height: UInt32 = 0
        if let source = CGImageSourceCreateWithData(image as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value ?? 0
        }

        var payload = Data()
        payload.appendBigEndianMetadata(UInt32(3))
        payload.appendBigEndianMetadata(UInt32(mime.count))
        payload.append(mime)
        payload.appendBigEndianMetadata(UInt32(0))
        payload.appendBigEndianMetadata(width)
        payload.appendBigEndianMetadata(height)
        payload.appendBigEndianMetadata(UInt32(isPNG ? 32 : 24))
        payload.appendBigEndianMetadata(UInt32(0))
        payload.appendBigEndianMetadata(UInt32(image.count))
        payload.append(image)
        return payload
    }

    private static func appendWAVInfo(url: URL, tags: AudioTags) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("RIFF".utf8) else {
            throw NativeConversionError.message("系统生成的文件不是有效 RIFF/WAV。")
        }

        var fields: [(String, String)] = [
            ("INAM", tags.title),
            ("IART", tags.artist),
            ("ITRK", "\(tags.trackNumber)/\(tags.trackTotal)"),
        ]
        if let value = tags.album { fields.append(("IPRD", value)) }
        if let value = tags.date { fields.append(("ICRD", value)) }
        if let value = tags.isrc { fields.append(("ISRC", value)) }
        if let value = tags.genre { fields.append(("IGNR", value)) }

        var info = Data("INFO".utf8)
        for (fourCC, value) in fields {
            var bytes = Data(clean(value).utf8)
            bytes.append(0)
            if bytes.count % 2 != 0 { bytes.append(0) }
            info.append(contentsOf: fourCC.utf8)
            info.appendLittleEndianMetadata(UInt32(bytes.count))
            info.append(bytes)
        }
        var list = Data("LIST".utf8)
        list.appendLittleEndianMetadata(UInt32(info.count))
        list.append(info)

        try handle.seekToEnd()
        try handle.write(contentsOf: list)
        let finalSize = try handle.offset()
        guard finalSize >= 8, finalSize - 8 <= UInt64(UInt32.max) else {
            throw NativeConversionError.message("WAV 文件大小超过 RIFF 限制。")
        }
        try handle.seek(toOffset: 4)
        var riffSize = UInt32(finalSize - 8).littleEndian
        try Swift.withUnsafeBytes(of: &riffSize) { try handle.write(contentsOf: Data($0)) }
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMultiline(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    mutating func appendLittleEndianMetadata<T: FixedWidthInteger>(_ value: T) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendBigEndianMetadata<T: FixedWidthInteger>(_ value: T) {
        var copy = value.bigEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
