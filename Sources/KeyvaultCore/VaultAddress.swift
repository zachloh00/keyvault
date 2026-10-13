import Foundation
import Security

public struct VaultAddress: Hashable, Codable, CustomStringConvertible {
    public let vault: String
    public let name: String

    public var description: String { "\(vault)/\(name)" }

    public init(vault: String, name: String) throws {
        guard Self.isValidComponent(vault), Self.isValidComponent(name) else {
            throw KeyvaultError.invalidAddress("\(vault)/\(name)")
        }
        self.vault = vault
        self.name = name
    }

    public init(_ string: String) throws {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw KeyvaultError.invalidAddress(string) }
        try self.init(vault: String(parts[0]), name: String(parts[1]))
    }

    public static func isValidComponent(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              value.unicodeScalars.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}

public enum KeyvaultError: Error, LocalizedError {
    case invalidAddress(String)
    case missingSecret(String)
    case keychainStatus(OSStatus, String)
    case invalidUTF8(String)
    case invalidEnvFile(String)
    case unsupportedReference(String)
    case executableNotFound(String)

    public static func readFailure(_ status: OSStatus, address: VaultAddress) -> KeyvaultError {
        if status == errSecItemNotFound { return .missingSecret(address.description) }
        return .keychainStatus(status, "Read \(address)")
    }

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "Invalid address '\(address)'; use <vault>/<name> with letters, numbers, dot, underscore, or hyphen."
        case .missingSecret(let address):
            return "No secret exists at \(address)."
        case .keychainStatus(let status, _):
            switch status {
            case errSecAuthFailed: return "Keychain access was denied."
            case errSecInteractionNotAllowed: return "Keychain is locked or access requires interaction."
            case errSecUserCanceled: return "Keychain access was canceled."
            case errSecItemNotFound: return "No secret exists at the requested address."
            default: return "Keychain operation failed (status \(status))."
            }
        case .invalidUTF8(let context): return "\(context) is not valid UTF-8."
        case .invalidEnvFile(let reason): return "Invalid env file: \(reason)"
        case .unsupportedReference: return "Secret references must occupy the entire environment value."
        case .executableNotFound(let name): return "Command not found: \(name)"
        }
    }
}
