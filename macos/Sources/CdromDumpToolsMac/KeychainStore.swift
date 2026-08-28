import Foundation
import Security

struct KeychainStore {
    static let shared = KeychainStore(service: "com.gavinlhx.cdrom-dump-tools.ai-secrets")

    private let service: String

    init(service: String) {
        self.service = service
    }

    func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status, operation: "读取")
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AppError.message("钥匙串中的 API Key 不是有效的 UTF-8 文本。")
        }
        return value
    }

    func write(_ value: String, account: String) throws {
        if value.isEmpty {
            try delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var createQuery = baseQuery
            attributes.forEach { createQuery[$0.key] = $0.value }
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw keychainError(status, operation: "保存")
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "删除")
        }
    }

    private func keychainError(_ status: OSStatus, operation: String) -> AppError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .message("无法\(operation)钥匙串中的 API Key：\(detail)")
    }
}

enum KeychainAccount {
    static let google = "google-translate-api-key"
    static let microsoft = "microsoft-translator-api-key"
    static let openAI = "openai-api-key"
    static let anthropic = "anthropic-api-key"

    static let all = [google, microsoft, openAI, anthropic]
}
