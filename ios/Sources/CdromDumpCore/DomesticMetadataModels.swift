import Foundation

enum DomesticMetadataSource: String, Codable, CaseIterable, Sendable {
    case netEase = "NetEase Cloud Music"
    case qqMusic = "QQ Music"
}

struct DomesticTrackAnchor: Codable, Hashable, Sendable {
    let position: Int
    let titleAliases: [String]
    let artist: String?
    let durationMilliseconds: Double
}

struct DomesticAlbumAnchor: Codable, Hashable, Sendable {
    let albumAliases: [String]
    let artist: String
    let year: String?
    let discNumber: Int
    let tracks: [DomesticTrackAnchor]
}

struct DomesticTrackMetadata: Identifiable, Codable, Hashable, Sendable {
    let position: Int
    let title: String
    let artist: String
    let durationMilliseconds: Double
    let identifier: String
    let numericIdentifier: String?
    let webURL: URL?

    var id: String { "\(position)#\(identifier)" }
}

struct DomesticAlbumMatchScore: Codable, Hashable, Sendable {
    let baseScore: Int
    let durationScore: Int
    let totalScore: Int
    let durationMatches: Int
    let nearExactDurationMatches: Int
    let averageDurationDeltaMilliseconds: Double
    let maximumDurationDeltaMilliseconds: Double
    let durationMatchRatio: Double
    let passedStructuralThreshold: Bool
    let isConfident: Bool
}

struct DomesticAlbumMetadataMatch: Identifiable, Codable, Hashable, Sendable {
    let source: DomesticMetadataSource
    let albumIdentifier: String
    let numericAlbumIdentifier: String?
    let title: String
    let artist: String
    let date: String?
    let year: String?
    let genres: [String]
    let coverURL: URL?
    let webURL: URL?
    let tracks: [DomesticTrackMetadata]
    let score: DomesticAlbumMatchScore
    let searchResultIndex: Int

    var id: String { "\(source.rawValue)#\(albumIdentifier)" }
}

protocol DomesticAlbumMetadataProviding: Sendable {
    var source: DomesticMetadataSource { get }

    func searchCandidates(anchor: DomesticAlbumAnchor) async throws -> [DomesticAlbumMetadataMatch]
}

extension DomesticAlbumMetadataProviding {
    func bestMatch(anchor: DomesticAlbumAnchor) async throws -> DomesticAlbumMetadataMatch? {
        try await searchCandidates(anchor: anchor)
            .filter(\.score.isConfident)
            .sorted(by: DomesticMetadataOrdering.isPreferred)
            .first
    }
}

enum DomesticMetadataError: LocalizedError, Sendable {
    case invalidAnchor(String)
    case invalidURL(DomesticMetadataSource)
    case invalidResponse(DomesticMetadataSource, String)
    case httpStatus(DomesticMetadataSource, Int)
    case transport(DomesticMetadataSource, domain: String, code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAnchor(let message):
            return "国内音乐源查询锚点无效：\(message)"
        case .invalidURL(let source):
            return "无法构造 \(source.rawValue) 请求。"
        case .invalidResponse(let source, let message):
            return "\(source.rawValue) 返回了无效响应：\(message)"
        case .httpStatus(let source, let status):
            return "\(source.rawValue) 请求失败（HTTP \(status)）。"
        case .transport(let source, let domain, let code):
            return "\(source.rawValue) 网络传输失败（\(domain) \(code)）。"
        }
    }
}

enum DomesticMetadataOrdering {
    static func isPreferred(_ left: DomesticAlbumMetadataMatch, _ right: DomesticAlbumMetadataMatch) -> Bool {
        if left.score.isConfident != right.score.isConfident {
            return left.score.isConfident && !right.score.isConfident
        }
        if left.score.totalScore != right.score.totalScore {
            return left.score.totalScore > right.score.totalScore
        }
        if left.score.averageDurationDeltaMilliseconds != right.score.averageDurationDeltaMilliseconds {
            return left.score.averageDurationDeltaMilliseconds < right.score.averageDurationDeltaMilliseconds
        }
        if left.searchResultIndex != right.searchResultIndex {
            return left.searchResultIndex < right.searchResultIndex
        }
        return left.albumIdentifier < right.albumIdentifier
    }
}
