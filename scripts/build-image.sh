#!/usr/bin/env bash
# Build one image reproducibly into an OCI archive; print its digest.
# Usage: build-image.sh builder|runner OUT.tar [BUILDER_OCI_TAR]   (run from repo root)
# Same script runs in CI and locally, so anyone can reproduce a published digest.
set -euo pipefail
img="${1:?builder|runner}"; out="${2:?out.tar}"; btar="${3:-}"
. docker/pins.env
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
bx=agl-repro
docker buildx inspect "$bx" >/dev/null 2>&1 || docker buildx create --name "$bx" --driver docker-container --driver-opt "image=$BUILDKIT_IMAGE" >/dev/null
args=(--builder "$bx" -f "docker/$img/Dockerfile" --provenance=false --sbom=false
      --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" --build-arg "BASE_DIGEST=$BASE_DIGEST" --build-arg "SNAPSHOT=$SNAPSHOT")
if [ "$img" = runner ]; then
  [ -n "$btar" ] || { echo "runner needs the builder OCI tar" >&2; exit 2; }
  d="$(mktemp -d)"; tar -xf "$btar" -C "$d"
  args+=(--build-context "builder=oci-layout://$d@$(jq -r '.manifests[0].digest' "$d/index.json")"
         --build-arg "RUNNER_VERSION=$RUNNER_VERSION" --build-arg "RUNNER_SHA256=$RUNNER_SHA256")
fi
[ -z "${NO_CACHE:-}" ] || args+=(--no-cache)
docker buildx build "${args[@]}" --output "type=oci,dest=$out,rewrite-timestamp=true" .
d2="$(mktemp -d)"; tar -xf "$out" -C "$d2"; jq -r '.manifests[0].digest' "$d2/index.json"
