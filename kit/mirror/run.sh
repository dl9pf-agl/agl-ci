#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Serve the cache of this trusted host read-only over HTTP (nginx container), for the source and sstate mirror of
# chapter 15. Both folders are mounted read-only; the container is unprivileged with a read-only root.
#   kit/mirror/run.sh        env: CACHE_DIR (/srv/agl-cache) PORT (8080) ENGINE (docker) MIRROR_NETWORK (default bridge)
#                            MIRROR_IMAGE (pinned below; bump by PR)
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CACHE_DIR="${CACHE_DIR:-/srv/agl-cache}"; PORT="${PORT:-8080}"; E="${ENGINE:-docker}"
IMAGE="${MIRROR_IMAGE:-docker.io/nginxinc/nginx-unprivileged:stable-alpine@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03}"
[ -d "$CACHE_DIR/dl" ] && [ -d "$CACHE_DIR/sstate" ] || { echo "$CACHE_DIR/dl or $CACHE_DIR/sstate missing" >&2; exit 1; }
"$E" rm -f agl-mirror >/dev/null 2>&1 || true
net=(-p "$PORT:8080"); [ -z "${MIRROR_NETWORK:-}" ] || net=(--network "$MIRROR_NETWORK")   # host network: listens on 8080
"$E" run -d --name agl-mirror --restart unless-stopped "${net[@]}" \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v "$here/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$CACHE_DIR/dl:/srv/mirror/dl:ro" -v "$CACHE_DIR/sstate:/srv/mirror/sstate:ro" \
  "$IMAGE" >/dev/null
echo "mirror up: http://$(hostname -f 2>/dev/null || hostname):$PORT/dl/ and /sstate/ (logs: $E logs agl-mirror)"
