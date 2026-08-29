import Foundation
import Security

protocol IOSSecretStoring {
    func value(for account: String) throws -> String?
    func setValue(_ value: String, for account: String) throws
    func removeValue(for account: String) throws
}

struct IOSKeychainStore: IOSSecretStoring {
    private let service: String

    init(service: String? = nil) {
        self.service = service
            ?? Bundle.main.bundleIdentifier.map { "\($0).translation-secrets" }
            ?? "com.gavinlhx.cdromdumptools.ios.translation-secrets"
    }

    func value(for account: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ] as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw IOSKeychainError.operation("读取", status: status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw IOSKeychainError.invalidStoredValue
        }
        return value
    }

    func setValue(_ value: String, for account: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try removeValue(for: account)
            return
        }

        let selector: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(selector as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw IOSKeychainError.operation("更新", status: updateStatus)
        }

        var item = selector
        item.merge(attributes) { _, replacement in replacement }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw IOSKeychainError.operation("保存", status: addStatus)
        }
    }

    func removeValue(for account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IOSKeychainError.operation("删除", status: status)
        }
    }
}

private enum IOSKeychainError: LocalizedError {
    case invalidStoredValue
    case operation(String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            return "Keychain 中的密钥不是有效的 UTF-8 文本。"
        case .operation(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "无法\(operation) Keychain 密钥（\(detail ?? "OSStatus \(status)")）。"
        }
    }
}
