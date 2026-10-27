#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# OPTIONAL: terminate TLS on the mirror container itself with a Let's Encrypt certificate, obtained and renewed by the
# official certbot container (agl-ci chapter 15). Not needed for the development setup (plain HTTP) and not the production plan,
# where a separate nginx with an HTTPS terminator sits in front; use it where this host is the public mirror.
#
#   TLS_NAME=mirror.example.org LE_EMAIL=ops@example.org kit/mirror/certbot.sh issue     first certificate
#   TLS_NAME=mirror.example.org kit/mirror/certbot.sh renew                              from cron, daily
#
#   TLS_NAME   REQUIRED. Public DNS name of this host; it must resolve to this host and port 80 must be reachable from the
#              internet while certbot runs (HTTP-01 challenge, certbot's own standalone server, published as port 80 of the host).
#   LE_EMAIL   REQUIRED for issue. Contact address for expiry notices.
#   LE_STAGING=1  use Let's Encrypt's staging service (untrusted certificates, no rate limits): try it first.
#   LE_DIR     certbot's state, default /etc/agl-runner/letsencrypt (root-only; holds the account and the private key).
#   CERTBOT_IMAGE  default: the pinned official image below; bump by PR.
#   CACHE_DIR, PORT, TLS_PORT, ENGINE  as for run.sh, which this script calls to (re)start the mirror with the new certificate.
# `renew` only asks Let's Encrypt when a certificate is within 30 days of expiry and restarts the mirror only when the
# certificate changed. The certbot container is short-lived (started, run, removed), has a read-only root file system, no
# capabilities except binding port 80, and sees nothing but LE_DIR.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
E="${ENGINE:-docker}"; le="${LE_DIR:-/etc/agl-runner/letsencrypt}"
IMAGE="${CERTBOT_IMAGE:-docker.io/certbot/certbot@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20}"
cmd="${1:-}"; name="${TLS_NAME:-}"
[[ "$cmd" =~ ^(issue|renew)$ ]] || { echo "usage: TLS_NAME=<dns name> [LE_EMAIL=<address>] $0 issue|renew" >&2; exit 2; }
[[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$name" == *.* ]] || { echo "TLS_NAME must be a DNS name, got: ${name:-nothing}" >&2; exit 1; }
args=(--non-interactive --config-dir /etc/letsencrypt --work-dir /tmp/work --logs-dir /tmp/logs)
[ -z "${LE_STAGING:-}" ] || args+=(--staging)
case "$cmd" in
  issue)
    email="${LE_EMAIL:-}"; [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$ ]] || { echo "LE_EMAIL must be an e-mail address" >&2; exit 1; }
    args=(certonly --standalone -d "$name" --email "$email" --agree-tos --no-eff-email "${args[@]}") ;;
  renew) args=(renew "${args[@]}") ;;
esac
install -d -m 0700 -o root -g root "$(dirname "$le")" "$le"
live="$le/live/$name/fullchain.pem"
before="$(sha256sum "$live" 2>/dev/null | cut -d' ' -f1 || true)"
"$E" run --rm --read-only --tmpfs /tmp --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges \
  -p 80:80 -v "$le:/etc/letsencrypt" "$IMAGE" "${args[@]}"
[ -r "$live" ] || { echo "certbot.sh: no certificate at $live after the run" >&2; exit 1; }
after="$(sha256sum "$live" | cut -d' ' -f1)"
if [ "$cmd" = renew ] && [ "$before" = "$after" ]; then echo "certbot.sh: certificate unchanged, mirror not restarted"; exit 0; fi
echo "certbot.sh: new certificate for $name, restarting the mirror with TLS"
exec env TLS_CERT="$live" TLS_KEY="$le/live/$name/privkey.pem" "$here/run.sh"
