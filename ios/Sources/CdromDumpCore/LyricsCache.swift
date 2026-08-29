import CryptoKit
import Foundation

struct OptionalDiskCacheValue<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?
}

actor LyricsCache {
    private struct Envelope<Value: Codable>: Codable {
        let createdAt: Date
        let value: Value
    }

    private let root: URL
    private let lifetime: TimeInterval?

    static let onlineContentLifetime: TimeInterval = 30 * 24 * 60 * 60

    init(root: URL? = nil, lifetime: TimeInterval? = nil, namespace: String = "Lyrics-v1") {
        if let root {
            self.root = root
        } else {
            let base = (try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.root = base.appendingPathComponent("CdromDumpToolsIOS/\(namespace)", isDirectory: true)
        }
        self.lifetime = lifetime
    }

    func value<Value: Codable & Sendable>(
        for keyMaterial: String,
        as type: Value.Type,
        allowExpired: Bool = false
    ) -> Value? {
        let url = fileURL(keyMaterial)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else { return nil }
        if !allowExpired,
           let lifetime,
           Date().timeIntervalSince(envelope.createdAt) > lifetime {
            return nil
        }
        return envelope.value
    }

    func store<Value: Codable & Sendable>(_ value: Value, for keyMaterial: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(createdAt: Date(), value: value))
        try data.write(to: fileURL(keyMaterial), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func removeExpired() {
        guard let lifetime else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-lifetime)
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func key(_ parts: [String]) -> String {
        parts.joined(separator: "\u{001f}")
    }

    static func key<Payload: Encodable>(
        schema: String,
        source: String,
        payload: Payload
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(payload)
        return key([schema, source, String(decoding: encoded, as: UTF8.self)])
    }

    private func fileURL(_ material: String) -> URL {
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(digest).json")
    }
}
