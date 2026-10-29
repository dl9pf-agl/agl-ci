#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checks docker/runner/job-started.sh with fake payloads. Usage: docker/runner/job-started_test.sh [path-to-hook]   (needs python3)
set -u
hook="${1:-$(dirname "$0")/job-started.sh}"; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; fail=0
payload() { printf '%s' "$2" > "$t/$1.json"; }
payload same  '{"repository":{"full_name":"dl9pf-agl/meta-agl"},"pull_request":{"head":{"repo":{"full_name":"dl9pf-agl/meta-agl"}}}}'
payload case  '{"repository":{"full_name":"dl9pf-agl/meta-agl"},"pull_request":{"head":{"repo":{"full_name":"DL9PF-agl/Meta-Agl"}}}}'
payload fork  '{"repository":{"full_name":"dl9pf-agl/meta-agl"},"pull_request":{"head":{"repo":{"full_name":"dl9pf/meta-agl"}}}}'
payload gone  '{"repository":{"full_name":"dl9pf-agl/meta-agl"},"pull_request":{"head":{"repo":null}}}'
payload nohead '{"repository":{"full_name":"dl9pf-agl/meta-agl"}}'
payload push  '{"repository":{"full_name":"dl9pf-agl/meta-agl"}}'
printf 'not json' > "$t/bad.json"
command -v python3 >/dev/null || { echo "python3 is needed" >&2; exit 2; }
# expect EXPECTED_RC NAME POOL EVENT PAYLOAD-FILE-OR-EMPTY [REASON]: a refusal must also say the expected reason, so that a refusal
# for the wrong reason (missing tool, bad path) cannot pass for a correct one.
expect() {
  local want="$1" name="$2" pool="$3" ev="$4" file="$5" reason="${6:-}" rc err
  err="$(env -i PATH="$PATH" ${pool:+AGL_POOL="$pool"} ${ev:+GITHUB_EVENT_NAME="$ev"} ${file:+GITHUB_EVENT_PATH="$t/$file.json"} GITHUB_REPOSITORY=dl9pf-agl/meta-agl bash "$hook" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$reason" ] || [[ "$err" == *"$reason"* ]]; }; then echo "ok    $name"; else echo "FAIL  $name (exit $rc, want $want; message: $err)"; fail=1; fi
}
expect 0 "trusted: same-repo pull_request"            trusted pull_request same
expect 0 "trusted: same repo, other letter case"      trusted pull_request case
expect 1 "trusted: fork pull_request"                 trusted pull_request fork "from fork dl9pf/meta-agl"
expect 1 "trusted: fork pull_request_target"          trusted pull_request_target fork "from fork"
expect 1 "trusted: fork pull_request_review"          trusted pull_request_review fork "from fork"
expect 1 "trusted: deleted fork (head repo null)"     trusted pull_request gone "unknown (deleted fork?)"
expect 1 "trusted: pull_request without head"         trusted pull_request nohead "unknown (deleted fork?)"
expect 1 "trusted: pull_request, payload missing"     trusted pull_request "" "no event payload"
expect 1 "trusted: pull_request, payload not JSON"    trusted pull_request bad "cannot be read"
expect 1 "trusted: no event name (fail closed)"       trusted "" same "GITHUB_EVENT_NAME is not set"
expect 1 "pool unset: fork pull_request (fail closed)" "" pull_request fork "from fork"
expect 0 "trusted: push"                              trusted push push
expect 0 "trusted: schedule"                          trusted schedule ""
expect 0 "trusted: workflow_dispatch"                 trusted workflow_dispatch ""
expect 0 "untrusted: fork pull_request"               untrusted pull_request fork
expect 0 "untrusted: deleted fork"                    untrusted pull_request gone
exit "$fail"
