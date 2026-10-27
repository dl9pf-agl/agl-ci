#!/usr/bin/env bash
# One-shot deploy on Debian 13. Only input needed: the GitHub token.
#   sudo ./deploy.sh /path/to/token-file         # token from file
#   sudo GH_TOKEN=ghp_... ./deploy.sh            # token from env
#   sudo ./deploy.sh                             # prompts (hidden)
# Optional env: GH_ORG (default dl9pf-agl) SLOTS (default 1) ENGINE (docker|podman, default auto)
#               POOL (trusted | untrusted, default trusted): a host serves one pool only. trusted = same-repo PRs, nightly,
#               push, release (label agl-pr); untrusted = fork PRs (label agl-fork). SLOTS = number of slots on this host.
#               MIRROR_URL (untrusted hosts): where the trusted mirror is read, e.g. https://mirror.example/
#               LABELS (default by POOL) MEM_LIMIT CPU_LIMIT CACHE_DIR (default /srv/agl-cache)
#               POOL and MIRROR_URL default to the previous deploy; a pool change needs FORCE_POOL_CHANGE=1.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ORG="${GH_ORG:-dl9pf-agl}"; SLOTS="${SLOTS:-1}"

# --- token: file argument, else env GH_TOKEN, else the token of the previous deploy, else a prompt
old() { sed -n "s/^$1=//p" /etc/agl-runner/runner.env 2>/dev/null || true; }
if [ -n "${1:-}" ]; then GH_TOKEN="$(tr -d '[:space:]' < "$1")"
elif [ -z "${GH_TOKEN:-}" ]; then GH_TOKEN="$(old GH_TOKEN)"; fi
if [ -z "${GH_TOKEN:-}" ]; then read -rsp "GitHub token for org $ORG: " GH_TOKEN; echo; fi
[ -n "$GH_TOKEN" ] || { echo "no token" >&2; exit 1; }

# --- host packages + container engine (docker preferred, podman accepted, else install docker)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl jq ca-certificates
ENGINE="${ENGINE:-}"
if [ -z "$ENGINE" ]; then
  if command -v docker >/dev/null; then ENGINE=docker
  elif command -v podman >/dev/null; then ENGINE=podman
  else apt-get install -y -qq --no-install-recommends docker.io; systemctl enable --now docker; ENGINE=docker; fi
fi
command -v "$ENGINE" >/dev/null || { echo "$ENGINE not found" >&2; exit 1; }
echo "engine: $ENGINE"

# --- verify token can manage org runners before touching anything else
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" "https://api.github.com/orgs/$ORG/actions/runners")"
[ "$code" = 200 ] || { echo "token check failed (HTTP $code): needs org $ORG 'Self-hosted runners: read/write' (or admin:org)" >&2; exit 1; }

# --- config (token stays root-only on the host)
# POOL and MIRROR_URL stay as deployed before unless given, so that a plain update does not undo them
prev_pool="$(old POOL)"; [ -n "$prev_pool" ] || [ ! -f /etc/agl-runner/runner.env ] || prev_pool=trusted   # hosts from before pools are trusted
POOL="${POOL:-${prev_pool:-trusted}}"; MIRROR_URL="${MIRROR_URL-$(old MIRROR_URL)}"
case "$POOL" in
  trusted) default_labels=agl-pr ;;
  untrusted) default_labels=agl-fork ;;
  *) echo "POOL must be trusted or untrusted" >&2; exit 1 ;;
esac
if [ -n "$prev_pool" ] && [ "$prev_pool" != "$POOL" ] && [ -z "${FORCE_POOL_CHANGE:-}" ]; then
  echo "this host is $prev_pool; a host never serves both pools. Set FORCE_POOL_CHANGE=1 to move it (and empty its CACHE_DIR)" >&2; exit 1
fi
install -d -m 0755 /opt/agl-runner
install -d -m 0700 /etc/agl-runner
umask 077
cat > /etc/agl-runner/runner.env <<EOF
ENGINE=$ENGINE
GH_ORG=$ORG
GH_TOKEN=$GH_TOKEN
RUNNER_GROUP_ID=1
LABELS=${LABELS:-$default_labels}
POOL=$POOL
MIRROR_URL=$MIRROR_URL
MEM_LIMIT=${MEM_LIMIT:-24g}
CPU_LIMIT=${CPU_LIMIT:-8}
DIND=${DIND:-1}
CACHE_DIR=${CACHE_DIR:-/srv/agl-cache}
EOF
umask 022
# Cache layout, independent of the accounts on this host: the parent is root-only, so no other account (whatever its
# uid) can walk in; the two folders that the containers mount belong to uid 1001, which is the runner user INSIDE the
# image and needs no account on the host. The Docker daemon mounts them as root and never walks through the parent.
cache="${CACHE_DIR:-/srv/agl-cache}"
install -d -o root -g root -m 0700 "$cache"
install -d -o 1001 -g 1001 -m 0755 "$cache/sstate" "$cache/dl"
install -m 0755 "$here/run-loop.sh" /opt/agl-runner/run-loop.sh
install -m 0644 "$here/agl-runner@.service" /etc/systemd/system/agl-runner@.service

# --- image: pull the signed runner by digest, verify before first use (needs a checkout of agl-ci)
# shellcheck source=../policy/project.env disable=SC1091
. "$here/../policy/project.env"
# shellcheck source=../docker/pins.env disable=SC1091
. "$here/../docker/pins.env"
digest="${RUNNER_DIGEST:-$(tr -d '[:space:]' < "$here/runner.digest")}"
[ -n "$digest" ] || { echo "kit/runner.digest is empty: publish the runner image first, then pin its digest" >&2; exit 1; }
image="$REGISTRY/$PROJECT_REPO/runner@$digest"
if ! command -v cosign >/dev/null; then
  curl -fsSL -o /usr/local/bin/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_RELEASE}/cosign-linux-amd64"
  echo "$COSIGN_LINUX_AMD64_SHA256  /usr/local/bin/cosign" | sha256sum -c - && chmod 0755 /usr/local/bin/cosign
fi
cosign verify --certificate-identity-regexp "$CI_IDENTITY_REGEXP" --certificate-oidc-issuer "$OIDC_ISSUER" "$image" >/dev/null
echo "verified: $image"
"$ENGINE" pull "$image"
printf "RUNNER_IMAGE=%s\nDIND_IMAGE=%s\n" "$image" "$DIND_IMAGE" >> /etc/agl-runner/runner.env

# --- start
systemctl daemon-reload
for i in $(seq 1 "$SLOTS"); do systemctl enable --now "agl-runner@$i.service"; done
for u in $(systemctl list-units --all --plain --no-legend 'agl-runner@*.service' | grep -o 'agl-runner@[0-9]*\.service' | sort -u); do   # slots no longer wanted
  n="${u#agl-runner@}"; n="${n%.service}"; [ "$n" -le "$SLOTS" ] || systemctl disable --now "$u"
done
echo "done. status: systemctl status agl-runner@1 ; logs: journalctl -fu agl-runner@1"
echo "runner appears in https://github.com/organizations/$ORG/settings/actions/runners ($POOL pool, $SLOTS slots, label: ${LABELS:-$default_labels})"
