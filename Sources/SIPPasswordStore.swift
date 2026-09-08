import Foundation
import Security
import LocalAuthentication

protocol SIPPasswordStore {
    func read() throws -> String?
    func write(_ password: String) throws
}

struct KeychainSIPPasswordStore: SIPPasswordStore {
    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "de.limtec.siptray.sip",
         kSecAttrAccount as String: "primary-account",
         kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        return value
    }

    func write(_ password: String) throws {
        if password.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(value) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw KeychainFailure(status: status) }
    }
}

struct KeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "SIP-Passwort konnte nicht im Schlüsselbund gelesen oder gespeichert werden (\(status)). Schlüsselbund entsperren und SipTray neu starten."
    }
}
