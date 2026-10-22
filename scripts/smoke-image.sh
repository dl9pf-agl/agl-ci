#!/usr/bin/env bash
# Start a built image the way its consumers do and fail if it cannot run.
# Usage: smoke-image.sh builder|runner OCI.tar     (needs docker, skopeo)
# builder: through its ENTRYPOINT as root (what kas-container does) and as uid 1000, plus the baked-in tools.
# runner : tools plus the runner start script (it is only started with a JIT config, so no run).
set -euo pipefail
img="${1:?builder|runner}"; tar="${2:?OCI.tar}"; ref="agl-smoke-$img:test"
# oci-archive -> docker-archive -> docker load works on every Docker; docker load of the OCI archive itself
# needs the containerd image store, skopeo copy straight to docker-daemon fails with Docker 29.
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
skopeo copy "oci-archive:$tar" "docker-archive:$t/i.tar:$ref"
docker load -q -i "$t/i.tar" >/dev/null
run() { echo "+ $*"; docker run --rm "$@"; }
case "$img" in
  builder)
    run "$ref" --version                      # ENTRYPOINT /entrypoint.sh as root: remap ci user, exec kas
    run -u 1000 "$ref" --version              # ENTRYPOINT as the non-root user
    run --entrypoint oelint-adv "$ref" --version
    ;;
  runner)
    run --entrypoint kas "$ref" --version
    run --entrypoint docker "$ref" --version
    run --entrypoint test "$ref" -x ./run.sh
    ;;
  *) echo "builder|runner" >&2; exit 2 ;;
esac
