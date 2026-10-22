#!/usr/bin/env bash
# One runner slot. Per job: private network + workspace volume + privileged docker:dind sidecar,
# then an UNprivileged runner container that talks to the sidecar (DOCKER_HOST) - so kas-container works.
# Long-lived GH_TOKEN stays on the host; the runner container only gets a single-use JIT config.
set -euo pipefail
slot="${1:?slot}"
# shellcheck disable=SC1091  # written by deploy.sh
. /etc/agl-runner/runner.env   # ENGINE RUNNER_IMAGE DIND_IMAGE GH_ORG GH_TOKEN RUNNER_GROUP_ID LABELS MEM_LIMIT CPU_LIMIT DIND
E="$ENGINE"; WS=/home/runner/actions-runner/_work   # same path in runner + sidecar (nested bind mounts)
dev=(); [ -c /dev/kvm ] && dev=(--device /dev/kvm) || echo "warn: no /dev/kvm" >&2

cleanup() { "$E" rm -f "agl-r$slot" "agl-d$slot" >/dev/null 2>&1 || true
            "$E" network rm "agl-n$slot" >/dev/null 2>&1 || true
            "$E" volume rm "agl-w$slot" >/dev/null 2>&1 || true; }
trap cleanup EXIT

while :; do
  cleanup
  name="$(hostname -s)-${slot}-$(date +%s)"
  # shellcheck disable=SC2153  # LABELS comes from runner.env
  labels="$(jq -cn --arg l "$LABELS" '["self-hosted","Linux","X64"] + ($l|split(",")|map(select(length>0)))')"
  cfg="$(curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/orgs/$GH_ORG/actions/runners/generate-jitconfig" \
      -d "$(jq -cn --arg n "$name" --argjson g "${RUNNER_GROUP_ID:-1}" --argjson l "$labels" \
            '{name:$n, runner_group_id:$g, labels:$l, work_folder:"_work"}')" \
      | jq -er .encoded_jit_config)" || { echo "JIT config request failed, retry in 30s" >&2; sleep 30; continue; }

  run=("$E" run --rm --name "agl-r$slot" "${dev[@]}" --security-opt seccomp=unconfined
       --memory "${MEM_LIMIT:-24g}" --cpus "${CPU_LIMIT:-8}" --pids-limit 8192 -e JITCONFIG="$cfg")
  if [ "${DIND:-1}" = 1 ]; then
    "$E" network create "agl-n$slot" >/dev/null
    "$E" volume create "agl-w$slot" >/dev/null
    "$E" run --rm -v "agl-w$slot:/w" --user 0 --entrypoint chown "$RUNNER_IMAGE" 1001:1001 /w
    "$E" run -d --rm --privileged --name "agl-d$slot" --network "agl-n$slot" "${dev[@]}" \
        -e DOCKER_TLS_CERTDIR= -v "agl-w$slot:$WS" "$DIND_IMAGE" >/dev/null
    for _ in $(seq 1 90); do   # sidecar needs up to ~30 s before it listens
      "$E" run --rm --network "agl-n$slot" -e DOCKER_HOST="tcp://agl-d$slot:2375" --entrypoint docker "$RUNNER_IMAGE" \
          info >/dev/null 2>&1 && break; sleep 2; done
    run+=(--network "agl-n$slot" -e DOCKER_HOST="tcp://agl-d$slot:2375" -e KAS_CONTAINER_ENGINE=docker -v "agl-w$slot:$WS")
  fi
  "${run[@]}" "$RUNNER_IMAGE" || echo "runner container exited non-zero" >&2
  cleanup; sleep 2
done
