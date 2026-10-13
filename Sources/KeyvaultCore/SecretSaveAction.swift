import Foundation

public enum SecretSaveOutcome: Equatable {
    case saved(VaultAddress)
    case inlineError(String)
}

public struct SecretEditorSaveFeedback {
    public private(set) var inlineError: String?

    public init() {}

    @discardableResult
    public mutating func apply(_ outcome: SecretSaveOutcome) -> Bool {
        switch outcome {
        case .saved:
            inlineError = nil
            return true
        case .inlineError(let message):
            inlineError = message
            return false
        }
    }
}

/// Validates an address and writes a secret through the supplied storage operation.
public struct SecretSaveAction {
    private let write: (Data, VaultAddress) throws -> Void

    public init(write: @escaping (Data, VaultAddress) throws -> Void) {
        self.write = write
    }

    @discardableResult
    public func save(_ data: Data, vault: String, name: String) throws -> VaultAddress {
        let address = try VaultAddress(vault: vault, name: name)
        try write(data, address)
        return address
    }

    public func submit(_ data: Data, vault: String, name: String) -> SecretSaveOutcome {
        do {
            return .saved(try save(data, vault: vault, name: name))
        } catch {
            return .inlineError(error.localizedDescription)
        }
    }
}
