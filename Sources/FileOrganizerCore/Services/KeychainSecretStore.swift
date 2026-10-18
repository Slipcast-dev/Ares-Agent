import Foundation
import Security

/// Минимальное хранилище ключей провайдеров. SQLite получает лишь ссылку на
/// ключ, тогда как секрет остаётся в системном Keychain macOS.
public final class KeychainSecretStore: @unchecked Sendable {
    private let service = "dev.slipcast.FileOrganizer"

    public init() {}

    public func save(secret: String, reference: String) throws {
        guard !secret.isEmpty, !reference.isEmpty else { throw KeychainSecretStoreError.invalidInput }
        let data = Data(secret.utf8)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: reference]
        SecItemDelete(query as CFDictionary)
        let attributes = query.merging([kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw KeychainSecretStoreError.writeFailed }
    }

    public func secret(reference: String) throws -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: reference, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let secret = String(data: data, encoding: .utf8) else { throw KeychainSecretStoreError.readFailed }
        return secret
    }

    public func delete(reference: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: reference]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainSecretStoreError.deleteFailed }
    }
}

public enum KeychainSecretStoreError: Error, LocalizedError, Sendable {
    case invalidInput, writeFailed, readFailed, deleteFailed
    public var errorDescription: String? { "Не удалось безопасно обработать ключ ИИ-провайдера в Keychain." }
}
