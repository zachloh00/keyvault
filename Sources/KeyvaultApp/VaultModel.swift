import AppKit
import KeyvaultCore
import LocalAuthentication
import SwiftUI

@MainActor
final class VaultModel: ObservableObject {
    @Published private(set) var entries: [VaultEntry] = []
    @Published private(set) var isUnlocked = false
    @Published var errorMessage: String?

    private let vault: KeychainVault?

    init() {
        do {
            vault = try KeychainVault()
        } catch {
            vault = nil
            errorMessage = error.localizedDescription
        }
    }

    func unlock() async {
        guard await authenticate(reason: "Unlock Keyvault to manage your local secrets.") else { return }
        isUnlocked = true
        refresh()
    }

    func lock() {
        entries = []
        isUnlocked = false
    }

    func refresh() {
        guard let vault else { return }
        do {
            entries = try vault.list()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ data: Data, vaultName: String, secretName: String) -> SecretSaveOutcome {
        guard let vault else {
            return .inlineError(errorMessage ?? "Keyvault could not open the login Keychain.")
        }
        let outcome = SecretSaveAction(write: vault.write).submit(data, vault: vaultName, name: secretName)
        switch outcome {
        case .saved:
            refresh()
        case .inlineError(let message):
            errorMessage = message
        }
        return outcome
    }

    func delete(_ entry: VaultEntry) {
        guard let vault, let address = try? VaultAddress(entry.address) else { return }
        do {
            try vault.delete(address)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reveal(_ entry: VaultEntry) async -> String? {
        guard await authenticate(reason: "Authenticate to reveal this secret.") else { return nil }
        guard let vault, let address = try? VaultAddress(entry.address) else { return nil }
        do {
            return String(data: try vault.read(address), encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func copy(_ entry: VaultEntry) async {
        guard await authenticate(reason: "Authenticate to copy this secret.") else { return }
        guard let vault, let address = try? VaultAddress(entry.address) else { return }
        do {
            let data = try vault.read(address)
            guard let value = String(data: data, encoding: .utf8) else {
                errorMessage = "This secret is not valid UTF-8 and cannot be copied as text."
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            errorMessage = policyError?.localizedDescription ?? "Touch ID or account password is unavailable."
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                Task { @MainActor in
                    if !success { self.errorMessage = error?.localizedDescription ?? "Authentication was cancelled." }
                    else { self.errorMessage = nil }
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
