import Foundation
import CryptoKit

struct MusicBrainzDiscIdentity: Codable, Hashable, Sendable {
    let discID: String
    let toc: String
    let leadoutSector: Int64
    let trackOffsets: [Int64]
}

enum DiscIdentity {
    static func musicBrainz(tracks: [CDTrack], binSize: Int64) throws -> MusicBrainzDiscIdentity {
        guard !tracks.isEmpty, tracks.count <= 99 else {
            throw NativeConversionError.message("MusicBrainz Disc ID 要求 1 到 99 条轨道。")
        }
        guard binSize > 0, binSize % 2_352 == 0 else {
            throw NativeConversionError.message("BIN 长度没有按 2352 字节 CD-DA 扇区对齐。")
        }

        let offsets = try tracks.map { track -> Int64 in
            guard track.index1OffsetBytes % 2_352 == 0 else {
                throw NativeConversionError.message("第 \(track.number) 轨的 INDEX 01 未按 CD-DA 扇区对齐。")
            }
            return track.index1OffsetBytes / 2_352 + 150
        }
        let leadout = binSize / 2_352 + 150
        var hashText = String(format: "%02X%02X%08X", 1, tracks.count, leadout)
        for index in 0..<99 {
            hashText += String(format: "%08X", index < offsets.count ? offsets[index] : 0)
        }
        let digest = Insecure.SHA1.hash(data: Data(hashText.utf8))
        let base64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
        let toc = (["1", String(tracks.count), String(leadout)] + offsets.map(String.init)).joined(separator: " ")
        return MusicBrainzDiscIdentity(discID: base64, toc: toc, leadoutSector: leadout, trackOffsets: offsets)
    }
}
