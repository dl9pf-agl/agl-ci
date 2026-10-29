#!/usr/bin/env bash
# One runner slot. Per job: private network + workspace volume + privileged docker:dind sidecar,
# then an UNprivileged runner container that talks to the sidecar (DOCKER_HOST) - so kas-container works.
# Long-lived GH_TOKEN stays on the host; the runner container only gets a single-use JIT config.
set -euo pipefail
slot="${1:?slot}"
# shellcheck disable=SC1091  # written by deploy.sh
. /etc/agl-runner/runner.env   # ENGINE RUNNER_IMAGE DIND_IMAGE GH_ORG GH_TOKEN RUNNER_GROUP_ID LABELS MEM_LIMIT CPU_LIMIT DIND CACHE_DIR
#                               POOL MIRROR_URL HASHSERV_RW HASHSERV_UPSTREAM SLOTS LINT_LABELS LINT_MEM_LIMIT LINT_CPU_LIMIT
# --- slot role: slots 1..SLOTS serve the pool label; the slots after them are lint slots (own label, small, no cache, no hash server)
if [ "$slot" -gt "${SLOTS:-1}" ]; then
  LABELS="${LINT_LABELS:?LINT_LABELS missing in runner.env}"; MEM_LIMIT="${LINT_MEM_LIMIT:-4g}"; CPU_LIMIT="${LINT_CPU_LIMIT:-2}"
  CACHE_DIR=""; MIRROR_URL=""; HASHSERV_RW=""; HASHSERV_UPSTREAM=""
fi
# --- end slot role
E="$ENGINE"; WS=/home/runner/actions-runner/_work   # same path in runner + sidecar (nested bind mounts)
# Cache of this host: all its slots read and write CACHE_DIR, same path in host, sidecar and runner. A host is either
# trusted or untrusted (POOL, set by deploy.sh), never both, so its cache never mixes the two. A trusted host's
# CACHE_DIR is the mirror source; an untrusted host reads the mirror over the network (MIRROR_URL, chapter 15).
cache=(); cache_env=()
if [ -n "${CACHE_DIR:-}" ]; then
  cache=(-v "$CACHE_DIR:$CACHE_DIR")
  cache_env=(-e AGL_SSTATE_DIR="$CACHE_DIR/sstate" -e AGL_DL_DIR="$CACHE_DIR/dl")
  [ -z "${MIRROR_URL:-}" ] || cache_env+=(-e AGL_MIRROR_URL="$MIRROR_URL")
fi
hs_env=()   # shared hash equivalence server: read-write for trusted hosts, read-only upstream for untrusted ones (deploy.sh checks)
[ -z "${HASHSERV_RW:-}" ] || hs_env+=(-e AGL_HASHSERV_RW="$HASHSERV_RW")
[ -z "${HASHSERV_UPSTREAM:-}" ] || hs_env+=(-e AGL_HASHSERV_UPSTREAM="$HASHSERV_UPSTREAM")
dev=(); [ -c /dev/kvm ] && dev=(--device /dev/kvm) || echo "warn: no /dev/kvm" >&2

cleanup() { "$E" rm -f "agl-r$slot" "agl-d$slot" >/dev/null 2>&1 || true
            "$E" network rm "agl-n$slot" >/dev/null 2>&1 || true
            "$E" volume rm "agl-w$slot" >/dev/null 2>&1 || true; }
trap cleanup EXIT

api() { curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

# Sidecar, network and volume first. Registers nothing at GitHub, so a broken engine cannot flood the org.
prepare() {
  "$E" network create "agl-n$slot" >/dev/null &&
  "$E" volume create "agl-w$slot" >/dev/null &&
  "$E" run --rm -v "agl-w$slot:/w" --user 0 --entrypoint chown "$RUNNER_IMAGE" 1001:1001 /w &&
  "$E" run -d --rm --privileged --name "agl-d$slot" --network "agl-n$slot" "${dev[@]}" \
      -e DOCKER_TLS_CERTDIR= -v "agl-w$slot:$WS" "${cache[@]}" "$DIND_IMAGE" >/dev/null || return 1
  for _ in $(seq 1 90); do   # sidecar needs up to ~70 s before it listens
    "$E" run --rm --network "agl-n$slot" -e DOCKER_HOST="tcp://agl-d$slot:2375" --entrypoint docker "$RUNNER_IMAGE" \
        info >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "sidecar agl-d$slot never answered on tcp://agl-d$slot:2375" >&2; "$E" logs --tail 20 "agl-d$slot" >&2 || true
  return 1
}

fails=0
backoff() { fails=$((fails + 1)); d=$((fails * 30)); [ "$d" -gt 600 ] && d=600
            echo "failure $fails, retry in ${d}s" >&2; cleanup; sleep "$d"; }

while :; do
  cleanup
  if [ "${DIND:-1}" = 1 ]; then prepare || { backoff; continue; }; fi

  name="$(hostname -s)-${slot}-$(date +%s)"
  # shellcheck disable=SC2153  # LABELS comes from runner.env
  labels="$(jq -cn --arg l "$LABELS" '["self-hosted","Linux","X64"] + ($l|split(",")|map(select(length>0)))')"
  resp="$(api -X POST "https://api.github.com/orgs/$GH_ORG/actions/runners/generate-jitconfig" \
      -d "$(jq -cn --arg n "$name" --argjson g "${RUNNER_GROUP_ID:-1}" --argjson l "$labels" \
            '{name:$n, runner_group_id:$g, labels:$l, work_folder:"_work"}')")" || { echo "JIT config request failed" >&2; backoff; continue; }
  cfg="$(jq -er .encoded_jit_config <<<"$resp")"; rid="$(jq -er .runner.id <<<"$resp")"

  run=("$E" run --rm --name "agl-r$slot" "${dev[@]}" --security-opt seccomp=unconfined
       --memory "${MEM_LIMIT:-24g}" --cpus "${CPU_LIMIT:-8}" --pids-limit 8192 -e JITCONFIG="$cfg")
  [ "${DIND:-1}" = 1 ] && run+=(--network "agl-n$slot" -e DOCKER_HOST="tcp://agl-d$slot:2375" -e KAS_CONTAINER_ENGINE=docker -v "agl-w$slot:$WS")
  [ -z "${CACHE_DIR:-}" ] || run+=("${cache[@]}" "${cache_env[@]}")
  run+=("${hs_env[@]}")
  run+=(-e AGL_POOL="${POOL:-trusted}")   # read by the job-started hook of the runner image (trusted: refuses fork pull requests)
  t0=$(date +%s)
  "${run[@]}" "$RUNNER_IMAGE" || echo "runner container exited non-zero" >&2
  if [ $(($(date +%s) - t0)) -lt 30 ]; then   # died at once: never served a job; drop the registration, back off
    api -X DELETE "https://api.github.com/orgs/$GH_ORG/actions/runners/$rid" >/dev/null 2>&1 || true
    backoff
  else
    fails=0; cleanup; sleep 2
  fi
done
