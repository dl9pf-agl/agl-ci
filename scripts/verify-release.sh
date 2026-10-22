#!/usr/bin/env bash
# Verify an agl-ci image. Usage: verify-release.sh IMAGE_REF [--release]
#   IMAGE_REF: ghcr.io/dl9pf-agl/agl-ci/builder:TAG or ...@sha256:DIGEST
#   --release: additionally require a valid release-engineer (YubiKey) signature from keys/release/*.pub
# Needs: cosign (version in docker/pins.env), docker buildx, gh (for provenance).
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
ref="${1:?image ref}"; release="${2:-}"
. policy/project.env
repo="${AGL_CI_REPO:-$PROJECT_REPO}"
issuer=https://token.actions.githubusercontent.com
idre="^https://github.com/${repo}/\.github/workflows/images\.yml@refs/(heads/main|tags/v[0-9].*)\$"
digest="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}')"
pinned="${ref%%[:@]*}@$digest"
echo "digest: $digest"
cosign verify --certificate-identity-regexp "$idre" --certificate-oidc-issuer "$issuer" "$pinned" >/dev/null && echo "OK ci signature"
cosign verify-attestation --type spdxjson --certificate-identity-regexp "$idre" --certificate-oidc-issuer "$issuer" "$pinned" >/dev/null && echo "OK sbom attestation"
gh attestation verify "oci://$pinned" --repo "$repo" >/dev/null && echo "OK slsa provenance"
if [ "$release" = --release ]; then
  ok=0
  for k in keys/release/*.pub; do
    [ -e "$k" ] || continue; id="$(basename "$k" .pub)"
    grep -q "^$id " keys/REVOKED.txt && { echo "skip revoked key $id"; continue; }
    if cosign verify --key "$k" "$pinned" >/dev/null 2>&1; then echo "OK release signature by $id"; ok=1; fi
  done
  [ "$ok" = 1 ] || { echo "FAIL no valid release-engineer signature" >&2; exit 1; }
fi
