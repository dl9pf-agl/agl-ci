#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runner job-started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED, set in the runner image, outside the runner's own directory).
# GitHub runs it before the first step of every job; a non-zero exit fails the job and no step runs.
#
# Rule: a TRUSTED host (AGL_POOL=trusted, or unset: fail closed) refuses every pull request event whose head repository is not the
# repository itself: a fork, or a deleted fork (the head repository is then null). The workflow file of a fork pull request is the
# fork's own, so nothing in the workflow can keep it off the trusted label; this hook can, because it runs on the host side and
# reads the payload that GitHub wrote. An UNTRUSTED host (AGL_POOL=untrusted) accepts everything, it is the place for fork jobs.
# Other events (push, schedule, workflow_dispatch, release) are not affected.
set -u
deny() { echo "agl-hook: job refused: $*" >&2; exit 1; }
[ "${AGL_POOL:-}" != untrusted ] || exit 0
event="${GITHUB_EVENT_NAME:-}"
[ -n "$event" ] || deny "GITHUB_EVENT_NAME is not set, cannot tell what started this job"
case "$event" in
  pull_request*) ;;      # pull_request, pull_request_target, pull_request_review, pull_request_review_comment
  *) exit 0 ;;
esac
payload="${GITHUB_EVENT_PATH:-}"
[ -r "$payload" ] || deny "no event payload for a $event event"
out="$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
h = ((d.get("pull_request") or {}).get("head") or {}).get("repo") or {}
print(h.get("full_name") or "-")
print((d.get("repository") or {}).get("full_name") or "-")' "$payload" 2>/dev/null)" || deny "the event payload of a $event event cannot be read"
head="$(sed -n 1p <<<"$out")"; base="$(sed -n 2p <<<"$out")"
[ "$head" != "-" ] || deny "the head repository of the pull request is unknown (deleted fork?)"
[ "$base" != "-" ] || base="${GITHUB_REPOSITORY:-}"
[ -n "$base" ] || deny "the base repository is unknown"
[ "${head,,}" = "${base,,}" ] || deny "$event from fork $head on a trusted host (base $base); fork jobs run on the untrusted pool"
exit 0
