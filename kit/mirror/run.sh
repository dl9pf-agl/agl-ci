#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Serve the cache of this trusted host read-only over HTTP (nginx container), for the source and sstate mirror of
# chapter 15. Both folders are mounted read-only; the container is unprivileged with a read-only root.
#   kit/mirror/run.sh        env: CACHE_DIR (/srv/agl-cache) PORT (8080) ENGINE (docker) MIRROR_NETWORK (default bridge)
#                            TLS_CERT, TLS_KEY (PEM files; with both, HTTPS is served too on TLS_PORT, default 8443). Optional:
#                            without them the mirror speaks plain HTTP only. kit/mirror/certbot.sh gets and renews the files.
#                            TLS_COPY_DIR (root-only folder for the copy the container reads, default /etc/agl-runner/mirror-tls)
#                            MIRROR_IMAGE (pinned below; bump by PR)
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"   # CACHE_DIR is root-only on the host
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CACHE_DIR="${CACHE_DIR:-/srv/agl-cache}"; PORT="${PORT:-8080}"; E="${ENGINE:-docker}"
IMAGE="${MIRROR_IMAGE:-docker.io/nginxinc/nginx-unprivileged:stable-alpine@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03}"
[ -d "$CACHE_DIR/dl" ] && [ -d "$CACHE_DIR/sstate" ] || { echo "$CACHE_DIR/dl or $CACHE_DIR/sstate missing" >&2; exit 1; }
NAME="${MIRROR_NAME:-agl-mirror}"   # another name lets a test run next to the real mirror without touching it
"$E" rm -f "$NAME" >/dev/null 2>&1 || true
tls=(); tls_port=()
if [ -n "${TLS_CERT:-}" ] || [ -n "${TLS_KEY:-}" ]; then
  [ -r "${TLS_CERT:-}" ] && [ -r "${TLS_KEY:-}" ] || { echo "TLS_CERT and TLS_KEY must both be readable files" >&2; exit 1; }
  # The container user is not root (uid 101 in this image), so it cannot read a key that only root may read, which is what
  # Let's Encrypt and most admins leave behind. Keep a copy that only that uid can read, in a root-only folder. A renewed
  # certificate reaches the mirror when run.sh runs again (a renewal hook).
  uid="$("$E" run --rm --entrypoint id "$IMAGE" -u)"; tlsdir="${TLS_COPY_DIR:-/etc/agl-runner/mirror-tls}"
  install -d -m 0700 -o root -g root "$(dirname "$tlsdir")" "$tlsdir"
  install -m 0444 "$TLS_CERT" "$tlsdir/fullchain.pem"; install -m 0400 -o "$uid" -g "$uid" "$TLS_KEY" "$tlsdir/privkey.pem"
  tls=(-v "$here/tls-server.conf:/etc/nginx/mirror/tls/server.conf:ro" -v "$tlsdir/fullchain.pem:/etc/nginx/mirror/cert/fullchain.pem:ro" -v "$tlsdir/privkey.pem:/etc/nginx/mirror/cert/privkey.pem:ro")
  [ -n "${MIRROR_NETWORK:-}" ] || tls_port=(-p "${TLS_PORT:-8443}:8443")
fi
git=(); [ ! -d "$CACHE_DIR/git" ] || git=(-v "$CACHE_DIR/git:/srv/mirror/git:ro")   # bare layer mirrors, if git-mirrors.sh made any
net=(-p "$PORT:8080"); [ -z "${MIRROR_NETWORK:-}" ] || net=(--network "$MIRROR_NETWORK")   # host network: listens on 8080
"$E" run -d --name "$NAME" --restart unless-stopped "${net[@]}" "${tls_port[@]}" \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v "$here/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$here/locations.conf:/etc/nginx/mirror/locations.conf:ro" "${tls[@]}" \
  -v "$CACHE_DIR/dl:/srv/mirror/dl:ro" -v "$CACHE_DIR/sstate:/srv/mirror/sstate:ro" "${git[@]}" \
  "$IMAGE" >/dev/null
echo "mirror up: http://$(hostname -f 2>/dev/null || hostname):$PORT/dl/ and /sstate/ (logs: $E logs $NAME)"
[ "${#tls[@]}" -eq 0 ] || echo "          and https on port ${TLS_PORT:-8443} (with MIRROR_NETWORK=host: 8443)"
