#!/usr/bin/env bash
# Release engineer countersignature with the YubiKey (PIV slot "signature").
# Usage: sign-release.sh builder|runner TAG   (e.g. sign-release.sh builder 1.0.0)
# Verifies the CI signature first, signs the digest (touch the key), then verifies the result.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
img="${1:?builder|runner}"; tag="${2:?tag}"
. policy/project.env
ref="$REGISTRY/$PROJECT_REPO/$img:$tag"
scripts/verify-release.sh "$ref"                       # never countersign what CI did not sign
digest="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}')"
echo "Signing ${ref%%:*}@$digest - PIN prompt, then touch the YubiKey"
cosign sign --sk --slot signature --yes "${ref%%:*}@$digest"
scripts/verify-release.sh "$ref" --release
