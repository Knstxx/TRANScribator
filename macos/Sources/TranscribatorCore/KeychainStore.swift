import Foundation
import Security

public struct KeychainStore: Sendable {
    private static let currentService = "app.transcribator.mac"
    private static let legacyService = "com.knst.transcribator.mac"

    private let service: String
    private let account: String
    private let fallbackServices: [String]

    public init(
        service: String = "app.transcribator.mac",
        account: String = "openai-api-key"
    ) {
        self.service = service
        self.account = account
        fallbackServices = service == Self.currentService ? [Self.legacyService] : []
    }

    public func read() throws -> String? {
        if let value = try read(service: service) { return value }
        for fallbackService in fallbackServices {
            if let value = try read(service: fallbackService) { return value }
        }
        return nil
    }

    private func read(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    public func containsValue() throws -> Bool {
        if try containsValue(service: service) { return true }
        for fallbackService in fallbackServices where try containsValue(service: fallbackService) {
            return true
        }
        return false
    }

    private func containsValue(service: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }

    public func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete()
            return
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw KeychainError(status: insertStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    public func delete() throws {
        try delete(service: service)
        for fallbackService in fallbackServices {
            try delete(service: fallbackService)
        }
    }

    private func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

public enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData

    init(status: OSStatus) { self = .status(status) }

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Ошибка Keychain: \(status)"
        case .invalidData:
            "Ключ в Keychain имеет неизвестный формат"
        }
    }
}
