# Keyvault

Keyvault is a small macOS app and `kv` command for storing local secrets in the login Keychain. The app and CLI share one Swift library. Keychain provides encryption at rest; Keyvault adds no custom cryptography, syncing, or sharing.

## Trust model

The v1 vault is available to automation running as the logged-in macOS user. The `kv` CLI reads secrets without prompting, including unattended worker processes. The app uses Touch ID with the account password as fallback when its window opens or unlocks and before a secret is revealed or copied. This authentication protects the app window only. Keychain items do not require user presence, and any process running as this macOS user can invoke `kv` and read them. Vault names organize secrets; they do not isolate workers.

Keychain items use the `com.firstmate.keyvault` service in the login Keychain with synchronization disabled. Access lists trust the installed app and CLI. Keep the local signing identity and installed paths stable so rebuilds retain Keychain access. Secrets and child process output are not masked; `kv run` passes resolved values to the child, which may print them.

## Build and install

This project requires macOS 13 or later and Swift 5.9 or later.

```sh
scripts/create-signing-identity.sh
scripts/build-install.sh
```

The first command creates the self-signed `Keyvault Local Signing` identity in the login Keychain. The second builds `Keyvault.app` at `~/Applications/Keyvault.app` and links `~/.local/bin/kv` to its bundled CLI. Add `~/.local/bin` to `PATH` if needed. The signing private key remains in the login Keychain; temporary key material is removed by the identity script.

## App

Open `~/Applications/Keyvault.app`. Authenticate with Touch ID or the account password to unlock the window. Secrets are grouped by vault and can be searched, added, edited, deleted, revealed, and copied. Reveal and copy each require fresh authentication. Lock the window with the `Lock` button.

## CLI

```text
kv get <vault>/<name>
kv set <vault>/<name>
kv list [--json]
kv rm <vault>/<name>
kv run [--env-file file]... -- command [args...]
kv import-env <file|-> --vault <vault> [--overwrite] [--dry-run]
```

- `get` writes the exact stored bytes to stdout, with no added newline. `set` reads all bytes from stdin, or uses a hidden prompt when stdin is a terminal. The secret is never accepted as a command argument.
- `list` shows names and creation/modification dates only. `--json` emits the same metadata as JSON.
- `run` parses each env file without sourcing or evaluating it. It supports `KEY=VALUE`, optional `export`, blank lines, comments, single and double quotes, multiline quoted values, empty values, and last-duplicate-wins. It does not expand shell variables or command substitutions. Env-file values override inherited variables, and later files override earlier files. A whole value of the form `kv://<vault>/<name>` is resolved. Embedded `kv://` references fail clearly. All references are resolved before the child starts; a missing, locked, or denied secret prevents launch. The child inherits the current working directory and receives the given command and arguments. Its output is not masked.
- `import-env` shows each target name and whether it is new or collides. `--dry-run` shows the preview without writing. Without `--overwrite`, colliding items are skipped; `op://` values are refused. Other valid values are still imported, and the command reports partial completion with a nonzero exit status when any item is skipped or fails. The source file is never changed.
- For `import-env`, use `-` as the source path to read env text from standard input.

Addresses are flat: `<vault>/<name>`. Each component starts with a letter or number and contains only letters, numbers, `.`, `_`, or `-`.

## Tests

Run the standalone parser and reference-resolution unit tests with:

```sh
swift run kv-tests
```

The test runner covers env parsing, reference resolution, editor save feedback, and CLI error output for simulated Keychain statuses. It injects storage through a protocol and does not create Keychain items. End-to-end Keychain checks should use dummy entries under a temporary `KEYVAULT_SERVICE_PREFIX`, then delete those entries.
