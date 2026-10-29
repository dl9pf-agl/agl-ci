#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runner job-started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED, set in the runner image, outside the runner's own directory).
# GitHub runs it before the first step of every job; a non-zero exit fails the job and no step runs.
#
# Rule: a TRUSTED host (pool trusted, or not known: fail closed) refuses every pull request whose head repository is not the
# repository itself: a fork, or a deleted fork (the head repository is then null). The workflow file of a fork pull request is the
# fork's own, so nothing in the workflow can keep it off the trusted label; this hook can, because it runs on the host side and
# reads the payload that GitHub wrote. An UNTRUSTED host accepts everything, it is the place for fork jobs.
#
# Hardening against a workflow that can put values into this hook's environment (not known whether GitHub does):
#  - the pool is read from the environment of the container's FIRST process (docker run -e AGL_POOL, see kit/run-loop.sh), which
#    a workflow cannot change; the AGL_POOL of this hook's own environment is ignored;
#  - a pull request is recognised by its payload (it has a pull_request object), not only by GITHUB_EVENT_NAME;
#  - the base repository is the one in the payload, there is no fallback to GITHUB_REPOSITORY;
#  - the tool path is fixed, and a readable payload is required for every job on a trusted host (fail closed).
# What it cannot stop: a pre-existing file in the image used through GITHUB_EVENT_PATH or BASH_ENV; the container is single-use and
# a workflow cannot create files before the job starts, and the image has no file that would help.
set -u
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
deny() { echo "agl-hook: job refused: $*" >&2; exit 1; }
pool="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^AGL_POOL=//p' | head -n 1)"
[ "$pool" != untrusted ] || exit 0
event="${GITHUB_EVENT_NAME:-}"
payload="${GITHUB_EVENT_PATH:-}"
[ -r "$payload" ] || deny "no readable event payload (event '$event')"
out="$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
h = ((d.get("pull_request") or {}).get("head") or {}).get("repo") or {}
print("1" if "pull_request" in d else "0")
print(h.get("full_name") or "-")
print((d.get("repository") or {}).get("full_name") or "-")' "$payload" 2>/dev/null)" || deny "the event payload of a '$event' event cannot be read"
is_pr="$(sed -n 1p <<<"$out")"; head="$(sed -n 2p <<<"$out")"; base="$(sed -n 3p <<<"$out")"
case "$event" in
  pull_request*) is_pr=1 ;;   # pull_request, pull_request_target, pull_request_review, pull_request_review_comment
  "") deny "the event name is not set, cannot tell what started this job" ;;
esac
[ "$is_pr" = 1 ] || exit 0
[ "$head" != "-" ] || deny "the head repository of the pull request is unknown (deleted fork?)"
[ "$base" != "-" ] || deny "the base repository is unknown"
[ "${head,,}" = "${base,,}" ] || deny "pull request from fork $head on a trusted host (base $base, event '$event'); fork jobs run on the untrusted pool"
exit 0
