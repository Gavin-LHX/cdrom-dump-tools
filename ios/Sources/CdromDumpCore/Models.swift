import Foundation
import AudioToolbox

enum AudioOutputFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case flac
    case wav

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .flac: return "FLAC（无损压缩）"
        case .wav: return "WAV（无损 PCM）"
        }
    }
}

struct CDTrack: Identifiable, Codable, Hashable, Sendable {
    let number: Int
    let sourceFile: String
    let offsetBytes: Int64
    let lengthBytes: Int64
    let pregapBytes: Int64
    let isrc: String?
    let hasPreEmphasis: Bool

    var id: Int { number }
    var index1OffsetBytes: Int64 { offsetBytes + pregapBytes }
    var frameCount: Int64 { lengthBytes / 4 }
    var duration: TimeInterval { Double(frameCount) / 44_100.0 }
}

struct AlbumTrackMetadata: Identifiable, Codable, Hashable, Sendable {
    let position: Int
    let title: String
    let artist: String
    let recordingID: String?

    var id: Int { position }
}

struct AlbumCandidate: Identifiable, Codable, Hashable, Sendable {
    let releaseID: String
    let mediumPosition: Int
    let title: String
    let artist: String
    let date: String?
    let country: String?
    let barcode: String?
    let tracks: [AlbumTrackMetadata]

    var id: String { "\(releaseID)#\(mediumPosition)" }
    var year: String? {
        guard let date, date.count >= 4 else { return nil }
        let prefix = String(date.prefix(4))
        return prefix.allSatisfy(\.isNumber) ? prefix : nil
    }
}

struct NativeConversionRequest: Sendable {
    let binURL: URL
    let tocURL: URL
    let outputParentURL: URL
    let format: AudioOutputFormat
    let verifyAudio: Bool
    let album: AlbumCandidate?
    let enrichment: EnrichedAlbumMetadata?
    let coverData: Data?
    let appVersion: String

    init(
        binURL: URL,
        tocURL: URL,
        outputParentURL: URL,
        format: AudioOutputFormat,
        verifyAudio: Bool,
        album: AlbumCandidate?,
        enrichment: EnrichedAlbumMetadata? = nil,
        coverData: Data?,
        appVersion: String
    ) {
        self.binURL = binURL
        self.tocURL = tocURL
        self.outputParentURL = outputParentURL
        self.format = format
        self.verifyAudio = verifyAudio
        self.album = album
        self.enrichment = enrichment
        self.coverData = coverData
        self.appVersion = appVersion
    }
}

struct ConversionProgressEvent: Sendable {
    let currentTrack: Int
    let totalTracks: Int
    let fraction: Double
    let message: String
}

struct TrackConversionSummary: Codable, Hashable, Sendable {
    let number: Int
    let file: String
    let title: String
    let artist: String
    let sampleCount: Int64
    let sourceSegmentSHA256: String
    let decodedOutputPCMSHA256: String?
    let verified: Bool
}

struct ConversionSummary: Encodable, Sendable {
    let schema: String
    let appVersion: String
    let createdAt: String
    let sourceBIN: String
    let sourceTOC: String
    let outputFormat: String
    let albumTitle: String?
    let albumArtist: String?
    let musicBrainzReleaseID: String?
    let audioVerification: String
    let tracks: [TrackConversionSummary]
    let outputDirectory: URL

    private enum CodingKeys: String, CodingKey {
        case schema, appVersion, createdAt, sourceBIN, sourceTOC, outputFormat
        case albumTitle, albumArtist, musicBrainzReleaseID, audioVerification, tracks
    }
}

enum IOSAppVersion {
    static let fallback = "2.15.0"

    static var current: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return fallback
    }
}

enum NativeConversionError: LocalizedError {
    case message(String)
    case osStatus(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        case .osStatus(let operation, let status):
            let value = UInt32(bitPattern: status)
            let characters = [24, 16, 8, 0].map { shift -> Character in
                let byte = UInt8((value >> UInt32(shift)) & 0xff)
                return byte >= 32 && byte <= 126 ? Character(UnicodeScalar(byte)) : "?"
            }
            return "\(operation)失败（OSStatus \(status)，\(String(characters))）。"
        }
    }
}
