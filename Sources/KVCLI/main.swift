import Foundation
import KeyvaultCore
import Darwin

do {
    let vault = try KeychainVault()
    try dispatch(Array(CommandLine.arguments.dropFirst()), vault: vault)
} catch {
    let output = KeyvaultCLIErrorOutput(error: error)
    FileHandle.standardError.write(Data("kv: \(output.message)\n".utf8))
    exit(output.exitCode)
}

private func dispatch(_ arguments: [String], vault: any VaultStorage) throws {
    guard let command = arguments.first else { throw usageError() }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "get":
        guard rest.count == 1 else { throw usageError() }
        let address = try VaultAddress(rest[0])
        FileHandle.standardOutput.write(try vault.read(address))
    case "set":
        guard rest.count == 1 else { throw usageError() }
        let address = try VaultAddress(rest[0])
        let value = try readSecretInput()
        try vault.write(value, to: address)
    case "list":
        try listSecrets(arguments: rest, vault: vault)
    case "rm":
        guard rest.count == 1 else { throw usageError() }
        try vault.delete(VaultAddress(rest[0]))
    case "run":
        try runChild(arguments: rest, vault: vault)
    case "import-env":
        try importEnv(arguments: rest, vault: vault)
    case "help", "--help", "-h":
        printUsage()
    default:
        throw usageError()
    }
}

private func listSecrets(arguments: [String], vault: any VaultStorage) throws {
    guard arguments.isEmpty || arguments == ["--json"] else { throw usageError() }
    let entries = try vault.list()
    if arguments == ["--json"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(entries))
        FileHandle.standardOutput.write(Data([0x0a]))
        return
    }
    for entry in entries {
        let created = entry.createdAt.map(isoDate) ?? "unknown"
        let modified = entry.modifiedAt.map(isoDate) ?? "unknown"
        print("\(entry.address)\tcreated=\(created)\tmodified=\(modified)")
    }
}

private func readSecretInput() throws -> Data {
    if isatty(STDIN_FILENO) != 0 {
        guard let input = getpass("Secret: ") else { throw CLIError.inputFailed }
        return Data(String(cString: input).utf8)
    }
    return FileHandle.standardInput.readDataToEndOfFile()
}

private func runChild(arguments: [String], vault: any VaultStorage) throws {
    var envFiles: [String] = []
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--" {
            index += 1
            break
        }
        guard arguments[index] == "--env-file", index + 1 < arguments.count else { throw usageError() }
        envFiles.append(arguments[index + 1])
        index += 2
    }
    guard index < arguments.count else { throw usageError() }

    var environment = ProcessInfo.processInfo.environment
    for path in envFiles {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fileValues = try EnvFileParser.parse(data)
        environment.merge(fileValues, uniquingKeysWith: { _, later in later })
    }
    let resolved = try SecretReferenceResolver.resolve(environment: environment) { address in
        try vault.read(address)
    }
    guard !resolved.values.contains(where: { $0.contains("\0") }) else {
        throw CLIError.invalidEnvironmentValue
    }

    let commandAndArguments = Array(arguments[index...])
    let commandPath = try resolveExecutable(commandAndArguments[0], path: resolved["PATH"])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: commandPath)
    process.arguments = Array(commandAndArguments.dropFirst())
    process.environment = resolved
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        throw CLIError.launchFailed(commandAndArguments[0])
    }
    switch process.terminationReason {
    case .exit: exit(process.terminationStatus)
    case .uncaughtSignal: exit(128 + process.terminationStatus)
    @unknown default: exit(EXIT_FAILURE)
    }
}

private func resolveExecutable(_ command: String, path: String?) throws -> String {
    if command.contains("/") {
        guard FileManager.default.isExecutableFile(atPath: command) else {
            throw KeyvaultError.executableNotFound(command)
        }
        return command
    }
    let searchPath = (path?.isEmpty == false ? path! : "/usr/bin:/bin")
    for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
            .appendingPathComponent(command).path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    throw KeyvaultError.executableNotFound(command)
}

private func importEnv(arguments: [String], vault: any VaultStorage) throws {
    guard let filePath = arguments.first else { throw usageError() }
    var targetVault: String?
    var overwrite = false
    var dryRun = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--vault" where index + 1 < arguments.count:
            targetVault = arguments[index + 1]
            index += 2
        case "--overwrite":
            overwrite = true
            index += 1
        case "--dry-run":
            dryRun = true
            index += 1
        default:
            throw usageError()
        }
    }
    guard let targetVault, VaultAddress.isValidComponent(targetVault) else { throw usageError() }

    let parsed = try EnvFileParser.parse(fileAt: filePath)
    var plans: [ImportPlan] = []
    for (name, value) in parsed.sorted(by: { $0.key < $1.key }) {
        let address = try VaultAddress(vault: targetVault, name: name)
        if value.contains("op://") {
            plans.append(ImportPlan(address: address, value: Data(), exists: false, refusedReason: "op:// reference"))
            continue
        }
        do {
            plans.append(ImportPlan(address: address, value: Data(value.utf8), exists: try vault.contains(address), refusedReason: nil))
        } catch {
            plans.append(ImportPlan(address: address, value: Data(), exists: false, refusedReason: "Keychain access failed"))
        }
    }

    for plan in plans {
        let state: String
        if let refusedReason = plan.refusedReason { state = "refused: \(refusedReason)" }
        else { state = plan.exists ? "collision" : "new" }
        print("\(plan.address.description) [\(state)]")
    }
    if dryRun {
        let preflightFailures = plans.filter { $0.refusedReason == "Keychain access failed" }.count
        if preflightFailures > 0 { throw CLIError.importPartial(successes: 0, failures: preflightFailures) }
        return
    }

    var successes = 0
    var failures = 0
    for plan in plans {
        if plan.refusedReason != nil { failures += 1; continue }
        if plan.exists && !overwrite { failures += 1; continue }
        do {
            try vault.write(plan.value, to: plan.address)
            successes += 1
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("kv: could not import \(plan.address.description).\n".utf8))
        }
    }
    if failures > 0 {
        FileHandle.standardError.write(Data("kv: imported \(successes); skipped or failed \(failures). Use --overwrite to replace collisions.\n".utf8))
        throw CLIError.importPartial(successes: successes, failures: failures)
    }
    FileHandle.standardError.write(Data("kv: imported \(successes) secret(s).\n".utf8))
}

private struct ImportPlan {
    let address: VaultAddress
    let value: Data
    let exists: Bool
    let refusedReason: String?
}

private enum CLIError: LocalizedError {
    case inputFailed
    case invalidEnvironmentValue
    case launchFailed(String)
    case importPartial(successes: Int, failures: Int)

    var errorDescription: String? {
        switch self {
        case .inputFailed: return "Could not read secret input."
        case .invalidEnvironmentValue: return "Environment values cannot contain a null byte."
        case .launchFailed(let command): return "Could not start command '\(command)'."
        case .importPartial(let successes, let failures): return "Partial import: \(successes) imported, \(failures) skipped or failed."
        }
    }
}

private func isoDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func usageError() -> NSError {
    NSError(domain: "kv", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid command. Run 'kv help' for usage."])
}

private func printUsage() {
    print("""
    Usage:
      kv get <vault>/<name>
      kv set <vault>/<name>                 Read secret from stdin or a hidden prompt
      kv list [--json]
      kv rm <vault>/<name>
      kv run [--env-file file]... -- command [args...]
      kv import-env <file|-> --vault <vault> [--overwrite] [--dry-run]
    """)
}
