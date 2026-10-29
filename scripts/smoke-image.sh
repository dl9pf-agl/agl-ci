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
# runs inside the runner image (bash -e), as the first process of a container started with -e AGL_POOL=trusted (what run-loop.sh does)
hook_check="$(cat <<'EOS'
H="$ACTIONS_RUNNER_HOOK_JOB_STARTED"
[ "$H" = /opt/agl-hooks/job-started.sh ]
[ "$(stat -c %U "$H")" = root ]
cat > /tmp/p.json <<'JSON'
{"repository":{"full_name":"o/r"},"pull_request":{"head":{"repo":{"full_name":"x/r"}}}}
JSON
export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH=/tmp/p.json
if "$H" 2>/tmp/e; then echo "the hook accepted a fork pull request on a trusted host" >&2; exit 1; fi
grep -q "from fork x/r" /tmp/e
# values a workflow might put into the environment of the hook must not help
if AGL_POOL=untrusted "$H" 2>/dev/null; then echo "AGL_POOL in the environment of the hook was believed" >&2; exit 1; fi
if GITHUB_EVENT_NAME=push "$H" 2>/dev/null; then echo "GITHUB_EVENT_NAME=push was believed" >&2; exit 1; fi
sed -i "s|x/r|o/r|" /tmp/p.json
"$H"
EOS
)"
# the same fork payload on an untrusted host (container started with -e AGL_POOL=untrusted) is accepted
untrusted_check="$(cat <<'EOS'
cat > /tmp/p.json <<'JSON'
{"repository":{"full_name":"o/r"},"pull_request":{"head":{"repo":{"full_name":"x/r"}}}}
JSON
GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH=/tmp/p.json "$ACTIONS_RUNNER_HOOK_JOB_STARTED"
EOS
)"
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
    run --entrypoint actionlint "$ref" -version
    run --entrypoint zizmor "$ref" --version
    run --entrypoint shellcheck "$ref" --version
    run --entrypoint python3 "$ref" -c 'import yaml'     # scripts/check-kas.py of agl-ucb needs it
    # the job-started hook: set, root-owned, refuses a fork pull request on a trusted host (also with a tampered environment), accepts a same-repo one, and accepts the fork one on an untrusted host
    run -e AGL_POOL=trusted --entrypoint bash "$ref" -ec "$hook_check"
    run -e AGL_POOL=untrusted --entrypoint bash "$ref" -ec "$untrusted_check"
    ;;
  *) echo "builder|runner" >&2; exit 2 ;;
esac
