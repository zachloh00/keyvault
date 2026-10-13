#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
identity_name="Keyvault Local Signing"
keychain_path="$HOME/Library/Keychains/login.keychain-db"
application_path="$HOME/Applications/Keyvault.app"
cli_path="$application_path/Contents/MacOS/kv"
cli_link="$HOME/.local/bin/kv"
application_id="com.firstmate.keyvault"
cli_id="com.firstmate.keyvault.cli"
application_requirement="designated => identifier \"$application_id\" and certificate leaf[subject.CN] = \"$identity_name\""
cli_requirement="designated => identifier \"$cli_id\" and certificate leaf[subject.CN] = \"$identity_name\""

identity_listing="$(security find-identity -v -p codesigning "$keychain_path")"
if [[ "$identity_listing" != *"\"$identity_name\""* ]]; then
  echo "Missing signing identity. Run scripts/create-signing-identity.sh first." >&2
  exit 1
fi

if [[ -e "$cli_link" || -L "$cli_link" ]]; then
  if [[ ! -L "$cli_link" || "$(readlink "$cli_link")" != "$cli_path" ]]; then
    echo "Refusing to replace existing $cli_link; remove or move it first." >&2
    exit 1
  fi
fi

cd "$repo_root"
swift build --configuration release
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
staging_root="$(mktemp -d "$HOME/Applications/.keyvault-install.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
staged_app="$staging_root/Keyvault.app"
mkdir -p "$staged_app/Contents/MacOS"
cp .build/release/Keyvault "$staged_app/Contents/MacOS/Keyvault"
cp .build/release/kv "$staged_app/Contents/MacOS/kv"
chmod 755 "$staged_app/Contents/MacOS/Keyvault" "$staged_app/Contents/MacOS/kv"
cat > "$staged_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Keyvault</string>
  <key>CFBundleIdentifier</key><string>$application_id</string>
  <key>CFBundleName</key><string>Keyvault</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign "$identity_name" --identifier "$cli_id" \
  -r "=$cli_requirement" "$staged_app/Contents/MacOS/kv"
codesign --force --sign "$identity_name" --identifier "$application_id" \
  -r "=$application_requirement" "$staged_app"
codesign --verify --strict "$staged_app/Contents/MacOS/kv"
codesign --verify --deep --strict "$staged_app"

if /usr/bin/pgrep -x Keyvault >/dev/null 2>&1; then
  echo "Warning: Keyvault.app is running; quit it before installing." >&2
fi

previous_app="$staging_root/previous.app"
if [[ -e "$application_path" ]]; then mv "$application_path" "$previous_app"; fi
if ! mv "$staged_app" "$application_path"; then
  if [[ -e "$previous_app" ]]; then mv "$previous_app" "$application_path"; fi
  exit 1
fi
ln -sfn "$cli_path" "$cli_link"
echo "Installed $application_path and linked $cli_link"
if [[ -t 0 ]]; then
  scripts/reauthorize.sh
else
  echo "Run scripts/reauthorize.sh from this repository in a terminal to reauthorize Keyvault items."
fi
