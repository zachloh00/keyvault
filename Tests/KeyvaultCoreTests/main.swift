import Foundation
import KeyvaultCore
import Security

@main
struct KeyvaultCoreTests {
    static func main() throws {
        try testEnvFileValuesAndPrecedence()
        try testMultilineValuesRemainLiteral()
        try testMalformedEnvFilesFail()
        try testWholeValueReferencesResolveExactly()
        try testUnsupportedReferencesFail()
        try testMissingReferencesFail()
        try testDeniedReferencesFail()
        try testKeychainReadFailuresMapToCLIOutput()
        try testSecretSaveActionWritesValidatedAddressAndBytes()
        try testSecretSaveActionReportsWriteFailure()
        try testSecretSaveActionRejectsInvalidAddress()
        print("11 KeyvaultCore unit tests passed.")
    }
}

private func testEnvFileValuesAndPrecedence() throws {
    let source = """
    # comment
    PLAIN=value # inline comment
    SINGLE=' a # b '
    DOUBLE="line\\nnext \\\"quoted\\\""
    EMPTY=
    PLAIN=last
    """
    let values = try EnvFileParser.parse(source)
    try expect(values["PLAIN"] == "last", "last duplicate wins")
    try expect(values["SINGLE"] == " a # b ", "single-quoted content is literal")
    try expect(values["DOUBLE"] == "line\nnext \"quoted\"", "double-quoted escapes are decoded")
    try expect(values["EMPTY"] == "", "empty values are retained")
}

private func testMultilineValuesRemainLiteral() throws {
    let literal = "$(touch /tmp/keyvault-must-not-run)"
    let source = "TOKEN=\"first line\n\(literal)\nlast line\"\n"
    let values = try EnvFileParser.parse(source)
    try expect(values["TOKEN"] == "first line\n\(literal)\nlast line", "multiline value is preserved without evaluation")
}

private func testMalformedEnvFilesFail() throws {
    try expectThrows("missing equals") { _ = try EnvFileParser.parse("NO_EQUALS\n") }
    try expectThrows("unterminated quote") { _ = try EnvFileParser.parse("BROKEN=\"value\n") }
    try expectThrows("invalid key") { _ = try EnvFileParser.parse("BAD-NAME=value\n") }
}

private func testWholeValueReferencesResolveExactly() throws {
    let environment = ["TOKEN": "kv://workers/build-token", "MODE": "release"]
    let resolved = try SecretReferenceResolver.resolve(environment: environment) { address in
        try expect(address.description == "workers/build-token", "reference address is parsed")
        return Data("secret value\n".utf8)
    }
    try expect(resolved["TOKEN"] == "secret value\n", "secret whitespace is preserved")
    try expect(resolved["MODE"] == "release", "ordinary environment values are preserved")
}

private func testUnsupportedReferencesFail() throws {
    try expectThrows("interpolated reference") {
        _ = try SecretReferenceResolver.resolve(environment: ["TOKEN": "prefix-kv://workers/token"]) { _ in Data() }
    }
    try expectThrows("invalid address") {
        _ = try SecretReferenceResolver.resolve(environment: ["TOKEN": "kv://workers/a/b"]) { _ in Data() }
    }
}

private func testMissingReferencesFail() throws {
    try expectThrows("missing secret") {
        _ = try SecretReferenceResolver.resolve(environment: ["TOKEN": "kv://workers/missing"]) { address in
            throw KeyvaultError.missingSecret(address.description)
        }
    }
}

private func testDeniedReferencesFail() throws {
    try expectThrows("denied secret") {
        _ = try SecretReferenceResolver.resolve(environment: ["TOKEN": "kv://workers/denied-token"]) { address in
            throw KeyvaultError.keychainStatus(errSecAuthFailed, "Read (address)")
        }
    }
}

private func testKeychainReadFailuresMapToCLIOutput() throws {
    let address = try VaultAddress("workers/denied-token")
    let secretMarker = "DUMMY_SECRET_MUST_NOT_APPEAR"
    let cases: [(OSStatus, String)] = [
        (errSecAuthFailed, "denied"),
        (errSecInteractionNotAllowed, "locked or access requires interaction"),
        (errSecUserCanceled, "canceled"),
        (errSecItemNotFound, "No secret exists at workers/denied-token"),
    ]

    for (status, expectedMessage) in cases {
        let storage: any VaultStorage = SimulatedVault(
            readError: KeyvaultError.readFailure(status, address: address),
            storedValue: Data(secretMarker.utf8)
        )
        do {
            _ = try storage.read(address)
            throw TestFailure(reason: "Keychain status \(status) unexpectedly returned a secret")
        } catch is TestFailure {
            throw TestFailure(reason: "Keychain status \(status) unexpectedly returned a secret")
        } catch {
            let output = KeyvaultCLIErrorOutput(error: error)
            try expect(output.exitCode != 0, "Keychain status \(status) maps to a nonzero kv exit code")
            try expect(output.message.localizedCaseInsensitiveContains(expectedMessage), "Keychain status \(status) has a clear kv error message")
            try expect(!output.message.contains(secretMarker), "Keychain status \(status) output contains no secret material")
        }
    }
}

private final class SimulatedVault: VaultStorage {
    private let readError: Error?
    private let storedValue: Data

    init(readError: Error? = nil, storedValue: Data) {
        self.readError = readError
        self.storedValue = storedValue
    }

    func read(_ address: VaultAddress) throws -> Data {
        if let readError { throw readError }
        return storedValue
    }
    func write(_ data: Data, to address: VaultAddress) throws {}
    func delete(_ address: VaultAddress) throws {}
    func contains(_ address: VaultAddress) throws -> Bool { false }
    func list() throws -> [VaultEntry] { [] }
}

private func testSecretSaveActionWritesValidatedAddressAndBytes() throws {
    let expected = Data("dummy value with trailing whitespace \n".utf8)
    var writtenData: Data?
    var writtenAddress: VaultAddress?
    let action = SecretSaveAction { data, address in
        writtenData = data
        writtenAddress = address
    }

    let outcome = action.submit(expected, vault: "workers", name: "acceptance-token")
    guard case .saved(let address) = outcome else { throw TestFailure(reason: "save action should return success") }
    var feedback = SecretEditorSaveFeedback()
    try expect(feedback.apply(outcome), "successful sheet save closes without showing an inline error")
    try expect(feedback.inlineError == nil, "successful sheet save clears inline error")
    try expect(writtenData == expected, "save action writes the exact secret bytes")
    try expect(writtenAddress == address, "save action writes the validated address")
    try expect(address.description == "workers/acceptance-token", "save action returns the saved address")
}

private func testSecretSaveActionReportsWriteFailure() throws {
    let action = SecretSaveAction { _, _ in throw SimulatedWriteFailure() }
    let outcome = action.submit(Data("dummy".utf8), vault: "workers", name: "denied-token")
    var feedback = SecretEditorSaveFeedback()
    try expect(outcome == .inlineError("simulated Keychain denial"), "write failure returns a user-facing inline error")
    try expect(!feedback.apply(outcome), "failed sheet save stays open")
    try expect(feedback.inlineError == "simulated Keychain denial", "failed sheet save displays the inline error")
}

private struct SimulatedWriteFailure: LocalizedError {
    var errorDescription: String? { "simulated Keychain denial" }
}

private func testSecretSaveActionRejectsInvalidAddress() throws {
    var didWrite = false
    let action = SecretSaveAction { _, _ in didWrite = true }
    let outcome = action.submit(Data("dummy".utf8), vault: "workers/subfolder", name: "token")
    try expect(outcome == .inlineError("Invalid address 'workers/subfolder/token'; use <vault>/<name> with letters, numbers, dot, underscore, or hyphen."), "invalid address becomes an inline error")
    try expect(!didWrite, "invalid addresses do not reach storage")
}

private struct TestFailure: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

private func expect(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw TestFailure(reason: reason) }
}

private func expectThrows(_ description: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch is TestFailure {
        throw TestFailure(reason: "\(description) unexpectedly produced a test assertion failure")
    } catch {
        return
    }
    throw TestFailure(reason: "\(description) did not throw")
}
