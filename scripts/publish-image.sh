#!/usr/bin/env bash
# Push a built OCI archive to the registry and check the pushed digest equals the built one.
# Usage: publish-image.sh IMAGE ARCHIVE.tar TAG EXPECTED_DIGEST      Env: REGISTRY_USER REGISTRY_TOKEN
# Prints the digest reference IMAGE@sha256:... Forge-independent: needs skopeo only.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
. policy/project.env
img="${1:?image}"; archive="${2:?archive}"; tag="${3:?tag}"; expect="${4:?digest}"
ref="$REGISTRY/$PROJECT_REPO/$img"
skopeo copy --preserve-digests --dest-creds "$REGISTRY_USER:$REGISTRY_TOKEN" "oci-archive:$archive" "docker://$ref:$tag"
got="sha256:$(skopeo inspect --raw --creds "$REGISTRY_USER:$REGISTRY_TOKEN" "docker://$ref:$tag" | sha256sum | cut -d' ' -f1)"
[ "$got" = "$expect" ] || { echo "pushed digest $got != built $expect" >&2; exit 1; }
echo "$ref@$got"
