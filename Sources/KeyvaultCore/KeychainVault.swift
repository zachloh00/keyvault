import Foundation
import LocalAuthentication
import Security

public struct VaultEntry: Codable, Hashable, Identifiable {
    public let vault: String
    public let name: String
    public let createdAt: Date?
    public let modifiedAt: Date?

    public var id: String { "\(vault)/\(name)" }
    public var address: String { id }
}

public protocol VaultStorage {
    func read(_ address: VaultAddress) throws -> Data
    func write(_ data: Data, to address: VaultAddress) throws
    func delete(_ address: VaultAddress) throws
    func contains(_ address: VaultAddress) throws -> Bool
    func list() throws -> [VaultEntry]
}

public final class KeychainVault: VaultStorage {
    public static let defaultServicePrefix = "com.firstmate.keyvault"

    public let servicePrefix: String
    private let keychain: SecKeychain
    private let authenticationContext: LAContext
    private let applicationPath: String
    private let cliPath: String

    public init(servicePrefix: String? = ProcessInfo.processInfo.environment["KEYVAULT_SERVICE_PREFIX"]) throws {
        self.servicePrefix = servicePrefix ?? Self.defaultServicePrefix
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let loginKeychainPath = "\(home)/Library/Keychains/login.keychain-db"
        var openedKeychain: SecKeychain?
        let openStatus = SecKeychainOpen(loginKeychainPath, &openedKeychain)
        guard openStatus == errSecSuccess, let openedKeychain else {
            throw KeyvaultError.keychainStatus(openStatus, "Open login Keychain")
        }
        self.keychain = openedKeychain
        let context = LAContext()
        context.interactionNotAllowed = true
        self.authenticationContext = context
        self.applicationPath = "\(home)/Applications/Keyvault.app/Contents/MacOS/Keyvault"
        self.cliPath = "\(home)/Applications/Keyvault.app/Contents/MacOS/kv"
    }

    public func read(_ address: VaultAddress) throws -> Data {
        var query = baseQuery(for: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeyvaultError.readFailure(status, address: address) }
        guard let data = result as? Data else { throw KeyvaultError.invalidUTF8("Secret at \(address)") }
        return data
    }

    public func write(_ data: Data, to address: VaultAddress) throws {
        let query = baseQuery(for: address)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeyvaultError.keychainStatus(updateStatus, "Write \(address)")
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: address.description,
            kSecAttrSynchronizable as String: false,
            kSecUseKeychain as String: keychain,
            kSecUseAuthenticationContext as String: authenticationContext,
            kSecAttrAccess as String: try makeAccessControl(),
            kSecValueData as String: data,
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeyvaultError.keychainStatus(retryStatus, "Write \(address)")
            }
            return
        }
        throw KeyvaultError.keychainStatus(addStatus, "Write \(address)")
    }

    public func delete(_ address: VaultAddress) throws {
        let status = SecItemDelete(baseQuery(for: address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyvaultError.keychainStatus(status, "Delete \(address)")
        }
    }

    public func contains(_ address: VaultAddress) throws -> Bool {
        var query = baseQuery(for: address)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeyvaultError.keychainStatus(status, "Check \(address)") }
        return true
    }

    public func list() throws -> [VaultEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecUseKeychain as String: keychain,
            kSecUseAuthenticationContext as String: authenticationContext,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyvaultError.keychainStatus(status, "List secrets") }
        let records = (result as? [[String: Any]]) ?? []
        return try records.compactMap { record in
            guard let account = record[kSecAttrAccount as String] as? String else { return nil }
            let address = try VaultAddress(account)
            return VaultEntry(
                vault: address.vault,
                name: address.name,
                createdAt: record[kSecAttrCreationDate as String] as? Date,
                modifiedAt: record[kSecAttrModificationDate as String] as? Date
            )
        }.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
    }

    private func baseQuery(for address: VaultAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: address.description,
            kSecUseKeychain as String: keychain,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
    }

    private func makeAccessControl() throws -> SecAccess {
        var applications: [SecTrustedApplication] = []
        for path in [applicationPath, cliPath] {
            var trustedApplication: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &trustedApplication)
            guard status == errSecSuccess, let trustedApplication else {
                throw KeyvaultError.keychainStatus(status, "Trust installed app and CLI")
            }
            applications.append(trustedApplication)
        }
        var access: SecAccess?
        let status = SecAccessCreate("Keyvault local app and CLI" as CFString, applications as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw KeyvaultError.keychainStatus(status, "Create Keychain access list")
        }
        return access
    }
}
