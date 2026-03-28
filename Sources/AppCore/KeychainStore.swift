import Foundation
import Security

public enum KeychainStoreError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "Keychain returned invalid credential data."
        }
    }
}

public protocol KeychainStoring: Sendable {
    func readPassword(service: String, account: String) throws -> String?
    func writePassword(_ value: String, service: String, account: String) throws
    func deletePassword(service: String, account: String) throws
}

public enum KeychainServiceCompatibility {
    public static func legacyServices(for service: String) -> [String] {
        switch service {
        case "OmniVoice":
            return ["Playground"]
        default:
            return []
        }
    }
}

public struct SystemKeychainStore: KeychainStoring {
    public init() {}

    public func readPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func writePassword(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(insertStatus)
        }
    }

    public func deletePassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
