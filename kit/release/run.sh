#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# What the cron of the DOWNLOAD SERVER runs (kit/server.cron): pull, update agl-ucb, promote. With "cleanup": the daily
# removal of promoted staging copies. With "nightly": pull nightly builds only (never signed, never promoted - the pull IS the
# publish). With "nightly cleanup": the daily removal of nightly directories older than NIGHTLY_KEEP_DAYS. The settings come from
# /etc/agl-release/promote.env (kit/release/promote.env.example). Output goes to /var/log/agl-release.log (RELEASE_LOG), so the
# cron lines stay short.
#   kit/release/run.sh                     every 5 minutes
#   kit/release/run.sh cleanup             daily
#   kit/release/run.sh nightly             every 5 minutes
#   kit/release/run.sh nightly cleanup     daily
#   kit/release/run.sh mirror              every 5 minutes: pull dl, sstate and git of the build hosts (kit/mirror/pull-sync.sh)
#   kit/release/run.sh git                 every 30 minutes: refresh the git mirrors (kit/mirror/git-refresh.sh)
# The last two log to /var/log/agl-mirror.log (MIRROR_LOG), the others to /var/log/agl-release.log (RELEASE_LOG).
set -euo pipefail

# cron starts with PATH=/usr/bin:/bin; cosign is usually installed in /usr/local/bin
PATH="/usr/local/sbin:/usr/local/bin:$PATH"; export PATH

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=/dev/null
. "${RELEASE_ENV:-/etc/agl-release/promote.env}"
log="${RELEASE_LOG:-/var/log/agl-release.log}"
case "${1:-}" in mirror|git) log="${MIRROR_LOG:-/var/log/agl-mirror.log}" ;; esac
exec >> "$log" 2>&1
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) run.sh ${1:-} ${2:-}"
# the two jobs of the mirror tree: no promotion, no exclude files (dl, sstate and git are content addressed)
if [ "${1:-}" = mirror ]; then exec env SOURCES="$BUILD_RSYNC" MIRROR_ROOT="$RELEASE_ROOT" "$here/../mirror/pull-sync.sh"; fi
if [ "${1:-}" = git ]; then exec env MIRROR_ROOT="$RELEASE_ROOT" "$here/../mirror/git-refresh.sh"; fi
if [ "${1:-}" = cleanup ]; then exec "$here/cleanup-staging.sh"; fi
if [ "${1:-}" = nightly ] && [ "${2:-}" = cleanup ]; then exec "$here/cleanup-nightly.sh"; fi
if [ "${1:-}" = nightly ]; then
  # Just the pull: a nightly is never signed, so there is no promote step - the pull itself is the publish.
  touch "$RELEASE_ROOT/nightly-done.txt"
  exec env AREAS=nightly SOURCES="$BUILD_RSYNC" RSYNC_EXTRA="--exclude-from=$RELEASE_ROOT/nightly-done.txt" MIRROR_ROOT="$RELEASE_ROOT" "$here/../mirror/pull-sync.sh"
fi
[ -z "${1:-}" ] || { echo "usage: run.sh [cleanup|nightly|nightly cleanup|mirror|git]" >&2; exit 1; }
# 1. the exclude file of the pull must exist (cleanup-staging.sh fills it)
touch "$RELEASE_ROOT/release-done.txt"
# 2. pull the staging area of the build host; releases that were cleaned up are excluded and not fetched again
AREAS=staging SOURCES="$BUILD_RSYNC" RSYNC_EXTRA="--exclude-from=$RELEASE_ROOT/release-done.txt" MIRROR_ROOT="$RELEASE_ROOT" "$here/../mirror/pull-sync.sh"
# 3. the engineers' signatures are commits in agl-ucb
git -C "$RELEASE_UCB_DIR" pull -q --ff-only
# 4. verify and promote
exec "$here/promote.sh"
