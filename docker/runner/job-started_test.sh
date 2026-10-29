#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checks docker/runner/job-started.sh with fake payloads, fake "first process" environments and attempts to tamper with the
# environment of the hook. Usage: docker/runner/job-started_test.sh [path-to-hook]   (needs python3)
set -u
hook="${1:-$(dirname "$0")/job-started.sh}"; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; fail=0
command -v python3 >/dev/null || { echo "python3 is needed" >&2; exit 2; }
grep -q '/proc/1/environ' "$hook" || { echo "FAIL  the hook does not read the pool from /proc/1/environ" >&2; exit 1; }
# the hook reads the first process of the container; the tests substitute a file for it in a copy
sed "s|/proc/1/environ|$t/environ|g" "$hook" > "$t/hook.sh"
repo='"repository":{"full_name":"dl9pf-agl/meta-agl"}'
payload() { printf '%s' "$2" > "$t/$1.json"; }
payload same   "{$repo,\"pull_request\":{\"head\":{\"repo\":{\"full_name\":\"dl9pf-agl/meta-agl\"}}}}"
payload case   "{$repo,\"pull_request\":{\"head\":{\"repo\":{\"full_name\":\"DL9PF-agl/Meta-Agl\"}}}}"
payload fork   "{$repo,\"pull_request\":{\"head\":{\"repo\":{\"full_name\":\"dl9pf/meta-agl\"}}}}"
payload gone   "{$repo,\"pull_request\":{\"head\":{\"repo\":null}}}"
payload nohead "{$repo,\"pull_request\":{}}"
payload norepo '{"pull_request":{"head":{"repo":{"full_name":"dl9pf/meta-agl"}}}}'
payload push   "{$repo,\"ref\":\"refs/heads/master\"}"
payload sched  "{$repo,\"schedule\":\"17 1 * * *\"}"
payload space  "{$repo,\"pull_request\":{\"head\":{\"repo\":{\"full_name\":\"dl9pf-agl/meta-agl \"}}}}"
payload dslash "{$repo,\"pull_request\":{\"head\":{\"repo\":{\"full_name\":\"dl9pf-agl//meta-agl\"}}}}"
printf 'not json' > "$t/bad.json"
mkdir "$t/fakebin"; printf '#!/bin/sh\nprintf "1\\ndl9pf-agl/meta-agl\\ndl9pf-agl/meta-agl\\n"\n' > "$t/fakebin/python3"; chmod +x "$t/fakebin/python3"
# the first process of the container: pool trusted, untrusted, or no AGL_POOL at all
printf 'HOME=/x\0AGL_POOL=trusted\0' > "$t/env-trusted"; printf 'HOME=/x\0AGL_POOL=untrusted\0' > "$t/env-untrusted"; printf 'HOME=/x\0' > "$t/env-none"
# expect WANT NAME FIRST-PROCESS-ENV EVENT PAYLOAD [REASON] [EXTRA VAR=value ...]: a refusal must also say the expected reason, so that a
# refusal for the wrong reason (missing tool, bad path) cannot pass for a correct one.
expect() {
  local want="$1" name="$2" penv="$3" ev="$4" file="$5" reason="${6:-}" rc err; shift 6 2>/dev/null || shift $#
  cp "$t/$penv" "$t/environ"
  err="$(env -i PATH="$PATH" ${ev:+GITHUB_EVENT_NAME="$ev"} ${file:+GITHUB_EVENT_PATH="$t/$file.json"} GITHUB_REPOSITORY=dl9pf-agl/meta-agl "$@" bash "$t/hook.sh" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$reason" ] || [[ "$err" == *"$reason"* ]]; }; then echo "ok    $name"; else echo "FAIL  $name (exit $rc, want $want; message: $err)"; fail=1; fi
}
echo "-- the rule"
expect 0 "trusted: same-repo pull_request"             env-trusted pull_request same
expect 0 "trusted: same repo, other letter case"       env-trusted pull_request case
expect 1 "trusted: fork pull_request"                  env-trusted pull_request fork "from fork dl9pf/meta-agl"
expect 1 "trusted: fork pull_request_target"           env-trusted pull_request_target fork "from fork"
expect 1 "trusted: fork pull_request_review"           env-trusted pull_request_review fork "from fork"
expect 1 "trusted: deleted fork (head repo null)"      env-trusted pull_request gone "unknown (deleted fork?)"
expect 1 "trusted: pull_request without head"          env-trusted pull_request nohead "unknown (deleted fork?)"
expect 1 "trusted: pull_request, payload missing"      env-trusted pull_request "" "no readable event payload"
expect 1 "trusted: pull_request, payload not JSON"     env-trusted pull_request bad "cannot be read"
expect 1 "trusted: no event name (fail closed)"        env-trusted "" same "event name is not set"
expect 1 "no AGL_POOL in the first process: fail closed" env-none pull_request fork "from fork"
expect 0 "trusted: push"                               env-trusted push push
expect 0 "trusted: schedule"                           env-trusted schedule sched
expect 0 "trusted: workflow_dispatch"                  env-trusted workflow_dispatch sched
expect 1 "trusted: non-PR event without a payload"     env-trusted push "" "no readable event payload"
expect 0 "untrusted: fork pull_request"                env-untrusted pull_request fork
expect 0 "untrusted: deleted fork"                     env-untrusted pull_request gone
echo "-- payload tricks"
expect 1 "head name with a trailing space"             env-trusted pull_request space "from fork"
expect 1 "head name with a double slash"               env-trusted pull_request dslash "from fork"
echo "-- tampering with the environment of the hook (a workflow might set these)"
expect 1 "AGL_POOL=untrusted in the hook's environment" env-trusted pull_request fork "from fork" AGL_POOL=untrusted
expect 1 "GITHUB_EVENT_NAME=push, payload is a fork PR" env-trusted push fork "from fork"
expect 1 "GITHUB_EVENT_NAME=schedule, payload is a fork PR" env-trusted schedule fork "from fork"
expect 1 "PATH with a fake python3 first"              env-trusted pull_request fork "from fork" PATH="$t/fakebin:$PATH"
expect 1 "GITHUB_REPOSITORY set to the fork, payload without repository" env-trusted pull_request norepo "base repository is unknown" GITHUB_REPOSITORY=dl9pf/meta-agl
expect 1 "BASH_ENV pointing nowhere"                   env-trusted pull_request fork "from fork" BASH_ENV=/nonexistent
exit "$fail"
