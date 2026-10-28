#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Start the read-only rsync daemon that publishes this TRUSTED build host's cache to the download server (agl-ci chapter 15).
# The download server pulls (kit/mirror/pull-sync.sh); this host holds no credential for it and the download server has no
# account here.
#   RSYNCD_BIND=10.0.0.5 RSYNCD_ALLOW=10.0.0.9 kit/mirror/rsyncd.sh
#
#   RSYNCD_BIND   REQUIRED. Address of this host on the PRIVATE network (physical or VPN) towards the download server. The port
#                 is published on that address only; 0.0.0.0 and :: are refused.
#   RSYNCD_ALLOW  REQUIRED. Address(es) or CIDR of the download server (rsyncd.conf "hosts allow"); everything else is refused.
#   RSYNCD_PORT   default 873.
#   CACHE_DIR     default /srv/agl-cache; its dl/, sstate/ and (if present) git/ are mounted read-only.
#   RSYNCD_IMAGE  default: the signed builder image of this checkout (ci/builder.digest); it has rsync and is on the host anyway.
#   RSYNCD_NETWORK  optional docker network mode (e.g. host, for tests); then the daemon itself binds RSYNCD_BIND:RSYNCD_PORT.
#   ENGINE        default docker.
# Container: read-only root file system, all capabilities dropped except the three the daemon needs to chroot into the module and
# drop to uid 1001, no new privileges, read-only mounts. Stop it with: docker rm -f agl-rsyncd
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"   # CACHE_DIR is root-only on the host
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CACHE_DIR="${CACHE_DIR:-/srv/agl-cache}"; E="${ENGINE:-docker}"; PORT="${RSYNCD_PORT:-873}"
bind="${RSYNCD_BIND:-}"; allow="${RSYNCD_ALLOW:-}"
[ -n "$bind" ] && [ -n "$allow" ] || { echo "set RSYNCD_BIND (private address of this host) and RSYNCD_ALLOW (address of the download server)" >&2; exit 1; }
case "$bind" in 0.0.0.0|::|"[::]") echo "RSYNCD_BIND must be one private address, not $bind" >&2; exit 1 ;; esac
[[ "$bind" =~ ^[0-9A-Fa-f.:]+$ ]] || { echo "RSYNCD_BIND must be an IP address: $bind" >&2; exit 1; }
[[ "$allow" =~ ^[0-9A-Fa-f.:/,\ ]+$ ]] || { echo "RSYNCD_ALLOW must be addresses or CIDRs separated by comma or space: $allow" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "RSYNCD_PORT must be a number" >&2; exit 1; }
[ -d "$CACHE_DIR/dl" ] && [ -d "$CACHE_DIR/sstate" ] || { echo "$CACHE_DIR/dl or $CACHE_DIR/sstate missing" >&2; exit 1; }
IMAGE="${RSYNCD_IMAGE:-ghcr.io/dl9pf-agl/agl-ci/builder@$(tr -d '[:space:]' < "$here/../../ci/builder.digest")}"
mounts=(-v "$CACHE_DIR/dl:/srv/agl/dl:ro" -v "$CACHE_DIR/sstate:/srv/agl/sstate:ro")
[ ! -d "$CACHE_DIR/git" ] || mounts+=(-v "$CACHE_DIR/git:/srv/agl/git:ro")
if [ -n "${RSYNCD_NETWORK:-}" ]; then net=(--network "$RSYNCD_NETWORK"); listen=(--address "$bind" --port "$PORT")
else net=(-p "$bind:$PORT:873"); listen=(--port 873); fi
"$E" rm -f agl-rsyncd >/dev/null 2>&1 || true
# shellcheck disable=SC2016  # the single-quoted script is meant to expand inside the container
"$E" run -d --name agl-rsyncd --restart unless-stopped "${net[@]}" \
  --read-only --tmpfs /tmp --user 0 --cap-drop ALL --cap-add SYS_CHROOT --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges --entrypoint bash -e ALLOW="$allow" \
  -v "$here/rsyncd.conf:/etc/rsyncd.conf:ro" "${mounts[@]}" "$IMAGE" \
  -c '{ printf "hosts allow = %s\n" "$ALLOW"; cat /etc/rsyncd.conf; } > /tmp/rsyncd.conf; exec rsync --daemon --no-detach --config=/tmp/rsyncd.conf "$@"' bash "${listen[@]}" >/dev/null
echo "rsync daemon up: rsync://$bind:$PORT/agl/ (read-only, allowed: $allow; logs: $E logs agl-rsyncd)"
