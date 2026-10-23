#!/usr/bin/env bash
# One-shot deploy on Debian 13. Only input needed: the GitHub token.
#   sudo ./deploy.sh /path/to/token-file         # token from file
#   sudo GH_TOKEN=ghp_... ./deploy.sh            # token from env
#   sudo ./deploy.sh                             # prompts (hidden)
# Optional env: GH_ORG (default dl9pf-agl) SLOTS (default 1) ENGINE (docker|podman, default auto)
#               LABELS (default agl-pr) MEM_LIMIT CPU_LIMIT CACHE_DIR (default /srv/agl-cache)
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ORG="${GH_ORG:-dl9pf-agl}"; SLOTS="${SLOTS:-1}"

# --- token
if [ -n "${1:-}" ]; then GH_TOKEN="$(tr -d '[:space:]' < "$1")"
elif [ -z "${GH_TOKEN:-}" ]; then read -rsp "GitHub token for org $ORG: " GH_TOKEN; echo; fi
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
install -d -m 0755 /opt/agl-runner
install -d -m 0700 /etc/agl-runner
umask 077
cat > /etc/agl-runner/runner.env <<EOF
ENGINE=$ENGINE
GH_ORG=$ORG
GH_TOKEN=$GH_TOKEN
RUNNER_GROUP_ID=1
LABELS=${LABELS:-agl-pr}
MEM_LIMIT=${MEM_LIMIT:-24g}
CPU_LIMIT=${CPU_LIMIT:-8}
DIND=${DIND:-1}
CACHE_DIR=${CACHE_DIR:-/srv/agl-cache}
EOF
umask 022
install -d -o 1001 -g 1001 -m 0755 "${CACHE_DIR:-/srv/agl-cache}" "${CACHE_DIR:-/srv/agl-cache}/sstate" "${CACHE_DIR:-/srv/agl-cache}/dl"   # 1001 = runner user
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
echo "done. status: systemctl status agl-runner@1 ; logs: journalctl -fu agl-runner@1"
echo "runner appears in https://github.com/organizations/$ORG/settings/actions/runners (label: ${LABELS:-agl-pr})"
