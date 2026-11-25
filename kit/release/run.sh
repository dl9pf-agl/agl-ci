#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# What the cron of the DOWNLOAD SERVER runs (kit/release/agl-release.cron): pull, update agl-ucb, promote. With "cleanup": the daily
# removal of promoted staging copies. With "nightly": pull nightly builds only (never signed, never promoted - the pull IS the
# publish). With "nightly cleanup": the daily removal of nightly directories older than NIGHTLY_KEEP_DAYS. The settings come from
# /etc/agl-release/promote.env (kit/release/promote.env.example). Output goes to /var/log/agl-release.log (RELEASE_LOG), so the
# cron lines stay short.
#   kit/release/run.sh                     every 5 minutes
#   kit/release/run.sh cleanup             daily
#   kit/release/run.sh nightly             every 5 minutes
#   kit/release/run.sh nightly cleanup     daily
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=/dev/null
. "${RELEASE_ENV:-/etc/agl-release/promote.env}"
exec >> "${RELEASE_LOG:-/var/log/agl-release.log}" 2>&1
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) run.sh ${1:-} ${2:-}"
if [ "${1:-}" = cleanup ]; then exec "$here/cleanup-staging.sh"; fi
if [ "${1:-}" = nightly ] && [ "${2:-}" = cleanup ]; then exec "$here/cleanup-nightly.sh"; fi
if [ "${1:-}" = nightly ]; then
  # Just the pull: a nightly is never signed, so there is no promote step - the pull itself is the publish.
  touch "$RELEASE_ROOT/nightly-done.txt"
  exec env AREAS=nightly SOURCES="$BUILD_RSYNC" RSYNC_EXTRA="--exclude-from=$RELEASE_ROOT/nightly-done.txt" MIRROR_ROOT="$RELEASE_ROOT" "$here/../mirror/pull-sync.sh"
fi
[ -z "${1:-}" ] || { echo "usage: run.sh [cleanup|nightly|nightly cleanup]" >&2; exit 1; }
# 1. the exclude file of the pull must exist (cleanup-staging.sh fills it)
touch "$RELEASE_ROOT/release-done.txt"
# 2. pull the staging area of the build host; releases that were cleaned up are excluded and not fetched again
AREAS=staging SOURCES="$BUILD_RSYNC" RSYNC_EXTRA="--exclude-from=$RELEASE_ROOT/release-done.txt" MIRROR_ROOT="$RELEASE_ROOT" "$here/../mirror/pull-sync.sh"
# 3. the engineers' signatures are commits in agl-ucb
git -C "$RELEASE_UCB_DIR" pull -q --ff-only
# 4. verify and promote
exec "$here/promote.sh"
