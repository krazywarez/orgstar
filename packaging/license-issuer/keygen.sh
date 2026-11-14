#!/bin/sh
# Makes the license signing key pair once: stores the private key as the Worker's
# LICENSE_PRIVATE_KEY secret and writes the public key into Sources/OrgApp/LicenseKey.swift.
# The private key is never written to disk; keep a copy in a password manager when prompted.
# Usage: packaging/license-issuer/keygen.sh
set -eu
cd "$(dirname "$0")"
pem="$(openssl genpkey -algorithm ed25519)"
public="$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER | tail -c 32 | base64)"
printf '%s\n' "$pem" | npx wrangler secret put LICENSE_PRIVATE_KEY
sed -i '' "s|public static let publicKey = .*|public static let publicKey = \"$public\"|" ../../Sources/OrgApp/LicenseKey.swift
echo "Public key $public written to Sources/OrgApp/LicenseKey.swift; commit it."
echo "Back up the private key now (it is not saved anywhere else):"
printf '%s\n' "$pem"
