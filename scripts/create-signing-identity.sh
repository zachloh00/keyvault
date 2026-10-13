#!/bin/bash
set -euo pipefail
umask 077

identity_name="Keyvault Local Signing"
keychain_path="$HOME/Library/Keychains/login.keychain-db"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/keyvault-signing.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

trust_identity() {
  security find-certificate -c "$identity_name" -p "$keychain_path" > "$temporary_directory/certificate.pem"
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain_path" "$temporary_directory/certificate.pem"
  local valid_identities
  valid_identities="$(security find-identity -v -p codesigning "$keychain_path")"
  if [[ "$valid_identities" != *"\"$identity_name\""* ]]; then
    echo "The imported certificate is not a valid code-signing identity." >&2
    exit 1
  fi
}

identity_listing="$(security find-identity -p codesigning "$keychain_path")"
if [[ "$identity_listing" == *"\"$identity_name\""* ]]; then
  valid_identities="$(security find-identity -v -p codesigning "$keychain_path")"
  if [[ "$valid_identities" != *"\"$identity_name\""* ]]; then trust_identity; fi
  echo "Signing identity is ready: $identity_name"
  exit 0
fi

cat > "$temporary_directory/codesign.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no

[subject]
CN = Keyvault Local Signing

[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$temporary_directory/codesign.cnf" -keyout "$temporary_directory/private-key.pem" \
  -out "$temporary_directory/certificate.pem"
temporary_password="$(openssl rand -hex 24)"
KEYVAULT_P12_PASSWORD="$temporary_password" openssl pkcs12 -export \
  -inkey "$temporary_directory/private-key.pem" -in "$temporary_directory/certificate.pem" \
  -name "$identity_name" -out "$temporary_directory/identity.p12" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -iter 2048 \
  -passout env:KEYVAULT_P12_PASSWORD
KEYVAULT_P12_PASSWORD="$temporary_password" openssl pkcs12 -in "$temporary_directory/identity.p12" \
  -noout -passin env:KEYVAULT_P12_PASSWORD
security import "$temporary_directory/identity.p12" -f pkcs12 -k "$keychain_path" \
  -P "$temporary_password" -T /usr/bin/codesign >/dev/null
trust_identity
echo "Created and trusted signing identity: $identity_name"
