import Foundation

public enum SecretReferenceResolver {
    public static func resolve(
        environment: [String: String],
        readSecret: (VaultAddress) throws -> Data
    ) throws -> [String: String] {
        var resolved: [String: String] = [:]
        for (key, value) in environment {
            if value.hasPrefix("kv://") {
                let addressText = String(value.dropFirst("kv://".count))
                let address = try VaultAddress(addressText)
                let data = try readSecret(address)
                guard let secret = String(data: data, encoding: .utf8) else {
                    throw KeyvaultError.invalidUTF8("Secret at \(address)")
                }
                resolved[key] = secret
            } else if value.contains("kv://") {
                throw KeyvaultError.unsupportedReference(value)
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }
}
